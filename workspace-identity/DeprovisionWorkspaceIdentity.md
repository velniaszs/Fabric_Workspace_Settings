# Flow — `DeprovisionWorkspaceIdentity`

Child flow. Deletes the Fabric workspace identity of one workspace. **If the workspace has no identity, it returns `NotProvisioned` and does not fail.**

> **Specification. Not built yet.** Read [README.md](README.md) first. The connections, the Fabric call pattern, the Catch block, the LRO poll and the final `Respond` are all specified there once, and this document refers back to them.

API: [Workspaces — Deprovision Identity](https://learn.microsoft.com/en-us/rest/api/fabric/core/workspaces/deprovision-identity). `POST /v1/workspaces/{workspaceId}/deprovisionIdentity`, with no body. It answers `200` with an empty body or `202` with an operation. The caller needs workspace **Admin**.

Related: [ProvisionWorkspaceIdentity.md](ProvisionWorkspaceIdentity.md) is the flow this undoes.

> ### This flow cannot be undone
>
> A deleted workspace identity **cannot be restored**. Provisioning again creates a *different* identity, with a new client ID and a new object ID. Every Azure RBAC assignment, storage firewall exception and Fabric connection that used the old identity stops working at once, and none of them follows the new identity.
>
> **This flow takes `workspaceId` at face value.** It does not check whether the requester owns the workspace. That check belongs to the caller in the provisioning solution, and it must be made **before** this flow is called. Do not expose this flow to a canvas app as it stands.
>
> **The flow returns the IDs of the identity it deleted** (`clientid`, `serviceprincipalid`), so the caller can record them and clean up the grants that referenced them.

---

## Shape

```
trigger   Manually trigger a flow — workspaceId
Step 2    7 × Initialize variable
Scope_try
  Step 3  Get_workspace
          Set_clientId, Set_servicePrincipalId     ← the identity about to be deleted
          Condition_has_identity
            ├─ Yes: Step 4  Deprovision_identity
            │               Condition_accepted
            │                 ├─ Yes: LRO poll (README)
            │                 └─ No:  empty
            │               Set_outcome_deleted, Set_message_deleted
            └─ No:  Set_outcome_none, Set_message_none
  Step 5  Get_workspace_final
          Condition_identity_gone
            ├─ Yes: empty
            └─ No:  Set_outcome_still_present, Set_message_still_present
Scope_catch                                        ← README
Step 6    Respond_result
          Condition_outcome_failed                 ← Yes: Terminate (Failed)
```

Unlike the provisioning flow, the *Yes* branch here is the one that does the work. The test is the same in both flows: "does an identity exist?" Only what each branch holds is mirrored.

---

## Step 1 — Trigger

**Manually trigger a flow**, with one Text input `workspaceId` → `triggerBody()['text']`. See [README.md](README.md) → *Trigger*.

## Step 2 — Variables

These are the same seven as in [ProvisionWorkspaceIdentity.md](ProvisionWorkspaceIdentity.md) Step 2: `outcome` (`Failed`), `message`, `clientId`, `servicePrincipalId`, `operationId`, `opStatus` and `opError`. Every one except `outcome` starts empty.

---

## Step 3 — Is there anything to delete?

**Control → Scope**, renamed `Scope_try`. Everything up to and including Step 5 goes inside it.

### `Get_workspace` — Invoke an HTTP request (Fabric connection)

| Field | Value |
|---|---|
| Method | `GET` |
| URL of the request | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}` |
| Header `Accept` | `application/json` |

### Capture the identity before it goes

| Rename to | Name | Value |
|---|---|---|
| `Set_clientId` | `clientId` | `coalesce(body('Get_workspace')?['workspaceIdentity']?['applicationId'], '')` |
| `Set_servicePrincipalId` | `servicePrincipalId` | `coalesce(body('Get_workspace')?['workspaceIdentity']?['servicePrincipalId'], '')` |

**Read these from `Get_workspace`, not from `Get_workspace_final`.** After a successful delete the final read has no identity left, and the IDs of what was deleted are what the caller needs.

### `Condition_has_identity` — Condition

| Left (expression) | Operator | Right |
|---|---|---|
| `if(empty(variables('clientId')), 'No', 'Yes')` | is equal to | `Yes` |

**Yes branch.** Step 4.

**No branch.** Two **Set variable** actions, and nothing else:

| Rename to | Name | Value |
|---|---|---|
| `Set_outcome_none` | `outcome` | `NotProvisioned` |
| `Set_message_none` | `message` | `Workspace has no identity. Nothing was deleted.` |

---

## Step 4 — Deprovision

All of Step 4 goes **inside the Yes branch** of `Condition_has_identity`.

### `Deprovision_identity` — Invoke an HTTP request (Fabric connection)

| Field | Value |
|---|---|
| Method | `POST` |
| URL of the request | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}/deprovisionIdentity` |
| Headers | none |
| Body | none. Leave it empty |
| ⋯ → Settings → **Asynchronous pattern** | **Off** |

**There is no second existence check before the `POST`.** Step 3 has just made one. If another run deletes the identity in the seconds between the two calls, Fabric rejects this call, the Catch reports it, and a rerun returns `NotProvisioned`.

### `Condition_accepted` — Condition

| Left (expression) | Operator | Right |
|---|---|---|
| `outputs('Deprovision_identity')?['statusCode']` | is equal to | `202` |

**Yes branch — `202`.** The LRO poll from [README.md](README.md) → *Long-running operations*, with `<POST action>` = `Deprovision_identity`.

**No branch — `200`.** Leave it empty.

### After `Condition_accepted` — still inside the *Yes* branch of `Condition_has_identity`

| Rename to | Name | Value |
|---|---|---|
| `Set_outcome_deleted` | `outcome` | `Deleted` |
| `Set_message_deleted` | `message` | `Workspace identity deprovisioned.` |

These are siblings after `Condition_accepted`. `Deleted` is provisional, and Step 5 overrides it if the identity is still there.

---

## Step 5 — Re-read and decide

Back at the **top level of `Scope_try`**, after `Condition_has_identity`.

### `Get_workspace_final` — Invoke an HTTP request (Fabric connection)

The same request as `Get_workspace`. Add the `Accept` header again, because duplicating an action does not copy headers.

### `Condition_identity_gone` — Condition

| Left (expression) | Operator | Right |
|---|---|---|
| `if(empty(body('Get_workspace_final')?['workspaceIdentity']?['applicationId']), 'Yes', 'No')` | is equal to | `Yes` |

> **This polarity is the reverse of every other check in this folder.** Here *Yes* means the identity is **gone**, which is the success state. Read the `if` carefully before you copy it from another flow.

**Yes branch.** Leave it empty. `outcome` is already `Deleted` or `NotProvisioned`.

**No branch.** The identity is still present.

| Rename to | Name | Value |
|---|---|---|
| `Set_outcome_still_present` | `outcome` | `Failed` |
| `Set_message_still_present` | `message` | the expression below |

```
concat('Workspace identity still present after deprovisioning. Operation status: ', if(empty(variables('opStatus')), 'none (POST answered 200)', variables('opStatus')), if(empty(variables('opError')), '', concat(' - ', variables('opError'))), ' | run ', workflow()?['run']?['name'])
```

> **Check whether the identity can still be read in Entra after this flow reports `Deleted`.** Entra can lag behind Fabric briefly. [VerifyWorkspaceIdentity](VerifyWorkspaceIdentity.md) on the same workspace returns `NotProvisioned` immediately, because it asks Fabric first. A direct Graph lookup by the old `clientid` may still find the service principal for a short while.

---

## Catch

`Scope_catch` exactly as specified in [README.md](README.md) → *Try / Catch*. `Respond_caught` returns the fields in Step 6 with `outcome` = `Failed`. Here `clientid` and `serviceprincipalid` **are usually filled on the caught path**, because Step 3 sets them before the `POST`. A caller that sees `Failed` with a `clientid` knows which identity it should check by hand.

---

## Step 6 — Respond

`Respond_result` and `Condition_outcome_failed`, wired as in [README.md](README.md) → *The final `Respond`*. All the outputs are **Text**:

| Output | Value |
|---|---|
| `outcome` | `variables('outcome')` |
| `message` | `variables('message')` |
| `workspaceid` | `triggerBody()['text']` |
| `clientid` | `variables('clientId')`, which is the identity that **was** deleted. It is empty for `NotProvisioned` |
| `serviceprincipalid` | `variables('servicePrincipalId')`, likewise |

| `outcome` | Meaning | Run status |
|---|---|---|
| `Deleted` | This run deleted the identity | Succeeded |
| `NotProvisioned` | There was no identity, and nothing was changed | Succeeded |
| `Failed` | A call failed (caught), or the identity is still present afterwards | **Failed** |

---

## To verify after building

Use a **disposable workspace**. Every successful test here destroys an identity for good.

| # | Test | Expect |
|---|---|---|
| 1 | Workspace with an identity | `Deleted`. `clientid` equals the value [VerifyWorkspaceIdentity](VerifyWorkspaceIdentity.md) reported before the run. The portal shows no identity |
| 2 | Run it again on the same workspace | `NotProvisioned`, `clientid` empty, and `Deprovision_identity` skipped |
| 3 | Run [ProvisionWorkspaceIdentity](ProvisionWorkspaceIdentity.md) after test 1 | `Created` with a **different** `clientid`. This proves the delete cannot be undone |
| 4 | Random GUID as `workspaceId` | `Failed`. The message names `Get_workspace`, and the run is red |
| 5 | Workspace where the service account is only a Member, and an identity exists | `Failed`. `clientid` is **filled**, and the run ID opens to a `403` on `Deprovision_identity` |
| 6 | Search the flow for any action with *has failed* in its run-after inside `Scope_try` | None |
