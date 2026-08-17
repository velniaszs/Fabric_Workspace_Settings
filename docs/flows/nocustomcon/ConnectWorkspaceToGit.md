# Flow — `ConnectWorkspaceToGit`

Build  instructions for stage 1 of the connect wizard: it points a Fabric workspace at an Azure DevOps repo, then **probes** Fabric for which way the content should move and stops. `SyncWorkspaceWithGit` is stage 2 and moves the content. Runs as the broker.

Verified against `Workflows/ConnectWorkspaceToGit-1E895D49-DA8F-F111-8076-70A8A530AE85.json` on 2026-08-17.

Related: [../../FLOWS.md](../../FLOWS.md) §5 (design rationale), [../../PREREQUISITES.md](../../PREREQUISITES.md) (A3, B1, D1, E3, E4), [../../OPEN-ISSUES.md](../../OPEN-ISSUES.md) §1.11, §5.4, §10.3, §10.6.

---

## 0. Before you start

- Create the flow **inside the solution**, so it binds to connection references rather than raw connections.
- **No connector connection is needed.** The flow uses only built-in actions: `Compose`, `Run a Child Flow`, `Initialize variable`, `Set variable`, `HTTP`, `Condition`, `Respond to a Power App or flow`.
- The child flow **`GetFabricToken`** must already exist. It is referenced by GUID: `50895fca-088f-f111-8076-7ced8d76bf1b` → `Workflows/GetFabricToken-50895FCA-088F-F111-8076-7CED8D76BF1B.json`.
- Authentication is **service principal**, not delegated. `GetFabricToken` runs the client-credentials grant as the broker SPN; all four Fabric calls carry that bearer token in a hand-written header.
- The broker SPN must hold **workspace Admin** on the target workspace — `git/connect`, `git/myGitCredentials` and `git/initializeConnection` are all Admin-only.
- The `connectionId` passed in must already carry a role assignment for the broker. That is what `AddConnectionRoleAssignment` (delegated) is for, and it runs on the wizard step immediately before this one.
- The `directoryName` must already exist in the repo, with at least a placeholder file — Git cannot store an empty directory, and a first-time connect against a missing folder returns `GitProviderResourceNotFound` (PREREQUISITES D1, OPEN-ISSUES §1.11).
- Environment variables are **not referenced directly by this flow**. They are consumed by the child flow:

  | Variable | Default in the solution | Used by |
  |---|---|---|
  | `ab_TenantId` | `9e929790-272d-4977-a2ab-301443c11ece` | `GetFabricToken` (token endpoint) |
  | `ab_BrokerClientId` | `a385fde9-1d6a-4e7f-8336-dc7feba5a4bc` | `GetFabricToken` (client id) |
  | `ab_BrokerObjectId` | `6f70a764-908f-435b-a930-ffcb375577f3` | *not used by this flow* |

  The broker **client secret** lives inside `GetFabricToken` as an `Initialize variable`, is scrubbed on export, and must be re-entered per environment (PREREQUISITES E4). Never commit it.

Actions are listed in execution order. Build them in that order — inserting an action later re-parents its successor and silently creates a parallel branch.

> **JSON key order is not execution order in this export.** `Initialize_requiredAction` is the *last* key in the `actions` object but runs sixth, and `Check_existing` is keyed before `Is_not_connected` yet depends on it. Follow `runAfter`.

---

## 1. Trigger — Power Apps (V2)

| Field | Value |
|---|---|
| Type | `Request` |
| Kind | `PowerAppV2` |
| Action name | `manual` |

Seven text inputs, all `x-ms-content-hint: TEXT`, all with the designer default description `Please enter your input`, and **all seven required**:

| # | Input title | Schema key | Type | Required | Raw reference |
|---|---|---|---|---|---|
| 1 | `workspaceId` | `text` | string | Yes | `@triggerBody()['text']` |
| 2 | `connectionId` | `text_1` | string | Yes | `@triggerBody()['text_1']` |
| 3 | `organizationName` | `text_2` | string | Yes | `@triggerBody()['text_2']` |
| 4 | `projectName` | `text_3` | string | Yes | `@triggerBody()['text_3']` |
| 5 | `repositoryName` | `text_4` | string | Yes | `@triggerBody()['text_4']` |
| 6 | `branchName` | `text_5` | string | Yes | `@triggerBody()['text_5']` |
| 7 | `directoryName` | `text_6` | string | Yes | `@triggerBody()['text_6']` |

The titles are cosmetic. `text`, `text_1` … `text_6` bind **positionally**, so add the inputs in exactly this order or the wizard will cross-wire org, project and repo without any error.

Keep all seven **required**. An optional PowerApp V2 input is dropped from the payload entirely when blank — the property is absent, `triggerBody()['text_n']` throws `InvalidTemplate`, and the run history shows nothing. Most references in this flow use the unguarded `['text_n']` form, so a blank optional input would be fatal rather than merely wrong.

The wizard supplies `organizationName` / `projectName` / `repositoryName` derived from `GET /v1/connections/{id}` → `connectionDetails.path`, so the user does not paste a URL.

> The flow takes `workspaceId` at face value. There is no ownership check and no audit row, so it will connect any workspace the broker administers for any caller who can run it. Deferred by decision — OPEN-ISSUES §10.3.

---

## 2. `Compose` — Compose

First action; `runAfter` is empty. Keeps the designer's default name.

Inputs are an object, not a string:

```json
{
  "workspaceId": "@{triggerBody()?['text']}",
  "connectionId": "@{triggerBody()?['text_1']}",
  "organizationName": "@{triggerBody()?['text_2']}",
  "projectName": "@{triggerBody()?['text_3']}",
  "repositoryName": "@{triggerBody()?['text_4']}",
  "branchName": "@{triggerBody()?['text_5']}",
  "directoryName": "@{triggerBody()?['text_6']}"
}
```

Nothing downstream reads `outputs('Compose')`. It exists so the run history shows the seven inputs under readable names — the trigger outputs only show `text`, `text_1` … — which is the difference between a five-minute and a fifty-minute diagnosis when the positional keys get crossed. Note it is the only place in the flow using the safe `?['text_n']` form.

---

## 3. `Run_a_Child_Flow` — Workflow

Runs after `Compose` on **Succeeded**.

| Field | Value |
|---|---|
| Type | `Workflow` |
| `host.workflowReferenceName` | `50895fca-088f-f111-8076-7ced8d76bf1b` |
| Inputs | none |

That GUID is `GetFabricToken`. It takes no parameters and returns `access_token`.

---

## 4. Variables

Five **Initialize variable** actions, each chained on **Succeeded** from the previous one, in this exact order:

| Order | Action name | Variable | Type | Initial value |
|---|---|---|---|---|
| 1 | `Initialize_accessToken` | `accessToken` | String | `@body('Run_a_Child_Flow')?['access_token']` |
| 2 | `Initialize_outcome` | `outcome` | String | `Failed` |
| 3 | `Initialize_message` | `message` | String | *(no value key)* |
| 4 | `Initialize_operationId` | `operationId` | String | *(no value key)* |
| 5 | `Initialize_requiredAction` | `requiredAction` | String | `None` |

`outcome` is seeded `Failed` on purpose: every path that reaches the Respond without having set it explicitly is, by definition, a path that did not succeed.

`accessToken` holds a bearer token with tenant-wide Fabric rights. It is deliberately never a trigger input and never returned to the app.

---

## 5. `Check_existing` — HTTP

Runs after `Initialize_requiredAction` on **Succeeded**.

| Field | Value |
|---|---|
| Method | `GET` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}/git/connection` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Header `Accept` | `application/json` |
| Body | none |
| Authentication block | none — no `authentication` property; the bearer token is supplied by hand in the header |

The flow reads the connection state **inside its own run** rather than trusting a value the app passed in.

A disconnected workspace returns **200 with `gitConnectionState: NotConnected`**, not a 404.

---

## 6. `Is_not_connected` — If

Runs after `Check_existing` on **Succeeded** only.

Expression, verbatim:

```json
"expression": {
  "equals": [
    "@body('Check_existing')?['gitConnectionState']",
    "NotConnected"
  ]
}
```

Unlike the equivalent test in `DisconnectWorkspaceFromGit`, there is no `coalesce(..., '')` here — a body with no `gitConnectionState` yields `null`, which is not equal to `NotConnected`, so it falls to the else branch and answers `AlreadyConnected`.

`gitConnectionState` has three values — `NotConnected`, `Connected`, `ConnectedAndInitialized` — so the else branch covers both connected states.

### 6.1 True branch — not connected, so connect

Seven actions. The main chain is `Connect` → `Set_credentials` → `Initialize_connection` → `Set_outcome` → `Set_requiredAction` → `Set_message` → `Set_operationId_probe`. A **second, parallel** chain hangs off `Connect` on `Failed`.

#### 6.1.1 `Connect` — HTTP

`runAfter` empty (first action in the branch).

| Field | Value |
|---|---|
| Method | `POST` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}/git/connect` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Header `Content-Type` | `application/json` |
| Authentication block | none — bearer token supplied by hand in the header |

Body:

```json
{
  "gitProviderDetails": {
    "gitProviderType": "AzureDevOps",
    "organizationName": "@{triggerBody()['text_2']}",
    "projectName": "@{triggerBody()['text_3']}",
    "repositoryName": "@{triggerBody()['text_4']}",
    "branchName": "@{triggerBody()['text_5']}",
    "directoryName": "@{triggerBody()['text_6']}"
  },
  "myGitCredentials": {
    "source": "ConfiguredConnection",
    "connectionId": "@{triggerBody()['text_1']}"
  }
}
```

`gitProviderType` is hardcoded to `AzureDevOps`. GitHub is not supported by this flow.

#### 6.1.2 `Set_credentials` — HTTP

Runs after `Connect` on **Succeeded**.

| Field | Value |
|---|---|
| Method | `PATCH` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}/git/myGitCredentials` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Header `Content-Type` | `application/json` |
| Authentication block | none — bearer token supplied by hand in the header |

Body:

```json
{
  "source": "ConfiguredConnection",
  "connectionId": "@{triggerBody()['text_1']}"
}
```

Almost certainly redundant — `Connect` already sent the same `myGitCredentials` payload — but **kept by decision 2026-08-11**. It has never failed in testing, and removing it would mean re-running every stage-1 test to prove nothing regressed. See OPEN-ISSUES §5.4.

#### 6.1.3 `Initialize_connection` — HTTP (the probe)

Runs after `Set_credentials` on **Succeeded**.

| Field | Value |
|---|---|
| Method | `POST` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}/git/initializeConnection` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Header `Content-Type` | `application/json` |
| Body | `{ "initializationStrategy": "None" }` |
| `operationOptions` | *(absent — Asynchronous Pattern stays **On**)* |

The strategy is hardcoded to `None` deliberately. The owner cannot sensibly answer "prefer remote or prefer workspace?" before anyone knows whether both sides even hold content, so the flow asks Fabric first and lets the answer drive the question. If both sides hold items, Fabric refuses with `errorCode: MissingInitializationStrategy` — which this flow treats as a **successful probe**, not a failure.

Emptiness decides, not difference: Fabric returns a direction when exactly one side is empty and demands a strategy when both hold items. Identical content on both sides still yields `NeedsChoice`, because a fresh connection has no shared history.

Leaving Asynchronous Pattern **On** is a decision, not an oversight — initialize records a direction rather than moving data and has returned synchronously in every test, so letting the connector absorb a rare `202` beats owning a polling loop inside the 120-second response budget.

#### 6.1.4 `Set_outcome` — Set variable

Runs after `Initialize_connection` on **Succeeded or Failed**. The `Failed` leg is required: a `400 MissingInitializationStrategy` is the `NeedsChoice` answer, and without it the whole downstream chain is skipped.

| Field | Value |
|---|---|
| Name | `outcome` |

```
@{if(equals(coalesce(outputs('Initialize_connection')?['statusCode'],0),202),'Pending',if(less(coalesce(outputs('Initialize_connection')?['statusCode'],0),300),'Connected',if(equals(coalesce(body('Initialize_connection')?['errorCode'],''),'MissingInitializationStrategy'),'NeedsChoice','Failed')))}
```

#### 6.1.5 `Set_requiredAction` — Set variable

Runs after `Set_outcome` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `requiredAction` |

```
@{if(less(coalesce(outputs('Initialize_connection')?['statusCode'],0),300),coalesce(body('Initialize_connection')?['requiredAction'],'None'),'None')}
```

#### 6.1.6 `Set_message` — Set variable

Runs after `Set_requiredAction` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `message` |

```
@{if(less(coalesce(outputs('Initialize_connection')?['statusCode'],0),300),'Connected and initialized.',if(equals(coalesce(body('Initialize_connection')?['errorCode'],''),'MissingInitializationStrategy'),'Workspace and repository both contain items. Choose which side wins.',string(body('Initialize_connection'))))}
```

#### 6.1.7 `Set_operationId_probe` — Set variable

Runs after `Set_message` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `operationId` |

```
@{coalesce(outputs('Initialize_connection')?['headers']?['x-ms-operation-id'], outputs('Initialize_connection')?['headers']?['X-Ms-Operation-Id'], last(split(coalesce(outputs('Initialize_connection')?['headers']?['Location'],''),'/')), '')}
```

Both header casings are tried, then the last segment of `Location`, then empty string. Only populated on the `202` path, which is unreachable while Asynchronous Pattern is On.

#### 6.1.8 `Set_outcome_connectfailed` — Set variable

Runs after **`Connect`** on **Failed**. This is a second successor on `Connect`, i.e. a deliberate parallel branch — build it by adding a *run after → has failed* branch on `Connect`, not by inserting into the main chain.

| Field | Value |
|---|---|
| Name | `outcome` |
| Value | `Failed` |

#### 6.1.9 `Set_message_connectfailed` — Set variable

Runs after `Set_outcome_connectfailed` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `message` |
| Value | `@{string(body('Connect'))}` |

Without 6.1.8 and 6.1.9, a failed `Connect` skipped everything downstream and the flow ended with **no response at all**. The most likely real failure lands exactly here: `GitProviderResourceNotFound`, returned when `directoryName` does not already exist in the repo.

### 6.2 Else branch — already connected

Two **Set variable** actions, chained on **Succeeded**:

| Order | Action name | Name | Value |
|---|---|---|---|
| 1 | `Set_variable_no_outcome` | `outcome` | `AlreadyConnected` |
| 2 | `Set_variable_no_message` | `message` | `Workspace is already connected to a repository.` |

Nothing is written and nothing is re-pointed. `operationId` stays empty and `requiredAction` stays `None` from their initial values.

---

## 7. `Respond_to_a_Power_App_or_flow` — Response

Runs after `Is_not_connected` on **Succeeded or Failed**. Type `Response`, kind `PowerApp`, `statusCode` 200.

That run-after is the other half of the fix in 6.1.8 — without it, a condition that fails anywhere inside skips the Respond and the app gets a hard error instead of a message.

---

## Response contract

| Output name (as exported) | Title | Type | Value |
|---|---|---|---|
| `outcome` | `outcome` | string | `@variables('outcome')` |
| `message` | `message` | string | `@variables('message')` |
| `operationid` | `operationId` | string | `@variables('operationId')` |
| `requiredaction` | `requiredAction` | string | `@variables('requiredAction')` |

Keep every Respond field typed **string**. The designer wraps a single expression in `@{ }`, which stringifies it, so a field declared boolean or number returns `"true"` / `"7"` and fails schema validation — and one bad field makes every output of the flow unreadable in the app, not just the bad one. All four fields here are correctly string, and all four bind `@variables(...)` rather than an inline `@{ }` expression.

Output names come back **lowercased** in Power Fx — bind to `outcome`, `message`, `operationid`, `requiredaction`, not to the titles.

`outcome` values and what the app does next:

| `outcome` | Meaning | Next step |
|---|---|---|
| `Connected` | Fabric named a direction, in `requiredaction` | Call `SyncWorkspaceWithGit` with that `requiredAction`, no strategy |
| `NeedsChoice` | Both sides hold items; Fabric refuses to guess | Ask the owner, then call `SyncWorkspaceWithGit` with their strategy |
| `AlreadyConnected` | Nothing was done | Offer disconnect or change settings |
| `Failed` | `Connect` or the probe errored; raw payload in `message` | Show the error |
| `Pending` | `202` from initialize | Unreachable while Asynchronous Pattern is On; kept as a guard |

---

## After building

- Add the flow to the canvas app (left rail → Power Automate → **+ Add flow**). Watch for a suffixed duplicate such as `ConnectWorkspaceToGit_1` from adding it twice.
- If you change the trigger inputs later, **remove and re-add the flow in the app** — Power Apps caches the signature at bind time. With seven positional inputs this is the change most likely to be made and least likely to announce itself.
- Renaming the flow does not change the name Power Fx binds to. Trust formula-bar autocomplete over the portal display name.
- Pass the inputs **positionally**, in trigger order: `ConnectWorkspaceToGit.Run(workspaceId, connectionId, organizationName, projectName, repositoryName, branchName, directoryName)`. Do not use a trailing options record.
- The flow answers a PowerApp, so it must respond within **120 seconds**. The chain is one token call plus up to four synchronous Fabric calls; there is no loop.

---

## Known drift from the exported definition

- `FLOWS.md` §5 opens its **As built** list with "1. **Token** — child call to `GetFabricToken`, then variables `accessToken`, `outcome` (seeded `Failed`), `message`, `operationId`, `requiredAction` (seeded `None`)." The export's first action is not the child call: `Run_a_Child_Flow` has `"runAfter": { "Compose": [ "Succeeded" ] }`, and `Compose` — an action `FLOWS.md` does not mention anywhere — has `"runAfter": {}`. Rebuilding from §5 alone produces a flow that works but whose run history lacks the named echo of the seven positional trigger keys.
