# Flow — `InitializeCapacityPolicySet`

Creates the policy set for a newly provisioned capacity, registers it in Dataverse, builds the default rules and activates it. Called by the capacity-provisioning Power App.

> **Not built yet.** Specification, not a description of something that exists.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md), [GetPolicyToken.md](docs/flows/capacity-policies/GetPolicyToken.md), [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md).

---

## 0. Before you start

- Build [GetPolicyToken.md](docs/flows/capacity-policies/GetPolicyToken.md) and [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) first. This flow calls both.
- Needs a **Dataverse connection**.
- The SPN needs **Contributor on the holder workspace** and **Capacity Admin on the capacity being initialised**. The second is what step 8 requires; without it activation fails and the capacity is left with rules that are not in force.
- Substitute your publisher prefix for `crbab_`.

> ### The capacity is born locked, on purpose
>
> Rule 1 denies creation of every governed item type. A capacity that has just been through this flow permits **no** governed item creation until a workspace is whitelisted through [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md). Power BI items are not governed and stay creatable.
>
> That is the intended posture — secure by default — but the provisioning app **must tell the user**. Otherwise the first person to open a new capacity files a bug, and someone "fixes" it by deactivating the policy set.

---

## Step 1 — Create the flow

**Solutions** → **New** → **Automation** → **Cloud flow** → **Instant** → name `InitializeCapacityPolicySet` → trigger **Power Apps (V2)**.

Two **Text** inputs, in this order:

| Order | Title | Key | Reference |
|---|---|---|---|
| 1 | `capacityId` | `text` | `triggerBody()['text']` |
| 2 | `capacityDisplayName` | `text_1` | `triggerBody()['text_1']` |

Both required. An optional PowerApp V2 input is dropped from the payload entirely when blank, and `triggerBody()['text_1']` then throws `InvalidTemplate` rather than returning `""`.

---

## Step 2 — Token and outcome variables

1. **Run a Child Flow** → `GetPolicyToken` (leave named `Run_a_Child_Flow`).
2. `Initialize_variable` — `accessToken`, String, `body('Run_a_Child_Flow')?['access_token']`.
3. `Initialize_policySetId` — `policySetId`, String, empty.
4. `Initialize_outcome` — `outcome`, String, `Failed`.
5. `Initialize_message` — `message`, String, empty.

Seeding `outcome` with `Failed` means any path nobody anticipated reports failure rather than silence.

---

## Step 3 — Already registered?

`Get_policy_row` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Capacity Policies` |
| Filter rows | `crbab_capacityid eq '@{triggerBody()['text']}'` |
| Row count | `1` |

`Condition_already_exists` — **Condition**:

| Left | Operator | Right |
|---|---|---|
| `empty(body('Get_policy_row')?['value'])` | is equal to | `false` |

**Yes** → set `outcome` = `AlreadyExists`, `policySetId` = `first(body('Get_policy_row')?['value'])?['crbab_policysetid']`, `message` = `This capacity already has a policy set.` Then skip to the Respond.

Everything below goes in the **No** branch.

---

## Step 4 — Check the capacity is eligible

`Get_capacities` — **HTTP**:

| Field | Value |
|---|---|
| Method | `GET` |
| URI | `https://api.fabric.microsoft.com/v1/capacities` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Header `Accept` | `application/json` |

`Filter_capacity` — **Filter array**:

| Field | Value |
|---|---|
| From | `body('Get_capacities')?['value']` |
| Condition (advanced) | `@equals(toLower(item()?['id']), toLower(triggerBody()['text']))` |

`Condition_eligible` — **Condition**, advanced mode:

```
@and(
  not(empty(body('Filter_capacity'))),
  equals(first(body('Filter_capacity'))?['state'], 'Active'),
  startsWith(toUpper(coalesce(first(body('Filter_capacity'))?['sku'], '')), 'F')
)
```

**No** branch → `outcome` = `Skipped`, message naming which check failed. Skip to Respond.

Three separate reasons, one outcome:

| Condition | Why |
|---|---|
| Not in the list | Either it does not exist, or the SPN is not an admin on it — indistinguishable from here, and both mean this flow cannot proceed |
| Not `Active` | A paused capacity cannot host a working policy set |
| SKU is not `F*` | **Only Fabric capacities can hold a policy set.** Power BI SKUs — `P`, `A`, `EM`, `PP` — are a normal thing to encounter, not an error. `Skipped`, not `Failed` |

---

## Step 5 — Build the policy set name

Three **Compose** actions. Capacity display names are far more permissive than Fabric item names, so this has to be done properly or the create fails on characters the user never typed.

### 5a. `Compose_name_raw`

```
@{concat(parameters('PolicyNamePrefix (ab_PolicyNamePrefix)'), triggerBody()['text_1'])}
```

### 5b. `Compose_name_clean`

```
@{trim(replace(replace(replace(replace(replace(replace(replace(replace(replace(outputs('Compose_name_raw'), '\', '_'), '/', '_'), ':', '_'), '*', '_'), '?', '_'), '"', '_'), '<', '_'), '>', '_'), '|', '_'))}
```

Nine replacements, one per character Fabric item names reject, then a trim.

### 5c. `Compose_name_final`

```
@{if(endsWith(if(greater(length(outputs('Compose_name_clean')), 256), substring(outputs('Compose_name_clean'), 0, 256), outputs('Compose_name_clean')), '.'), substring(if(greater(length(outputs('Compose_name_clean')), 256), substring(outputs('Compose_name_clean'), 0, 256), outputs('Compose_name_clean')), 0, sub(length(if(greater(length(outputs('Compose_name_clean')), 256), substring(outputs('Compose_name_clean'), 0, 256), outputs('Compose_name_clean'))), 1)), if(greater(length(outputs('Compose_name_clean')), 256), substring(outputs('Compose_name_clean'), 0, 256), outputs('Compose_name_clean')))}
```

Ugly, and unavoidable without a variable — it caps at 256 characters and then strips a single trailing dot. **Fabric rejects trailing dots silently**, which is the sort of failure that costs an afternoon.

If you prefer readability, use an `Initialize variable` for the capped value and a second Compose for the dot strip. The expression above exists so the flow needs no extra variable; either is fine.

> **Display names are not unique across capacities.** Two capacities called `Finance` produce one policy set name. `migrate_policy_sets.ps1` appends the first 8 characters of the capacity ID on collision. This flow does not check, because `Capacity Policies` is keyed on capacity ID and the name is cosmetic — but a duplicate name will fail the create with `ItemDisplayNameAlreadyInUse`, which step 6 surfaces. If that becomes common, append the ID suffix here.

---

## Step 6 — Create the policy set

`Create_policy_set` — **HTTP**:

| Field | Value |
|---|---|
| Method | `POST` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ab_PolicyHolderWorkspaceId)')}/policySets` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Header `Content-Type` | `application/json` |

Body:

```json
{
  "displayName": "@{outputs('Compose_name_final')}",
  "description": "@{concat('Item creation policy for capacity ', triggerBody()['text_1'])}",
  "creationPayload": {
    "scope": {
      "type": "Capacity",
      "id": "@{triggerBody()['text']}"
    }
  }
}
```

Then ⋯ → **Settings** → **Asynchronous Pattern** → **Off**.

> Leave **Retry Policy** at Default on every HTTP action here. It already covers `429`. The one to watch is `Activate`: the Admin activation endpoints are documented at **10 requests per minute**, so a provisioning burst creating several capacities at once is where throttling would first show up.

> **Turn the async pattern off deliberately.** Create Policy Set is a long-running operation: it answers `201` with the created item, or `202` with `Location` and `x-ms-operation-id`. Left on, the connector follows the `Location` header itself — but that points at the *operation*, not the created item, so the action resolves to an operation status and `body('Create_policy_set')?['id']` is not the policy set ID. Handling the two status codes explicitly is longer and predictable.

---

## Step 7 — Resolve the ID

`Condition_created_sync` — **Condition**:

| Left | Operator | Right |
|---|---|---|
| `outputs('Create_policy_set')?['statusCode']` | is equal to | `201` |

Status code is on `outputs(...)`, never on `body(...)`.

### Yes — `201`

`Set_policySetId_sync` — Set variable → `policySetId` = `body('Create_policy_set')?['id']`.

### No — treat as `202`

1. `Initialize_operationId` — String, `outputs('Create_policy_set')?['headers']?['x-ms-operation-id']`.
2. `Initialize_opStatus` — String, `Running`.
3. **Do until** `@or(equals(variables('opStatus'), 'Succeeded'), equals(variables('opStatus'), 'Failed'))`, count `60`, timeout `PT10M`:
   - `Get_operation` — HTTP `GET https://api.fabric.microsoft.com/v1/operations/@{variables('operationId')}` with the auth header.
   - `Set_opStatus` — Set variable → `coalesce(body('Get_operation')?['status'], 'Running')`.
   - **Delay** 5 seconds. Without it the loop burns its 60 iterations in seconds and reports a timeout on an operation that was going to succeed.
4. `Get_operation_result` — HTTP `GET https://api.fabric.microsoft.com/v1/operations/@{variables('operationId')}/result`.
5. `Set_policySetId_async` — Set variable → `policySetId` = `body('Get_operation_result')?['id']`.

The created item is at `/result`, not on the operation itself. The operation only reports status.

---

## Step 8 — Register, build rules, activate

### 8a. `Add_policy_row` — Dataverse **Add a new row**

| Column | Value |
|---|---|
| `crbab_capacityid` | `triggerBody()['text']` |
| `crbab_capacityname` | `triggerBody()['text_1']` |
| `crbab_policysetid` | `variables('policySetId')` |
| `crbab_status` | `Inactive` |

**Write the row before activating.** If activation fails, the policy set still exists in Fabric and must be recorded, or the next run creates a second one and `SyncCapacityPolicySets` reports a `Conflict` nobody caused.

### 8b. `Run_rebuild` — **Run a Child Flow** → `RebuildCapacityPolicyRules`, passing `triggerBody()['text']`.

With no `FabricEnabled` workspaces on the capacity's Node yet, this writes **rule 1 alone** — the intended default, and it exercises the zero-workspace path on day one rather than months later.

> **A brand-new capacity may have no `ubsppcoe_Node` row yet, and the rebuild fails closed on that** — see [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) Step 5b. The policy set is still created and recorded, so this is recoverable: add the Node row and rerun. But if provisioning routinely creates the capacity before its inventory record, expect this step to fail on first run, and decide whether the provisioning app should order the two the other way round.

### 8c. `Activate` — **HTTP**

| Field | Value |
|---|---|
| Method | `POST` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ab_PolicyHolderWorkspaceId)')}/policySets/@{variables('policySetId')}/activate` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Header `Content-Type` | `application/json` |
| Body | `{ "scopeId": "@{triggerBody()['text']}", "scopeType": "Capacity" }` |

⋯ → **Configure run after** `Run_rebuild` on **is successful** only. Activating rules that failed to build would put an unknown rule set into force.

**Do not pass `allowReplace`.** `PolicySetActivationConflict` means another policy set already governs this capacity — on a freshly provisioned one that should be impossible, so it signals something worth a human looking at. Taking the capacity over silently is the wrong default here; the nightly job in [RebuildAllCapacityPolicies.md](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) is where that decision belongs.

### 8d. `Update_status` — Dataverse **Update a row**

Runs after `Activate` on **is successful** and **has failed**.

| Column | Value |
|---|---|
| Row ID | `body('Add_policy_row')?['crbab_capacitypolicyid']` |
| `crbab_status` | `if(less(coalesce(outputs('Activate')?['statusCode'], 0), 300), 'Active', 'Inactive')` |
| `crbab_lasterror` | `if(less(coalesce(outputs('Activate')?['statusCode'], 0), 300), '', coalesce(body('Activate')?['message'], body('Activate')?['errorCode'], string(body('Activate'))))` |

Tolerate `PolicySetIsAlreadyActive` — it means the end state is already what was wanted. Treat any `2xx`, and that specific error code, as `Active`.

### 8e. `Set_outcome_created` — **Set variable**

Runs after `Update_status` on **is successful** and **has failed**.

| Field | Value |
|---|---|
| Name | `outcome` |
| Value | `if(less(coalesce(outputs('Activate')?['statusCode'], 0), 300), 'Created', 'Failed')` |

> **Without this step the flow never reports success.** `outcome` is seeded `Failed` in Step 2 and only reassigned on the two early-exit branches, so the whole happy path — create, register, rebuild, activate — would end at the Respond still saying `Failed`. Easy to miss, because every Fabric side effect works correctly and only the answer is wrong.

Also set `message` here: on success, name the policy set and say the capacity is now governed; on failure, carry `body('Activate')?['message']` so the caller sees why activation failed rather than a bare status.

---

## Step 9 — Respond

**Respond to a Power App or flow**, run after the last action on **is successful** and **has failed**. Three **Text** outputs:

| Output | Value |
|---|---|
| `Outcome` | `variables('outcome')` — set by Step 8e on the success path |
| `PolicySetId` | `variables('policySetId')` |
| `Message` | `variables('message')` |

`outcome` values: `Created`, `AlreadyExists`, `Skipped`, `Failed`.

Every output **Text**. A field typed Number or Boolean fails schema validation and makes *every* output unreadable to the caller, not just the bad one.

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | A fresh F-SKU capacity | `Created`; one policy set in the portal with **exactly one** rule, active on the capacity |
| 2 | Run again on the same capacity | `AlreadyExists`, no second policy set |
| 3 | A P-SKU capacity | `Skipped`, no Fabric write attempted |
| 4 | A capacity ID that does not exist | `Skipped` with a message saying it was not found or not administered |
| 5 | A capacity whose display name contains `/` or `:` | Created with `_` in place of them |
| 6 | Revoke Capacity Admin, then run | Row written, `status = Inactive`, `last_error` populated, outcome reports the failure. **The policy set must still be registered** |
| 7 | Force a `202` if you can | The `/result` path resolves the correct policy set ID |

Test 6 is the one that matters most. It is the difference between a recoverable state and an orphaned policy set nobody knows about.

> Testing from the designer reports **`ActionResponseSkipped`** on the Respond action — expected, since nothing is waiting for the response. Everything else still runs.
