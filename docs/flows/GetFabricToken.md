# Flow — `GetFabricToken`

Build instructions for the child flow that performs the client-credentials grant for the broker service principal and hands the resulting bearer token back to its caller. It is the only flow in the solution that holds a secret; every other flow calls it instead of repeating the token block.

Verified against `Workflows/GetFabricToken-50895FCA-088F-F111-8076-7CED8D76BF1B.json` on 2026-08-17.

Related: [../FLOWS.md](../FLOWS.md) §1 (design rationale), [../PREREQUISITES.md](../PREREQUISITES.md) (A1, A3, B1, E3, E4), [../OPEN-ISSUES.md](../OPEN-ISSUES.md) §1.6, §2, §8.3. Callers documented in [GetGitOperationStatus.md](GetGitOperationStatus.md), [GetGitPolicy.md](GetGitPolicy.md), [SetGitPolicy.md](SetGitPolicy.md), [GetWorkspaceGitState.md](GetWorkspaceGitState.md), [ConnectWorkspaceToGit.md](ConnectWorkspaceToGit.md), [DisconnectWorkspaceFromGit.md](DisconnectWorkspaceFromGit.md), [SyncWorkspaceWithGit.md](SyncWorkspaceWithGit.md).

---

## 0. Before you start

- Create the flow **inside the solution**, so the environment variables resolve as `parameters('… (ab_…)')` rather than literals.
- **No connector connection is needed.** The flow uses only built-in actions: `Initialize variable`, `HTTP`, `Respond to a Power App or flow`. `connectionReferences` in the export is `{}`.
- Authentication is **service principal** (client credentials), not delegated. This flow *is* the place where that grant happens.
- Two environment variables are referenced directly:

  | Variable | Parameter name in the definition | Default in the solution |
  |---|---|---|
  | `ab_TenantId` | `TenantId (ab_TenantId)` | `9e929790-272d-4977-a2ab-301443c11ece` |
  | `ab_BrokerClientId` | `BrokerClientId (ab_BrokerClientId)` | `a385fde9-1d6a-4e7f-8336-dc7feba5a4bc` |

  `ab_BrokerObjectId` is **not** used here — that is the directory object ID and belongs to `AddConnectionRoleAssignment`. The client (application) ID is what Entra wants for a token request; the two are not interchangeable and swapping them fails at runtime, not at import.

- The **client secret** is an `Initialize variable` inside this flow. The solution export scrubs it to a single space, so it must be re-entered by hand in every environment (PREREQUISITES E4). Nothing in the solution runs until it is. Never commit it.
- PREREQUISITES A3 + B1 must be in place — the broker SP in `fabric_power_app_grp`, and *Service principals can call Fabric public APIs* enabled for that group. Without them this flow still returns a token happily; every downstream Fabric call then returns a bare `401`.

Actions are listed in execution order. Build them in that order — inserting an action later re-parents its successor and silently creates a parallel branch.

---

## 1. Trigger — Manually trigger a flow

| Field | Value |
|---|---|
| Type | `Request` |
| Kind | `Button` |
| Action name | `manual` |
| Inputs | `schema` with empty `properties` and empty `required` — **no inputs** |

**The kind must stay `Button`, not `PowerAppV2`.** A child flow can only be invoked by `Run a Child Flow` if its trigger is *Manually trigger a flow*. This is the same constraint that forced `GetGitOperationStatus` out of the child-flow role when its trigger became `PowerAppV2`.

There are no trigger inputs and therefore no `@triggerBody()` references anywhere in the definition. Callers pass nothing.

---

## 2. `Initialize_variable` — InitializeVariable

First action; `runAfter` is empty.

| Field | Value |
|---|---|
| Name | `clientSecret` |
| Type | String |
| Value | *(a single space in the export — the scrubbed placeholder)* |

The export carries `"value": " "`. That is the scrub, not the secret. Paste the real `sp_fabric_powerapp` secret here after import, in the maker portal only.

Migrating this to a Key Vault-backed secret environment variable is deferred, not resolved — OPEN-ISSUES §2.

---

## 3. `HTTP` — Http

Runs after `Initialize_variable` on **Succeeded**.

| Field | Value |
|---|---|
| Method | `POST` |
| URI | `https://login.microsoftonline.com/@{parameters('TenantId (ab_TenantId)')}/oauth2/v2.0/token` |
| Header `Content-Type` | `application/x-www-form-urlencoded` |
| Authentication block | none — this call *obtains* the credential, it does not present one |
| `retryPolicy` | *(absent — default exponential, 4 retries)* |

Body, verbatim — a form-encoded string, not a JSON object:

```
grant_type=client_credentials&client_id=@{parameters('BrokerClientId (ab_BrokerClientId)')}&client_secret=@{variables('clientSecret')}&scope=https://api.fabric.microsoft.com/.default
```

The secret reaches the request only through `@{variables('clientSecret')}`. Do not inline it.

Scope is the `.default` form of the Fabric resource. A broker token legitimately comes back with `roles: (none)` — Fabric does not grant REST access through Entra application permissions, so do not add any (PREREQUISITES A1).

**Secure inputs and outputs are switched on.** The export carries:

```json
"runtimeConfiguration": {
  "secureData": {
    "properties": [ "inputs", "outputs" ]
  }
}
```

Set both in **Settings → Secure Inputs / Secure Outputs** on this action. Without it the secret appears in the request body in run history and the raw bearer token appears in the response. Downstream actions can still read `body('HTTP')`; only the run-history display is suppressed.

---

## Response contract

`Respond_to_a_Power_App_or_flow` — type `Response`, kind `PowerApp`, `statusCode` 200. Runs after `HTTP` on **Succeeded** only.

| Output name | Title | Type | Value |
|---|---|---|---|
| `access_token` | `access_token` | string | `@{body('HTTP')?['access_token']}` |

Keep every Respond field typed **string**. The designer wraps a single expression in `@{ }`, which stringifies it, so a field declared boolean or number returns `"true"` / `"7"` and fails schema validation — and one bad field makes every output of the flow unreadable to the caller, not just the bad one. The single field here is correctly string.

Output names come back **lowercased** in Power Fx. That only matters if this flow is ever called from the canvas app directly, which it is not — callers are flows and read `body('Run_a_Child_Flow')?['access_token']`, which preserves the exported casing.

`Respond` runs on **Succeeded** only. A rejected token request therefore fails the run with no response, and the caller's `Run a Child Flow` action fails too. That is the intended behaviour: no token means nothing downstream can work, and failing loudly at the child is better than handing a caller an empty string that turns into a `401` three actions later.

Nothing else is returned. `expires_in`, `token_type` and the raw body are all discarded.

---

## After building — how callers invoke it

This is a child flow, not an app-facing one. **Do not add it to the canvas app.**

Callers add a **Run a Child Flow** action:

| Field | Value |
|---|---|
| Type | `Workflow` |
| `host.workflowReferenceName` | `50895fca-088f-f111-8076-7ced8d76bf1b` |
| Inputs | none |

That GUID is this flow. It is what appears in the exported JSON; the designer shows the display name.

Twelve flows in `Workflows/` carry that reference today:

`ConnectWorkspaceToGit`, `DisconnectWorkspaceFromGit`, `GetGatewayRules`, `GetGitOperationStatus`, `GetGitPolicy`, `GetOAPSetting`, `GetOutboundRules`, `GetWorkspaceGitState`, `SetGatewayRules`, `SetGitPolicy`, `SetOutboundRules`, `SyncWorkspaceWithGit`.

Two consumption patterns exist, both correct:

- **Via a variable** — `Initialize variable accessToken` = `@body('Run_a_Child_Flow')?['access_token']`, then headers read `Bearer @{variables('accessToken')}`. Used by most flows, including `GetGitPolicy` and `SetGitPolicy`.
- **Direct** — headers read `Bearer @{body('Run_a_Child_Flow')?['access_token']}` with no intermediate variable. Used by `GetGitOperationStatus`.

The token is **never** a trigger input of any caller and is **never** returned to the canvas app. It carries tenant-wide Fabric rights for the broker; putting it in an app makes it recoverable by anyone who can open that app.

Renaming this flow does not change the reference — callers bind to the GUID, so a rename is safe here in a way it is not for app-facing flows.

Each caller that answers a PowerApp still owes its own answer within **120 seconds**, and the child call spends part of that budget. It is one round trip to Entra; treat it as cheap but not free.

---

## Known drift from the exported definition

- `FLOWS.md` §1 gives the trigger as "**PowerApp V2, no inputs**". The exported trigger is `"type": "Request"`, `"kind": "Button"` — *Manually trigger a flow*. The export is the correct form and `FLOWS.md` §2 says so itself: "**`GetFabricToken` stays a child flow — a parent may have any trigger**", under the rule that "**Child flows must use *Manually trigger a flow***". Building this trigger as `PowerAppV2` would break all twelve callers.
