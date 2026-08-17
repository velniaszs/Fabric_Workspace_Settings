# Flow — `GetGitPolicy`

Build instructions for the read that reports a workspace's outbound Git communication policy — whether Fabric permits the workspace to talk to a Git provider at all. Called by the canvas app's Outbound tab to set the Git toggle. One of the eight pre-existing networking flows, not part of the Git-integration build order.

Verified against `Workflows/GetGitPolicy-42395F29-8C89-F111-AB0F-7C1E528D41FB.json` on 2026-08-17.

Related: [../../FLOWS.md](../../FLOWS.md) (Networking flows table), [../../PREREQUISITES.md](../../PREREQUISITES.md) (A1, A3, B1, E4), [../../OPEN-ISSUES.md](../../OPEN-ISSUES.md) §1.6, [../../APP-OUTBOUND-TAB.md](../../APP-OUTBOUND-TAB.md) (how the app calls it), [GetFabricToken.md](GetFabricToken.md) (the child flow it calls), [SetGitPolicy.md](SetGitPolicy.md) (the matching write).

---

## 0. Before you start

- Create the flow **inside the solution**, so it binds to connection references rather than raw connections.
- **No connector connection is needed.** The flow uses only built-in actions: `Run a Child Flow`, `Initialize variable`, `HTTP`, `Respond to a Power App or flow`. `connectionReferences` in the export is `{}`.
- The child flow **`GetFabricToken`** must already exist. It is referenced by GUID: `50895fca-088f-f111-8076-7ced8d76bf1b` → `Workflows/GetFabricToken-50895FCA-088F-F111-8076-7CED8D76BF1B.json`.
- Authentication is **service principal**, not delegated. The inline `clientSecret` → token `HTTP` → `Parse_JSON` block that this flow used to carry was deleted on 2026-08-07 and replaced by the child-flow call (OPEN-ISSUES §1.6, FN.1). It previously ran as `sp_fabric_monit`, which holds `Tenant.Read.All` / `Tenant.ReadWrite.All`; it now runs as `sp_fabric_powerapp`. Do not reintroduce an inline token block.
- Environment variables are **not referenced directly by this flow**. They are consumed by the child flow:

  | Variable | Default in the solution | Used by |
  |---|---|---|
  | `ab_TenantId` | `9e929790-272d-4977-a2ab-301443c11ece` | `GetFabricToken` (token endpoint) |
  | `ab_BrokerClientId` | `a385fde9-1d6a-4e7f-8336-dc7feba5a4bc` | `GetFabricToken` (client id) |
  | `ab_BrokerObjectId` | `6f70a764-908f-435b-a930-ffcb375577f3` | *not used by this flow* |

  The broker **client secret** lives inside `GetFabricToken`, is scrubbed on export, and must be re-entered per environment (PREREQUISITES E4). Never commit it.

- The networking endpoints have only been exercised as `sp_fabric_powerapp` since the identity switch. A `403` here means the broker lacks a role on the workspace; a `401` means PREREQUISITES A3 or B1 is missing.

Actions are listed in execution order. Build them in that order — inserting an action later re-parents its successor and silently creates a parallel branch.

> **JSON key order is not execution order in this export.** `Run_a_Child_Flow` is the **last** key in `actions` and the **first** action to run. Follow `runAfter`.

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
| 1 | `workspaceId` | `text` | string | Yes | `@triggerBody()['text']` |

The underlying key is `text`; `workspaceId` is only the display title. Keep it required — an optional PowerApp V2 input is **dropped from the payload entirely** when blank, the property is absent rather than empty, and the unsafe `triggerBody()['text']` form used here would then throw `InvalidTemplate: property 'text' doesn't exist`.

> The flow takes `workspaceId` at face value. There is no ownership check, so it will read the policy of any workspace the broker administers for any caller who can run it. Same posture as the Git flows — OPEN-ISSUES §10.3.

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

## 3. `Initialize_variable` — InitializeVariable

Runs after `Run_a_Child_Flow` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `accessToken` |
| Type | String |
| Value | `@body('Run_a_Child_Flow')?['access_token']` |

Note the bare `@expr` form, not `@{ }`. The action name is the designer default `Initialize_variable` — it was not renamed when the token block was replaced.

`accessToken` holds a bearer token with tenant-wide Fabric rights for the broker. It is deliberately never a trigger input and never returned to the app.

---

## 4. `HTTP_2` — Http

Runs after `Initialize_variable` on **Succeeded**.

| Field | Value |
|---|---|
| Method | `GET` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}/networking/communicationPolicy/outbound/git` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Header `Accept` | `application/json` |
| Body | none |
| `retryPolicy` | *(absent — default exponential, 4 retries)* |
| Authentication block | none — bearer token supplied by hand in the header |

The action keeps its designer-generated name `HTTP_2` from before the FN.1 rewrite, when `HTTP` was the token call. Renaming it now would mean rewiring the Respond; it is left alone deliberately.

The response body carries `defaultAction` — the only field this flow uses.

---

## Response contract

`Respond_to_a_Power_App_or_flow` — type `Response`, kind `PowerApp`, `statusCode` 200. Runs after `HTTP_2` on **Succeeded**.

| Output name (as exported) | Title | Type | Value |
|---|---|---|---|
| `gitaction` | `GitAction` | string | `@{body('HTTP_2')?['defaultAction']}` |

Keep every Respond field typed **string**. The designer wraps a single expression in `@{ }`, which stringifies it, so a field declared boolean or number returns `"true"` / `"7"` and fails schema validation — and one bad field makes every output of the flow unreadable in the app, not just the bad one. The single field here is correctly string.

There is a live temptation to make this a boolean, because the app renders it as a toggle. Do not. Return the string and compare it in Power Fx. That exact conversion is what broke `isConnected` in `GetWorkspaceGitState` and `count` in `ListMyConnections`.

The safe `?[...]` accessor is used, so a response body without `defaultAction` yields an empty string rather than throwing.

Output names come back **lowercased** in Power Fx — bind to `gitaction`, not `GitAction`. The camel-case form is the display title only.

`Respond` runs on **Succeeded** only. A Fabric error therefore fails the run with no response, and the app sees a hard error rather than a readable message. That is the pre-existing shape of all eight networking flows; the Git-integration flows use **Succeeded or Failed** with a derived `outcome` instead.

---

## After building

- Add the flow to the canvas app (left rail → Power Automate → **+ Add flow**). Watch for a suffixed duplicate such as `GetGitPolicy_1` from adding it twice.
- If you change the trigger inputs later, **remove and re-add the flow in the app** — Power Apps caches the signature at bind time.
- Renaming the flow does not change the name Power Fx binds to. Trust formula-bar autocomplete over the portal display name.
- Pass the trigger input **positionally**: `GetGitPolicy.Run(workspaceId)`. Do not use a trailing options record.
- The flow answers a PowerApp, so it must respond within **120 seconds**. One child call and one GET; the budget is not at risk.
- The app calls this from the Outbound tab's `OnVisible`, **guarded** by `If(gblFlowResult.oapenabled, ...)` — no outbound policy API is called when OAP is off. See `APP-OUTBOUND-TAB.md`.
