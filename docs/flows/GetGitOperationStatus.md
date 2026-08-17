# Flow — `GetGitOperationStatus`

Build instructions for the single-shot, read-only flow that reports the state of a Fabric long-running operation. It is what the canvas app's Refresh button calls after `ConnectWorkspaceToGit` or `SyncWorkspaceWithGit` hands back an operation ID. It reads and answers; it advances nothing.

Verified against `Workflows/GetGitOperationStatus-5AFCD720-158F-F111-8076-7CED8D76BF1B.json` on 2026-08-17.

Related: [../FLOWS.md](../FLOWS.md) §2 (design rationale), [../PREREQUISITES.md](../PREREQUISITES.md) (A1, A3, B1, E4), [../OPEN-ISSUES.md](../OPEN-ISSUES.md) §1.13, §6.1, §6.2, §10.5, [GetFabricToken.md](GetFabricToken.md) (the child flow it calls), [SyncWorkspaceWithGit.md](SyncWorkspaceWithGit.md) and [ConnectWorkspaceToGit.md](ConnectWorkspaceToGit.md) (the flows that produce the operation IDs).

---

## 0. Before you start

- Create the flow **inside the solution**, so it binds to connection references rather than raw connections.
- **No connector connection is needed.** The flow uses only built-in actions: `Run a Child Flow`, `Initialize variable`, `HTTP`, `Condition`, `Set variable`, `Respond to a Power App or flow`. `connectionReferences` in the export is `{}`.
- The child flow **`GetFabricToken`** must already exist. It is referenced by GUID: `50895fca-088f-f111-8076-7ced8d76bf1b` → `Workflows/GetFabricToken-50895FCA-088F-F111-8076-7CED8D76BF1B.json`.
- Authentication is **service principal**, not delegated. `GetFabricToken` runs the client-credentials grant as the broker SPN; both Fabric calls here carry that bearer token in a hand-written header.
- Environment variables are **not referenced directly by this flow**. They are consumed by the child flow:

  | Variable | Default in the solution | Used by |
  |---|---|---|
  | `ab_TenantId` | `9e929790-272d-4977-a2ab-301443c11ece` | `GetFabricToken` (token endpoint) |
  | `ab_BrokerClientId` | `a385fde9-1d6a-4e7f-8336-dc7feba5a4bc` | `GetFabricToken` (client id) |
  | `ab_BrokerObjectId` | `6f70a764-908f-435b-a930-ffcb375577f3` | *not used by this flow* |

  The broker **client secret** lives inside `GetFabricToken`, is scrubbed on export, and must be re-entered per environment (PREREQUISITES E4). Never commit it.

- **There is no loop.** One `GET`, no `Delay`, no `Do_until`. The looping ancestor `PollFabricOperation` was renamed and rewritten in place on 2026-08-07, which is why the flow GUID and its connection references survive the rename — and why the canvas app still binds to the old name (see *After building*).

Actions are listed in execution order. Build them in that order — inserting an action later re-parents its successor and silently creates a parallel branch.

> **JSON key order is not execution order in this export.** `Respond_to_a_Power_App_or_flow` is the **first** key in `actions` and the **last** action to run. Follow `runAfter`.

---

## 1. Trigger — Power Apps (V2)

| Field | Value |
|---|---|
| Type | `Request` |
| Kind | `PowerAppV2` |
| Action name | `manual` |

One text input, `x-ms-content-hint: TEXT`, with the designer default description `Please enter your input`, **required**:

| # | Input title | Schema key | Type | Required | Raw reference |
|---|---|---|---|---|---|
| 1 | `operationId` | `text` | string | Yes | `@triggerBody()['text']` |

The underlying key is `text`; `operationId` is only the display title. Harmless with a single input — but if a second is ever added, rename deliberately first: `text`, `text_1`, `text_2` bind **positionally** and are trivial to cross-wire.

The input is required, and must stay required. An optional PowerApp V2 input is **dropped from the payload entirely** when blank — the property is absent rather than empty, `triggerBody()['text']` then throws `InvalidTemplate: property 'text' doesn't exist`, and a missing optional input is indistinguishable in run history from one that was never wired.

Note the flow reads `@triggerBody()['text']` in the **unsafe** form, without `?[...]`. That is correct precisely because the input is required.

`accessToken` is deliberately **not** a trigger input. Passing one would put an SPN credential with tenant-wide Fabric rights inside the canvas app, recoverable by anyone who can open it.

---

## 2. `Run_a_Child_Flow` — Workflow

First action; `runAfter` is empty.

| Field | Value |
|---|---|
| Type | `Workflow` |
| `host.workflowReferenceName` | `50895fca-088f-f111-8076-7ced8d76bf1b` |
| Inputs | none |

That GUID is `GetFabricToken`. It takes no parameters and returns `access_token`.

Unlike most callers, this flow does **not** copy the token into an `accessToken` variable. Both HTTP actions read `body('Run_a_Child_Flow')?['access_token']` directly.

---

## 3. Variables

Two **Initialize variable** actions, chained on **Succeeded**:

| Order | Action name | Variable | Type | Initial value |
|---|---|---|---|---|
| 1 | `Initialize_variable_requiredAction` | `requiredAction` | String | *(no `value` key — starts empty)* |
| 2 | `Initialize_variable_remoteCommitHash` | `remoteCommitHash` | String | *(no `value` key — starts empty)* |

`Initialize_variable_requiredAction` runs after `Run_a_Child_Flow` on **Succeeded**; `Initialize_variable_remoteCommitHash` runs after it on **Succeeded**.

Both are declared with **no `value` property** rather than an empty string. That is deliberate — the same shape as the fixed `cont` in `ListGateways`, which once initialised to backticks and sent them on the wire.

They are initialised here, outside the `Condition`, because the Respond reads them unconditionally. A variable initialised inside a branch that did not run is unreadable, and every field of the response would fail with it.

---

## 4. `Get_operation_state` — HTTP

Runs after `Initialize_variable_remoteCommitHash` on **Succeeded**.

| Field | Value |
|---|---|
| Method | `GET` |
| URI | `https://api.fabric.microsoft.com/v1/operations/@{triggerBody()['text']}` |
| Header `Authorization` | `Bearer @{body('Run_a_Child_Flow')?['access_token']}` |
| Header `Accept` | `application/json` |
| Body | none |
| Authentication block | none — bearer token supplied by hand in the header |

Retry policy, set **explicitly** rather than left on the default:

```json
"retryPolicy": {
  "type": "exponential",
  "count": 4,
  "interval": "PT10S"
}
```

This is the one call the UI hits repeatedly, so a throttled `429` is the retry policy's job rather than a branch in the flow. That is why F2.3 — "tolerate a 429 inside the polling loop" — is closed as superseded: there is no loop left to protect.

Returns **state only**: `status`, `percentComplete`, `error`. The payload of the operation is not here.

---

## 5. `Condition` — If

Runs after `Get_operation_state` on **Succeeded**, **Failed** *and* **TimedOut**.

Expression, verbatim:

```json
"expression": {
  "equals": [
    "@coalesce(body('Get_operation_state')?['status'], '')",
    "Succeeded"
  ]
}
```

The three-way `runAfter` is what keeps the flow answering when Fabric does not. A failed or timed-out state call still reaches the Respond, which reports `Unavailable` rather than ending the run with no output. *Skipped* satisfies neither `Succeeded` nor `Failed`, so omitting the extra legs here would strand the response.

The `coalesce(…, '')` guard matters: Logic Apps evaluates function arguments eagerly, so on the failed leg `body('Get_operation_state')` may carry no `status` at all.

### 5.1 True branch — `Succeeded`

Three actions in a chain.

**`Get_operation_result` — HTTP.** `runAfter` empty (first in the branch).

| Field | Value |
|---|---|
| Method | `GET` |
| URI | `https://api.fabric.microsoft.com/v1/operations/@{triggerBody()['text']}/result` |
| Header `Authorization` | `Bearer @{body('Run_a_Child_Flow')?['access_token']}` |
| Header `Accept` | `application/json` |
| Body | none |
| `retryPolicy` | *(absent — default exponential, 4 retries)* |
| Authentication block | none — bearer token supplied by hand in the header |

**Why `/result` is here.** `GET /v1/operations/{id}` returns state; the payload comes from this separate call. For `commitToGit` and `updateFromGit` it 404s and is ignored — success or failure is the whole answer. It exists for the one case stage 1 cannot answer synchronously: when `initializeConnection` returns **202** the body is empty, and `/result` is the only source of `requiredAction` and `remoteCommitHash`. `remoteCommitHash` is a required field of `updateFromGit`, so without this call a 202 on initialize is a dead end.

**`Set_variable` — SetVariable.** Runs after `Get_operation_result` on **Succeeded or Failed**.

| Field | Value |
|---|---|
| Name | `requiredAction` |
| Value | `@{coalesce(body('Get_operation_result')?['requiredAction'], '')}` |

The **Failed** leg is the 404 tolerance. Not every Fabric operation has a result, and a handled failure does not fail the enclosing `Condition` scope — so a 404 here still lets the Respond fire normally.

**`Set_variable_2` — SetVariable.** Runs after `Set_variable` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `remoteCommitHash` |
| Value | `@{coalesce(body('Get_operation_result')?['remoteCommitHash'], '')}` |

### 5.2 False branch — not yet terminal

**There is no `else` key in the export.** The false branch is genuinely empty, and building it that way is correct: `requiredAction` and `remoteCommitHash` keep their initialised empty values, and the Respond reports whatever `status` Fabric gave — `Running`, `Failed`, `NotStarted`, or `Unavailable` when the state call itself did not return 200.

---

## Response contract

`Respond_to_a_Power_App_or_flow` — type `Response`, kind `PowerApp`, `statusCode` 200. Runs after `Condition` on **Succeeded**.

| Output name (as exported) | Title | Type | Value |
|---|---|---|---|
| `status` | `status` | string | `@{if(equals(coalesce(outputs('Get_operation_state')?['statusCode'], 0), 200), coalesce(body('Get_operation_state')?['status'], 'Unknown'), 'Unavailable')}` |
| `errorcode` | `errorCode` | string | `@{coalesce(body('Get_operation_state')?['error']?['errorCode'], '')}` |
| `errormessage` | `errorMessage` | string | `@{coalesce(body('Get_operation_state')?['error']?['message'], '')}` |
| `errordetails` | `errordetails` | string | `@{string(coalesce(body('Get_operation_state')?['error']?['moreDetails'], json('[]')))}` |
| `percentcomplete` | `percentcomplete` | string | `@{coalesce(body('Get_operation_state')?['percentComplete'], 0)}` |
| `requiredaction` | `requiredaction` | string | `@{variables('requiredAction')}` |
| `remotecommithash` | `remotecommithash` | string | `@{variables('remoteCommitHash')}` |

Keep every Respond field typed **string**. The designer wraps a single expression in `@{ }`, which stringifies it, so a field declared boolean or number returns `"true"` / `"7"` and fails schema validation — and one bad field makes every output of the flow unreadable in the app, not just the bad one. All seven here are correctly string.

`percentcomplete` is the field to watch. It carries a **number** — `coalesce(…, 0)` — but is declared `string`, and that pairing is right, because the surrounding `@{ }` stringifies it before the schema is checked. Declaring it `number` to match the value is exactly the mistake that removed `isConnected` from `GetWorkspaceGitState` and `count` from `ListMyConnections`. Coerce with `Value()` in Power Fx.

`errordetails` is `string(...)` over an array, defaulting to `json('[]')`, so the app receives `[]` rather than a blank when there is no detail. This is F2.2: `GitSyncFailed` / *"Failed to sync between Git and the workspace"* names nothing, and `error.moreDetails` is what names the failing item and the reason.

Output names come back **lowercased** in Power Fx — bind to `status`, `errorcode`, `errormessage`, `errordetails`, `percentcomplete`, `requiredaction`, `remotecommithash`. Note that four of the exported names are already lowercase while `errorcode` and `errormessage` carry camel-case *titles*; the title is display only.

`status` values:

| `status` | Meaning |
|---|---|
| `Succeeded` | terminal; `/result` was read, so `requiredaction` / `remotecommithash` may be populated |
| `Running`, `NotStarted`, `Failed` | Fabric's own state, passed through unchanged |
| `Unknown` | the state call returned 200 with no `status` field |
| `Unavailable` | the state call did **not** return 200 — treat as "could not read", not as "operation failed" |

The Respond runs on **Succeeded** only, which is safe here because the `Condition` swallows a failed state call rather than propagating it: an `If` whose failures are all handled by `runAfter` reports Succeeded itself.

---

## After building

- Add the flow to the canvas app (left rail → Power Automate → **+ Add flow**). Watch for a suffixed duplicate such as `GetGitOperationStatus_1` from adding it twice.
- **The canvas app must call this as `PollFabricOperation.Run(operationId)`.** Renaming a flow changes the display name only; the identifier Power Fx binds to is fixed when the flow is created, and this flow was renamed in place from `PollFabricOperation` on 2026-08-07 to keep its GUID and connection references. Calling `GetGitOperationStatus.Run(...)` gives *'Run' is an unknown or unsupported function in namespace 'GetGitOperationStatus'*. Trust the formula-bar autocomplete over the portal display name. This is the solution's only such mismatch.
- If you change the trigger inputs later, **remove and re-add the flow in the app** — Power Apps caches the signature at bind time.
- Pass the trigger input **positionally**: `PollFabricOperation.Run(operationId)`. Do not use a trailing options record.
- The flow answers a PowerApp, so it must respond within **120 seconds**. Two GETs and one child call; there is no loop and no `Delay`, so the budget is not at risk.
- **It cannot be used as a child flow.** The `PowerAppV2` trigger disqualifies it — child flows must use *Manually trigger a flow*. `ConnectWorkspaceToGit`'s `Run_PollFabricOperation` action was deleted on 2026-08-07 for exactly this reason.
- **It advances nothing.** No writes, no state machine, no follow-up call. If `requiredaction` comes back populated, it is the **app** that decides to call `SyncWorkspaceWithGit`. `Retry-After` on a 202 is 30 seconds — that is what the UI should suggest before a re-click of Refresh.
