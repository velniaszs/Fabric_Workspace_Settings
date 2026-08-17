# Flow — `GetOAPSetting`

Build instructions for the read that tells the canvas app whether **Outbound Access Protection** is on for a workspace. It is the first flow the Outbound tab runs and the gate every other Outbound call is wrapped in. One of the eight pre-existing networking flows, not part of the Git-integration build order.

Verified against `Workflows/GetOAPSetting-1875AC61-1884-F111-AB0F-7C1E528D41FB.json` on 2026-08-17.

Related: [../../FLOWS.md](../../FLOWS.md) (Networking flows table), [../../PREREQUISITES.md](../../PREREQUISITES.md) (A1, A3, B1, E4), [../../OPEN-ISSUES.md](../../OPEN-ISSUES.md) §1.6, §10.3, [../../APP-OUTBOUND-TAB.md](../../APP-OUTBOUND-TAB.md) (the tab this flow gates), [GetFabricToken.md](GetFabricToken.md) (the child flow it calls), [GetOutboundRules.md](GetOutboundRules.md), [GetGatewayRules.md](GetGatewayRules.md), [GetGitPolicy.md](GetGitPolicy.md) (the reads it gates).

---

## 0. Before you start

- Create the flow **inside the solution**, so it binds to connection references rather than raw connections.
- **No connector connection is needed.** The flow uses only built-in actions: `Run a Child Flow`, `Initialize variable`, `HTTP`, `Parse JSON`, `Respond to a Power App or flow`. `connectionReferences` in the export is `{}`. The custom connector is not involved — do not add it.
- The child flow **`GetFabricToken`** must already exist. It is referenced by GUID: `50895fca-088f-f111-8076-7ced8d76bf1b` → `Workflows/GetFabricToken-50895FCA-088F-F111-8076-7CED8D76BF1B.json`.
- Authentication is **service principal**, not delegated. The inline `clientSecret` → token `HTTP` → `Parse_JSON` block that this flow used to carry was deleted on 2026-08-07 and replaced by the child-flow call (OPEN-ISSUES §1.6, FN.1). It previously ran as `sp_fabric_monit`, which holds `Tenant.Read.All` / `Tenant.ReadWrite.All`; it now runs as `sp_fabric_powerapp`. Do not reintroduce an inline token block.
- Environment variables are **not referenced directly by this flow**. They are consumed by the child flow:

  | Variable | Default in the solution | Used by |
  |---|---|---|
  | `ab_TenantId` | `9e929790-272d-4977-a2ab-301443c11ece` | `GetFabricToken` (token endpoint) |
  | `ab_BrokerClientId` | `a385fde9-1d6a-4e7f-8336-dc7feba5a4bc` | `GetFabricToken` (client id) |
  | `ab_BrokerObjectId` | `6f70a764-908f-435b-a930-ffcb375577f3` | *not used by this flow* |

  The broker **client secret** lives inside `GetFabricToken`, is scrubbed on export, and must be re-entered per environment (PREREQUISITES E4). Never commit it.

- This flow is called **unguarded** on every visit to the Outbound tab — it is the only Outbound call that is not wrapped in `If(gblFlowResult.oapenabled, ...)`, because it is what produces that value. If it fails, the whole tab renders as though OAP were off. A `403` means the broker lacks a role on the workspace; a `401` means PREREQUISITES A3 or B1 is missing.

Actions are listed in execution order. Build them in that order — inserting an action later re-parents its successor and silently creates a parallel branch.

> **JSON key order is not execution order in this export.** `Run_a_Child_Flow` is the **last** key in `actions` and the **first** action to run, and `Respond_to_a_Power_App_or_flow` appears **before** the `Parse_JSON_2` it depends on. Follow `runAfter`.

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

> The flow takes `workspaceId` at face value. There is no ownership check, so it will report the OAP posture of any workspace the broker administers for any caller who can run it. Same posture as the Git flows — OPEN-ISSUES §10.3.

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
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}/networking/communicationPolicy` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Header `Accept` | `application/json` |
| Body | none |
| `retryPolicy` | *(absent — default exponential, 4 retries)* |
| Authentication block | none — bearer token supplied by hand in the header |

This is the **root** of the communication-policy resource — no `/outbound/...` suffix. It returns both the `inbound` and `outbound` blocks in one document, which is why this flow can answer the OAP question without a second call.

The token comes from the `accessToken` variable, which comes from the child flow, which reads `ab_TenantId` and `ab_BrokerClientId` and holds the secret. Nothing sensitive appears in this action beyond the interpolated bearer value at run time.

**Headers are not copied when you duplicate an action.** A missing `Authorization` comes back as `401` with the same generic `RequestFailed` body Fabric uses for semantic rejections — check the header on every new HTTP action before chasing anything else.

The action keeps its designer-generated name `HTTP_2` from before the FN.1 rewrite, when `HTTP` was the token call. Renaming it now would mean rewiring `Parse_JSON_2` and the Respond; it is left alone deliberately.

---

## 5. `Parse_JSON_2` — ParseJson

Runs after `HTTP_2` on **Succeeded**. The only networking read that parses the response instead of returning it whole — because the app wants a decision, not a document.

| Field | Value |
|---|---|
| Content | `@body('HTTP_2')` |

Schema, verbatim:

```json
{
  "type": "object",
  "properties": {
    "inbound": {
      "type": "object",
      "properties": {
        "publicAccessRules": {
          "type": "object",
          "properties": {
            "defaultAction": { "type": "string" }
          }
        }
      }
    },
    "outbound": {
      "type": "object",
      "properties": {
        "publicAccessRules": {
          "type": "object",
          "properties": {
            "defaultAction": { "type": "string" }
          }
        }
      }
    }
  }
}
```

The schema declares no `required` array at any level, so a response missing `inbound` or `outbound` parses cleanly rather than failing the action — the absence is dealt with downstream by the `?[...]` chain in the Respond.

`inbound` is parsed but never read. It is in the schema because the designer generated it from a sample payload, not because anything consumes it. Leave it; deleting it gains nothing and re-generating the schema from a different workspace risks changing the `outbound` shape too.

The action name is the designer default with the `_2` suffix — a leftover from when `Parse_JSON` was the token-response parser, removed in the FN.1 rewrite.

---

## Response contract

`Respond_to_a_Power_App_or_flow` — type `Response`, kind `PowerApp`, `statusCode` 200. Runs after **`Parse_JSON_2`** on **Succeeded**, not after `HTTP_2`.

| Output name (as exported) | Title | Type | Value (verbatim) |
|---|---|---|---|
| `oapenabled` | `OAPEnabled` | **boolean** | `@equals(body('Parse_JSON_2')?['outbound']?['publicAccessRules']?['defaultAction'], 'Deny')` |

OAP is reported as **on** when the outbound public-access default action is `Deny`. Any other value — `Allow`, or the key being absent — yields `false`. The three `?[...]` hops are what make the missing-key case return `false` instead of throwing; `equals` evaluates its arguments eagerly, so an unguarded `['outbound']['publicAccessRules']['defaultAction']` would fail the run on a workspace with no policy at all.

**This is the one Respond field in the solution that is legitimately typed `boolean`**, and the reason it works is the expression form. The value is the bare `@equals(...)`, **not** `@{equals(...)}`. Only the bare `@expr` form preserves a real boolean; the designer's `@{ }` wrapper stringifies, so a `boolean`-typed field fed an interpolated expression returns `"true"` and fails schema validation — and one bad field makes every output of the flow unreadable in the app, not just the bad one. That is exactly how `GetWorkspaceGitState.isConnected` broke.

The rule stands for everything else: **keep every Respond field typed `string`** unless you have deliberately written a bare `@expr` and verified the run output, as was done here. If you edit this action in the designer and it re-wraps the expression as `@{equals(...)}`, change the schema type to `string` or restore the bare form — do not leave the mismatch.

Output names come back **lowercased** in Power Fx — bind to `oapenabled`, not `OAPEnabled`. Because it is a genuine boolean, `gblFlowResult.oapenabled` is usable directly in a `Visible` or an `If`; no `= true` is needed (APP-OUTBOUND-TAB, verified 2026-08-12).

`Respond` runs on **Succeeded** only. A rejected `GET` therefore fails the run with no response, and the app sees a hard error rather than a readable message. That is the pre-existing shape of most of the eight networking flows.

> `gblFlowResult` is blank until this flow returns, and blank is falsy. Every control gated on `oapenabled` starts hidden and `LblOapOff` starts visible — so the "OAP is disabled" message flashes on every workspace for the duration of this call. Documented, with an optional `gblOapLoaded` fix, in [../../APP-OUTBOUND-TAB.md](../../APP-OUTBOUND-TAB.md).

---

## After building

- Add the flow to the canvas app (left rail → Power Automate → **+ Add flow**). Watch for a suffixed duplicate such as `GetOAPSetting_1` from adding it twice.
- If you change the trigger inputs later, **remove and re-add the flow in the app** — Power Apps caches the signature at bind time.
- Renaming the flow does not change the name Power Fx binds to. Trust formula-bar autocomplete over the portal display name.
- Pass the single input positionally: `GetOAPSetting.Run(workspaceId)`. Do not use a trailing options record.
- The flow answers a PowerApp, so it must respond within **120 seconds**. One child call, one GET and a parse; the budget is not at risk. It is nonetheless on the critical path of every Outbound tab visit, so it is the call the user waits on.
- The app calls this from `Form Screen.OnVisible` as `Set(gblFlowResult, GetOAPSetting.Run(gblWsId));`, **unguarded**, before the `If(gblFlowResult.oapenabled, ...)` that wraps `GetOutboundRules`, `GetGitPolicy`, `ListGateways` and `GetGatewayRules`.
