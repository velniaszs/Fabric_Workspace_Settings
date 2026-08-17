# Flow — `AddConnectionRoleAssignment`

Build instructions for the delegated flow that grants SPN-A the `User` role on an owner's Fabric connection, so the broker can later reference that connection by ID.

Verified against `Workflows/AddConnectionRoleAssignment-5C9CFCBF-A294-F111-8075-000D3ABA40DB.json` on 2026-08-17.

Related: `FLOWS.md` §7 (design rationale), `CUSTOM-CONNECTOR.md` (the connector operations this flow calls), `PREREQUISITES.md` (run-only user sharing), `OPEN-ISSUES.md` §9.

---

## 0. Before you start

- Create the flow **inside the solution**, so it binds to a connection reference rather than a raw connection.
- The custom connector `gateway_lst_app_con` must already exist with operations `ListConnectionRoleAssignments` and `AddConnectionRoleAssignment`.
- The connector connection is **delegated** — it runs as the signed-in user. Sharing must be *Provided by run-only user*.
- Environment variable `ab_BrokerObjectId` must exist. Current default: `6f70a764-908f-435b-a930-ffcb375577f3`.

Actions are listed in execution order. Build them in that order — inserting an action later re-parents its successor and silently creates a parallel branch.

---

## 1. Trigger — Power Apps (V2)

Add **Power Apps (V2)**, then one input:

| Field | Value |
|---|---|
| Type | Text |
| Input title | `connectionId` |
| Description | `Please enter your input` |
| Required | Yes |

Referenced downstream as `@triggerBody()['text']` — the schema key stays `text` regardless of the title.

Make the input **required**. An optional PowerApp V2 input is dropped from the payload entirely when blank, invisible in run history.

---

## 2. Variables

Three **Initialize variable** actions, chained on Succeeded:

| Order | Name | Type | Initial value |
|---|---|---|---|
| 1 | `assignments` | Array | *(leave empty)* |
| 2 | `cont` | String | *(leave empty)* |
| 3 | `isDone` | Boolean | `false` |

---

## 3. `Do_until` — paged read of existing assignments

Add **Do until** after `Initialize_isDone`.

| Field | Value |
|---|---|
| Loop condition | `isDone` **is equal to** `true` |
| Count | `10` |
| Timeout | `PT1M` |

The raw expression is `@equals(variables('isDone'), true)`.

The timeout is one minute, not the five used elsewhere, because this flow answers a PowerApp and that response has a **120-second budget**. A five-minute loop would outlive the caller.

Inside the loop, in this exact order:

### 3.1 `ListConnectionRoleAssignments`

Custom connector action.

| Parameter | Value |
|---|---|
| `fabricConnectionId` | `@triggerBody()['text']` |
| `continuationToken` | `@variables('cont')` |

### 3.2 `Merge_assignments` — Compose

```
union(variables('assignments'), coalesce(body('ListConnectionRoleAssignments')?['value'], json('[]')))
```

A Compose rather than assigning the variable to an expression that reads itself. The `coalesce(..., json('[]'))` guards the final page, where `value` may be absent — function arguments evaluate eagerly, so an unguarded `union` throws.

### 3.3 `Set_variable_assignments` — Set variable

| Field | Value |
|---|---|
| Name | `assignments` |
| Value | `@outputs('Merge_assignments')` |

### 3.4 `Set_variable_cont` — Set variable

| Field | Value |
|---|---|
| Name | `cont` |
| Value | `@{coalesce(body('ListConnectionRoleAssignments')?['continuationToken'], '')}` |

### 3.5 `Set_variable_isDone` — Set variable

| Field | Value |
|---|---|
| Name | `isDone` |
| Value | `@empty(variables('cont'))` |

---

## 4. `Filter_array`

Add **Filter array** immediately after the loop.

| Field | Value |
|---|---|
| From | `@variables('assignments')` |
| Where | `@equals(item()?['principal']?['id'], parameters('BrokerObjectId (ab_BrokerObjectId)'))` |

**This must run after `Do_until`, not after `Initialize_isDone`.** If it ends up parented to the wrong predecessor it forms a parallel branch, reads `assignments` before the loop has written it, finds nothing, and issues a duplicate `POST`. The symptom is a correct-looking answer arriving by the wrong route — check the run graph, not just the output.

---

## 5. `Condition`

| Field | Value |
|---|---|
| Left | `@empty(body('Filter_array'))` |
| Operator | is equal to |
| Right | `@true` |

### 5.1 True branch — not yet granted

**`AddConnectionRoleAssignment`** (custom connector):

| Parameter | Value |
|---|---|
| `fabricConnectionId` | `@triggerBody()['text']` |
| `body/principal/id` | `@parameters('BrokerObjectId (ab_BrokerObjectId)')` |
| `body/principal/type` | `ServicePrincipal` |
| `body/role` | `User` |

Then **Respond to a Power App or flow**, running after `AddConnectionRoleAssignment` succeeds:

| Output (string) | Value |
|---|---|
| `outcome` | `Granted` |
| `message` | `Broker granted User on the connection` |

### 5.2 False branch — already granted

**Respond to a Power App or flow**:

| Output (string) | Value |
|---|---|
| `outcome` | `AlreadyGranted` |
| `message` | `Broker already has access` |

---

## 6. Response contract

Both Respond actions must declare **identical** output names and types:

| Name | Type |
|---|---|
| `outcome` | string |
| `message` | string |

Keep every Respond field typed **string**. The designer wraps a single expression in `@{ }`, which stringifies it, so a field declared boolean or number returns `"true"` / `"7"` and fails schema validation — and one bad field makes every output of the flow unreadable in the app.

Output names come back **lowercased** in Power Fx.

---

## 7. After building

- Add the flow to the canvas app (left rail → Power Automate → **+ Add flow**). Watch for a suffixed duplicate such as `AddConnectionRoleAssignment_1` from adding it twice.
- If you change the trigger inputs later, **remove and re-add the flow in the app** — Power Apps caches the signature at bind time.
- Renaming the flow does not change the name Power Fx binds to. Trust formula-bar autocomplete over the portal display name.
- Pass the trigger input positionally: `AddConnectionRoleAssignment.Run(connId)`.

---

## 8. Known drift from the exported definition

- `FLOWS.md` §7 describes a `Failed` outcome and says the success Respond runs on "**Succeeded or Failed**". The exported definition has `Respond_to_a_Power_App_or_flow` running after `AddConnectionRoleAssignment` on **Succeeded only**, and no `Failed` branch exists. A connector error therefore fails the run with no response, and the app sees a timeout rather than an outcome.
- The export carries **two** connection references for the same connector — `…_e7dd2` used by `ListConnectionRoleAssignments` and `…_36424` used by `AddConnectionRoleAssignment`. Rebuilding by hand normally produces one. This is harmless but means a connection recreation must be checked against both.
