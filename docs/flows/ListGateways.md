# Flow — `ListGateways`

Build instructions for the delegated read that returns every gateway the signed-in user has permission for, paged, as a single JSON string. The canvas app's Outbound tab calls it to populate the gateway picker. One of the eight pre-existing networking flows, not part of the Git-integration build order.

Verified against `Workflows/ListGateways-4469367C-AD89-F111-AB0F-7C1E528D41FB.json` on 2026-08-17.

Related: [../FLOWS.md](../FLOWS.md) (Networking flows → ListGateways), [../CUSTOM-CONNECTOR.md](../CUSTOM-CONNECTOR.md) §2.1 (the `ListGateways` operation), [../PREREQUISITES.md](../PREREQUISITES.md) (A2, E5, E6, E7, E8), [../OPEN-ISSUES.md](../OPEN-ISSUES.md) §1.3, §1.4, §1.5, §9, [../APP-OUTBOUND-TAB.md](../APP-OUTBOUND-TAB.md) (how the app calls it), [ListMyConnections.md](ListMyConnections.md) (the other delegated connector flow, same paging idiom), [AddConnectionRoleAssignment.md](AddConnectionRoleAssignment.md) (same idiom again).

---

## 0. Before you start

- Create the flow **inside the solution**, so it binds to a connection reference rather than a raw connection.
- The custom connector `gateway_lst_app_con` (schema name `ab_gateway-5flst-5fapp-5fcon`) must already exist with the operation `ListGateways`. See `CUSTOM-CONNECTOR.md` §2.1.
- The connector connection is **delegated** — `runtimeSource` is `"invoker"`, which is what makes the action run as the signed-in user rather than as the flow owner. Sharing must be *Provided by run-only user* (PREREQUISITES E5).
- The delegated app registration `gateway_lister_app` must publish `Gateway.Read.All` and `offline_access`, and the connector's Security tab must ask for the same space-delimited string. The two are edited separately and neither validates the other (PREREQUISITES A2).
- **No environment variables are referenced by this flow.** `ab_TenantId`, `ab_BrokerClientId` and `ab_BrokerObjectId` all describe the broker service principal; this flow never touches the broker.

  | Variable | Default in the solution | Used by this flow |
  |---|---|---|
  | `ab_TenantId` | `9e929790-272d-4977-a2ab-301443c11ece` | no |
  | `ab_BrokerClientId` | `a385fde9-1d6a-4e7f-8336-dc7feba5a4bc` | no |
  | `ab_BrokerObjectId` | `6f70a764-908f-435b-a930-ffcb375577f3` | no |

- The connector hardcodes `TenantId` in its connection parameters and that value travels with the export. In another tenant every sign-in fails until it is corrected (PREREQUISITES E8).
- The connection reference in the export is `ab_sharedgateway5flst5fapp5fcon5fe4e6bd1abcd77fac5f0c1c5dd7f4e428ac_502aa`, bound under the local name `shared_gateway-5flst-5fapp-5fcon-5fe4e6bd1abcd77fac-5f0c1c5dd7f4e428ac_1`.

Actions are listed in execution order. Build them in that order — inserting an action later re-parents its successor and silently creates a parallel branch.

> **JSON key order is not execution order in this export.** `Initialize_variable_4` is the **last** key in `actions` and the **fourth** action to run; `Respond_to_a_Power_App_or_flow` is declared before it and runs last. Inside `Do_until`, `Increment_variable` is the fifth key and the first inner action. Follow `runAfter`.

---

## 1. Trigger — Power Apps (V2)

| Field | Value |
|---|---|
| Type | `Request` |
| Kind | `PowerAppV2` |
| Action name | `manual` |

**No inputs.** The trigger schema is:

```json
{ "type": "object", "properties": {}, "required": [] }
```

Nothing downstream reads `triggerBody()`. The flow returns the caller's gateways, and who the caller is comes from the delegated connection, not from a parameter.

Because there are no inputs there is no positional-key hazard here. If one is ever added, make it **required** — an optional PowerApp V2 input is dropped from the payload entirely when blank, and is invisible in run history.

---

## 2. `Initialize_variable` — InitializeVariable

First action; `runAfter` is empty.

| Field | Value |
|---|---|
| Name | `gwArray` |
| Type | Array |
| Value | `[]` |

The accumulator for merged pages.

---

## 3. `Initialize_variable_2` — InitializeVariable

Runs after `Initialize_variable` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `cont` |
| Type | String |
| Value | *(no `value` property at all)* |

**Leave the value box empty.** Do not type quotes, backticks or a space. This action once carried backticks and iteration 1 sent `continuationToken=%60%60` — FN.2, fixed and verified 2026-08-06 (OPEN-ISSUES §1.3). An omitted `value` starts the variable as the empty string, so iteration 1 sends `continuationToken=`, which the API accepts.

---

## 4. `Initialize_variable_3` — InitializeVariable

Runs after `Initialize_variable_2` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `more` |
| Type | Boolean |
| Value | `true` |

Seeded `true` so the loop runs at least once. Note the polarity is the opposite of `isDone` in `ListMyConnections` and `AddConnectionRoleAssignment` — here `more` means *keep going*.

---

## 5. `Initialize_variable_4` — InitializeVariable

Runs after `Initialize_variable_3` on **Succeeded**. Declared **last** in the JSON.

| Field | Value |
|---|---|
| Name | `pageCount` |
| Type | Integer |
| Value | `0` |

The page cap counter. See §6 for why it exists and what it costs.

---

## 6. `Do_until` — paged read of gateways

Runs after `Initialize_variable_4` on **Succeeded**.

| Field | Value |
|---|---|
| Loop condition (raw) | `@or(equals(variables('more'), false), greaterOrEquals(variables('pageCount'), 5))` |
| Count | `60` |
| Timeout | `PT1H` |

The condition cannot be expressed in the designer's basic mode — an OR of two tests needs **advanced mode**. Type the expression above verbatim.

**The 5-page cap is deliberate** (OPEN-ISSUES §1.4, FN.3). The residual it carries is unaddressed and worth knowing: when the cap is what stops the loop, the flow returns **success with a silently truncated list**, and neither the flow nor the app can distinguish that from a complete result. If gateway counts ever approach five pages, either surface `more` as a "more results exist" flag or raise the cap.

**The `count: 60` / `timeout: PT1H` limits are the designer defaults and are effectively dead**, because the page cap always fires first. They are also far outside the **120-second** budget this flow has for its PowerApp response — `AddConnectionRoleAssignment` sets `PT1M` for exactly that reason. Nothing here enforces the budget; the 5-page cap does it by accident.

Inside the loop, in this exact order:

### 6.1 `Increment_variable` — IncrementVariable

`runAfter` is empty — this is the **first** inner action, before the connector call.

| Field | Value |
|---|---|
| Name | `pageCount` |
| Value | `1` |

Counting before fetching means `pageCount` is 1 during the first page, so the cap admits pages 1–5.

### 6.2 `list_gateways` — OpenApiConnection

Runs after `Increment_variable` on **Succeeded**.

| Field | Value |
|---|---|
| `host.connectionName` | `shared_gateway-5flst-5fapp-5fcon-5fe4e6bd1abcd77fac-5f0c1c5dd7f4e428ac_1` |
| `host.operationId` | `ListGateways` |
| `host.apiId` | `/providers/Microsoft.PowerApps/apis/shared_gateway-5flst-5fapp-5fcon-5fe4e6bd1abcd77fac-5f0c1c5dd7f4e428ac` |
| Parameter `continuationToken` | `@variables('cont')` |
| `authentication` | `@parameters('$authentication')` |

`GET /v1/gateways?continuationToken=…` behind the connector. The action name `list_gateways` is the operation's **Summary**, not its Operation ID — every expression below references `body('list_gateways')`, so renaming it breaks four expressions at once.

### 6.3 `MergePages` — Compose

Runs after `list_gateways` on **Succeeded**.

```
@union(variables('gwArray'), coalesce(body('list_gateways')?['value'], json('[]')))
```

A Compose, not a Set variable. `Set variable gwArray = union(variables('gwArray'), …)` is **illegal** — a variable may not reference itself in its own assignment. The Compose holds the union and the next action copies it out.

The `coalesce(..., json('[]'))` guards the final page, where `value` may be absent. Logic Apps evaluates function arguments eagerly, so an unguarded `union` throws rather than short-circuiting.

### 6.4 `Set_variable_3` — SetVariable

Runs after `MergePages` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `gwArray` |
| Value | `@outputs('MergePages')` |

### 6.5 `Set_variable` — SetVariable

Runs after `Set_variable_3` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `cont` |
| Value | `@{coalesce(body('list_gateways')?['continuationToken'], '')}` |

The `@{ }` form is correct here: the target is a string variable, and the interpolation is what turns a missing token into `''`.

### 6.6 `Set_variable_2` — SetVariable

Runs after `Set_variable` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `more` |
| Value | `@not(empty(variables('cont')))` |

Bare `@expr`, not `@{ }` — this one must stay a real boolean, because the loop condition compares it with `equals(variables('more'), false)`.

The three setters must run **after** `MergePages`, in this order. `cont` is read by the next iteration's `list_gateways` and by `Set_variable_2` in the same iteration, so a parallel branch here produces a loop that either never exits or exits after one page.

> **Nothing outside the loop references a loop-internal action.** Every value that survives the loop does so through `gwArray`. Referencing `body('list_gateways')` after the loop would resolve to nothing.

---

## Response contract

`Respond_to_a_Power_App_or_flow` — type `Response`, kind `PowerApp`, `statusCode` 200. Runs after `Do_until` on **Succeeded**.

| Output name (as exported) | Title | Type | Value (verbatim) |
|---|---|---|---|
| `gatewaysjson` | `GatewaysJson` | string | `@{string(variables('gwArray'))}` |

Keep every Respond field typed **string**. The designer wraps a single expression in `@{ }`, which stringifies it, so a field declared boolean or number returns `"true"` / `"7"` and fails schema validation — and one bad field makes every output of the flow unreadable in the app, not just the bad one. The single field here is correctly string, and the explicit `string(...)` around the array is what makes it honest.

Output names come back **lowercased** in Power Fx — bind to `gatewaysjson`, not `GatewaysJson`. Parse it app-side with `ParseJSON`.

**A Do-until that exits on its own limit still reports Succeeded.** With `Respond` running on **Succeeded** only, a capped or timed-out loop is indistinguishable from a complete one — the app gets a 200 and a short list. This is the same warning that drove F2.1, retained here because this flow keeps its loop (OPEN-ISSUES §6.2, §1.4).

---

## After building

- Add the flow to the canvas app (left rail → Power Automate → **+ Add flow**). Watch for a suffixed duplicate such as `ListGateways_1` from adding it twice.
- Renaming the flow does not change the name Power Fx binds to. Trust formula-bar autocomplete over the portal display name.
- The flow takes no inputs: call it as `ListGateways.Run()`.
- The trigger has no inputs to change, so the remove-and-re-add rule does not bite here — but it would the moment one is added, because Power Apps caches the signature at bind time.
- The flow answers a PowerApp, so it must respond within **120 seconds**. Up to five connector round trips; the budget is not at risk in practice, but nothing in the loop limits enforces it.
- The app calls this from `Form Screen.OnVisible`, guarded by `If(gblFlowResult.oapenabled, ...)` — see `APP-OUTBOUND-TAB.md`.
- Because the connection is delegated, set **Run only users → Provided by run-only user** on this flow. Left on the owner's connection it returns the *owner's* gateways to every user, silently and plausibly.

---

## Known drift from the exported definition

- **`FLOWS.md` claims `ListGateways` is the only flow with a loop.** Under *Gotchas*: "`ListGateways` is the only flow with a loop left." `OPEN-ISSUES.md` §6.2 repeats it: "The underlying warning still stands for `ListGateways`, which keeps its loop." The export has `Do_until` loops in **three** flows — this one, `ListMyConnections-98B3E46A-…` and `AddConnectionRoleAssignment-5C9CFCBF-…`. The Do-until-reports-success warning applies to all three.
- **The connection reference logical name does not match the documented one.** `ARCHITECTURE.md` §5 gives `ab_sharedgateway5flst5fapp5fcon5fe4e6bd1abcd77fac5f0c1c5dd7f4e428ac_e4bca`, and `OPEN-ISSUES.md` §1.5 says "A single connection reference remains". This flow's export carries `…_502aa`; `ListMyConnections` carries `…_78f84`; `AddConnectionRoleAssignment` carries `…_e7dd2` and `…_36424`. Four distinct references across three flows, and **none** of them is `…_e4bca`. Recreating a connection mints a new reference, so re-check every flow after any connection change rather than assuming one name covers the solution.
- **The connector scope string differs between docs.** `ARCHITECTURE.md` §5 lists `Gateway.Read.All offline_access`; `CUSTOM-CONNECTOR.md` §1 and `PREREQUISITES.md` A2 both list `Gateway.Read.All Connection.ReadWrite.All offline_access`. The connector is shared with `ListMyConnections` and `AddConnectionRoleAssignment`, which need `Connection.ReadWrite.All`, so the longer string is the correct one — `ARCHITECTURE.md` predates those operations.
