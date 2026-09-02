# Flow — `ListPrivateEndpoints`

Build instructions for the read that returns a workspace's **managed private endpoints** — the gallery on the canvas app's Private endpoints element. One of three new networking flows; the writes are `CreatePrivateEndpoint` and `DeletePrivateEndpoint`.

> **Built and tested 2026-09-02 — not yet verified against an export.** Every other file in this folder is *verified against* an exported definition in `Workflows/`. This one was written as a specification and the flow was built from it. Re-export the solution and reconcile this document against the JSON before trusting the action names and `runAfter` details.

Related: [../../APP-PRIVATE-ENDPOINTS.md](../../APP-PRIVATE-ENDPOINTS.md) (design investigation — read §2 and §3 first), [../../FLOWS.md](../../FLOWS.md) (Networking flows table), [../../PREREQUISITES.md](../../PREREQUISITES.md) (A1, A3, B1, E4), [../../OPEN-ISSUES.md](../../OPEN-ISSUES.md) §1.6, §10.3, [GetFabricToken.md](GetFabricToken.md) (the child flow it calls), [CreatePrivateEndpoint.md](CreatePrivateEndpoint.md), [DeletePrivateEndpoint.md](DeletePrivateEndpoint.md), [GetOutboundRules.md](GetOutboundRules.md) (the closest existing read), [ListMyConnections.md](../ListMyConnections.md) (the paging idiom this borrows).

---

## 0. Before you start

- Create the flow **inside the solution**, so it binds to connection references rather than raw connections.
- **No connector connection is needed.** The flow uses only built-in actions: `Run a Child Flow`, `Initialize variable`, `Do until`, `HTTP`, `Compose`, `Set variable`, `Respond to a Power App or flow`. `connectionReferences` must end up `{}`. The custom connector is not involved — do not add it. See [../../APP-PRIVATE-ENDPOINTS.md](../../APP-PRIVATE-ENDPOINTS.md) §3 for why there is no delegated path here.
- The finished flow is **one** `Respond`, not two. If you are mid-build from an earlier revision of this document and have `Respond_success` / `Respond_failed`, delete both and rebuild §8 — the two-Respond shape required a blank output value, which the designer rejects.
- The child flow **`GetFabricToken`** must already exist. Reference it by GUID: `50895fca-088f-f111-8076-7ced8d76bf1b` → `Workflows/GetFabricToken-50895FCA-088F-F111-8076-7CED8D76BF1B.json`.
- Authentication is **service principal** (`sp_fabric_powerapp`), not delegated. Do not add an inline token block — that pattern was removed from all eight networking flows on 2026-08-07 (OPEN-ISSUES §1.6, FN.1).
- Environment variables are **not referenced directly by this flow**. They are consumed by the child flow:

  | Variable | Default in the solution | Used by |
  |---|---|---|
  | `ab_TenantId` | `9e929790-272d-4977-a2ab-301443c11ece` | `GetFabricToken` (token endpoint) |
  | `ab_BrokerClientId` | `a385fde9-1d6a-4e7f-8336-dc7feba5a4bc` | `GetFabricToken` (client id) |
  | `ab_BrokerObjectId` | `6f70a764-908f-435b-a930-ffcb375577f3` | *not used by this flow* |

  The broker **client secret** lives inside `GetFabricToken`, is scrubbed on export, and must be re-entered per environment (PREREQUISITES E4). Never commit it.

- The API requires **Viewer or higher** on the workspace. The broker holds Admin, so this is comfortably covered. A `403` means the broker lost its role on that workspace; a `401` means PREREQUISITES A3 or B1 is missing. Fabric's error body is generic for both — read the status code, not the message.
- **No Azure permission is involved in reading**, or in anything else this feature does. See [../../APP-PRIVATE-ENDPOINTS.md](../../APP-PRIVATE-ENDPOINTS.md) §3.2.

Actions are listed in execution order. Build them in that order — inserting an action later re-parents its successor and silently creates a parallel branch.

---

## 1. Trigger — Power Apps (V2)

| Field | Value |
|---|---|
| Type | `Request` |
| Kind | `PowerAppV2` |
| Action name | `manual` |

One text input, `x-ms-content-hint: TEXT`, **required**:

| # | Input title | Schema key | Type | Required | Raw reference |
|---|---|---|---|---|---|
| 1 | `workspaceId` | `text` | string | Yes | `@triggerBody()['text']` |

The underlying key is `text`; `workspaceId` is only the display title. Keep it required — an optional PowerApp V2 input is **dropped from the payload entirely** when blank, the property is absent rather than empty, and `triggerBody()['text']` would then throw `InvalidTemplate: property 'text' doesn't exist`.

> The flow takes `workspaceId` at face value. There is no ownership check, so it will list the private endpoints of any workspace the broker administers for any caller who can run it. Same posture as every other flow in this solution — OPEN-ISSUES §10.3. For a read this is the accepted position; for the two writes it is not (see [CreatePrivateEndpoint.md](CreatePrivateEndpoint.md) §0).

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

Bare `@expr` form, not `@{ }`. Keep the action name `Initialize_variable` to match the other networking flows.

`accessToken` holds a bearer token for the broker. It is deliberately never a trigger input and never returned to the app.

---

## 4. `Initialize_endpoints` — InitializeVariable

Runs after `Initialize_variable` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `endpoints` |
| Type | Array |
| Value | *(leave empty)* |

---

## 5. `Initialize_nextUri` — InitializeVariable

Runs after `Initialize_endpoints` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `nextUri` |
| Type | String |
| Value | `@{concat('https://api.fabric.microsoft.com/v1/workspaces/', triggerBody()['text'], '/managedPrivateEndpoints')}` |

**Seeded with the first-page URL**, which is what makes the loop body uniform — one HTTP action serves both the first page and every continuation.

> **Why `continuationUri` and not `continuationToken`.** Fabric returns the token **already percent-encoded** — the documented sample is `LDEsMTAwMDAwLDA%3D`. Building the next URL yourself means choosing between passing it raw (correct here, wrong if Fabric ever returns an unencoded token) and running `encodeUriComponent` over it (which turns `%3D` into `%253D` and silently returns page 1 forever). `continuationUri` is the same value already assembled correctly by the service, so the question never arises. The connector-based flows (`ListMyConnections`, `ListGateways`) do not face this because the connector owns the query-string encoding; a raw `HTTP` action does not.

---

## 6. `Initialize_isDone` — InitializeVariable

Runs after `Initialize_nextUri` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `isDone` |
| Type | Boolean |
| Value | `false` |

---

## 7. `Do_until` — paged read

Runs after `Initialize_isDone` on **Succeeded**.

| Field | Value |
|---|---|
| Loop condition (raw) | `@equals(variables('isDone'), true)` |
| Count | `10` |
| Timeout | `PT1M` |

**`PT1M`, not `PT5M`.** This flow answers a PowerApp and that response has a **120-second** budget; a loop permitted to run five minutes cannot deliver inside it. `ListMyConnections` carries `PT5M` and is wrong on paper for exactly this reason — do not copy it. `AddConnectionRoleAssignment` is the flow to imitate here.

Inside the loop, in this exact order:

### 7.1 `List_page` — Http

`runAfter` is empty — the **first** inner action.

| Field | Value |
|---|---|
| Method | `GET` |
| URI | `@{variables('nextUri')}` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Header `Accept` | `application/json` |
| Body | none |
| `retryPolicy` | *(leave default — exponential, 4 retries)* |
| Authentication block | none — bearer token supplied by hand in the header |

**Headers are not copied when you duplicate an action.** A missing `Authorization` comes back as `401` with the same generic `RequestFailed` body Fabric uses for semantic rejections — check the header on every new HTTP action before chasing anything else.

### 7.2 `Merge_endpoints` — Compose

Runs after `List_page` on **Succeeded**.

```
@union(variables('endpoints'), coalesce(body('List_page')?['value'], json('[]')))
```

A Compose, not a Set variable. `Set variable endpoints = union(variables('endpoints'), …)` is **illegal** — a variable may not reference itself in its own assignment. The Compose holds the union; the next action copies it out.

`coalesce(..., json('[]'))` guards a workspace with no endpoints at all, where `value` may be absent. Logic Apps evaluates function arguments eagerly, so an unguarded `union` throws.

### 7.3 `Set_variable_endpoints` — SetVariable

Runs after `Merge_endpoints` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `endpoints` |
| Value | `@outputs('Merge_endpoints')` |

### 7.4 `Set_variable_nextUri` — SetVariable

Runs after `Set_variable_endpoints` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `nextUri` |
| Value | `@{coalesce(body('List_page')?['continuationUri'], '')}` |

`continuationUri` is **removed from the response** on the last page, not returned empty — hence the `coalesce`.

### 7.5 `Set_variable_isDone` — SetVariable

Runs after `Set_variable_nextUri` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `isDone` |
| Value | `@empty(variables('nextUri'))` |

Bare `@expr`, not `@{ }` — it must stay a real boolean for the loop condition's `equals(variables('isDone'), true)` to work. Wrapping it makes the loop run until it hits the count limit and the symptom is a slow flow, not an error.

The order is load-bearing: merge, store the array, store the URI, then set the flag. `isDone` reads `nextUri`, which the previous action wrote in the same iteration.

> **Nothing outside the loop references a loop-internal action.** Everything that survives does so through `endpoints`.

---

## 8. Response contract

**One** `Respond to a Power App or flow` action — type `Response`, kind `PowerApp`, `statusCode` 200.

⋯ → **Configure run after** on `Do_until` → tick **is successful**, **has failed** and **has timed out**.

| Output name to type | Type | Value — entered through the **fx** tab |
|---|---|---|
| `EndpointsJson` | Text | `string(variables('endpoints'))` |
| `ErrorMessage` | Text | `coalesce(body('List_page')?['message'], body('List_page')?['errorCode'], '')` |

> **Never leave a Respond output blank.** The action treats every declared output as required and fails validation with *"… is required"* if the value box is empty. An earlier version of this document said to leave `ErrorMessage` empty on the success path — that does not build. If the failing field is named `text_1` rather than `ErrorMessage`, the Name box was never committed either; fix both.

**Both expressions work on both paths, which is what removes the need for a second Respond.**

- `EndpointsJson` — `endpoints` is initialised to an empty array and only ever appended to, so it is always a valid JSON array: the full set on success, `[]` if the first page failed, and a partial set if a later page did.
- `ErrorMessage` — on success the last page's body carries `value` and possibly `continuationToken`, but no `message` and no `errorCode`, so the `coalesce` falls through to `''`. On failure it returns Fabric's own text. If `List_page` never ran at all, `body('List_page')` is null and it still falls through to `''`.

**The app should treat a non-empty `errormessage` as authoritative even when `endpointsjson` has rows.** A multi-page read that fails on page 2 returns both — partial data and an error — and rendering the partial list silently would be worse than saying the load failed.

**Why bother with an error path on a read at all.** `GetOutboundRules` has only a success Respond, and a rejected call there ends the run with no output — the app gets a hard error and no reason. This flow runs on every visit to the tab, so an unreadable failure is a support ticket every time. Returning `[]` rather than nothing also stops the app's `ParseJSON` throwing a second, misleading error on top of the first.

**Choose Text for both outputs.** Anything other than Text fails schema validation at runtime, because the designer wraps single expressions in `@{ }` and hands back the string `"true"` where a boolean was promised. One bad field makes **every** output of the flow unreadable in the app, not just the bad one — that defect cost `GetWorkspaceGitState` its `isConnected` field and `ListMyConnections` its `count` (FLOWS §4). For the same reason there is **no** `count` output here; use `CountRows` app-side.

Output names come back **lowercased** in Power Fx — you type `EndpointsJson`, the app binds `endpointsjson`.

---

## 9. What the app does with the result

`ParseJSON(ListPrivateEndpoints.Run(gblWsId).endpointsjson)` into a collection. Each row carries:

| Field | Notes |
|---|---|
| `id` | GUID — the input to `DeletePrivateEndpoint` |
| `name` | |
| `targetPrivateLinkResourceId` | Full Azure resource ID |
| `targetSubresourceType` | May be absent |
| `provisioningState` | `Provisioning` / `Succeeded` / `Updating` / `Deleting` / `Failed` |
| `connectionState.status` | `Pending` / `Approved` / `Rejected` / `Disconnected` — **may be absent entirely** on a freshly created row |
| `connectionState.description` | The approver's message, when present |

Read `connectionState` null-safely. `provisioningState: Succeeded` with `connectionState.status: Pending` is the **normal** state for minutes to days after creation and must not render as an error — see [../../APP-PRIVATE-ENDPOINTS.md](../../APP-PRIVATE-ENDPOINTS.md) §2.1.

This collection is also what the create panel validates against before enabling its Create button — the duplicate rule lives there, not in `CreatePrivateEndpoint` ([CreatePrivateEndpoint.md](CreatePrivateEndpoint.md) §7).

---

## After building

- Add the flow to the canvas app (left rail → Power Automate → **+ Add flow**). Watch for a suffixed duplicate such as `ListPrivateEndpoints_1` from adding it twice.
- Call it as `ListPrivateEndpoints.Run(gblWsId)`. Pass inputs positionally; no trailing options record.
- If you change the trigger inputs later, **remove and re-add the flow in the app** — Power Apps caches the signature at bind time.
- Renaming the flow does not change the name Power Fx binds to. Trust formula-bar autocomplete over the portal display name.
- Set **Run-only users** on the flow: connections *Use this connection* for the HTTP actions. This does not survive solution import and must be re-applied per environment (OPEN-ISSUES §8.2).
- Do **not** gate the calling control on `gblFlowResult.oapenabled`. Managed private endpoints are independent of Outbound Access Protection — [../../APP-PRIVATE-ENDPOINTS.md](../../APP-PRIVATE-ENDPOINTS.md) §7.
- Gate the "no private endpoints" label on a `gblMpeLoaded` flag. A blank collection is falsy, so an unguarded label flashes on every workspace that *does* have endpoints — the same defect documented in [../../APP-OUTBOUND-TAB.md](../../APP-OUTBOUND-TAB.md).

---

## To verify after the first run

| # | Check | Why |
|---|---|---|
| 1 | A workspace with **zero** endpoints returns `[]`, not a failure | `value` may be absent; §7.2's `coalesce` is what covers it |
| 2 | `connectionState` is absent on a row created seconds earlier | Confirms the null-safety requirement in §9 |
| 3 | A workspace on a **sub-F64 capacity** — does the list read succeed, or does the whole feature 4xx? | Only creation is documented as capacity-gated. If reads fail too, the app needs a different empty state |
| 4 | Multi-page behaviour | Cannot be produced with realistic data. The loop rests on the pattern being identical to `ListMyConnections`; if you can force it, confirm `continuationUri` is honoured verbatim |
