# Flow — `ProvisionWorkspaceIdentity`

Child flow. Creates the Fabric workspace identity for one workspace. **If the workspace already has one, it returns `AlreadyExists` and does not fail.**

> **Specification. Not built yet.** Read [README.md](README.md) first. The connections, the Fabric call pattern, the Catch block, the LRO poll and the final `Respond` are all specified there once, and this document refers back to them.

API: [Workspaces — Provision Identity](https://learn.microsoft.com/en-us/rest/api/fabric/core/workspaces/provision-identity). `POST /v1/workspaces/{workspaceId}/provisionIdentity`, with no body. It answers `200` with `{ applicationId, servicePrincipalId }` or `202` with an operation. The caller needs workspace **Admin**.

Related: [DeprovisionWorkspaceIdentity.md](DeprovisionWorkspaceIdentity.md) undoes this flow, and [VerifyWorkspaceIdentity.md](VerifyWorkspaceIdentity.md) checks its result in Entra.

---

## Shape

```
trigger   Manually trigger a flow — workspaceId
Step 2    7 × Initialize variable
Scope_try
  Step 3  Get_workspace
          Condition_already_exists
            ├─ Yes: Set_outcome_exists, Set_message_exists
            └─ No:  Step 4  Provision_identity
                            Condition_accepted
                              ├─ Yes: LRO poll (README)
                              └─ No:  empty
                            Set_outcome_created, Set_message_created
  Step 5  Get_workspace_final
          Set_clientId, Set_servicePrincipalId
          Condition_identity_present
            ├─ Yes: empty
            └─ No:  Set_outcome_missing, Set_message_missing
Scope_catch                               ← README
Step 6    Respond_result
          Condition_outcome_failed        ← Yes: Terminate (Failed)
```

**Step 5 is a sibling of `Condition_already_exists`. It is not inside either branch.** Every path converges on one re-read of the workspace. The flow's output always describes the identity Fabric reports **now**, whichever branch ran, whether the `POST` answered `200` or `202`, and even if the poll ran out of time.

---

## Step 1 — Trigger

**Manually trigger a flow**, with one Text input `workspaceId` → `triggerBody()['text']`. See [README.md](README.md) → *Trigger*.

## Step 2 — Variables

All of these go at the top level, above `Scope_try`.

| Rename to | Name | Type | Value |
|---|---|---|---|
| `Initialize_outcome` | `outcome` | String | `Failed` |
| `Initialize_message` | `message` | String | *(empty)* |
| `Initialize_clientId` | `clientId` | String | *(empty)* |
| `Initialize_servicePrincipalId` | `servicePrincipalId` | String | *(empty)* |
| `Initialize_operationId` | `operationId` | String | *(empty)* |
| `Initialize_opStatus` | `opStatus` | String | *(empty)* |
| `Initialize_opError` | `opError` | String | *(empty)* |

`operationId`, `opStatus` and `opError` are only used by the `202` branch, two levels deep. They are declared here because `Initialize variable` cannot be placed there.

---

## Step 3 — Already provisioned?

**Control → Scope**, renamed `Scope_try`. Everything up to and including Step 5 goes inside it.

### `Get_workspace` — Invoke an HTTP request (Fabric connection)

| Field | Value |
|---|---|
| Method | `GET` |
| URL of the request | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}` |
| Header `Accept` | `application/json` |

A wrong GUID, or a workspace the service account cannot see, returns `404` or `403`. The action fails and the Catch reports Fabric's own message, because this action is an immediate child of `Scope_try`.

### `Condition_already_exists` — Condition

| Left (expression) | Operator | Right |
|---|---|---|
| `if(empty(body('Get_workspace')?['workspaceIdentity']?['applicationId']), 'No', 'Yes')` | is equal to | `Yes` |

**Yes means an identity already exists**, so the *Yes* branch is the early exit. If you invert that polarity, the flow only works on workspaces it has already provisioned.

**Yes branch.** Two **Set variable** actions, and nothing else:

| Rename to | Name | Value |
|---|---|---|
| `Set_outcome_exists` | `outcome` | `AlreadyExists` |
| `Set_message_exists` | `message` | `Workspace already has an identity. Nothing was changed.` |

Do **not** set `clientId` here. Step 5 sets it on every path.

**No branch.** Step 4.

---

## Step 4 — Provision

All of Step 4 goes **inside the No branch** of `Condition_already_exists`.

### `Provision_identity` — Invoke an HTTP request (Fabric connection)

| Field | Value |
|---|---|
| Method | `POST` |
| URL of the request | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}/provisionIdentity` |
| Headers | none |
| Body | none. Leave it empty |
| ⋯ → Settings → **Asynchronous pattern** | **Off** |

When Fabric rejects the call, the action fails and the Catch takes over. Because the action sits inside a Condition, the Catch message will name `Condition_already_exists` and carry the boilerplate text. Open the run from the run ID in the message to read Fabric's error ([README.md](README.md) → *Try / Catch*).

### `Condition_accepted` — Condition

| Left (expression) | Operator | Right |
|---|---|---|
| `outputs('Provision_identity')?['statusCode']` | is equal to | `202` |

The status code is on `outputs(...)`, never on `body(...)`. **Confirm on the first real run** that this connector surfaces `statusCode` and `headers`. The capacity-policies flows rely on the same thing, and they carry the same warning.

**Yes branch — `202`.** The LRO poll from [README.md](README.md) → *Long-running operations*, with `<POST action>` = `Provision_identity`.

**No branch — `200`.** Leave it empty. The `200` body contains the IDs, but Step 5 reads them back from the workspace anyway, so there is only one source.

### After `Condition_accepted` — still inside the *No* branch of `Condition_already_exists`

| Rename to | Name | Value |
|---|---|---|
| `Set_outcome_created` | `outcome` | `Created` |
| `Set_message_created` | `message` | `Workspace identity provisioned.` |

Both actions are **siblings after** `Condition_accepted`, not inside one of its branches. If they go inside the `202` branch, a `200` answer reports `Failed`.

They set `Created` provisionally. Step 5 overrides it if the workspace still has no identity.

---

## Step 5 — Re-read and decide

Back at the **top level of `Scope_try`**, after `Condition_already_exists`.

### `Get_workspace_final` — Invoke an HTTP request (Fabric connection)

The same request as `Get_workspace`. **Duplicating an action does not copy its headers**, so add `Accept` again.

### Two Set variable actions

| Rename to | Name | Value |
|---|---|---|
| `Set_clientId` | `clientId` | `coalesce(body('Get_workspace_final')?['workspaceIdentity']?['applicationId'], '')` |
| `Set_servicePrincipalId` | `servicePrincipalId` | `coalesce(body('Get_workspace_final')?['workspaceIdentity']?['servicePrincipalId'], '')` |

### `Condition_identity_present` — Condition

| Left (expression) | Operator | Right |
|---|---|---|
| `if(empty(variables('clientId')), 'No', 'Yes')` | is equal to | `Yes` |

**Yes branch.** Leave it empty. `outcome` is already `Created` or `AlreadyExists`.

**No branch.** Fabric accepted the request, but no identity exists. Either the LRO reported `Failed`, or the poll ran out of time while it was still `Running`.

| Rename to | Name | Value |
|---|---|---|
| `Set_outcome_missing` | `outcome` | `Failed` |
| `Set_message_missing` | `message` | the expression below |

```
concat('No workspace identity after provisioning. Operation status: ', if(empty(variables('opStatus')), 'none (POST answered 200)', variables('opStatus')), if(empty(variables('opError')), '', concat(' - ', variables('opError'))), ' | run ', workflow()?['run']?['name'])
```

> **A `Running` status here means the poll timed out, not that provisioning failed.** The operation may still complete later. A rerun of this flow then reports `AlreadyExists`, which is the correct way to find out. Do not raise the poll limits to hide this; 10 minutes is already far longer than provisioning normally takes.

> **Check on the first build that the identity shows up immediately after the LRO reports `Succeeded`.** If `Get_workspace_final` returns no `workspaceIdentity` straight after a successful operation, add a 10-second **Delay** before it. Do not add a retry loop.

---

## Catch

`Scope_catch` exactly as specified in [README.md](README.md) → *Try / Catch*. `Respond_caught` returns the fields in Step 6, with `outcome` = `Failed`, `message` = `variables('message')`, and `variables('clientId')` and `variables('servicePrincipalId')` as they stand. They are usually empty on that path.

---

## Step 6 — Respond

`Respond_result` and `Condition_outcome_failed`, wired as in [README.md](README.md) → *The final `Respond`*. All the outputs are **Text**:

| Output | Value |
|---|---|
| `outcome` | `variables('outcome')` |
| `message` | `variables('message')` |
| `workspaceid` | `triggerBody()['text']` |
| `clientid` | `variables('clientId')` |
| `serviceprincipalid` | `variables('servicePrincipalId')` |

| `outcome` | Meaning | Run status |
|---|---|---|
| `Created` | This run provisioned the identity | Succeeded |
| `AlreadyExists` | The identity was already there, and nothing was changed | Succeeded |
| `Failed` | A call failed (caught), or no identity exists after provisioning | **Failed** |

**`clientid` is filled for both `Created` and `AlreadyExists`.** The caller never needs a second call to find out which identity it has.

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | Workspace with no identity | `Created`. `clientid` and `serviceprincipalid` are filled and match **Workspace settings → Workspace identity** in the portal |
| 2 | Run it again on the same workspace | `AlreadyExists` with the **same** `clientid`. `Provision_identity` is skipped in the run history |
| 3 | Inspect test 1's run | Note whether `Provision_identity` answered `200` or `202`. If it answered `202`, the poll ran and `opStatus` ended `Succeeded` |
| 4 | Random GUID as `workspaceId` | `Failed`. The message names `Get_workspace` and carries Fabric's `404` text, and the run is red |
| 5 | Workspace where the service account is only a Member | `Failed`. The message names `Condition_already_exists` (boilerplate text). The run ID opens to a `403` on `Provision_identity` |
| 6 | Call it from a parent with `Run a Child Flow` | Parent's action **succeeds** in every case, including test 4. The parent reads `outcome` |
| 7 | Search the flow for any action with *has failed* in its run-after inside `Scope_try` | None |
| 8 | Inspect any action's headers | No `Authorization` header anywhere |
