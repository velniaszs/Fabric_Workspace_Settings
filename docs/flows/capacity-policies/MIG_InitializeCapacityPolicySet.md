# Flow — `MIG_InitializeCapacityPolicySet`

**Migration only.** Child flow. Creates one capacity's policy set and registers it in Dataverse — and stops there. It does **not** build rules and does **not** activate.

> **Not built yet.** Specification, not a description of something that exists.

Related: [MIG_RegisterAllCapacityPolicySets.md](docs/flows/capacity-policies/MIG_RegisterAllCapacityPolicySets.md) (the loop that calls this), [MIG_ActivateAllCapacityPolicySets.md](docs/flows/capacity-policies/MIG_ActivateAllCapacityPolicySets.md), [InitializeCapacityPolicySet.md](docs/flows/capacity-policies/InitializeCapacityPolicySet.md) (the BAU flow this is derived from), [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §8.

---

## 0. Why this exists rather than reusing the BAU flow

Three reasons, and the first is the one that forces the issue.

**A Power Apps (V2) trigger cannot be called by `Run a Child Flow`.** [InitializeCapacityPolicySet](docs/flows/capacity-policies/InitializeCapacityPolicySet.md) has one, so a loop cannot call it. Something with a *Manually trigger a flow* trigger has to exist.

**Migration must not activate.** The estate has to land **deactivated**, so that flags and exceptions can be reconciled and rules rebuilt before anything is enforced. Bolting a `mode` input onto the BAU flow would put a branch in a tested flow that is dead weight for the rest of its life.

**These flows are disposable.** The `MIG_` prefix is the point: after cutover, all three are turned off and deleted. Keeping them separate means cutover leaves no residue in the BAU flows, and nothing tested today has to be re-tested.

> ### What this flow deliberately drops
>
> | Dropped | Why |
> |---|---|
> | Step 4 — the `GET /v1/capacities` eligibility check | The parent already filtered to Active F-SKU capacities, and it holds the list. Repeating it here is one full capacity-list `GET` per capacity — 200 pointless calls |
> | Step 8b — `Run_rebuild` | Rules are built later, estate-wide, by `RebuildAllCapacityPolicies`, after exceptions are seeded |
> | Step 8c — `Activate` | Separate, deliberate step. See §0 above |
> | Step 8d/8e — the status flip | Nothing to flip. Rows are written `Inactive` and stay that way until activation |
>
> **Dropping Step 4 makes this flow unsafe to run standalone.** It will happily create a policy set for a paused capacity, a P-SKU, or a GUID that is not a capacity at all, because nothing checks. That is acceptable for a tool that only ever runs behind [MIG_RegisterAllCapacityPolicySets](docs/flows/capacity-policies/MIG_RegisterAllCapacityPolicySets.md) — but do not hand this flow to anyone as a one-off fixer. Use the BAU flow for that.

---

## 1. Before you start

- Build this **before** [MIG_RegisterAllCapacityPolicySets](docs/flows/capacity-policies/MIG_RegisterAllCapacityPolicySets.md), which calls it.
- Needs a **Dataverse connection** and the *HTTP with Microsoft Entra ID (preauthorized)* connector. **No `Authorization` header** — see [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) §0 for the connector pattern.
- The connection's identity needs **Contributor on the holder workspace**. It does **not** need Capacity Admin, because this flow never activates — that permission is only required by [MIG_ActivateAllCapacityPolicySets](docs/flows/capacity-policies/MIG_ActivateAllCapacityPolicySets.md).

> **Build it fresh. Do not try to copy `InitializeCapacityPolicySet` and change the trigger.** Power Automate does not let you swap a trigger, and Power Apps (V2) → *Manually trigger a flow* is precisely the swap it refuses — `Save As` keeps the original trigger, and the designer will not let you delete it. This is the same constraint recorded in [SyncCapacityPolicySets.md](docs/flows/capacity-policies/SyncCapacityPolicySets.md) Step 1 and [GetFabricToken.md](docs/flows/nocustomcon/GetFabricToken.md).
>
> It is about twenty actions and every value is below, so building it from this document is quicker than fighting the platform. **Use ⋯ → *Copy to my clipboard* on the three Step 5 Composes** and paste them into the new flow — those expressions are long enough that retyping them is where a typo would come from, and they are unchanged from the BAU flow.

---

## Step 1 — Create the flow

**Solutions** → **New** → **Automation** → **Cloud flow** → **Instant** → name `MIG_InitializeCapacityPolicySet` → trigger **Manually trigger a flow**.

> **Not Power Apps (V2).** That is the whole reason this flow exists — see §0.

Two **Text** inputs, in this order:

| Order | Title | Key | Reference |
|---|---|---|---|
| 1 | `capacityId` | `text` | `triggerBody()['text']` |
| 2 | `capacityDisplayName` | `text_1` | `triggerBody()['text_1']` |

**The display name comes from the parent, not from a lookup.** The parent already read `GET /v1/capacities` and has the authoritative `displayName` in hand, so passing it avoids a second call and avoids the drift the BAU flow is exposed to, where a caller supplies a name nothing verifies.

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

Seeding `outcome` with `Failed` means a path nobody anticipated reports failure rather than silence.

> ### The shape of this flow
>
> Same nesting convention as the BAU flow: **no Terminate anywhere**, a single `Respond` at the end that every path must reach, and early exits that set variables and contain nothing else.
>
> ```
> trigger
> Step 2   5 × Initialize variable
> Step 3   Get_policy_row
>          Condition_already_exists
>            ├─ Yes: 3 × Set variable          ← AlreadyExists
>            └─ No:  Step 4   Get_node_row
>                             Condition_node_missing
>                               ├─ Yes: 2 × Set variable   ← Failed, no Node row
>                               └─ No:  Step 5  3 × Compose
>                                       Step 6  Create_policy_set
>                                       Step 7  Condition_created_sync
>                                                 ├─ Yes: 201 branch
>                                                 └─ No:  202 branch
>                                       Step 8  Add_policy_row
>                                               Set_outcome_registered
> Step 9   Respond                              ← top level, run after: succeeded + failed + skipped
> ```
>
> **Step 8 is a sibling of `Condition_created_sync`, not a child of either branch.** Both branches exist only to resolve `policySetId`; they converge and the registration happens once, after. This is the mistake that cost an afternoon on the BAU flow.
>
> **Nothing else nests, and there is no failure branch.** A step that fails — typically `Create_policy_set` on a duplicate name — skips everything after it, and Step 9's run-after settings are what turn that into a usable answer instead of a bare fault. See Step 9.

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

**True means a row was found**, so *Yes* is the early exit and *No* is the normal path.

**Yes branch** — three **Set variable** actions and nothing else:

| Rename to | Name | Value |
|---|---|---|
| `Set_outcome_exists` | `outcome` | `AlreadyExists` |
| `Set_policySetId_exists` | `policySetId` | `first(body('Get_policy_row')?['value'])?['ubsppcoe_policysetid']` |
| `Set_message_exists` | `message` | `Already registered; nothing done.` |

> **This is what makes the migration re-runnable, and it is not optional.** A 200-capacity run that fails at capacity 140 has to be restartable without creating 139 duplicate policy sets. `AlreadyExists` is the mechanism, and the parent counts it as a success rather than an error.
>
> It also means the run can be done in tranches — a dozen capacities, check the result, then the rest — which is the safest way to do this at all.

**No branch** — everything from Step 4 to Step 8 goes inside it. Step 9 does **not**.

---

## Step 4 — Resolve the Node row

`Get_node_row` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Nodes` (`ubsppcoe_Node`) |
| Filter rows | `ubsppcoe_nodeuniqueid eq @{triggerBody()['text']}` |
| Row count | `1` |

**The GUID is unquoted.** `ubsppcoe_nodeuniqueid` is a unique-identifier column holding the Fabric capacity id.

**This step exists to fetch `ubsppcoe_nodeid`, the Node row's primary key** — a *different* GUID from the capacity id, and the one Step 8's lookup must bind to ([CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §1). Leave **Select columns** empty, or include `ubsppcoe_nodeid` explicitly.

`Condition_node_missing` — **Condition**:

| Left (expression) | Operator | Right |
|---|---|---|
| `empty(body('Get_node_row')?['value'])` | is equal to | `true` |

**Yes branch** — two **Set variable** actions and nothing else:

| Rename to | Name | Value |
|---|---|---|
| `Set_outcome_no_node` | `outcome` | `Failed` |
| `Set_message_no_node` | `message` | `No Node row for this capacity, so its workspaces cannot be determined. Ask the platform team to add one, then re-run.` |

**No branch** — Steps 5 to 8 go inside it.

> **This is the finding migration exists to surface.** Nothing else in the estate reveals a capacity with no inventory record, and the consequence is severe: registered, activated, and permanently un-rebuildable, because [RebuildCapacityPolicyRules](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) Step 5a fails closed on a blank `node` lookup, for the life of that capacity.
>
> Failing **before** anything is created in Fabric is what keeps that recoverable. The parent's failure list is the deliverable: it is the list to hand the platform team.

---

## Step 5 — Build the policy set name

Three **Compose** actions, identical to the BAU flow. Capacity display names are far more permissive than Fabric item names.

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

Caps at 256 characters, then strips a single trailing dot. **Fabric rejects trailing dots silently.**

> **Duplicate display names bite harder here than in BAU.** Two capacities called `Finance` produce one policy set name, and the second create fails with `ItemDisplayNameAlreadyInUse`. In BAU that is a rare one-off; in a 200-capacity run it is close to certain.
>
> `migrate_policy_sets.ps1` appends the first 8 characters of the capacity ID on collision. **Check for duplicates before running** — the parent's capacity list makes that a one-minute look. If there are any, append the suffix unconditionally in 5a: `concat(prefix, displayName, ' (', substring(triggerBody()['text'], 0, 8), ')')`. Names are cosmetic, so doing it for every capacity costs nothing and removes the failure mode.

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

Then ⋯ → **Settings** → **Asynchronous Pattern** → **Off**, for the reason set out in the BAU flow: left on, the connector follows `Location` to the *operation* and `body(...)?['id']` is then the operation id, not the policy set id.

Leave **Retry Policy** at Default.

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

1. `Set_operationId` — `operationId` = `outputs('Create_policy_set')?['headers']?['x-ms-operation-id']`.
2. `Set_opStatus_initial` — `opStatus` = `Running`.
3. **Do until** `@or(equals(variables('opStatus'), 'Succeeded'), equals(variables('opStatus'), 'Failed'))`, count `30`, timeout **`PT90S`**:
   - `Get_operation` — **Invoke an HTTP request**, `GET https://api.fabric.microsoft.com/v1/operations/@{variables('operationId')}`.
   - `Set_opStatus` — Set variable → `coalesce(body('Get_operation')?['status'], 'Running')`.
   - **Delay** 3 seconds.
4. `Get_operation_result` — **Invoke an HTTP request**, `GET https://api.fabric.microsoft.com/v1/operations/@{variables('operationId')}/result`.
5. `Set_policySetId_async` — Set variable → `policySetId` = `body('Get_operation_result')?['id']`.

> **`PT90S`, not the BAU flow's `PT10M`.** This flow is called by `Run a Child Flow`, which must get its `Respond` back within roughly **120 seconds** ([RebuildAllCapacityPolicies.md](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) §5). A ten-minute poll would hang the parent and take the whole migration run down with it.
>
> Ninety seconds fails *inside* the parent's budget, so a slow create costs one capacity in the failure list instead of the run. Creation almost always answers `201`, so this branch should be rare — but "rare" across 200 capacities is not "never".

---

## Step 8 — Register

**Place this after `Condition_created_sync` closes, at the same level as it.** `policySetId` is set by whichever branch ran.

### 8a. `Add_policy_row` — Dataverse **Add a new row**

| Field | Value |
|---|---|
| Table name | **`Capacity Policies`** (`ubsppcoe_CapacityPolicy`) |

| Column | Logical name | Value |
|---|---|---|
| Capacity name | `ubsppcoe_capacityname` | `triggerBody()['text_1']` |
| Capacity ID | `ubsppcoe_capacityid` | `triggerBody()['text']` |
| **Node** | `ubsppcoe_node` | `concat('/ubsppcoe_nodes(', first(body('Get_node_row')?['value'])?['ubsppcoe_nodeid'], ')')` |
| Policy set ID | `ubsppcoe_policysetid` | `variables('policySetId')` |
| Policy set name | `ubsppcoe_policysetname` | `outputs('Compose_name_final')` |
| Status | `ubsppcoe_status` | `Inactive` |

> **The `Node` bind takes the row key, not the capacity id.** `ubsppcoe_nodeuniqueid` holds the capacity id but is an ordinary column; binding to it fails with `Entity 'ubsppcoe_Node' With Id = … Does Not Exist`. Step 4 fetched the key for exactly this line.
>
> **Put this in the ƒx tab** — it is a pure expression, with no `@{}` interpolation.
>
> A blank `Node` here registers the capacity and makes it permanently un-rebuildable. Step 4 exists to make this line safe to write; test 5 exists to prove it did.

> **`ubsppcoe_status` is the plain text column, not the system `statecode`/`statuscode` pair.** Writing the system pair would soft-deactivate the row, hiding it from `List rows` — so the next run would report `Registered` again and create a second policy set.
>
> `Inactive` is not a placeholder here. It is the value [MIG_ActivateAllCapacityPolicySets](docs/flows/capacity-policies/MIG_ActivateAllCapacityPolicySets.md) selects on, so it is the migration backlog.

Leave `ubsppcoe_lastrebuild`, `ubsppcoe_lasterror` and the three counts **empty**. `RebuildAllCapacityPolicies` fills them later, and an empty `lastrebuild` is what proves a capacity has not yet been through the rebuild phase.

### 8b. `Set_outcome_registered` — **Set variable**

| Field | Value |
|---|---|
| Name | `outcome` |
| Value | `Registered` |

And a second **Set variable** for `message`: `concat('Policy set created and registered, deactivated. ', outputs('Compose_name_final'))`.

> **Without this the flow never reports success.** `outcome` is seeded `Failed` in Step 2 and only reassigned on the two early-exit branches, so the whole happy path would end at the Respond still saying `Failed` — with every side effect having worked correctly.

---

## Step 9 — Respond

**Respond to a Power App or flow**, at the **top level**. ⋯ → **Configure run after** on `Set_outcome_registered` with **is successful**, **has failed** *and* **is skipped** ticked. Three **Text** outputs:

| Output | Value |
|---|---|
| `Outcome` | `variables('outcome')` |
| `PolicySetId` | `variables('policySetId')` |
| `Message` | the expression below |

```
if(empty(variables('message')), concat('Failed at or after policy set creation: ', coalesce(body('Create_policy_set')?['message'], body('Create_policy_set')?['errorCode'], string(outputs('Create_policy_set')?['statusCode']), 'no detail available')), variables('message'))
```

> ### These three run-after ticks are the whole error handling, and they replace a failure branch
>
> **Tick `is skipped`, not just the usual two.** Run-after has four states, and an action downstream of a failure is *skipped*, not *failed*. With only succeeded + failed, a failed `Create_policy_set` skips everything after it, no `Respond` fires, and the parent records the generic `'child flow failed'` — losing the reason. Across 200 capacities, where duplicate display names and permission gaps are both likely, that reason **is** the deliverable.
>
> **The `Message` expression is what recovers it.** `outcome` is already seeded `Failed` in Step 2, so it needs nothing. `message` is empty on any path that died mid-flow, and a failed action's `body(...)` is still readable afterwards — so the fallback pulls the API's own error text out of `Create_policy_set`. On the `AlreadyExists` and no-Node paths `message` is non-empty, so the fallback is never reached.
>
> **This is deliberately flatter than a `Condition` guarding the create.** A branch would work and would read more explicitly, but it means nesting Steps 7 and 8 inside it — and in this designer that is a lot of dragging for an outcome three run-after ticks already achieve.
>
> The BAU flow has no equivalent because a single interactive call surfaces the fault to the app directly. A loop swallows it.

`outcome` values: `Registered`, `AlreadyExists`, `Failed`.

**There is no `Skipped`.** The parent filters for Active F-SKU capacities before calling, so ineligibility never reaches this flow — see §0.

Every output **Text**. A field typed Number or Boolean fails schema validation and makes *every* output unreadable to the caller.

---

## To verify after building

Run it directly from the designer for tests 1–5, then let the parent drive it.

| # | Test | Expect |
|---|---|---|
| 1 | A throwaway F-SKU capacity with a Node row and no `Capacity Policies` row | `Registered`. One policy set in the holder workspace with **no rules** and **not activated** |
| 2 | **Open the row it created** | `Node` populated, `Status` = `Inactive`, `Policy set name` matches the portal, `lastrebuild` and the three counts **empty** |
| 3 | Run again on the same capacity | `AlreadyExists`, and **no second policy set** |
| 4 | A capacity with **no** Node row | `Failed`, and **nothing created in Fabric** — check the holder workspace to confirm |
| 5 | Blank the `Node` lookup on a row, then run `RebuildCapacityPolicyRules` against it | It fails closed. Confirms what test 2 is protecting against |
| 6 | Two capacities with the same display name | The second returns **`Failed` with the `ItemDisplayNameAlreadyInUse` message**, not a bare flow fault. This is what 7a buys |
| 7 | Call it from a throwaway parent with `Run a Child Flow` | The three outputs arrive and are readable. **Do this before building the real parent** |
| 8 | Point the holder-workspace environment variable at a workspace the identity cannot write, and run | `Failed` with a permission message in `Message`, and the parent can print it |

Test 1 is the one to check in the portal by eye. A policy set that arrives **activated** means Step 8c was not deleted from the copy — and that is deny-all in force on a capacity nobody approved.

Test 7 costs two minutes and catches the child-flow wiring problems — trigger type, same solution, embedded connections — before they show up 140 capacities into a run.

> Testing from the designer reports **`ActionResponseSkipped`** on the Respond action — expected, since nothing is waiting for the response. Everything else still runs.

---

## After cutover

**Turn this flow off and delete it.** It has no BAU role, it is unsafe standalone because Step 4's eligibility check was dropped, and leaving it in the solution invites someone to run it against a live capacity a year from now.
