# Flow — `DeletePrivateEndpoint`

Build instructions for the write that deletes a **managed private endpoint** from a workspace. One of three new networking flows; the matching read is `ListPrivateEndpoints` and the sibling write is `CreatePrivateEndpoint`.

> **Built and tested 2026-09-02 — not yet verified against an export.** Every other file in this folder is *verified against* an exported definition in `Workflows/`. This one was written as a specification and the flow was built from it. Re-export the solution and reconcile this document against the JSON before trusting the action names and `runAfter` details.

> **Confirm this flow is in scope before building it.** Open question P4 in [../../APP-PRIVATE-ENDPOINTS.md](../../APP-PRIVATE-ENDPOINTS.md) §8 asks whether v1 should be read + create only. Deleting is rare, irreversible for 15 minutes, and the Fabric UI can already do it for anyone with workspace Admin. Dropping this flow halves the risk surface of the feature. It is documented here so the decision is made deliberately rather than by omission.

Related: [../../APP-PRIVATE-ENDPOINTS.md](../../APP-PRIVATE-ENDPOINTS.md) (design investigation — §5.3, §5.4, §6), [../../FLOWS.md](../../FLOWS.md), [../../PREREQUISITES.md](../../PREREQUISITES.md) (A1, A3, B1, E4), [../../OPEN-ISSUES.md](../../OPEN-ISSUES.md) §10.3, F5.9, F5.10, [GetFabricToken.md](GetFabricToken.md), [ListPrivateEndpoints.md](ListPrivateEndpoints.md), [CreatePrivateEndpoint.md](CreatePrivateEndpoint.md), [DisconnectWorkspaceFromGit.md](DisconnectWorkspaceFromGit.md) (the status-code-derived response pattern this copies).

---

## 0. Before you start

- Create the flow **inside the solution**, so it binds to connection references rather than raw connections.
- **No connector connection is needed.** Built-in actions only: `Run a Child Flow`, `Initialize variable`, `HTTP`, `Respond to a Power App or flow`. `connectionReferences` must end up `{}`.
- The child flow **`GetFabricToken`** must already exist: `50895fca-088f-f111-8076-7ced8d76bf1b`.
- Authentication is **service principal** (`sp_fabric_powerapp`). The delete API requires **workspace Admin**, which owners do not hold — a delegated call would `403` for every user of the app. See [../../APP-PRIVATE-ENDPOINTS.md](../../APP-PRIVATE-ENDPOINTS.md) §3.
- Environment variables are **not referenced directly by this flow** — the child flow consumes `ab_TenantId` and `ab_BrokerClientId`. The broker **client secret** lives inside `GetFabricToken`, is scrubbed on export, and must be re-entered per environment (PREREQUISITES E4).
- **No Azure permission is involved.** Deleting the Fabric-side endpoint tears down the request; nothing is required of the target resource's owner. [../../APP-PRIVATE-ENDPOINTS.md](../../APP-PRIVATE-ENDPOINTS.md) §3.2.

> ### The most destructive flow in the solution
>
> It takes `workspaceId` and an endpoint ID at face value. Anyone who can reach the trigger URL can delete a private endpoint in **any** workspace the broker administers. Unlike a Git disconnect — which leaves the repository untouched and can be undone by reconnecting — deleting a managed private endpoint **breaks a live data path**: Spark jobs and notebooks relying on it start failing, and it cannot be recreated for **15 minutes** (§6 of the investigation). Recreating it also produces a fresh `Pending` request that a human in another organisation must approve again.
>
> **Do not ship this flow before F5.9** — the `crbab_Workspaces` ownership check (OPEN-ISSUES §10.3). Add the audit row (F5.10) at the same time. The deferral that was defensible for the Git flows is not defensible here.

Actions are listed in execution order.

---

## 1. Trigger — Power Apps (V2)

| Field | Value |
|---|---|
| Type | `Request` |
| Kind | `PowerAppV2` |
| Action name | `manual` |

Two text inputs, both `x-ms-content-hint: TEXT`, both **required**:

| # | Input title | Schema key | Type | Required | Raw reference |
|---|---|---|---|---|---|
| 1 | `workspaceId` | `text` | string | Yes | `@triggerBody()['text']` |
| 2 | `managedPrivateEndpointId` | `text_1` | string | Yes | `@triggerBody()['text_1']` |

The titles are display only; `text` and `text_1` bind **positionally**. Both are GUIDs, so a swap produces a syntactically valid URI that addresses nothing — a `404`, not an obvious error. Pass them in trigger order and check the run history the first time.

Both stay **required**. An optional PowerApp V2 input is dropped from the payload entirely when blank, and `triggerBody()['text_1']` would then throw `InvalidTemplate`.

`managedPrivateEndpointId` comes from the `id` field of the row the user selected in the gallery, which came from `ListPrivateEndpoints` — never from anything typed.

---

## 2. `Run_a_Child_Flow` — Workflow

First action; `runAfter` is empty.

| Field | Value |
|---|---|
| Type | `Workflow` |
| `host.workflowReferenceName` | `50895fca-088f-f111-8076-7ced8d76bf1b` |
| Inputs | none |

---

## 3. `Initialize_variable` — InitializeVariable

Runs after `Run_a_Child_Flow` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `accessToken` |
| Type | String |
| Value | `@body('Run_a_Child_Flow')?['access_token']` |

---

## 4. `Delete` — Http

Runs after `Initialize_variable` on **Succeeded**.

| Field | Value |
|---|---|
| Method | `DELETE` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}/managedPrivateEndpoints/@{triggerBody()['text_1']}` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Header `Accept` | `application/json` |
| Body | none |
| `retryPolicy` | *(leave default — exponential, 4 retries)* |

**Headers are not copied when you duplicate an action.** A missing `Authorization` returns `401` with the same generic body Fabric uses for semantic rejections — read the status code first.

**No pre-flight existence check, deliberately.** `DisconnectWorkspaceFromGit` reads the Git connection before disconnecting, because a repeat call there would otherwise error and the state is genuinely ambiguous. Here it is not: the endpoint ID came from the gallery, and a stale ID produces a `404` that the response in §5 already turns into a readable message. A `GET` first would add a round trip and a second failure mode to guard the same outcome.

---

## 5. Response contract

`Respond_to_a_Power_App_or_flow` — type `Response`, kind `PowerApp`, `statusCode` 200.

**Runs after `Delete` on *is successful* and *has failed*.** This is the whole error-handling design, and it is the pattern `DisconnectWorkspaceFromGit` settled on: one response, reachable on both paths, deriving the outcome from the status code rather than from a Condition.

| Output name | Title | Type | Value |
|---|---|---|---|
| `outcome` | `Outcome` | string | `@{if(less(coalesce(outputs('Delete')?['statusCode'], 0), 300), 'Deleted', if(equals(coalesce(outputs('Delete')?['statusCode'], 0), 404), 'NotFound', 'Failed'))}` |
| `message` | `Message` | string | `@{if(less(coalesce(outputs('Delete')?['statusCode'], 0), 300), 'Delete accepted. The endpoint may show as Deleting until Fabric finishes removing it.', coalesce(body('Delete')?['message'], body('Delete')?['errorCode'], string(body('Delete'))))}` |

`outcome` is one of:

| Value | Meaning | What the app does |
|---|---|---|
| `Deleted` | Fabric accepted the delete | Refresh the list. Expect the row to persist briefly as `Deleting` |
| `NotFound` | Already gone, or a stale ID | Refresh the list. Not an error worth alarming the user about |
| `Failed` | Fabric rejected it; raw payload in `message` | Show the error |

**Without a Respond reachable on failure, a rejected `DELETE` ends the run with no output at all** and the app shows a hard error with no reason. That defect has been fixed three times in this solution already — `ConnectWorkspaceToGit`, `AddConnectionRoleAssignment`, and by design in `DisconnectWorkspaceFromGit`. Do not make this the fourth.

**Keep both fields typed `string`.** A field declared boolean or number fails schema validation and makes **every** output of the flow unreadable in the app, not just the bad one (FLOWS §4).

Output names come back **lowercased** in Power Fx — bind to `outcome` and `message`.

---

## 6. `200` does not mean it is gone

The API answers `200` with an **empty body**. The endpoint then moves through `provisioningState: "Deleting"` and continues to appear in `ListPrivateEndpoints` until Fabric finishes.

Two consequences for the app:

- **A row still present after a successful delete is not a failed delete.** Render `Deleting` as its own state rather than re-issuing the delete or reporting an error.
- **The 15-minute cooldown starts now.** A new endpoint to the same resource will be refused until it elapses ([../../APP-PRIVATE-ENDPOINTS.md](../../APP-PRIVATE-ENDPOINTS.md) §6). Since there is also **no update API**, "rename this endpoint" and "point it somewhere else" both mean delete + wait + recreate. Say so in the confirmation dialog — an owner who discovers it afterwards has a broken data path and a quarter of an hour to think about it.

---

## After building

- Add the flow to the canvas app. Watch for a suffixed duplicate such as `DeletePrivateEndpoint_1`.
- Call it positionally, in trigger order: `DeletePrivateEndpoint.Run(gblWsId, galEndpoints.Selected.id)`. No trailing options record.
- If you change the trigger inputs later, **remove and re-add the flow in the app** — Power Apps caches the signature at bind time.
- Set **Run-only users**: *Use this connection* for the HTTP action. Does not survive solution import (OPEN-ISSUES §8.2).
- The flow answers a PowerApp, so it must respond within **120 seconds**. One child call and one DELETE; the budget is not at risk.
- **Gate the button behind a typed-name confirmation**, not a plain "Are you sure?". The user should have to type the endpoint's name to enable Delete. The confirmation text must state that the data path breaks immediately and that recreating it needs 15 minutes plus a fresh approval from the target resource's owner.

---

## To verify after the first run

| # | Test | Establishes |
|---|---|---|
| 1 | Delete, then immediately re-list | §6 — that `Deleting` appears and the app renders it as a state, not a failure |
| 2 | Delete the same ID twice | That the second call returns `404` and the response maps it to `NotFound` rather than `Failed` |
| 3 | Delete, then recreate to the same resource inside 15 minutes | §6 — that the cooldown failure reaches the app as a readable message via `CreatePrivateEndpoint` |
| 4 | Delete an endpoint whose `connectionState.status` is `Approved` | Whether Fabric removes the connection on the Azure side or leaves an orphaned entry for the resource owner to clean up. Affects what the confirmation dialog should promise |

Test 4 is the one worth doing deliberately — it is the only part of this flow whose effect lands outside Fabric, and the API documentation says nothing about it.

> **Testing from the designer reports `ActionResponseSkipped` on the Respond action.** That is expected, not a fault: nothing is waiting for the response when the run is started from the Test panel. The DELETE still happens. To check the outcome values, read the Respond action's **inputs** in the run history, or test from the app. See FLOWS §Gotchas.
