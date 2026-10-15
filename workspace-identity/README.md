# Workspace identity

Three child flows that **create**, **delete** and **verify** the Fabric **workspace identity** of a workspace — the automatically managed Entra service principal Fabric attaches to a workspace for trusted workspace access and connection authentication.

> **Consumer: the workspace provisioning solution.** For now these flows are called from there, with `Run a Child Flow`. Nothing in the canvas app calls them, and they are not part of `WorkspaceSol` ([../workspace-settings/README.md](../workspace-settings/README.md)) or of the capacity-policies solution ([../capacity-policies/README.md](../capacity-policies/README.md)).

> **Status: specification.** None of the three flows is built yet. Each document is the specification to build from. Once a flow is built and exported, check its document against the JSON before you trust the action names and `runAfter` details.

---

## The flows

| Flow | Input | Fabric / Graph calls | Outcomes | Fails the run when |
|---|---|---|---|---|
| [ProvisionWorkspaceIdentity](ProvisionWorkspaceIdentity.md) | `workspaceId` | `GET` workspace → `POST provisionIdentity` → poll → `GET` workspace | `Created` · `AlreadyExists` · `Failed` | Any call errors, the LRO fails, or no identity exists afterwards |
| [DeprovisionWorkspaceIdentity](DeprovisionWorkspaceIdentity.md) | `workspaceId` | `GET` workspace → `POST deprovisionIdentity` → poll → `GET` workspace | `Deleted` · `NotProvisioned` · `Failed` | Any call errors, the LRO fails, or the identity still exists afterwards |
| [VerifyWorkspaceIdentity](VerifyWorkspaceIdentity.md) | `workspaceId` | `GET` workspace → Graph `GET servicePrincipals?$filter=appId eq …` | `Verified` · `NotProvisioned` · `NotFoundInEntra` · `Mismatch` | Any call errors |

**All three are idempotent.** Provisioning a workspace that already has an identity returns `AlreadyExists`, and deprovisioning a workspace without one returns `NotProvisioned`. Both are successful runs. The caller can retry any of these flows safely.

---

## How "is an identity provisioned?" is decided

Every flow answers that question the same way: [Get Workspace](https://learn.microsoft.com/en-us/rest/api/fabric/core/workspaces/get-workspace) and read `workspaceIdentity`.

**Provisioned.** The object is present.

```json
{
  "id": "cfafbeb1-8037-4d0c-896e-a46fb27ff227",
  "displayName": "My Production Workspace",
  "type": "Workspace",
  "capacityId": "…",
  "workspaceIdentity": {
    "applicationId": "00a4a8f9-78d3-41b3-b87a-6ae5271c8d0d",
    "servicePrincipalId": "5ba4ae58-d402-45c6-a848-0253e834fd78"
  }
}
```

**Not provisioned.** There is no `workspaceIdentity` key.

```json
{
  "id": "cfafbeb1-8037-4d0c-896e-a46fb27ff227",
  "displayName": "My Production Workspace",
  "type": "Workspace",
  "capacityId": "…"
}
```

The test used throughout is:

```
if(empty(body('Get_workspace')?['workspaceIdentity']?['applicationId']), 'No', 'Yes')
```

It compares against the **string** `Yes`, not a boolean. A real boolean compared with a right-hand box that contains the text `true` is the classic silent mismatch in the designer ([../capacity-policies/docs/PLATFORM-FINDINGS.md](../capacity-policies/docs/PLATFORM-FINDINGS.md) §3). Strings avoid it.

| Field | Is | Used as |
|---|---|---|
| `workspaceIdentity.applicationId` | The **client ID** (`appId`) of the identity's Entra app registration | `clientid` in every flow's output. This is the key [VerifyWorkspaceIdentity](VerifyWorkspaceIdentity.md) uses to look the identity up in Entra |
| `workspaceIdentity.servicePrincipalId` | The **object ID** of its service principal (enterprise application) | `serviceprincipalid`. This is what Azure RBAC assignments reference |

---

## 0. Before you build any of them

### Solution and connections

- Create each flow **inside the workspace provisioning solution**, so that it binds to connection references and not to raw connections.
- Each flow uses the **HTTP with Microsoft Entra ID (preauthorized)** connector, and its connection is **signed in as the `workspace provisioning` service account**. Fabric sees that account on every call. The flow and whoever triggered it are invisible to Fabric.
- [VerifyWorkspaceIdentity](VerifyWorkspaceIdentity.md) needs a **second connection** of the same connector, pointed at Microsoft Graph. The table below lists both.

| Connection | Base Resource URL | Microsoft Entra ID Resource URI | Used by |
|---|---|---|---|
| Fabric | `https://api.fabric.microsoft.com` | `https://api.fabric.microsoft.com` | All three flows |
| Graph | `https://graph.microsoft.com` | `https://graph.microsoft.com` | `VerifyWorkspaceIdentity` only |

> **The Base Resource URL binds a connection to one host.** A Graph URL sent through the Fabric connection fails, and so does a Fabric URL sent through the Graph connection. When you add the Graph call, pick the Graph connection explicitly. The designer defaults to the most recently used connection.

### How every Fabric call is made

This is the pattern in [../capacity-policies/bau/RebuildCapacityPolicyRules.md](../capacity-policies/bau/RebuildCapacityPolicyRules.md) §0, and nothing here deviates from it:

1. **+ New step** → **HTTP with Microsoft Entra ID (preauthorized)** → **Invoke an HTTP request**.
2. Fill in **Method** and **URL of the request**. A `GET` sends `Accept: application/json`. **None of the calls in these flows has a body.** The connector base64-encodes request bodies (a known limitation of the connector), so `provisionIdentity` and `deprovisionIdentity` are deliberately sent with the body left empty.

| Do | Do not |
|---|---|
| Leave **Retry Policy** at Default. It covers `429` | **Add an `Authorization` header.** The connector adds it, and a hand-written header is either ignored or breaks the call |
| On every `POST` here, set ⋯ → **Settings** → **Asynchronous pattern** to **Off** | Use the plain **HTTP** action |

### Permissions

| Call | What the `workspace provisioning` account needs |
|---|---|
| `GET /v1/workspaces/{id}` | Any workspace role |
| `POST …/provisionIdentity`, `POST …/deprovisionIdentity` | **Admin** on the workspace |
| `GET /v1.0/servicePrincipals?$filter=appId eq '…'` | Read access to service principals in Entra ID. Default member users have it unless *user default permissions* are restricted in the tenant. See [VerifyWorkspaceIdentity](VerifyWorkspaceIdentity.md) §0 |

The provisioning solution creates the workspaces, so the account is normally already Admin on them. **No Azure RBAC is involved.** Granting the new identity access to storage is a separate step, and it is out of scope here.

Fabric does not allow a workspace identity in a **My workspace**. Every other workspace can have one.

---

## The shared skeleton

Every flow has the shape below. The flow documents name the actions that go into each box.

```
trigger    Manually trigger a flow  (input: workspaceId)
Step 2     n × Initialize variable                 ← top level, always
Scope_try
           Get_workspace                            ← first, and an immediate child, so its errors are readable
           Condition_…                              ← the idempotency check
           … the work …
           Get_workspace_final / Condition_…        ← re-read and decide the outcome
Scope_catch     runAfter Scope_try = has failed, is skipped, has timed out
           Compose_error / Filter_failed / Set_message / Add_log_row / Respond_caught / Terminate (Failed)
Respond_result  runAfter Scope_catch = all four statuses
Condition_outcome_failed                           ← Yes: Terminate (Failed)
```

### Trigger

**Solutions** → the provisioning solution → **New** → **Automation** → **Cloud flow** → **Instant** → trigger **Manually trigger a flow**. Add one **Text** input titled `workspaceId`, which is referenced as `triggerBody()['text']`.

> **Manual, not Power Apps (V2).** `Run a Child Flow` cannot call a Power Apps (V2) trigger, and you cannot swap a trigger after the flow is saved ([PLATFORM-FINDINGS](../capacity-policies/docs/PLATFORM-FINDINGS.md) §4). If the canvas app ever needs these flows, build a thin Power Apps (V2) wrapper that calls them. Do not rebuild them.

> **Do not set trigger Concurrency Control.** Power Automate rejects it on any flow that contains a `Respond` action.

### Variables

All of them are `Initialize variable` actions at the **top level**, above `Scope_try`. Power Automate refuses to save an `Initialize variable` inside a Scope or a Condition.

`outcome` is seeded with `Failed`, so an unanticipated path reports failure and not silence.

### Try / Catch

The rules are those in [../capacity-policies/bau/AddWorkspaceToPolicy.md](../capacity-policies/bau/AddWorkspaceToPolicy.md) Step 7, and they are verified in [PLATFORM-FINDINGS](../capacity-policies/docs/PLATFORM-FINDINGS.md) §1–§2. In short:

- **No action inside `Scope_try` may use *Configure run after → has failed*.** That makes the scope report Succeeded and silently skips the Catch.
- **No `Terminate` inside `Scope_try`.** It aborts the scope, and nothing can catch an abort.
- **The Catch must end in `Terminate` status Failed.** A Catch that only logs turns a loud failure into a green run.

#### `Scope_catch`

**Control** → **Scope**, renamed `Scope_catch`. ⋯ → **Configure run after** on `Scope_try`: tick **has failed**, **is skipped** and **has timed out**, and untick *is successful*.

| # | Action | Detail |
|---|---|---|
| 1 | `Compose_error` — **Compose** | `result('Scope_try')`. This shows in the run history only and is **never** written anywhere |
| 2 | `Filter_failed` — **Filter array** | From `result('Scope_try')`, `item()?['status']` **is equal to** `Failed` |
| 3 | `Set_message_caught` — **Set variable** | `message` = the expression below |
| 4 | `Add_log_row` — Dataverse **Add a new row** | Optional. See below |
| 5 | `Respond_caught` — **Respond to a Power App or flow** | Same fields as the flow's `Respond_result`, with `outcome` = `Failed` and `message` = `variables('message')` |
| 6 | `Terminate` | Status **Failed**, message `variables('message')` |

```
concat(coalesce(first(body('Filter_failed'))?['name'], 'no failed action in Scope_try'), ': ', coalesce(first(body('Filter_failed'))?['error']?['message'], 'scope was skipped or timed out'), ' | run ', workflow()?['run']?['name'])
```

**Copy that expression from the code block, not from a table.** It contains a literal `|`.

> **Why `Respond_caught` exists, and why it comes before the Terminate.** A child flow that ends without responding makes the parent's `Run a Child Flow` action fail with a generic error. With `Respond_caught`, the parent always receives the same contract with a readable `message`, and it branches on `outcome` the same way on every path. The `Terminate` still turns **this** run red, so the failure shows in this flow's own run history and in its failure notifications. Anything placed after the Terminate never runs ([PLATFORM-FINDINGS](../capacity-policies/docs/PLATFORM-FINDINGS.md) §1).

> **A failure inside a Condition reports as the Condition.** `result()` lists immediate children only. When `Provision_identity` fails, `Filter_failed` names `Condition_already_exists` and the message is the boilerplate *"An action failed. No dependent actions succeeded."* The run ID at the end of the message leads to the real error. Every flow here keeps its Fabric `GET` calls as immediate children of `Scope_try`, so failures of those calls carry the real Fabric error text.

**`Add_log_row` (optional).** If the provisioning solution writes to the platform team's `Logging` table, add the same insert as [AddWorkspaceToPolicy.md](../capacity-policies/bau/AddWorkspaceToPolicy.md) 7d. Use `Log Category` = `Error`, `Log Source Name` = `workflow()?['tags']?['flowDisplayName']`, and `Log Source URL` = the run URL. Leave its run-after at the default, so that a broken log write still fails the run. **The logical names of those columns are unconfirmed (Q48).** Take them from a populated row, and do not guess them.

### The final `Respond` and the red run

`Respond_result` is **Respond to a Power App or flow**. It sits at the top level after `Scope_catch`. ⋯ → **Configure run after** on `Scope_catch`: tick **all four** statuses. `Scope_catch` is *skipped* on every healthy run, so a run-after of *is successful* only would never fire. On the caught path the `Terminate` has already ended the run, so this action is never reached there.

**Declare every output as Text.** A field declared as a boolean or a number fails schema validation, and that makes **every** output unreadable to the caller. **Name the outputs in lower case.** The caller reads them as `body('Run_a_Child_Flow')?['clientid']`, and lower case removes any doubt about the key.

`Condition_outcome_failed` comes after `Respond_result`. Its test is `variables('outcome')` **is equal to** `Failed`. The **Yes** branch holds a `Terminate` with status **Failed** and message `variables('message')`. The **No** branch is empty.

That covers the one failure that does not throw: a long-running operation that reports `Failed`, or one that completes but leaves the workspace in the wrong state. The caller still receives the response, and this run still goes red.

### Long-running operations

`provisionIdentity` and `deprovisionIdentity` are [LROs](https://learn.microsoft.com/en-us/rest/api/fabric/articles/long-running-operation). Each one answers `200` when it is done, or `202` with `x-ms-operation-id`, `Location` and `Retry-After` when it is still in progress. Both flows handle the `202` with the poll below. It is the same block as in [InitializeCapacityPolicySet.md](../capacity-policies/bau/InitializeCapacityPolicySet.md) Step 7.

| # | Action | Detail |
|---|---|---|
| 1 | `Set_operationId` | `outputs('<POST action>')?['headers']?['x-ms-operation-id']` |
| 2 | `Set_opStatus_initial` | `Running` |
| 3 | `Do_until_done` — **Do until** | `@or(equals(variables('opStatus'), 'Succeeded'), equals(variables('opStatus'), 'Failed'))`. Change limits: count `60`, timeout `PT10M` |
| 3a | └ `Delay` | 5 seconds. Put it **first**, because Fabric's `Retry-After` is 5 seconds and an immediate poll is wasted |
| 3b | └ `Get_operation` | `GET https://api.fabric.microsoft.com/v1/operations/@{variables('operationId')}` |
| 3c | └ `Set_opStatus` | `coalesce(body('Get_operation')?['status'], 'Running')` |
| 3d | └ `Set_opError` | `coalesce(body('Get_operation')?['error']?['message'], '')` |

**There is no `/result` call.** Neither operation returns a resource. The flows find out what happened by **re-reading the workspace** afterwards, which also covers the `200` path, so both paths converge on one check.

> **Use `@expr`, not `@{expr}`, in the Do until condition.** In its wrapped form the boolean becomes the string `"true"`, the condition is never met, and the loop runs to its count limit. The result is a slow flow, not an error ([PLATFORM-FINDINGS](../capacity-policies/docs/PLATFORM-FINDINGS.md) §3).

> **Why the asynchronous pattern is Off.** If you leave it On, the connector follows `Location` on its own and the action returns the *operation* status, which consumes the `202` and its headers. Handling the two status codes explicitly is longer, but you can see what it does.

### Callers

```
Run a Child Flow → ProvisionWorkspaceIdentity (workspaceId)
Condition: body('Run_a_Child_Flow')?['outcome'] is not equal to Failed
```

- **Branch on `outcome`. Do not branch on whether the action succeeded.** Every path through these flows responds, so the parent's action succeeds even when this run failed. `Failed` together with `message` is how the failure reaches the parent.
- **The parent waits for up to about 10 minutes** while an LRO is polled. That is acceptable for a child flow. It is **not** acceptable from a canvas app, which has a 120-second response budget ([PLATFORM-FINDINGS](../capacity-policies/docs/PLATFORM-FINDINGS.md) §5). That is one more reason the app should never call these flows directly.

---

## Things that will surprise you

**Deleting an identity cannot be undone.** Fabric cannot restore a deprovisioned identity. A new one gets a **new client ID and a new object ID**, and every RBAC assignment, firewall exception and connection that referenced the old one has to be granted again. Items that rely on the identity break immediately.

**The identity's name follows the workspace name.** When a workspace is renamed, its identity is renamed to match. Fabric does this, and nothing in these flows does it.

**Names are not unique in Entra.** Several app registrations can share a name. For example, a deleted workspace keeps its identity for the whole retention period, so a recreated workspace with the same name produces a second identity with that name. **Look up by `clientid` only. Never look up by name.** [VerifyWorkspaceIdentity](VerifyWorkspaceIdentity.md) reports the name, and it never searches on it.

**Deleting a workspace deletes its identity.** You cannot deprovision the identity of a workspace that is in its *Deleted* retention state until the workspace is permanently deleted.

**Two concurrent provision runs for the same workspace can both pass the existence check.** The second `POST` then gets a Fabric error, the Catch handles it, and that run goes red. The identity itself is fine, and a rerun reports `AlreadyExists`. Trigger concurrency cannot be used to prevent this, because these are request-response flows. Prevent it in the caller.
