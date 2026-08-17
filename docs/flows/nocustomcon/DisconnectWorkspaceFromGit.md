# Flow — `DisconnectWorkspaceFromGit`

Build instructions for the broker flow that removes a Fabric workspace's Git connection. Called by the canvas app when the owner chooses to disconnect, or as the first half of a branch/directory change — there is no update API, so a settings change is disconnect + reconnect.

Verified against `Workflows/DisconnectWorkspaceFromGit-3FDE40BB-AC94-F111-8075-000D3ABA40DB.json` on 2026-08-17.

Related: [../../FLOWS.md](../../FLOWS.md) §6 (design rationale), [../../PREREQUISITES.md](../../PREREQUISITES.md) (A3, B1, E3, E4), [../../OPEN-ISSUES.md](../../OPEN-ISSUES.md) §1.7, §10.3.

---

## 0. Before you start

- Create the flow **inside the solution**, so it binds to connection references rather than raw connections.
- **No connector connection is needed.** The flow uses only built-in actions: `Run a Child Flow`, `Initialize variable`, `HTTP`, `Condition`, `Respond to a Power App or flow`.
- The child flow **`GetFabricToken`** must already exist. It is referenced by GUID: `50895fca-088f-f111-8076-7ced8d76bf1b` → `Workflows/GetFabricToken-50895FCA-088F-F111-8076-7CED8D76BF1B.json`.
- Authentication is **service principal**, not delegated. `GetFabricToken` runs the client-credentials grant as the broker SPN; both Fabric calls here carry that bearer token in a hand-written header.
- The broker SPN must hold **workspace Admin** on the target workspace. `git/disconnect` is an Admin-only operation. A `403` here means the broker lost its role, not that a scope is missing.
- Environment variables are **not referenced directly by this flow**. They are consumed by the child flow:

  | Variable | Default in the solution | Used by |
  |---|---|---|
  | `ab_TenantId` | `9e929790-272d-4977-a2ab-301443c11ece` | `GetFabricToken` (token endpoint) |
  | `ab_BrokerClientId` | `a385fde9-1d6a-4e7f-8336-dc7feba5a4bc` | `GetFabricToken` (client id) |
  | `ab_BrokerObjectId` | `6f70a764-908f-435b-a930-ffcb375577f3` | *not used by this flow* |

  The broker **client secret** lives inside `GetFabricToken` as an `Initialize variable`, is scrubbed on export, and must be re-entered per environment (PREREQUISITES E4). Never commit it.

Actions are listed in execution order. Build them in that order — inserting an action later re-parents its successor and silently creates a parallel branch.

---

## 1. Trigger — Power Apps (V2)

| Field | Value |
|---|---|
| Type | `Request` |
| Kind | `PowerAppV2` |
| Action name | `manual` |

One input:

| Input title | Schema key | Type | Content hint | Required |
|---|---|---|---|---|
| `workspaceId` | `text` | string | `TEXT` | Yes |

Referenced downstream as `@triggerBody()['text']` — the schema key stays `text` regardless of the title. This flow reads the trigger key directly everywhere; it does not copy it into a variable.

The input is already **required** in the export, and must stay that way. An optional PowerApp V2 input is dropped from the payload entirely when blank, and the unguarded `triggerBody()['text']` used in both URIs would throw `InvalidTemplate: property 'text' doesn't exist`.

> The flow takes `workspaceId` at face value. There is no ownership check, so it will disconnect any workspace the broker administers for any caller who can run it. Deferred by decision — OPEN-ISSUES §10.3.

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

## 3. `Initialize_variable` — Initialize variable

Runs after `Run_a_Child_Flow` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `accessToken` |
| Type | String |
| Value | `@body('Run_a_Child_Flow')?['access_token']` |

The action keeps the designer's default name, `Initialize_variable`. Only the variable is named.

---

## 4. `Check_existing` — HTTP

Runs after `Initialize_variable` on **Succeeded**.

| Field | Value |
|---|---|
| Method | `GET` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}/git/connection` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Body | none |
| Authentication block | none — no `authentication` property; the bearer token is supplied by hand in the header |

No `Accept` header on this one, unlike the equivalent call in `GetWorkspaceGitState` and `ConnectWorkspaceToGit`.

The state is read **inside this run**, not taken from the caller. A value the app read earlier and passed back in is a value the caller could have altered.

A disconnected workspace returns **200 with `gitConnectionState: NotConnected`**, not a 404.

---

## 5. `Condition` — If

Runs after `Check_existing` on **Succeeded** only.

Expression, verbatim:

```json
"expression": {
  "equals": [
    "@equals(coalesce(body('Check_existing')?['gitConnectionState'],''), 'NotConnected')",
    "@true"
  ]
}
```

`coalesce(..., '')` covers a body that has no `gitConnectionState` at all. `gitConnectionState` has three values — `NotConnected`, `Connected`, `ConnectedAndInitialized` — so testing only for `NotConnected` correctly lets **both** connected states through to the else branch.

> `Check_existing` has no `Failed` tolerance. If the GET fails, the `Condition` is skipped, every action under it is skipped, and the run ends with no response — the app sees a hard error rather than a message.

### 5.1 True branch — already disconnected

**`Respond_to_a_Power_App_or_flow`** — type `Response`, kind `PowerApp`, `statusCode` 200. `runAfter` is empty (first action in the branch).

| Output (string) | Value |
|---|---|
| `outcome` | `NotConnected` |
| `message` | `Workspace is not connected to Git; nothing to disconnect.` |

Both are literals — no expression, so nothing to stringify. This is what makes a repeat call return a clean message instead of an error.

### 5.2 False branch — connected, so disconnect

**`Disconnect`** — HTTP, `runAfter` empty (first action in the branch).

| Field | Value |
|---|---|
| Method | `POST` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}/git/disconnect` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Body | none — the export has no `body` property, and no `Content-Type` header |
| Authentication block | none — bearer token supplied by hand in the header |

Synchronous. Returns `200`; there is no `202`, no `x-ms-operation-id` and nothing to poll. Disconnecting leaves the Azure DevOps folder and its contents untouched.

**`Respond_to_a_Power_App_or_flow_2`** — type `Response`, kind `PowerApp`, `statusCode` 200. Runs after `Disconnect` on **Succeeded or Failed**.

| Output (string) | Value |
|---|---|
| `outcome` | `@{if(equals(outputs('Disconnect')['statusCode'],200),'Disconnected','Failed')}` |
| `message` | `@{if(equals(outputs('Disconnect')['statusCode'],200),'Workspace disconnected from Git.',string(body('Disconnect')))}` |

The **Succeeded or Failed** run-after is load-bearing. Without it a Fabric error fails `Disconnect`, skips the Respond, and ends the run with no output at all — the same skip-propagation defect fixed in `ConnectWorkspaceToGit` and `AddConnectionRoleAssignment`. With it, the raw Fabric payload reaches the app as readable text.

Note the comparison is `equals(..., 200)` exactly, not `less(..., 300)`. Any other 2xx would be reported as `Failed`.

---

## 6. Response contract

Two Respond actions, one per branch. They declare **identical** output names and types, which is required — the app binds one signature.

| Name | Type | Set by 5.1 | Set by 5.2 |
|---|---|---|---|
| `outcome` | string | `NotConnected` | `Disconnected` or `Failed` |
| `message` | string | fixed text | fixed text or the raw Fabric body |

Keep every Respond field typed **string**. The designer wraps a single expression in `@{ }`, which stringifies it, so a field declared boolean or number returns `"true"` / `"7"` and fails schema validation — and one bad field makes every output of the flow unreadable in the app, not just the bad one.

Output names come back **lowercased** in Power Fx. Here both are already lowercase.

---

## 7. After building

- Add the flow to the canvas app (left rail → Power Automate → **+ Add flow**). Watch for a suffixed duplicate such as `DisconnectWorkspaceFromGit_1` from adding it twice.
- If you change the trigger input later, **remove and re-add the flow in the app** — Power Apps caches the signature at bind time.
- Renaming the flow does not change the name Power Fx binds to. This flow was renamed from `DisconnectWorkspaceGit`, so check formula-bar autocomplete rather than the portal display name before assuming `DisconnectWorkspaceFromGit.Run(...)` resolves.
- Pass the trigger input positionally: `DisconnectWorkspaceFromGit.Run(workspaceId)`.
- The flow answers a PowerApp, so it must respond within **120 seconds**. One token call, one GET and at most one POST, all synchronous — the budget is not at risk.
- The app must warn that disconnect + reconnect re-runs initialization, since this is also the only route to a branch or directory change.
