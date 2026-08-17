# Flow — `SyncWorkspaceWithGit`

Build instructions for stage 2 of the connect wizard: it moves content between a Fabric workspace and its already-connected Azure DevOps repo, in the direction Fabric asks for or the direction the owner chose. Runs as the broker, called by the canvas app after `ConnectWorkspaceToGit` has probed.

Verified against `Workflows/SyncWorkspaceWithGit-93D7AF32-BC94-F111-8075-000D3ABA40DB.json` on 2026-08-17.

Related: [../FLOWS.md](../FLOWS.md) §8 (design rationale), [../PREREQUISITES.md](../PREREQUISITES.md) (A3, B1, D1, E3, E4), [../OPEN-ISSUES.md](../OPEN-ISSUES.md) §1.1, §1.2, §1.8, §1.10, §1.13, §10.3.

---

## 0. Before you start

- Create the flow **inside the solution**, so it binds to connection references rather than raw connections.
- **No connector connection is needed.** The flow uses only built-in actions: `Run a Child Flow`, `Initialize variable`, `Set variable`, `HTTP`, `Condition`, `Switch`, `Respond to a Power App or flow`.
- The child flow **`GetFabricToken`** must already exist. It is referenced by GUID: `50895fca-088f-f111-8076-7ced8d76bf1b` → `Workflows/GetFabricToken-50895FCA-088F-F111-8076-7CED8D76BF1B.json`.
- Authentication is **service principal**, not delegated. `GetFabricToken` runs the client-credentials grant as the broker SPN; every Fabric call here carries that bearer token in a hand-written header.
- The workspace must **already be connected**. This flow never calls `git/connect`; calling it on an unconnected workspace fails at `git/status`. That separation is why this is a flow of its own rather than a branch inside `ConnectWorkspaceToGit`.
- Environment variables are **not referenced directly by this flow**. They are consumed by the child flow:

  | Variable | Default in the solution | Used by |
  |---|---|---|
  | `ab_TenantId` | `9e929790-272d-4977-a2ab-301443c11ece` | `GetFabricToken` (token endpoint) |
  | `ab_BrokerClientId` | `a385fde9-1d6a-4e7f-8336-dc7feba5a4bc` | `GetFabricToken` (client id) |
  | `ab_BrokerObjectId` | `6f70a764-908f-435b-a930-ffcb375577f3` | *not used by this flow* |

  The broker **client secret** lives inside `GetFabricToken` as an `Initialize variable`, is scrubbed on export, and must be re-entered per environment (PREREQUISITES E4). Never commit it.

Actions are listed in execution order. Build them in that order — inserting an action later re-parents its successor and silently creates a parallel branch.

> **JSON key order is not execution order in this export.** `Initialize_variable_outcome`, `Initialize_variable_message`, `Initialize_variable_allowOverride`, `Set_action_final` and `Respond_to_a_Power_App_or_flow` are all keyed *after* `act_on_action` yet several of them run before it. Follow `runAfter`.

> **Ordering is load-bearing.** `Get_git_status` must stay after `Condition_needs_strategy`: status requires an initialized connection, so on a `NeedsChoice` workspace it only works once initialize has run.

---

## 1. Trigger — Power Apps (V2)

| Field | Value |
|---|---|
| Type | `Request` |
| Kind | `PowerAppV2` |
| Action name | `manual` |

Three text inputs, all `x-ms-content-hint: TEXT`, all with the designer default description `Please enter your input`, and **all three required**:

| # | Input title | Schema key | Type | Required | Raw reference |
|---|---|---|---|---|---|
| 1 | `workspaceId` | `text` | string | Yes | `@triggerBody()['text']` |
| 2 | `requiredAction` | `text_1` | string | Yes | `@triggerBody()?['text_1']` |
| 3 | `initializationStrategy` | `text_2` | string | Yes | `@triggerBody()?['text_2']` |

`text_1` carries the `requiredAction` that `ConnectWorkspaceToGit` (or `GetGitOperationStatus`) reported. `text_2` carries the owner's choice — `PreferRemote` or `PreferWorkspace` — and is blank when Fabric already named a direction.

`initializationStrategy` was made **required on 2026-08-12** and must stay required. As an optional input the calling app dropped it from the payload entirely: the key was absent from the trigger outputs, `Condition_needs_strategy` evaluated false, initialization never ran, and the owner's `PreferRemote` choice had no effect. A missing optional input is indistinguishable in run history from one that was never wired. Required means a blank now arrives as `text_2: ""` and is visible.

Every reference to `text_1` and `text_2` uses the safe `?[...]` form wrapped in `coalesce(…, '')`, which is what lets the flow treat a blank strategy as "no strategy" rather than throwing.

> The flow takes `workspaceId` at face value. There is no ownership check, so it will sync any workspace the broker administers for any caller who can run it. Deferred by decision — OPEN-ISSUES §10.3.

---

## 2. `Run_a_Child_Flow` — Workflow

First action; `runAfter` is empty.

| Field | Value |
|---|---|
| Type | `Workflow` |
| `host.workflowReferenceName` | `50895fca-088f-f111-8076-7ced8d76bf1b` |
| Inputs | none |

That GUID is `GetFabricToken`. It takes no parameters and returns `access_token`.

---

## 3. Variables

Six **Initialize variable** actions, each chained on **Succeeded** from the previous one, in this exact order:

| Order | Action name | Variable | Type | Initial value |
|---|---|---|---|---|
| 1 | `Initialize_variable_accessToken` | `accessToken` | String | `@body('Run_a_Child_Flow')?['access_token']` |
| 2 | `Initialize_variable_action` | `action` | String | *(no value key)* |
| 3 | `Initialize_variable_operationId` | `operationId` | String | *(no value key)* |
| 4 | `Initialize_variable_outcome` | `outcome` | String | `Failed` |
| 5 | `Initialize_variable_message` | `message` | String | *(no value key)* |
| 6 | `Initialize_variable_allowOverride` | `allowOverride` | **Boolean** | `@equals(triggerBody()?['text_2'],'PreferRemote')` |

`allowOverride` is the only non-string variable in the flow, and it is safe because it never reaches the Respond — it is rendered into a request body via `if(variables('allowOverride'),'true','false')`. Note its value uses the bare `@expr` form, not `@{ }`; braces here would produce the string `"True"` and break the `Initialize variable` type check.

`outcome` is seeded `Failed`, so any path reaching the Respond without setting it explicitly reports failure rather than a blank.

`accessToken` holds a bearer token with tenant-wide Fabric rights. It is deliberately never a trigger input and never returned to the app.

---

## 4. `Condition_needs_strategy` — If

Runs after `Initialize_variable_allowOverride` on **Succeeded**.

Expression, verbatim:

```json
"expression": {
  "equals": [
    "@not(empty(coalesce(triggerBody()?['text_2'],'')))",
    "@true"
  ]
}
```

True when the owner supplied a strategy. **There is no `else` key in the export** — the false branch is genuinely empty, and building it that way is correct: with no strategy, initialization was already done by `ConnectWorkspaceToGit` and the caller's `requiredAction` is trusted.

### 4.1 True branch — `Initialize_with_strategy` (HTTP)

`runAfter` empty (only action in the branch).

| Field | Value |
|---|---|
| Method | `POST` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}/git/initializeConnection` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Header `Content-Type` | `application/json` |
| Body | `{ "initializationStrategy": "@{triggerBody()['text_2']}" }` |
| `operationOptions` | *(absent — Asynchronous Pattern stays **On**)* |
| Authentication block | none — bearer token supplied by hand in the header |

Asynchronous Pattern is deliberately left On here, unlike the two sync calls in §6. `initializeConnection` does not move data — it records a direction — so it resolves inline, and the normal `200` path yields `requiredAction` directly.

`initializeConnection` is **not idempotent**. Any re-run against an already-initialized workspace returns `409 WorkspaceGitConnectionAlreadyInitialized`, and §5 depends on that.

---

## 5. `Get_git_status` — HTTP

Runs after `Condition_needs_strategy` on **Succeeded or Failed**.

| Field | Value |
|---|---|
| Method | `GET` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}/git/status` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Header `Accept` | `application/json` |
| Body | none |
| Authentication block | none — bearer token supplied by hand in the header |

The **Failed** leg is required. A `409` from initialize is the expected result of any re-run and must not stop the flow.

Supplies `workspaceHead`, `remoteCommitHash` and `changes` to everything downstream.

---

## 6. `Set_action_final` — Set variable

Runs after `Get_git_status` on **Succeeded or Failed**.

| Field | Value |
|---|---|
| Name | `action` |

```
@{if(empty(coalesce(triggerBody()?['text_2'],'')),coalesce(triggerBody()?['text_1'],'None'),if(equals(coalesce(outputs('Initialize_with_strategy')?['statusCode'],0),409),if(empty(coalesce(body('Get_git_status')?['changes'],json('[]'))),'None',if(equals(triggerBody()?['text_2'],'PreferRemote'),'UpdateFromGit','CommitToGit')),if(less(coalesce(outputs('Initialize_with_strategy')?['statusCode'],0),300),coalesce(body('Initialize_with_strategy')?['requiredAction'],if(empty(coalesce(body('Get_git_status')?['changes'],json('[]'))),'None',if(equals(triggerBody()?['text_2'],'PreferRemote'),'UpdateFromGit','CommitToGit'))),'InitFailed')))}
```

Decoded:

| Situation | Result |
|---|---|
| No strategy passed (`text_2` blank) | the caller's `text_1`, defaulting to `None` |
| Initialize returned `409`, `changes` empty | `None` |
| Initialize returned `409`, changes pending | `UpdateFromGit` if strategy is `PreferRemote`, else `CommitToGit` |
| Initialize returned < 300 and its body carries `requiredAction` | that value |
| Initialize returned < 300 with no `requiredAction` (the `202` case) | derived from `git/status` `changes` exactly as the `409` rows |
| Any other initialize status | `InitFailed` |

Reading `git/status` on the `409` rows rather than mapping the strategy blindly is what stops a re-run from firing a pointless sync.

Every reference to `Initialize_with_strategy` is guarded with `coalesce(..., 0)`. Logic Apps evaluates function arguments eagerly, so the expression touches that action even on the no-strategy path where it never ran.

The **Failed** leg on `Get_git_status` matters: status fails when initialize failed and left the connection uninitialized. Without it, the Switch and the Response are skipped, and *Skipped* satisfies neither run-after condition — the flow would end with no answer at all and the app would see a hard error instead of `outcome: Failed`.

---

## 7. `act_on_action` — Switch

Runs after `Set_action_final` on **Succeeded**.

| Field | Value |
|---|---|
| Type | `Switch` |
| On | `@variables('action')` |
| Cases | `CommitToGit`, `UpdateFromGit`, `InitFailed` |
| Default | present |

### 7.1 Case `CommitToGit`

Four actions in a chain.

**`CommitToGit` — HTTP.** `runAfter` empty.

| Field | Value |
|---|---|
| Method | `POST` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}/git/commitToGit` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Header `Content-Type` | `application/json` |
| `operationOptions` | `DisableAsyncPattern` |
| Authentication block | none — bearer token supplied by hand in the header |

Body — a single expression, not a JSON object:

```
@json(concat('{"mode":"All","comment":"Sync from Fabric workspace"', if(empty(coalesce(body('Get_git_status')?['workspaceHead'],'')), '', concat(',"workspaceHead":"', body('Get_git_status')?['workspaceHead'], '"')), '}'))
```

Built with `json(concat(...))` because `workspaceHead` must be **present or absent**, never empty. `@{ }` interpolation renders a null as `""`, and `""` is not a valid SHA.

`DisableAsyncPattern` is required: the API always returns `202`, and with the default setting the connector would poll to completion, swallow the operation ID, and on a large workspace blow the 120-second response budget.

**`Set_operationId_commit` — Set variable.** Runs after `CommitToGit` on **Succeeded or Failed**.

| Field | Value |
|---|---|
| Name | `operationId` |

```
@{coalesce(outputs('CommitToGit')?['headers']?['x-ms-operation-id'], outputs('CommitToGit')?['headers']?['X-Ms-Operation-Id'], last(split(coalesce(outputs('CommitToGit')?['headers']?['Location'],''),'/')), '')}
```

**`Set_outcome_commit` — Set variable.** Runs after `Set_operationId_commit` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `outcome` |

```
@{if(equals(outputs('CommitToGit')['statusCode'],202),'Started',
 if(less(outputs('CommitToGit')['statusCode'],300),'Completed','Failed'))}
```

The literal newline and leading space before the inner `if` are in the export; they are cosmetic.

**`Set_message_commit` — Set variable.** Runs after `Set_outcome_commit` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `message` |

```
@{if(equals(outputs('CommitToGit')['statusCode'],202),'Commit started.',
 if(less(outputs('CommitToGit')['statusCode'],300),'Workspace committed to Git.',string(body('CommitToGit'))))}
```

### 7.2 Case `UpdateFromGit`

Four actions in a chain, mirroring 7.1.

**`Update_from_git` — HTTP.** `runAfter` empty.

| Field | Value |
|---|---|
| Method | `POST` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}/git/updateFromGit` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Header `Content-Type` | `application/json` |
| `operationOptions` | `DisableAsyncPattern` |
| Authentication block | none — bearer token supplied by hand in the header |

Body:

```
@json(concat('{', if(empty(coalesce(body('Get_git_status')?['workspaceHead'],'')), '', concat('"workspaceHead":"', body('Get_git_status')?['workspaceHead'], '",')), '"remoteCommitHash":"', body('Get_git_status')?['remoteCommitHash'], '","conflictResolution":{"conflictResolutionType":"Workspace","conflictResolutionPolicy":"', if(empty(coalesce(triggerBody()?['text_2'],'')),'PreferRemote',triggerBody()?['text_2']), '"},"options":{"allowOverrideItems":', if(variables('allowOverride'),'true','false'), '}}'))
```

`allowOverrideItems` is emitted **unquoted** — `true` / `false` as a JSON boolean, not `"true"`. That is the point of building the body through `concat` and then `json(...)`.

`conflictResolutionPolicy` comes from the owner's strategy and falls back to `PreferRemote` when none was passed. `conflictResolutionType` is fixed at `Workspace`.

`workspaceHead` is conditionally omitted, `remoteCommitHash` is not — it is interpolated directly from `git/status`. That is deliberate: this branch is only reachable when the remote branch has commits, so the hash is always populated. OPEN-ISSUES §1.8 records the run where it was not, and the root cause was branch selection, not this expression.

**`Set_operationId_update` — Set variable.** Runs after `Update_from_git` on **Succeeded or Failed**.

| Field | Value |
|---|---|
| Name | `operationId` |

```
@{coalesce(outputs('Update_from_git')?['headers']?['x-ms-operation-id'], outputs('Update_from_git')?['headers']?['X-Ms-Operation-Id'], last(split(coalesce(outputs('Update_from_git')?['headers']?['Location'],''),'/')), '')}
```

**`Set_outcome_update` — Set variable.** Runs after `Set_operationId_update` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `outcome` |

```
@{if(equals(outputs('Update_from_git')['statusCode'],202),'Started',if(less(outputs('Update_from_git')['statusCode'],300),'Completed','Failed'))}
```

**`Set_message_update` — Set variable.** Runs after `Set_outcome_update` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `message` |

```
@{if(equals(outputs('Update_from_git')['statusCode'],202),'Update started.',if(less(outputs('Update_from_git')['statusCode'],300),'Workspace updated from Git.',string(body('Update_from_git'))))}
```

### 7.3 Case `InitFailed`

Two **Set variable** actions, chained on **Succeeded**:

| Order | Action name | Name | Value |
|---|---|---|---|
| 1 | `Set_outcome_initfailed` | `outcome` | `Failed` |
| 2 | `Set_message_initfailed` | `message` | `@{string(body('Initialize_with_strategy'))}` |

The raw Fabric payload reaches the app as text — this is where `MissingInitializationStrategy` surfaces.

### 7.4 Default — nothing to do

Two **Set variable** actions, chained on **Succeeded**. Note the first action's key is lowercase in the export.

| Order | Action name | Name | Value |
|---|---|---|---|
| 1 | `set_outcome_nothing` | `outcome` | `NothingToDo` |
| 2 | `Set_message_nothing` | `message` | `Workspace and repository are already in sync.` |

Reached when `action` resolves to `None` — the `409`-with-no-changes case, or a caller that passed `None`.

---

## Response contract

`Respond_to_a_Power_App_or_flow` — type `Response`, kind `PowerApp`, `statusCode` 200. Runs after `act_on_action` on **Succeeded or Failed**.

| Output name (as exported) | Title | Type | Value |
|---|---|---|---|
| `outcome` | `outcome` | string | `@variables('outcome')` |
| `operationid` | `operationId` | string | `@variables('operationId')` |
| `requiredaction` | `requiredAction` | string | `@variables('action')` |
| `message` | `message` | string | `@variables('message')` |

Keep every Respond field typed **string**. The designer wraps a single expression in `@{ }`, which stringifies it, so a field declared boolean or number returns `"true"` / `"7"` and fails schema validation — and one bad field makes every output of the flow unreadable in the app, not just the bad one. All four here are correctly string, and all four bind `@variables(...)` rather than an inline `@{ }` expression. Note `requiredaction` is fed by the variable named `action`, not by a variable of the same name.

Output names come back **lowercased** in Power Fx — bind to `outcome`, `operationid`, `requiredaction`, `message`.

`outcome` values:

| `outcome` | Meaning |
|---|---|
| `Started` | `202` — poll `operationid` with `GetGitOperationStatus` |
| `Completed` | other 2xx — nothing to poll |
| `NothingToDo` | already in sync |
| `Failed` | Fabric rejected the call, or initialize failed; the raw payload is in `message` |

`Set_operationId_*` and the Respond all run after **Succeeded or Failed**, so a Fabric error is reported as data rather than failing the run — the run itself shows Succeeded and the app gets a readable message.

---

## After building

- Add the flow to the canvas app (left rail → Power Automate → **+ Add flow**). Watch for a suffixed duplicate such as `SyncWorkspaceWithGit_1` from adding it twice.
- If you change the trigger inputs later, **remove and re-add the flow in the app** — Power Apps caches the signature at bind time. This is exactly what the 2026-08-12 change to `initializationStrategy` required.
- Renaming the flow does not change the name Power Fx binds to. Trust formula-bar autocomplete over the portal display name.
- Pass the inputs **positionally**, in trigger order: `SyncWorkspaceWithGit.Run(workspaceId, requiredAction, initializationStrategy)`. Do **not** use a trailing options record — that form is what silently dropped the strategy before it was made required.
- The flow answers a PowerApp, so it must respond within **120 seconds**. `DisableAsyncPattern` on both sync calls is what keeps it inside that budget: the flow returns the operation ID and lets `GetGitOperationStatus` do the waiting.
