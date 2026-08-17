# Flow — `SetGitPolicy`

Build instructions for the write that sets a workspace's outbound Git communication policy — the toggle on the canvas app's Outbound tab that permits or blocks the workspace talking to a Git provider. The matching read is `GetGitPolicy`. One of the eight pre-existing networking flows, not part of the Git-integration build order.

Verified against `Workflows/SetGitPolicy-8A588A8D-8E89-F111-AB0F-7C1E528D41FB.json` on 2026-08-17.

Related: [../../FLOWS.md](../../FLOWS.md) (Networking flows table), [../../PREREQUISITES.md](../../PREREQUISITES.md) (A1, A3, B1, E4), [../../OPEN-ISSUES.md](../../OPEN-ISSUES.md) §1.6, §10.3, [../../APP-OUTBOUND-TAB.md](../../APP-OUTBOUND-TAB.md) (how the app calls it), [GetFabricToken.md](GetFabricToken.md) (the child flow it calls), [GetGitPolicy.md](GetGitPolicy.md) (the matching read).

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

- This is a **write**, and the broker needs a role on the target workspace to make it. A `403` means the broker lost that role; a `401` means PREREQUISITES A3 or B1 is missing.

Actions are listed in execution order. Build them in that order — inserting an action later re-parents its successor and silently creates a parallel branch.

> **JSON key order is not execution order in this export.** `Run_a_Child_Flow` is the **last** key in `actions` and the **first** action to run. Follow `runAfter`.

---

## 1. Trigger — Power Apps (V2)

| Field | Value |
|---|---|
| Type | `Request` |
| Kind | `PowerAppV2` |
| Action name | `manual` |

Two text inputs, both `x-ms-content-hint: TEXT`, both with the designer default description `Please enter your input`, and **both required**:

| # | Input title | Schema key | Type | Required | Raw reference |
|---|---|---|---|---|---|
| 1 | `workspaceId` | `text` | string | Yes | `@triggerBody()['text']` |
| 2 | `Action` | `text_1` | string | Yes | `@triggerBody()['text_1']` |

The titles are display only; the schema keys `text` and `text_1` are what the definition reads, and they bind **positionally**. Getting them the wrong way round sends a workspace ID as the policy value and a policy value as the workspace ID — the URI 404s and nothing indicates a swap.

Both are required and must stay required. An optional PowerApp V2 input is **dropped from the payload entirely** when blank — the property is absent rather than empty — and both references here use the unsafe `triggerBody()['…']` form, which then throws `InvalidTemplate: property 'text_1' doesn't exist`. That is why neither reference needs a `?[...]` guard or a `coalesce`.

> The flow takes `workspaceId` at face value. There is no ownership check, so it will change the policy of any workspace the broker administers for any caller who can run it. Deferred by decision — OPEN-ISSUES §10.3.

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
| Method | `PUT` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}/networking/communicationPolicy/outbound/git` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Header `Content-Type` | `application/json` |
| `retryPolicy` | *(absent — default exponential, 4 retries)* |
| Authentication block | none — bearer token supplied by hand in the header |

Body — a JSON object with one interpolated field, not a `json(concat(...))` expression:

```json
{
  "defaultAction": "@{triggerBody()['text_1']}"
}
```

`defaultAction` is always a non-empty string here, so plain `@{ }` interpolation is safe. The `json(concat(...))` construction used in `SyncWorkspaceWithGit` exists only because a field there must be *present or absent*, never empty — that problem does not arise on this endpoint.

`PUT`, not `PATCH`: the whole policy document is replaced. The same URI as `GetGitPolicy`, and the field written is the field that flow reads back.

The action keeps its designer-generated name `HTTP_2` from before the FN.1 rewrite, when `HTTP` was the token call. Renaming it now would mean rewiring the Respond; it is left alone deliberately.

---

## Response contract

`Respond_to_a_Power_App_or_flow` — type `Response`, kind `PowerApp`, `statusCode` 200. Runs after `HTTP_2` on **Succeeded**.

| Output name (as exported) | Title | Type | Value (verbatim from the export) |
|---|---|---|---|
| `status` | `Status` | string | `"\"OK\""` |

Keep every Respond field typed **string**. The designer wraps a single expression in `@{ }`, which stringifies it, so a field declared boolean or number returns `"true"` / `"7"` and fails schema validation — and one bad field makes every output of the flow unreadable in the app, not just the bad one. The single field here is correctly string.

Output names come back **lowercased** in Power Fx — bind to `status`, not `Status`.

Two things about that value are worth stating plainly:

- **It is a literal, not a derived one.** Nothing is read from `HTTP_2`. `status` is `OK` on every run that reaches the Respond and carries no information beyond "the run got this far".
- **The quotes are part of the string.** The exported JSON is `"status": "\"OK\""`, so the app receives the six characters `"OK"` — including the double quotes — not `OK`. Any Power Fx comparison must account for that, or match on the flow having returned at all rather than on the value.

`Respond` runs on **Succeeded** only. A rejected `PUT` therefore fails the run with no response, and the app sees a hard error rather than a readable message. That is the pre-existing shape of all eight networking flows; the Git-integration flows use **Succeeded or Failed** with a derived `outcome` and a `message` carrying the raw Fabric payload instead. It also means a returned `status` genuinely does imply the write succeeded, which is the only reason the constant is tolerable.

---

## After building

- Add the flow to the canvas app (left rail → Power Automate → **+ Add flow**). Watch for a suffixed duplicate such as `SetGitPolicy_1` from adding it twice.
- If you change the trigger inputs later, **remove and re-add the flow in the app** — Power Apps caches the signature at bind time. With two positional inputs this matters more here than on the single-input flows.
- Renaming the flow does not change the name Power Fx binds to. Trust formula-bar autocomplete over the portal display name.
- Pass the inputs **positionally**, in trigger order: `SetGitPolicy.Run(workspaceId, action)`. Do not use a trailing options record.
- The flow answers a PowerApp, so it must respond within **120 seconds**. One child call and one PUT; the budget is not at risk.
- The app calls this from `TglGitAllowed.OnCheck` / `.OnUncheck` on the Outbound tab. That control is hidden when OAP is off, which is what keeps the write path from firing on a workspace where the policy does not apply — see `APP-OUTBOUND-TAB.md`.
