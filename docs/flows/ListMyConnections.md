# Flow — `ListMyConnections`

Build instructions for the delegated read that returns the **signed-in user's** Azure DevOps connections, so the Git wizard can offer a connection picker. Flow 3 of the Git-integration build order.

Verified against `Workflows/ListMyConnections-98B3E46A-278F-F111-8076-7CED8D76BF1B.json` on 2026-08-17.

Related: [../FLOWS.md](../FLOWS.md) §3 (design rationale), [../CUSTOM-CONNECTOR.md](../CUSTOM-CONNECTOR.md) §2.2 (the `ListConnections` operation), [../PREREQUISITES.md](../PREREQUISITES.md) (A2, E5, E6, E7, E8), [../OPEN-ISSUES.md](../OPEN-ISSUES.md) F3.1, §9, [../APP-GIT-TAB.md](../APP-GIT-TAB.md) (flow contracts), [../APP-GIT-CONNECT-FORM.md](../APP-GIT-CONNECT-FORM.md) (the dropdown it feeds), [AddConnectionRoleAssignment.md](AddConnectionRoleAssignment.md) (the delegated write that follows it), [ListGateways.md](ListGateways.md) (same paging idiom).

---

## 0. Before you start

- Create the flow **inside the solution**, so it binds to a connection reference rather than a raw connection.
- The custom connector `gateway_lst_app_con` (schema name `ab_gateway-5flst-5fapp-5fcon`) must already exist with the operation `ListConnections`. See `CUSTOM-CONNECTOR.md` §2.2.
- The connector connection is **delegated** — `runtimeSource` is `"invoker"`. That is the whole point of the flow: without it, it silently returns the flow owner's connections and reintroduces the exact bug F3.1 described. Sharing must be *Provided by run-only user* (PREREQUISITES E5).
- The delegated app registration `gateway_lister_app` must publish `Connection.ReadWrite.All` (and `offline_access`), and the connector's Security tab must ask for the same space-delimited string. Adding a scope later is expensive — the Entra consent grant outlives the connection and must be revoked per user before anyone can reconsent (OPEN-ISSUES §9.3).
- **No environment variables are referenced by this flow.** All three describe the broker service principal, which this flow never uses.

  | Variable | Default in the solution | Used by this flow |
  |---|---|---|
  | `ab_TenantId` | `9e929790-272d-4977-a2ab-301443c11ece` | no |
  | `ab_BrokerClientId` | `a385fde9-1d6a-4e7f-8336-dc7feba5a4bc` | no |
  | `ab_BrokerObjectId` | `6f70a764-908f-435b-a930-ffcb375577f3` | no |

- The connector hardcodes `TenantId` in its connection parameters and that value travels with the export (PREREQUISITES E8).
- The connection reference in the export is `ab_sharedgateway5flst5fapp5fcon5fe4e6bd1abcd77fac5f0c1c5dd7f4e428ac_78f84`, bound under the local name `shared_gateway-5flst-5fapp-5fcon-5fe4e6bd1abcd77fac-5f0c1c5dd7f4e428ac_1`.
- There is **no service-principal path here and there must not be one.** A delegated connector action carries its own auth; no `GetFabricToken` child call, no `accessToken` variable. Both were removed when this flow was rewritten in place on 2026-08-07.

Actions are listed in execution order. Build them in that order — inserting an action later re-parents its successor and silently creates a parallel branch.

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

Nothing reads `triggerBody()`. There is deliberately **no `workspaceId`** — connections belong to the user, not to a workspace, so the result set is identical on every workspace. That property is what makes the app's dropdown behave the way `APP-GIT-CONNECT-FORM.md` describes.

If an input is ever added, make it **required** — an optional PowerApp V2 input is dropped from the payload entirely when blank, and is invisible in run history.

---

## 2. `Initialize_connections` — InitializeVariable

First action; `runAfter` is empty.

| Field | Value |
|---|---|
| Name | `connections` |
| Type | Array |
| Value | *(no `value` property at all)* |

Unlike `ListGateways`, which seeds `gwArray` with `[]`, this one omits the value entirely. Both start empty; the omission is safe because `union` in §5.2 is only ever reached with the variable already initialized.

---

## 3. `Initialize_cont` — InitializeVariable

Runs after `Initialize_connections` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `cont` |
| Type | String |
| Value | *(no `value` property at all)* |

Leave the value box empty. Do not type quotes or backticks — the backtick defect that cost `ListGateways` an iteration (OPEN-ISSUES §1.3) starts exactly here.

---

## 4. `Initialize_isDone` — InitializeVariable

Runs after `Initialize_cont` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `isDone` |
| Type | Boolean |
| Value | `false` |

---

## 5. `Do_until` — paged read of the caller's connections

Runs after `Initialize_isDone` on **Succeeded**.

| Field | Value |
|---|---|
| Loop condition (raw) | `@equals(variables('isDone'), true)` |
| Count | `10` |
| Timeout | `PT5M` |

In the designer this is `isDone` **is equal to** `true`. No advanced mode needed — a single test, unlike `ListGateways`, which ORs a page cap in.

**`PT5M` outlives the caller.** This flow answers a PowerApp, and that response has a **120-second** budget; a loop permitted to run five minutes cannot deliver inside it. `AddConnectionRoleAssignment` sets `PT1M` for precisely this reason. In practice the loop is never the constraint — a delegated call returns only that user's connections, a handful rather than thousands — but the limit is wrong on paper.

Inside the loop, in this exact order:

### 5.1 `list_my_connections` — OpenApiConnection

`runAfter` is empty — this is the **first** inner action.

| Field | Value |
|---|---|
| `host.connectionName` | `shared_gateway-5flst-5fapp-5fcon-5fe4e6bd1abcd77fac-5f0c1c5dd7f4e428ac_1` |
| `host.operationId` | `ListConnections` |
| `host.apiId` | `/providers/Microsoft.PowerApps/apis/shared_gateway-5flst-5fapp-5fcon-5fe4e6bd1abcd77fac-5f0c1c5dd7f4e428ac` |
| Parameter `continuationToken` | `@variables('cont')` |
| `authentication` | `@parameters('$authentication')` |

The action name `list_my_connections` is the operation's **Summary**; the Operation ID is `ListConnections`. Four expressions reference `body('list_my_connections')`, so rename it before wiring anything, not after.

### 5.2 `Merge_connections` — Compose

Runs after `list_my_connections` on **Succeeded**.

```
@union(variables('connections'), coalesce(body('list_my_connections')?['value'], json('[]')))
```

A Compose, not a Set variable. `Set variable connections = union(variables('connections'), …)` is **illegal** — a variable may not reference itself in its own assignment. The Compose holds the union; the next action copies it out.

`coalesce(..., json('[]'))` guards the final page, where `value` may be absent. Logic Apps evaluates function arguments eagerly, so an unguarded `union` throws.

### 5.3 `Set_variable_connections` — SetVariable

Runs after `Merge_connections` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `connections` |
| Value | `@outputs('Merge_connections')` |

### 5.4 `Set_variable__cont` — SetVariable

Runs after `Set_variable_connections` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `cont` |
| Value | `@{coalesce(body('list_my_connections')?['continuationToken'], '')}` |

The action name carries a **double underscore** — `Set_variable__cont`, from a trailing space in the display name. Harmless, but match it exactly if you are reconciling against the export.

### 5.5 `Set_variable_isDone` — SetVariable

Runs after `Set_variable__cont` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `isDone` |
| Value | `@empty(variables('cont'))` |

Bare `@expr`, not `@{ }` — it must stay a real boolean for the loop condition's `equals(variables('isDone'), true)` to work.

The order is load-bearing: merge, then store the array, then the token, then the flag. `isDone` reads `cont`, which the previous action wrote in the same iteration.

> **Nothing outside the loop references a loop-internal action.** Everything that survives does so through `connections`.

---

## 6. `Filter_array` — Query

Runs after `Do_until` on **Succeeded**.

| Field | Value |
|---|---|
| From | `@variables('connections')` |
| Where | `@equals(item()?['connectionDetails']?['type'], 'AzureDevOpsSourceControl')` |

Filtered **client-side** because the API has no server-side type filter. Delegated scope keeps the unfiltered set small enough for that to be acceptable.

**This must run after `Do_until`, not after `Initialize_isDone`.** Attached to the wrong predecessor it forms a parallel branch, reads `connections` before the loop has written it, and returns an empty list — a plausible-looking answer arriving by the wrong route. Check the run graph, not just the output. Same defect as `AddConnectionRoleAssignment` §4.

---

## 7. `Select` — Select

Runs after `Filter_array` on **Succeeded**.

| Field | Value |
|---|---|
| From | `@body('Filter_array')` |

Map, three fields:

```json
{
  "id": "@item()?['id']",
  "displayName": "@item()?['displayName']",
  "path": "@item()?['connectionDetails']?['path']"
}
```

`path` is the repo URL. The wizard derives organization, project and repository from it, so the owner never pastes a URL. Everything else the API returns — `gatewayId`, `connectivityType`, `privacyLevel` — is dropped here deliberately.

All three use the safe `?[...]` accessor, so a connection missing any of them yields null rather than failing the run.

---

## Response contract

`Respond_to_a_Power_App_or_flow_2` — type `Response`, kind `PowerApp`, `statusCode` 200. Runs after `Select` on **Succeeded**.

| Output name (as exported) | Title | Type | Value (verbatim) |
|---|---|---|---|
| `connections` | `connections` | string | `@{string(body('Select'))}` |
| `count` | `count` | **number** | `@{length(body('Filter_array'))}` |

Keep every Respond field typed **string**. The designer wraps a single expression in `@{ }`, which stringifies it, so a field declared boolean or number returns `"true"` / `"7"` and fails schema validation — and one bad field makes every output of the flow unreadable in the app, not just the bad one.

> **`count` is that exact defect, still present in the export.** It is declared `"type": "number"` and emitted as `"@{length(body('Filter_array'))}"`, so the flow returns the string `"3"` where the schema promises `3`. Power Apps then fails the whole response with *JSON parsing error*, and `connections` becomes unreadable too — the field the app actually needs. `FLOWS.md` §3 and `APP-GIT-TAB.md` both record `count` as removed on 2026-08-12; it is not. **Delete it** (do not retype it to string) and use `CountRows(ParseJSON(…))` in Power Fx. See *Known drift* below.

Output names come back **lowercased** in Power Fx — bind to `connections`. Parse it with `ParseJSON`; it is a JSON array of `{ id, displayName, path }`.

`Respond` runs on **Succeeded** only. A connector failure therefore ends the run with no response and the app sees a hard error rather than a message.

---

## After building

- Add the flow to the canvas app (left rail → Power Automate → **+ Add flow**). Watch for a suffixed duplicate such as `ListMyConnections_1` from adding it twice.
- Renaming the flow does not change the name Power Fx binds to — this flow was renamed in place from the old broker-side flow 3 and kept its GUID `98B3E46A-278F-F111-8076-7CED8D76BF1B`. Trust formula-bar autocomplete over the portal display name.
- The flow takes no inputs: call it as `ListMyConnections.Run()`.
- If an input is ever added, **remove and re-add the flow in the app** — Power Apps caches the signature at bind time.
- The flow answers a PowerApp, so it must respond within **120 seconds**. The `PT5M` loop limit does not respect that; see §5.
- Set **Run only users → Provided by run-only user**. Left on the owner's connection this flow returns the owner's connections to every user — the F3.1 bug, and it looks entirely plausible from inside the app.

---

## Known drift from the exported definition

- **`count` was documented as removed and is still in the flow.** `FLOWS.md` §3 says: "~~`count`~~ was removed on 2026-08-12 — see the schema note under flow 4." `APP-GIT-TAB.md` strikes it through in the contracts table and states: "`ListMyConnections.count` had the identical defect (`@{length(...)}` against `"type": "number"`) and was deleted for the same reason." The export still declares it:

  ```json
  "body": {
    "connections": "@{string(body('Select'))}",
    "count": "@{length(body('Filter_array'))}"
  },
  "schema": { "properties": {
    "count": { "title": "count", "x-ms-dynamically-added": true, "type": "number" }
  } }
  ```

  This is not cosmetic. Response-schema validation covers the whole body, so while `count` is present the app cannot read `connections` either. Either the deletion was never made, or it was made and lost to a re-export.
- **`FLOWS.md` claims `ListGateways` is the only flow with a loop.** Under *Gotchas*: "`ListGateways` is the only flow with a loop left." This flow's `Do_until` is intact, as is `AddConnectionRoleAssignment`'s.
- **The connection reference logical name does not match the documented one.** `ARCHITECTURE.md` §5 gives `…_e4bca` and `OPEN-ISSUES.md` §1.5 says "A single connection reference remains". This flow carries `…_78f84`, `ListGateways` carries `…_502aa`, and `AddConnectionRoleAssignment` carries `…_e7dd2` and `…_36424`.
