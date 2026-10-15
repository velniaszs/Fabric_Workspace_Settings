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

**No branch — `200`.** Leave it empty. Fabric has finished provisioning. The `200` body contains the IDs, but Step 5 reads them back from the workspace anyway, so there is only one source.

**Yes branch — `202`.** Fabric has accepted the request but has not finished. The branch waits until Fabric reports the operation as `Succeeded` or `Failed`. Build it as follows.

#### What the finished Yes branch looks like

```
Condition_accepted
└─ Yes
   ├─ 1. Set_operationId          Set variable
   ├─ 2. Set_opStatus_initial     Set variable
   └─ 3. Do_until_done            Do until  (stop when opStatus = Succeeded OR Failed)
         ├─ 3a. Delay             Delay 5 seconds
         ├─ 3b. Get_operation     Invoke an HTTP request (GET operation status)
         ├─ 3c. Set_opStatus      Set variable
         └─ 3d. Set_opError       Set variable
```

All of these actions are already declared as variables in Step 2. This branch only uses **Set variable**. Never use **Initialize variable** here, because the designer will refuse to save it.

#### 1. `Set_operationId` — remember which operation to ask about

1. In the **Yes** branch of `Condition_accepted`, click **+** → **Add an action**.
2. Search for **Set variable** and select it.
3. Rename the action to `Set_operationId`. In the new designer, click the action title. In the classic designer, use **⋯** → **Rename**.
4. **Name:** select `operationId`.
5. **Value:** open the **ƒx** (expression) tab, paste the expression below, and click **Add** (or **OK**):

   ```
   outputs('Provision_identity')?['headers']?['x-ms-operation-id']
   ```

The `202` response carries the operation ID in its `x-ms-operation-id` header. Every later call in this branch uses this value.

#### 2. `Set_opStatus_initial` — start the loop in a known state

1. Under `Set_operationId`, still in the **Yes** branch, click **+** → **Add an action** → **Set variable**.
2. Rename it to `Set_opStatus_initial`.
3. **Name:** `opStatus`.
4. **Value:** type the plain text `Running`. This is text, not an expression.

#### 3. `Do_until_done` — repeat until Fabric is finished

1. Under `Set_opStatus_initial`, click **+** → **Add an action**, search for **Do until** (it is under **Control**), and select it.
2. Rename it to `Do_until_done`.
3. Build the exit condition as **two rows joined with `Or`**:

   | Row | Left (ƒx expression) | Operator | Right (plain text) |
   |---|---|---|---|
   | 1 | `variables('opStatus')` | is equal to | `Succeeded` |
   | 2 | `variables('opStatus')` | is equal to | `Failed` |

   - Fill row 1. Then click **+ Add** → **Add row** and fill row 2.
   - Change the group operator from **And** to **Or**. **This is the step most likely to go wrong.** With **And** the loop never ends, because the status can't be both values at once. It then runs until the limits below stop it.
   - The left-hand values must go in through the **ƒx** tab. If you type `variables('opStatus')` as plain text, the loop compares the literal words and never stops.
4. Set the loop limits. In the new designer these are the **Count** and **Timeout** fields on the action. In the classic designer, click **Change limits**.

   | Field | Value | Meaning |
   |---|---|---|
   | Count | `60` | At most 60 checks |
   | Timeout | `PT10M` | At most 10 minutes in total |

   Hitting a limit is not an error by itself. The loop just stops, `opStatus` is still `Running`, and Step 5 then reports `Failed` with that status in the message.

The next four actions go **inside** `Do_until_done`. Add each one with the **+** inside the loop box, not the **+** below it.

#### 3a. `Delay` — wait before each check

1. Inside `Do_until_done`, click **+** → **Add an action**, search for **Delay** (under **Schedule**), and select it.
2. Rename it to `Delay`.
3. **Count:** `5`. **Unit:** `Second`.

The delay comes **first** because Fabric's `202` asks the caller to wait 5 seconds (`Retry-After: 5`). Without it, the loop uses up its 60 checks in a few seconds.

#### 3b. `Get_operation` — ask Fabric how the operation is going

1. Under `Delay`, inside the loop, click **+** → **Add an action** → **HTTP with Microsoft Entra ID (preauthorized)** → **Invoke an HTTP request**.
2. Check that the **Fabric** connection is the one selected (Base Resource URL `https://api.fabric.microsoft.com`).
3. Rename it to `Get_operation`.
4. Fill in:

   | Field | Value |
   |---|---|
   | Method | `GET` |
   | URL of the request | `https://api.fabric.microsoft.com/v1/operations/@{variables('operationId')}` |
   | Header `Accept` | `application/json` |
   | Body | none |

   Type the URL up to `/operations/`. Then insert `variables('operationId')` from the **ƒx** tab, or pick **operationId** from the **Variables** list in **Dynamic content**.

5. Do **not** add an `Authorization` header. Leave **Retry Policy** at its default.

Fabric answers with a body like this:

```json
{ "status": "Running", "createdTimeUtc": "…", "lastUpdatedTimeUtc": "…", "percentComplete": 50 }
```

When it is finished, `status` is `Succeeded` or `Failed`. A `Failed` body also contains an `error` object with a `message`.

#### 3c. `Set_opStatus` — record the latest status

1. Under `Get_operation`, inside the loop, click **+** → **Add an action** → **Set variable**.
2. Rename it to `Set_opStatus`.
3. **Name:** `opStatus`.
4. **Value (ƒx):**

   ```
   coalesce(body('Get_operation')?['status'], 'Running')
   ```

This is the value the loop's exit condition checks. If the response has no `status`, the `coalesce` keeps the loop going instead of leaving `opStatus` blank.

#### 3d. `Set_opError` — keep Fabric's error text, if there is one

1. Under `Set_opStatus`, inside the loop, click **+** → **Add an action** → **Set variable**.
2. Rename it to `Set_opError`.
3. **Name:** `opError`.
4. **Value (ƒx):**

   ```
   coalesce(body('Get_operation')?['error']?['message'], '')
   ```

`opError` stays empty while the operation runs or succeeds. When the operation fails, it holds Fabric's reason, and Step 5 puts that reason in the flow's `message`.

#### Check the Yes branch before saving

| Check | Correct |
|---|---|
| Where is `Do_until_done`? | Inside the **Yes** branch of `Condition_accepted`, after `Set_opStatus_initial` |
| What is inside `Do_until_done`? | Exactly `Delay`, `Get_operation`, `Set_opStatus` and `Set_opError`, in that order |
| Loop condition group operator | **Or** |
| Loop limits | Count `60`, Timeout `PT10M` |
| Any action with *Configure run after → has failed*? | **None** (it would silently switch off the Catch) |
| `Set_outcome_created` / `Set_message_created` | **Not** in this branch. They go after `Condition_accepted`, as described below |

#### Check on the first run that returns `202`

Open the run history and expand `Condition_accepted` → **Yes**:

1. **`Set_operationId`** should show a GUID as its output. If it is empty, the connector is not passing response headers through. `Get_operation` then calls `/v1/operations/` with no ID and fails. If that happens, read the exact header name from `Provision_identity` → **Show raw outputs** → `headers` and correct the expression.
2. **`Do_until_done`** should show a few iterations. In the last one, `Get_operation` should return `"status": "Succeeded"`.
3. If `Get_operation` fails (for example with a `404`), the loop fails, `Scope_try` fails, and `Scope_catch` reports the error. That is intended, so don't add *has failed* handling here.

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
