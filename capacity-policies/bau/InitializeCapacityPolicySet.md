# Flow — `InitializeCapacityPolicySet`

Creates the policy set for a newly inventoried capacity, registers it in Dataverse, builds the default rules and activates it. **Fires on a `ubsppcoe_Node` row appearing.**

> **Not built yet.** Specification, not a description of something that exists.

> ## Retriggered 2026-09-12 — no longer called by the provisioning app
>
> It was an instant flow with a **Power Apps (V2)** trigger taking `capacityId` and `capacityDisplayName` from a caller. It now fires on a **Dataverse row trigger on `ubsppcoe_Node`**, and both values are **derived** from the row that triggered it.
>
> | # | Edit | Where |
> |---|---|---|
> | 1 | Delete the Power Apps (V2) trigger, add the Dataverse one | Step 1 |
> | 2 | `triggerBody()['text']` → `triggerOutputs()?['body/ubsppcoe_nodeuniqueid']` | Steps 3, 4, 8a, 8c |
> | 3 | `triggerBody()['text_1']` → the Fabric display name from Step 4 | Steps 5, 8a |
> | 4 | **Delete Step 4b entirely** — the trigger *is* the Node row | Step 4b |
> | 5 | Replace `Respond` with a `Compose` | Step 9 |
> | 6 | Wrap Steps 3–8 in `Scope_try`; add `Scope_catch` | Step 10 |
> | 7 | Concurrency Control On, Degree of Parallelism 1 | Settings |
>
> **The conversion removes more than it adds.** Step 4b existed only to turn a caller's capacity id into a Node row; the trigger hands over that row directly. One `List rows`, one Condition and an entire failure mode (`Failed — no Node row`) all disappear, because a flow triggered *by* a Node row cannot run without one.
>
> **Two things get materially riskier, and both are in §0.** Activation is now automatic, and there is no retry.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md), [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) §0 — which sets out the connector pattern every Fabric call here uses, [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) — the same conversion, done first, and the source of the try/catch pattern.

---

## 0. Before you start

- Build [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) first. This flow calls it, and its §0 defines the Fabric connector pattern used below.
- **There is no token flow.** Every Fabric call is *HTTP with Microsoft Entra ID (preauthorized)* → **Invoke an HTTP request**, with **no `Authorization` header**.
- Needs a **Dataverse connection**.
- The SPN needs **Contributor on the holder workspace** and **Capacity Admin on the capacity being initialised**. The second is what step 8 requires; without it activation fails and the capacity is left with rules that are not in force.
- Logical names below use the **`ubsppcoe_`** prefix, shared with the platform team's tables since 2026-09-07 — see [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §0. Pick tables and columns from the dropdowns rather than typing them.

> ### The capacity is born locked, on purpose — and now nobody asked for it
>
> Rule 1 denies creation of every governed item type. A capacity that has just been through this flow permits **no** governed item creation until a workspace is whitelisted through [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md). Power BI items are not governed and stay creatable.
>
> That was the intended posture when a provisioning app called this flow deliberately and could warn the user. **Under a row trigger, nobody decided.** The platform team adds an inventory row, and a capacity locks down within minutes — with no screen, no message and no acknowledgement anywhere.
>
> **This needs agreeing before the flow is turned on.** The failure mode is a capacity owner who cannot create a Lakehouse, does not know a policy exists, and finds nobody who admits to having done it. The likely resolution is that somebody deactivates the policy set, which is the one outcome this design cannot detect from the rebuild ([SyncCapacityPolicySets](docs/flows/capacity-policies/SyncCapacityPolicySets.md) is what catches it, a day later).
>
> Three ways out, in rough order of cost: have the platform team's process notify the capacity owner; create the set **deactivated** and activate it on a separate signal; or keep activation with a caller and let this flow do everything up to 8c. **Decide before turning this on, not after the first ticket.**

> ### There is no retry, and that is new
>
> A Dataverse row trigger fires **once per change**. If Step 4 answers `Skipped` — the commonest reason being that Fabric does not yet know about a capacity whose inventory row has already been created — **nothing runs this flow again**. The app used to be able to retry; there is no app.
>
> `Added or Modified` mitigates it only if something later edits the row. If the platform team writes the Node row once and never touches it, that capacity is never initialised, never governed, and **nothing reports it** — the nightly [RebuildAllCapacityPolicies](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) only walks capacities that already have a `Capacity Policies` row, so it cannot notice one that was never registered.
>
> **That is a governance hole, not an inconvenience.** A capacity silently ungoverned looks identical to one that was never meant to be governed. The fix is a scheduled sweep — list `ubsppcoe_Node`, left-join `Capacity Policies`, report the gaps — which does not exist and is not specified here. **Raise it with [SyncCapacityPolicySets](docs/flows/capacity-policies/SyncCapacityPolicySets.md), which is the flow that ought to own it.**

---

## Step 1 — The trigger

**Solutions** → **New** → **Automation** → **Cloud flow** → **Automated** → name `InitializeCapacityPolicySet` → trigger **Microsoft Dataverse — When a row is added, modified or deleted**.

| Field | Value |
|---|---|
| Change type | **Added or Modified** |
| Table name | `Nodes` (`ubsppcoe_Node`) |
| Scope | **Organization** |
| Select columns | `ubsppcoe_nodeuniqueid` |
| Filter rows | `ubsppcoe_nodeuniqueid ne null and ubsppcoe_isdeleted ne true` |

> **`ubsppcoe_isdeleted` is a PLACEHOLDER name — see [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §1 (Q46).** The platform team's tables soft-delete rather than hard-delete, so a decommissioned capacity keeps its Node row and its capacity GUID. Without this clause, any later edit to a decommissioned Node row would initialise and **activate** a policy set on a capacity somebody has retired.

The three values the flow needs all come off the trigger body:

| Was | Now |
|---|---|
| `triggerBody()['text']` — capacity id | `triggerOutputs()?['body/ubsppcoe_nodeuniqueid']` |
| `triggerBody()['text_1']` — display name | **Step 4's Fabric `displayName`** — see below |
| Step 4b's `Get_node_row` result | `triggerOutputs()?['body/ubsppcoe_nodeid']` |

**`Added or Modified`, not `Added`.** A Node row is not always created with its capacity GUID already populated, and the `Filter rows` condition means a row created blank does not fire at all. The `Modified` event is what catches it when the GUID is filled in later — without it, exactly the rows that arrive in two steps are the ones never governed.

**Scope must be `Organization`.** The default is `User`, which fires only for rows the connection's own user changed. This table belongs to the platform team and nothing here is created by us, so a `User` scope produces a flow that works in testing and never fires in production.

**`Filter rows` is doing real work.** `ubsppcoe_nodeuniqueid ne null` is the difference between deriving a capacity id and passing `null` into a Fabric URL. There is no guard for it later in the flow, because there does not need to be one.

> ### Take the display name from Fabric, not from the Node row
>
> `ubsppcoe_nodename` is the **Node's** display name in the platform team's inventory. It is not guaranteed to be the **capacity's** display name in Fabric, and the policy set is named `pol_<capacity display name>` to match what `migrate_policy_sets.ps1` produced for the ~200 existing sets.
>
> Step 4 already fetches the authoritative value — `first(body('Filter_capacity'))?['displayName']` — so use that in Steps 5 and 8a. **This is better than the flow it replaces**, which trusted whatever string the caller passed.
>
> The cost is ordering: the name cannot be built until after the eligibility check. That is already true — Step 5 comes after Step 4 — so nothing moves.

⋯ → **Settings** → **Concurrency Control On, Degree of Parallelism 1**. Permitted now that there is no `Respond`. It matters more here than in [AddWorkspaceToPolicy](docs/flows/capacity-policies/AddWorkspaceToPolicy.md): two concurrent runs for the same capacity would both pass Step 3's `AlreadyExists` check and create **two policy sets**, one of which nothing maps back to. The alternate key on `ubsppcoe_capacityid` recommended in [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §2 is the real defence; this setting is the cheap one.

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
| `Initialize_policyRowId` | `policyRowId` | String | *(leave empty)* |

`policyRowId` is new, and it exists for Step 10's Catch. Set it immediately after 8a with `body('Add_policy_row')?['ubsppcoe_capacitypolicyid']`. **The Catch cannot read `body('Add_policy_row')` directly** — on a run that failed before 8a that action never executed, and dereferencing it from the error handler is how a Catch throws.

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
> trigger  (Dataverse: Node row added or modified, nodeuniqueid not null)
> Step 2   6 × Initialize variable          ← outside Scope_try, always
> Scope_try
>   Step 3   Get_policy_row
>            Condition_already_exists
>              ├─ Yes:  3 × Set variable          ← AlreadyExists, then nothing else
>              └─ No:   Step 4   Get_capacities
>                               Filter_capacity
>                               Condition_eligible
>                                 ├─ Yes: Step 5   3 × Compose
>                                 │           Step 6   Create_policy_set
>                                 │           Step 7   Condition_created_sync
>                                 │                      ├─ Yes: Set_policySetId_sync
>                                 │                      └─ No:  the 202 branch
>                                 │           Step 8   8a … 8e   ← AFTER the Condition, not inside it
>                                 └─ No:  2 × Set variable         ← Skipped
> Scope_catch   runAfter Scope_try = Failed, Skipped, TimedOut
> Step 9   Compose_result                   ← top level, every path except the caught one
> ```
>
> **Step 8 is a sibling of `Condition_created_sync`, not a child of either branch.** Both branches of Step 7 exist only to resolve `policySetId`; they converge, and the registration work happens once, after. Drop 8a inside the `201` branch and a run that answered `202` skips the whole of Step 8 — the policy set is created, no Dataverse row is written, no rules are built, and the flow still reports whatever `outcome` was last set. Nothing fails, so the run history looks healthy apart from a column of greyed-out actions.
>
> **Step 4b is gone.** The trigger supplies the Node row, so the eligibility check leads straight into Step 5. One level of nesting disappeared with it.
>
> **Terminate still does not belong in the body**, and there is now a sharper reason than *the caller would get nothing*: a Terminate inside `Scope_try` ends the run before `Scope_catch` can execute ([SCOPE-SANDBOX.md](docs/flows/capacity-policies/SCOPE-SANDBOX.md) E4). The only Terminate in this flow is the last action of the Catch.

---

## Step 3 — Already registered?

`Get_policy_row` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Capacity Policies` |
| Filter rows | `ubsppcoe_capacityid eq '@{triggerOutputs()?['body/ubsppcoe_nodeuniqueid']}'` |
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
| Condition (advanced) | `@equals(toLower(item()?['id']), toLower(triggerOutputs()?['body/ubsppcoe_nodeuniqueid']))` |

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

## Step 4b — Deleted

> ### This step is gone, and the failure mode with it
>
> It was a `Get_node_row` **List rows** plus a `Condition_node_missing`, and it existed for one reason: to turn the caller's capacity id into the Node row's primary key, `ubsppcoe_nodeid`, so that 8a's lookup had something to bind to.
>
> **The trigger hands over that row.** `triggerOutputs()?['body/ubsppcoe_nodeid']` is the key, already in hand, with no query and no possibility of it being absent — a flow triggered *by* a Node row cannot run without one.
>
> So the `Failed — this capacity has no inventory record` outcome **cannot occur any more**. Do not keep it as a defensive branch; it would be unreachable code guarding against a state the trigger makes impossible. Remove it from the outcome list in Step 9 too.
>
> **What this does not change** is the fail-closed rule it protected. 8a must still write the `Node` lookup, [RebuildCapacityPolicyRules](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) Step 5a still refuses a blank one, and a capacity registered with an empty lookup is still permanently un-rebuildable. The guard moved from *check the Node exists* to *the trigger guarantees it*; the consequence of getting 8a wrong is identical.
>
> Keep reading the Node key from the trigger rather than re-querying it "to be safe". A second lookup could disagree with the row that fired the flow — if the row were deleted mid-run, the query returns nothing and the bind silently writes blank, which is the exact outcome this step used to prevent.

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
| Capacity name | `ubsppcoe_capacityname` | `first(body('Filter_capacity'))?['displayName']` |
| Capacity ID | `ubsppcoe_capacityid` | `triggerOutputs()?['body/ubsppcoe_nodeuniqueid']` |
| **Node** | `ubsppcoe_node` | `concat('/ubsppcoe_nodes(', triggerOutputs()?['body/ubsppcoe_nodeid'], ')')` |
| Policy set ID | `ubsppcoe_policysetid` | `variables('policySetId')` |
| Policy set name | `ubsppcoe_policysetname` | `outputs('Compose_name_final')` |
| Status | `ubsppcoe_status` | `Inactive` |

> **The Node bind now comes straight from the trigger.** `triggerOutputs()?['body/ubsppcoe_nodeid']` is the row key of the row that fired the flow — no query, and nothing that can return empty. Step 4b used to fetch it; see that section for why it is gone and why re-querying "to be safe" would be worse.

> **The `Node` lookup is the one that must not be skipped.** It is what every later rebuild reads, and Step 5a of [RebuildCapacityPolicyRules](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) fails closed without it. Step 4b exists solely to make this line safe to write.
>
> **Lookups are set with the OData bind form**, not a bare GUID: `/ubsppcoe_nodes(<guid>)`, with the **entity set** name and the target row's **primary key**. That key is `ubsppcoe_nodeid` — display name *Node*, the only unique-identifier column on the table. Step 4b exists to fetch it. If the connector rejects the path, check the entity set name against `/api/data/v9.2/$metadata` — the plural is not always what you would guess.
>
> **The key is *not* the capacity id.** `ubsppcoe_nodeuniqueid` holds the capacity id, but it is an ordinary column, not the row key — so binding `/ubsppcoe_nodes(<capacityId>)` fails with `Entity 'ubsppcoe_Node' With Id = … Does Not Exist`. Confirmed against a real environment 2026-09-09, correcting an assumption that had spread through several documents.
>
> **This value goes in the ƒx tab**, unlike the string form used elsewhere in this table — it is a pure expression with no `@{}` interpolation.

> **`ubsppcoe_policysetname` is written here and nowhere else.** [SyncCapacityPolicySets](docs/flows/capacity-policies/SyncCapacityPolicySets.md) uses it to spot a policy set renamed by hand without spending a `GET` per set, and the rebuild never touches it. Leave it blank and that check silently compares against nothing.

**Write the row before activating.** If activation fails, the policy set still exists in Fabric and must be recorded, or the next run creates a second one and `SyncCapacityPolicySets` reports a `Conflict` nobody caused.

### 8b. `Run_rebuild` — **Run a Child Flow** → `RebuildCapacityPolicyRules`, passing `triggerOutputs()?['body/ubsppcoe_nodeuniqueid']`.

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

Body:

```json
{
  "scopeType": "Capacity",
  "scopeId": "@{triggerOutputs()?['body/ubsppcoe_nodeuniqueid']}",
  "capacityId": "@{triggerOutputs()?['body/ubsppcoe_nodeuniqueid']}"
}
```

> **`capacityId` is required, and it is not in the published API reference.** The reference documents `scopeType` and `scopeId` only; the preview service additionally validates `capacityId` and rejects the call with **`PropertyCannotBeDefault — property capacityId is not expected to have its default value`** when it is absent. Send all three for capacity scope — unknown properties are ignored, so there is no cost to the redundancy.
>
> Confirmed against the live service 2026-09-09, and already documented in `activate_policy_set.ps1` in `C:\GIT\ubs-policies`. That script is the authority for these payloads; the reference markdown beside it is not.
>
> **The activation scope type must match the policy set's own scope type**, or the call fails with `InvalidActivationScope`. Step 6 creates the set with `scope.type = Capacity`, so `Capacity` is correct here — but if that ever changes, both must change together.

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

## Step 9 — Record the outcome

**Delete the `Respond to a Power App or flow` action** — invalid without a Power Apps or Request trigger, and it will block the save.

Replace it with `Compose_result` — **Compose**, run after **both** `Scope_try` and `Scope_catch` on **all four** statuses:

```
@{variables('outcome')} — @{variables('policySetId')} — @{variables('message')}
```

| `outcome` | Meaning | Run ends |
|---|---|---|
| `Created` | Policy set created, registered, rules built, activated | Succeeded |
| `AlreadyExists` | A `Capacity Policies` row was already there. **The common outcome** | Succeeded |
| `Skipped` | Not in the capacity list, not `Active`, or not an F SKU | Succeeded |
| `Failed` | Activation failed. The row exists and carries `lasterror` | Succeeded |
| `Caught` | An action failed outright. Set by `Scope_catch` | **Failed** |

**`Failed — no Node row` is gone.** Step 4b made it unreachable. Do not carry it forward.

> **`AlreadyExists` stops being an error and becomes routine.** Under the app trigger it meant somebody clicked twice. Under a row trigger it means the platform team edited a Node row for any reason at all — a rename, a correction, a bulk sync — and `Select columns` cannot narrow that, because `ubsppcoe_nodeuniqueid` is the only column worth watching and it is also the one most likely to be rewritten by an import.
>
> **Expect most runs of this flow to end in `AlreadyExists` having done nothing.** Say so somewhere visible, or the run history reads as a flow firing constantly for no reason.

---

## Step 10 — Try and Catch

Build **last**, once the flow works. Identical in shape to [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) Step 7 — build that one first and copy it.

### 10a. `Scope_try`

**Control** → **Scope**, renamed `Scope_try`. Drag Steps 3 through 8 into it. The six `Initialize variable` actions stay above it.

> ### This flow keeps two *has failed* configurations, deliberately
>
> [AddWorkspaceToPolicy](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) Step 5 states the rule: **no action inside a Try scope may run after *has failed***, because it makes the scope report Succeeded and skips the Catch ([SCOPE-SANDBOX.md](docs/flows/capacity-policies/SCOPE-SANDBOX.md) E3).
>
> **8d and 8e break that rule on purpose.** `Update_status` runs after `Activate` on *is successful* **and** *has failed*, and 8e follows it the same way. That is precisely the mechanism the rule warns about — and here it is the behaviour wanted.
>
> A failed **activation** is a fully handled state: the policy set exists, the row is written, `ubsppcoe_status` is `Inactive`, `ubsppcoe_lasterror` carries Fabric's own message, and `outcome` reports `Failed`. Everything a Catch would record is already recorded, and recorded better — routing it to the Catch would replace a real Fabric error with *"An action failed. No dependent actions succeeded."*
>
> **So `Scope_catch` here covers only the unhandled failures:** `Get_capacities`, `Create_policy_set`, the `202` polling branch, `Add_policy_row` and `Run_rebuild`. Those are the ones that leave no trace anywhere else.
>
> **Put a note on 8d in the flow itself.** The next person to apply the no-*has failed* rule mechanically will otherwise correct it, and silently convert every activation failure into a generic caught error with a worse message.

### 10b. `Scope_catch`

**Control** → **Scope**, renamed `Scope_catch`. **Configure run after** `Scope_try`: **has failed**, **is skipped**, **has timed out**.

| # | Action | Detail |
|---|---|---|
| 1 | `Compose_error` — **Compose** | `result('Scope_try')` |
| 2 | `Filter_failed` — **Filter array** | From `result('Scope_try')`, `item()?['status']` **is equal to** `Failed` |
| 3 | `Set variable` | `outcome` = `Caught` |
| 4 | `Set_message` — **Set variable** | `message` = the expression below |
| 5 | `Condition_row_known` — **Condition** | `empty(variables('policyRowId'))` is equal to `false` |
| 6 | └ **Yes** → `Update_policy_error` | `Capacity Policies`, row `variables('policyRowId')`, `ubsppcoe_lasterror` only |
| 7 | `Terminate` | Status **Failed**, message `concat(variables('outcome'), ' — ', variables('message'))` |

```
concat(coalesce(first(body('Filter_failed'))?['name'], 'no failed action in Scope_try'), ': ', coalesce(first(body('Filter_failed'))?['error']?['message'], 'scope was skipped or timed out'), ' | run ', workflow()?['run']?['name'])
```

Copy that from the code block, not from a table cell — the `|` would have to be escaped, and a `\|` pasted into the designer fails at runtime rather than at save.

> ### The `empty(policyRowId)` guard matters more here than anywhere else
>
> This flow can fail at six distinct points and only **one** of them is after `Add_policy_row`. Every earlier failure — the capacity list, the policy set creation, the `202` poll — leaves no row to write an error to, because the row does not exist yet.
>
> **So the common caught failure has nowhere to record itself except the run history.** Worth stating plainly: `ubsppcoe_lasterror` is not a log of everything that went wrong with initialisation. It is a log of what went wrong *after registration*.
>
> **What the gap costs:** a capacity whose policy set creation failed has no Dataverse row, so it is indistinguishable from a capacity nobody ever tried to initialise — which is the retry problem in §0 again. A failed run and a never-run look identical from the table, and only the sweep flow proposed there can separate them.

> ### A Fabric side effect can outlive a caught failure
>
> If `Create_policy_set` succeeds and `Add_policy_row` then fails, the Catch fires, the run goes red — and **a live policy set sits in the holder workspace with nothing in Dataverse pointing at it.**
>
> The Catch does not clean it up, and should not try. Deleting a Fabric item from an error handler, on a run that has just demonstrated it does not understand the current state, is how one bad run becomes two.
>
> [SyncCapacityPolicySets](docs/flows/capacity-policies/SyncCapacityPolicySets.md) reports it as `Untracked`. **Check the sync report after any `Caught` run on this flow** — it is the only thing that will find the orphan.

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | Add a `ubsppcoe_Node` row for a fresh F-SKU capacity | `Created`; one policy set in the portal with **exactly one** rule, active on the capacity |
| 2 | Edit any column on that Node row | Flow fires again, `AlreadyExists`, **no second policy set** |
| 3 | Add a Node row for a P-SKU capacity | `Skipped`, no Fabric write attempted |
| 4 | Add a Node row whose `ubsppcoe_nodeuniqueid` is a GUID Fabric does not know | `Skipped` — *not found or not administered*. **Confirm nothing retries** |
| 5 | Add a Node row with `ubsppcoe_nodeuniqueid` **blank**, then fill it in | No run on the first save; a run on the second. This is the whole reason for *Added or Modified* |
| 6 | **Open the `Capacity Policies` row test 1 created** | `Node` populated, `Policy set name` matches the portal. A blank `Node` means 8a's bind failed and every future rebuild of that capacity will fail |
| 7 | A capacity whose Fabric display name contains `/` or `:` | Created with `_` in place of them |
| 8 | Revoke Capacity Admin, then add a Node row | Row written, `status = Inactive`, `lasterror` populated, `outcome` = `Failed`. **The policy set must still be registered**, and `Scope_catch` must **not** fire — see 10a |
| 9 | Force a `202` if you can | The `/result` path resolves the correct policy set ID |
| 10 | Break `Add_policy_row` deliberately | `Caught`, run ends **Failed**, and a policy set is left in the holder workspace. **Confirm the sync report flags it as `Untracked`** |

**Test 8 is the one that proves 10a's exception.** A failed activation must end green with a real Fabric error in `lasterror` — if it ends red with *"An action failed"*, somebody has removed the *has failed* tick from 8d and the flow has lost its best error message.

**Test 10 is the one nobody runs, and it is the expensive one.** It is the only path that creates a Fabric object the flow then forgets about.

Test 6 remains the difference between a recoverable state and an orphaned policy set nobody knows about.
