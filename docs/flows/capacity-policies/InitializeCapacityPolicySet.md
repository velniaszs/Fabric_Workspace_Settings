# Flow — `InitializeCapacityPolicySet`

Creates the policy set for a newly provisioned capacity, registers it in Dataverse, builds the default rules and activates it. Called by the capacity-provisioning Power App.

> **Not built yet.** Specification, not a description of something that exists.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md), [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) §0 — which sets out the connector pattern every Fabric call here uses.

---

## 0. Before you start

- Build [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) first. This flow calls it, and its §0 defines the Fabric connector pattern used below.
- **There is no token flow.** Every Fabric call is *HTTP with Microsoft Entra ID (preauthorized)* → **Invoke an HTTP request**, with **no `Authorization` header**.
- Needs a **Dataverse connection**.
- The SPN needs **Contributor on the holder workspace** and **Capacity Admin on the capacity being initialised**. The second is what step 8 requires; without it activation fails and the capacity is left with rules that are not in force.
- Logical names below use the **`ubsppcoe_`** prefix, shared with the platform team's tables since 2026-09-07 — see [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §0. Pick tables and columns from the dropdowns rather than typing them.

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

## Step 2 — Variables

Five `Initialize variable` actions, **all at the top level**, before any Condition.

| Rename to | Name | Type | Value |
|---|---|---|---|
| `Initialize_policySetId` | `policySetId` | String | *(leave empty)* |
| `Initialize_outcome` | `outcome` | String | `Failed` |
| `Initialize_message` | `message` | String | *(leave empty)* |
| `Initialize_operationId` | `operationId` | String | *(leave empty)* |
| `Initialize_opStatus` | `opStatus` | String | *(leave empty)* |

> **No token step.** Earlier drafts started with `Run a Child Flow` → `GetPolicyToken` and an `accessToken` variable. Both are gone — delete them if you are copying an older draft.

> **`operationId` and `opStatus` are declared here even though only Step 7's `202` branch uses them.** `Initialize variable` is the one action Power Automate refuses to place inside a Condition, Scope or Apply to each — and that branch sits three levels deep. Declare at the top, assign with **Set variable** where they are needed.

Seeding `outcome` with `Failed` means any path nobody anticipated reports failure rather than silence.

> ### The shape of this flow — this one **does** nest, unlike the rebuild
>
> [RebuildCapacityPolicyRules](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) keeps its guards flat, because each one ends in **Terminate** and stops the run. **This flow has no Terminate anywhere.** It has a single `Respond` at the end that every path must reach, so an early exit cannot stop the run — it can only set `outcome` and `message` and let everything else be skipped by *not being on its branch*.
>
> That means the work genuinely lives inside the branches, two levels deep:
>
> ```
> trigger
> Step 2   Initialize_policySetId / Initialize_outcome / Initialize_message
>          Initialize_operationId / Initialize_opStatus
> Step 3   Get_policy_row
>          Condition_already_exists
>            ├─ Yes:  3 × Set variable          ← AlreadyExists, then nothing else
>            └─ No:   Step 4   Get_capacities
>                             Filter_capacity
>                             Condition_eligible
>                               ├─ Yes: Step 4b  Get_node_row
>                               │                Condition_node_missing
>                               │                  ├─ Yes: 2 × Set variable  ← Failed, no Node row
>                               │                  └─ No:  Step 5   3 × Compose
>                               │                          Step 6   Create_policy_set
>                               │                          Step 7   Condition_created_sync
>                               │                                     ├─ Yes: Set_policySetId_sync
>                               │                                     └─ No:  the 202 branch
>                               │                          Step 8   8a … 8e   ← AFTER the Condition, not inside it
>                               └─ No:  2 × Set variable         ← Skipped
> Step 9   Respond                              ← top level, reached by every path
> ```
>
> **Step 8 is a sibling of `Condition_created_sync`, not a child of either branch.** Both branches of Step 7 exist only to resolve `policySetId`; they converge, and the registration work happens once, after. Drop 8a inside the `201` branch and a run that answered `202` skips the whole of Step 8 — the policy set is created, no Dataverse row is written, no rules are built, and the flow still reports whatever `outcome` was last set. Nothing fails, so the run history looks healthy apart from a column of greyed-out actions.
>
> **Step 9 sits at the top level, after `Condition_already_exists`.** That is what "skip to the Respond" means throughout this document: there is no skipping instruction in Power Automate, and none is needed — a branch that sets its variables and contains nothing else simply falls out of the Condition and lands on the Respond.
>
> **Do not add a Terminate to the early exits here.** It would stop the run before Step 9, and the caller would get no outputs at all rather than `AlreadyExists` or `Skipped`.

---

## Step 3 — Already registered?

`Get_policy_row` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Capacity Policies` |
| Filter rows | `ubsppcoe_capacityid eq '@{triggerBody()['text']}'` |
| Row count | `1` |

`Condition_already_exists` — **Condition**:

| Left | Operator | Right |
|---|---|---|
| `empty(body('Get_policy_row')?['value'])` | is equal to | `false` |

**True means a row was found**, so *Yes* is the early exit and *No* is the normal path. Getting that polarity backwards builds a flow that only works for capacities it has already registered.

**Yes branch** — three **Set variable** actions and nothing else:

| Rename to | Name | Value |
|---|---|---|
| `Set_outcome_exists` | `outcome` | `AlreadyExists` |
| `Set_policySetId_exists` | `policySetId` | `first(body('Get_policy_row')?['value'])?['ubsppcoe_policysetid']` |
| `Set_message_exists` | `message` | `This capacity already has a policy set.` |

The branch ends there. Execution falls out of the Condition and reaches Step 9.

**No branch** — **everything from Step 4 to Step 8 goes inside it.** Step 9 does **not**; it stays at the top level so both branches reach it.

---

## Step 4 — Check the capacity is eligible

`Get_capacities` — **Invoke an HTTP request**:

| Field | Value |
|---|---|
| Method | `GET` |
| URL of the request | `https://api.fabric.microsoft.com/v1/capacities` |
| Header `Accept` | `application/json` |

> **This list is scoped to the connection's identity**, not to the flow. A capacity the identity does not administer is simply absent, and Step 4 reports `Skipped` — indistinguishable from the capacity not existing. If every capacity comes back `Skipped`, suspect the connection before suspecting the data (Q45).

`Filter_capacity` — **Filter array**:

| Field | Value |
|---|---|
| From | `body('Get_capacities')?['value']` |
| Condition (advanced) | `@equals(toLower(item()?['id']), toLower(triggerBody()['text']))` |

`Condition_eligible` — **Condition**. The new designer has no *Edit in advanced mode* on this card, so build it as **three rows joined with `And`** using the **+ Add** → **Add row** button. Each left side is an expression from the ƒx tab:

| # | Left (expression) | Operator | Right |
|---|---|---|---|
| 1 | `length(body('Filter_capacity'))` | is greater than | `0` |
| 2 | `first(body('Filter_capacity'))?['state']` | is equal to | `Active` |
| 3 | `substring(concat(toUpper(coalesce(first(body('Filter_capacity'))?['sku'], '')), 'X'), 0, 1)` | is equal to | `F` |

Set the group's join to **And**, not `Or`.

> **Row 3 looks convoluted for a reason.** The natural `startsWith(...)` returns a boolean, and comparing a real boolean against a right-hand box containing the text `true` is the classic silent mismatch in this editor. Taking the SKU's first character and comparing two strings avoids booleans entirely.
>
> The `concat(..., 'X')` guarantees at least one character, because `substring('', 0, 1)` throws on an empty string — which is what a capacity with a missing `sku` would produce. The appended `X` can never be mistaken for an `F`.

**True means eligible**, so this time *Yes* is the normal path.

**Yes branch** — **Steps 5 to 8 go inside it.**

**No branch** — two **Set variable** actions and nothing else:

| Rename to | Name | Value |
|---|---|---|
| `Set_outcome_skipped` | `outcome` | `Skipped` |
| `Set_message_skipped` | `message` | the expression below |

```
if(equals(length(body('Filter_capacity')), 0),
   'Capacity not found, or the connection identity does not administer it.',
   if(not(equals(first(body('Filter_capacity'))?['state'], 'Active')),
      concat('Capacity state is ', coalesce(first(body('Filter_capacity'))?['state'], 'unknown'), ', not Active.'),
      concat('Capacity SKU is ', coalesce(first(body('Filter_capacity'))?['sku'], 'unknown'), '. Only F SKUs can host a policy set.')))
```

**That nested `if` is what "naming which check failed" means.** The Condition itself only reports pass or fail, so without this the caller gets `Skipped` and no idea which of the three reasons applied — and they need different actions: chase the capacity id, resume a paused capacity, or accept that a P SKU can never be governed. The order matters: test for *not in the list* first, because the other two dereference `first(...)` and would fail on an empty array.

Three separate reasons, one outcome:

| Condition | Why |
|---|---|
| Not in the list | Either it does not exist, or **the connection's identity** is not an admin on it — indistinguishable from here, and both mean this flow cannot proceed |
| Not `Active` | A paused capacity cannot host a working policy set |
| SKU is not `F*` | **Only Fabric capacities can hold a policy set.** Power BI SKUs — `P`, `A`, `EM`, `PP` — are a normal thing to encounter, not an error. `Skipped`, not `Failed` |

---

## Step 4b — Resolve the Node row

**Inside Step 4's Yes branch, before Step 5.** This is the only flow that looks a capacity up in `ubsppcoe_Node`; every other flow reads the `node` lookup this step makes possible.

`Get_node_row` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Nodes` (`ubsppcoe_Node`) |
| Filter rows | `ubsppcoe_nodeuniqueid eq @{triggerBody()['text']}` |
| Row count | `1` |

**The GUID is unquoted** — `ubsppcoe_nodeuniqueid` is a unique-identifier column, and the capacity id *is* the Node row key ([CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §1).

**List rows, not *Get a row by ID*.** A `Get a row by ID` against a missing row fails the action with a `404`, which then needs a `Configure run after` to recover from. An empty `value` array is far easier to branch on.

`Condition_node_missing` — **Condition**:

| Left (expression) | Operator | Right |
|---|---|---|
| `empty(body('Get_node_row')?['value'])` | is equal to | `true` |

**Yes branch** — two **Set variable** actions and nothing else:

| Rename to | Name | Value |
|---|---|---|
| `Set_outcome_no_node` | `outcome` | `Failed` |
| `Set_message_no_node` | `message` | `This capacity has no inventory record, so its workspaces cannot be determined. Ask the platform team to add a Node row, then run this again.` |

**No branch** — **Steps 5 to 8 go inside it.**

> ### Why this comes before the policy set is created
>
> **Resolve the cheap, reversible thing before the expensive, irreversible one.** Creating the policy set first and *then* discovering there is no Node row leaves a live policy set in the holder workspace that nothing in Dataverse maps back to — [SyncCapacityPolicySets](docs/flows/capacity-policies/SyncCapacityPolicySets.md) reports it as `Untracked` and somebody cleans it up by hand.
>
> `Failed`, not `Skipped`: a missing Node row is a gap in the inventory that someone can close, unlike a P-SKU capacity which never becomes eligible.

> ### What this step exists to prevent
>
> Without it the flow writes a `Capacity Policies` row with a **blank `node` lookup**. The `Run_rebuild` in 8b then hits [RebuildCapacityPolicyRules](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) Step 5a, which fails closed by design — and so does every rebuild afterwards, for the life of that capacity, until someone sets the lookup by hand.
>
> The capacity would be registered, activated and permanently un-rebuildable, with `Created` reported to the caller.

---

## Step 5 — Build the policy set name

Three **Compose** actions. Capacity display names are far more permissive than Fabric item names, so this has to be done properly or the create fails on characters the user never typed.

### 5a. `Compose_name_raw`

```
@{concat(parameters('PolicyNamePrefix (ubsppcoe_PolicyNamePrefix)'), triggerBody()['text_1'])}
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

`Create_policy_set` — **Invoke an HTTP request**:

| Field | Value |
|---|---|
| Method | `POST` |
| URL of the request | `https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets` |
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

> Leave **Retry Policy** at Default on every Fabric call here. It already covers `429`. The one to watch is `Activate`: the Admin activation endpoints are documented at **10 requests per minute**, so a provisioning burst creating several capacities at once is where throttling would first show up.

> **Turn the async pattern off deliberately.** Create Policy Set is a long-running operation: it answers `201` with the created item, or `202` with `Location` and `x-ms-operation-id`. Left on, the connector follows the `Location` header itself — but that points at the *operation*, not the created item, so the action resolves to an operation status and `body('Create_policy_set')?['id']` is not the policy set ID. Handling the two status codes explicitly is longer and predictable.

---

## Step 7 — Resolve the ID

`Condition_created_sync` — **Condition**:

| Left | Operator | Right |
|---|---|---|
| `outputs('Create_policy_set')?['statusCode']` | is equal to | `201` |

Status code is on `outputs(...)`, never on `body(...)`.

> **Confirm this on the first real run.** `statusCode` and `headers` are read off an *Invoke an HTTP request* action here, not the plain `HTTP` action the earlier drafts used. API-connection actions expose both, but this branch and the `x-ms-operation-id` read below are the only places in the whole design that depend on it — so if the connector surfaces them differently, this is the one section to rewrite. Everything else reads `body(...)`.

### Yes — `201`

`Set_policySetId_sync` — Set variable → `policySetId` = `body('Create_policy_set')?['id']`.

### No — treat as `202`

**Both variables were declared in Step 2**, so these are **Set variable**, not Initialize.

1. `Set_operationId` — `operationId` = `outputs('Create_policy_set')?['headers']?['x-ms-operation-id']`.
2. `Set_opStatus_initial` — `opStatus` = `Running`.
3. **Do until** `@or(equals(variables('opStatus'), 'Succeeded'), equals(variables('opStatus'), 'Failed'))`, count `60`, timeout `PT10M`:
   - `Get_operation` — **Invoke an HTTP request**, `GET https://api.fabric.microsoft.com/v1/operations/@{variables('operationId')}`. No auth header.
   - `Set_opStatus` — Set variable → `coalesce(body('Get_operation')?['status'], 'Running')`.
   - **Delay** 5 seconds. Without it the loop burns its 60 iterations in seconds and reports a timeout on an operation that was going to succeed.
4. `Get_operation_result` — **Invoke an HTTP request**, `GET https://api.fabric.microsoft.com/v1/operations/@{variables('operationId')}/result`.
5. `Set_policySetId_async` — Set variable → `policySetId` = `body('Get_operation_result')?['id']`.

The created item is at `/result`, not on the operation itself. The operation only reports status.

> ### Why leaving the async pattern **on** does not replace this branch
>
> It is the obvious simplification and it does not work. With **Asynchronous Pattern On**, the connector follows `Location` and polls until the operation reaches a terminal state — then hands you **the operation status object**, because that is what `/v1/operations/{id}` returns. The policy set itself lives at `/operations/{id}/result`, a second call the connector does not make.
>
> So you would still need step 4 above — but you would no longer have `operationId` to build its URL with, because the `202` and its `x-ms-operation-id` header were consumed by the poller and never surfaced. Async On trades an explicit branch for the same work plus a lost identifier.
>
> **`body('Create_policy_set')?['id']` would then be the operation's id, not the policy set's** — and it is a GUID, so it writes to `ubsppcoe_policysetid` without complaint and every later rebuild `404`s against a policy set that does not exist.

---

## Step 8 — Register, build rules, activate

**Place these after `Condition_created_sync` closes, at the same level as it** — inside Step 4b's No branch, but outside both of Step 7's branches. `policySetId` is set by whichever branch ran; Step 8 reads the variable and does not care which.

### 8a. `Add_policy_row` — Dataverse **Add a new row**

| Field | Value |
|---|---|
| Table name | **`Capacity Policies`** (`ubsppcoe_CapacityPolicy`) |

Then the columns:

| Column | Logical name | Value |
|---|---|---|
| Capacity name | `ubsppcoe_capacityname` | `triggerBody()['text_1']` |
| Capacity ID | `ubsppcoe_capacityid` | `triggerBody()['text']` |
| **Node** | `ubsppcoe_node` | `/ubsppcoe_nodes(@{triggerBody()['text']})` |
| Policy set ID | `ubsppcoe_policysetid` | `variables('policySetId')` |
| Policy set name | `ubsppcoe_policysetname` | `outputs('Compose_name_final')` |
| Status | `ubsppcoe_status` | `Inactive` |

> **The `Node` lookup is the one that must not be skipped.** It is what every later rebuild reads, and Step 5a of [RebuildCapacityPolicyRules](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) fails closed without it. Step 4b exists solely to make this line safe to write.
>
> **Lookups are set with the OData bind form**, not a bare GUID: `/ubsppcoe_nodes(<guid>)`, with the **entity set** name and the target row's key. The capacity id works as that key because it *is* the Node row key. If the connector rejects it, check the entity set name against `/api/data/v9.2/$metadata` — the plural is not always what you would guess.
>
> **Type this one straight into the field — not into the ƒx tab.** Every other row in the table above is a bare expression, so the habit is to open **Expression** and paste. This row is a *string* with an expression interpolated into it, and `/ubsppcoe_nodes(@{...})` is not valid expression syntax — the editor rejects it as invalid. Paste it into the column's own box, where `@{}` is interpolation. If you would rather stay in the ƒx tab, the equivalent is `concat('/ubsppcoe_nodes(', triggerBody()['text'], ')')`.

> **`ubsppcoe_policysetname` is written here and nowhere else.** [SyncCapacityPolicySets](docs/flows/capacity-policies/SyncCapacityPolicySets.md) uses it to spot a policy set renamed by hand without spending a `GET` per set, and the rebuild never touches it. Leave it blank and that check silently compares against nothing.

**Write the row before activating.** If activation fails, the policy set still exists in Fabric and must be recorded, or the next run creates a second one and `SyncCapacityPolicySets` reports a `Conflict` nobody caused.

### 8b. `Run_rebuild` — **Run a Child Flow** → `RebuildCapacityPolicyRules`, passing `triggerBody()['text']`.

With no OAP-enabled workspaces on the capacity's Node yet, and no exception rows for a policy row that was created seconds ago, this writes **rule 1 alone** — the intended default, and it exercises the zero-workspace path on day one rather than months later.

> **A capacity with no `ubsppcoe_Node` row never reaches this step** — Step 4b stops it and returns `Failed` before anything is created in Fabric. What can still happen here is a Node row that exists but has **no OAP-enabled workspaces yet**, which is the normal state for a freshly provisioned capacity and produces rule 1 alone.
>
> If provisioning routinely creates the capacity before its inventory record, expect `Failed` from Step 4b on first run, and decide whether the provisioning app should order the two the other way round.

### 8c. `Activate` — **Invoke an HTTP request**

| Field | Value |
|---|---|
| Method | `POST` |
| URL of the request | `https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{variables('policySetId')}/activate` |
| Header `Content-Type` | `application/json` |
| Body | `{ "scopeId": "@{triggerBody()['text']}", "scopeType": "Capacity" }` |

⋯ → **Configure run after** `Run_rebuild` on **is successful** only. Activating rules that failed to build would put an unknown rule set into force.

**Do not pass `allowReplace`.** `PolicySetActivationConflict` means another policy set already governs this capacity — on a freshly provisioned one that should be impossible, so it signals something worth a human looking at. Taking the capacity over silently is the wrong default here; the nightly job in [RebuildAllCapacityPolicies.md](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) is where that decision belongs.

### 8d. `Update_status` — Dataverse **Update a row**

Runs after `Activate` on **is successful** and **has failed**.

| Field | Value |
|---|---|
| Table name | **`Capacity Policies`** (`ubsppcoe_CapacityPolicy`) — the row 8a created |

| Column | Value |
|---|---|
| Row ID | `body('Add_policy_row')?['ubsppcoe_capacitypolicyid']` |
| `ubsppcoe_status` | `if(less(coalesce(outputs('Activate')?['statusCode'], 0), 300), 'Active', 'Inactive')` |
| `ubsppcoe_lasterror` | `if(less(coalesce(outputs('Activate')?['statusCode'], 0), 300), '', coalesce(body('Activate')?['message'], body('Activate')?['errorCode'], string(body('Activate'))))` |

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
| 5 | **An F-SKU capacity with no `ubsppcoe_Node` row** | `Failed` from Step 4b, and **no policy set created** — check the holder workspace to confirm nothing was left behind |
| 6 | **Open the `Capacity Policies` row test 1 created** | `Node` is populated, `Policy set name` matches the set in the portal. A blank `Node` means 8a's lookup did not bind, and every future rebuild of that capacity will fail |
| 5 | A capacity whose display name contains `/` or `:` | Created with `_` in place of them |
| 6 | Revoke Capacity Admin, then run | Row written, `status = Inactive`, `last_error` populated, outcome reports the failure. **The policy set must still be registered** |
| 7 | Force a `202` if you can | The `/result` path resolves the correct policy set ID |

Test 6 is the one that matters most. It is the difference between a recoverable state and an orphaned policy set nobody knows about.

> Testing from the designer reports **`ActionResponseSkipped`** on the Respond action — expected, since nothing is waiting for the response. Everything else still runs.
