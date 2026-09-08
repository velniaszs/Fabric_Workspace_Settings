# Flow — `SyncCapacityPolicySets`

Scans the holder workspace, reconciles what Fabric actually holds against the `Capacity Policies` table, and records the differences. Detects policy sets created, replaced or deleted outside the flows.

> **Not built yet.** Specification, not a description of something that exists.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md), [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) §0 — which sets out the connector pattern every Fabric call here uses.

---

## 0. What this is for, and what it is not

**It is not how the app lists policies.** With the desired state in Dataverse, Power Apps binds `Capacity Policies` directly — filtering, sorting and delegation come free and nothing waits on a flow.

This flow answers a different question: *does Fabric still match what we think it holds?* It exists because the tables are only the source of truth for **rules**. The policy sets themselves can be created, activated, replaced or deleted by anyone with rights on the holder workspace, and nothing stops them.

> **The nightly rebuild does not make this redundant.** [RebuildAllCapacityPolicies](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) overwrites every rule from the tables each night, so rule-level drift is self-healing and not worth worrying about.
>
> What it cannot fix is a policy set that has been **deactivated, replaced or deleted**. In those cases the nightly rebuild writes rules to a set that is not in force, and **reports success**. The capacity is governed by something else entirely and every signal says healthy. That gap is the whole reason this scan exists.

### The cheap-scan trick

Resolving which capacity a policy set belongs to needs a per-set `GET`, because `properties.scope.id` is frequently absent from the list response. At 200–300 sets that is a non-starter.

But **matching on `id` needs no scope resolution at all.** The list gives every set's `id` and `status`; anything whose `id` is already in `Capacity Policies` is accounted for. Only the leftovers need a `GET`.

> In a healthy tenant the leftovers are **zero**, so the scan is one paged list plus a handful of Dataverse reads. The cost scales with the amount of drift, not with the size of the estate.

### What it detects

| Kind | Meaning |
|---|---|
| `Untracked` | A policy set in the holder workspace that Dataverse has never heard of. Someone created it by hand |
| `Missing` | A `Capacity Policies` row whose `policy_set_id` no longer exists in Fabric. Someone deleted it |
| `Inactive` | A tracked set that is no longer `Active`. Usually means another set took the capacity over |
| `Conflict` | Two or more sets scoped to the same capacity |

`Inactive` and `Untracked` normally appear together: that is the signature of *someone created a replacement and activated it*, which is the case worth catching. Only one policy set can be active on a capacity, so the old one is deactivated rather than removed and would otherwise sit there looking fine.

---

## 1. Before you start

- **There is no token flow.** Every Fabric call is *HTTP with Microsoft Entra ID (preauthorized)* → **Invoke an HTTP request**, with **no `Authorization` header** — see [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) §0.

> **Build this flow first, and it is the one that proves the connection.** It is read-only against Fabric, so a wrong or under-privileged identity shows up here as an empty list or a `401` — cheaply, before anything writes rules. See Q45.
- Needs a **Dataverse connection**.
- Logical names below use the **`ubsppcoe_`** prefix, shared with the platform team's tables since 2026-09-07 — so it no longer identifies who owns a table. Pick tables and columns from the dropdowns rather than typing them; see [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §0.

### A fourth table — `Policy Drift`

| Column | Logical name | Type |
|---|---|---|
| Kind | `ubsppcoe_driftkind` | Choice — `Untracked`, `Missing`, `Inactive`, `Conflict` |
| Policy set ID | `ubsppcoe_policysetid` | Text |
| Capacity ID | `ubsppcoe_capacityid` | Text — blank until resolved |
| Display name | `ubsppcoe_displayname` | Text (primary) |
| Detected | `ubsppcoe_detected` | Date and time |
| Details | `ubsppcoe_details` | Multiline text |

Findings are rewritten each run, so this table is a **current state**, not a log. If an audit trail is wanted, add a second table and append instead — but do not make one table try to be both.

> **This flow is the only writer, and that follows from the wipe.** Step 2b deletes every row before writing new ones, so anything another flow contributed would disappear at the next scan without warning. [RebuildAllCapacityPolicies](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) reports its failures by mail and through `last_error` on each capacity row for exactly this reason.

---

## Step 1 — Create the flow

**Solutions** → **New** → **Automation** → **Cloud flow** → **Scheduled**. Name it `SyncCapacityPolicySets`. Recurrence: once daily, outside business hours.

> **Pick Scheduled, not Instant, and pick it now.** A flow's trigger cannot reliably be swapped afterwards — if you start from **Instant** you will be deleting the flow and starting again. An Instant flow only ever runs when someone presses a button, so the nightly scan would silently never happen, and this is the only thing that detects a policy set being deactivated, replaced or deleted.
>
> Wanting to test it by hand is not a reason to choose Instant: a Scheduled flow still runs on demand from the **Test** panel.

> **If you want a "Scan now" button in the app instead**, use a **Power Apps (V2)** trigger with no inputs and add a `Respond to a Power App or flow` at the end returning the four counts. The body is identical. In steady state it returns well inside the 120-second budget; on a badly drifted tenant it will not, which is the argument for the schedule doing the work and the app reading `Policy Drift`.

Then ⋯ → **Settings** → **Concurrency Control** → **On**, **Degree of Parallelism = 1**. Two overlapping scans would both rewrite the drift table.

---

## Step 2 — Variables

> **No token step.** Earlier drafts opened with `Run a Child Flow` → `GetPolicyToken` and an `accessToken` variable. Both are gone.

1. `Initialize_policySets` — `policySets`, Array, empty.
2. `Initialize_nextUri` — `nextUri`, String:

```
@{concat('https://api.fabric.microsoft.com/v1/workspaces/', parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)'), '/policySets?recursive=true')}
```

3. `Initialize_isDone` — `isDone`, Boolean, `false`.

Seeding `nextUri` with the first page URL keeps the loop body uniform — one *Invoke an HTTP request* action serves the first page and every continuation.

---

## Step 2b — Clear the previous run

**This runs third, before any scanning.** Findings are current state, so stale rows must go *before* new ones are written.

1. `List_old_drift` — Dataverse **List rows** on `Policy Drift`, row count `5000`, pagination on.
2. `For_each_old_drift` — **Apply to each** over `body('List_old_drift')?['value']`, containing Dataverse **Delete a row**, Row ID `items('For_each_old_drift')?['ubsppcoe_policydriftid']`.

Deleting first means a failed scan leaves an empty table rather than yesterday's answers wearing today's date. An empty drift table beside a stale run time is obviously wrong; stale rows that look current are not.

> **Leave `For_each_old_drift` at its default concurrency — do not set it to 1.** Every iteration deletes a different row ID and none depends on another, so running them in parallel is both correct and faster.
>
> That looks inconsistent with Step 6, which *does* set Degree of Parallelism to 1. The difference is what the loop body does: Step 6 calls **Fabric** once per iteration and serialises to stay inside the API's rate limits. This loop only touches Dataverse rows that have nothing to do with each other. **Serialise loops that call an external API; leave loops doing independent row writes alone.**
>
> The one reason to change it would be Dataverse service protection limits returning `429` on a very large drift table. That should not arise — a healthy tenant has zero rows here and a badly drifted one has a handful — but if it ever does, concurrency 1 is the lever.

> **Two scans overlapping is the real risk, and it is already handled** — by the flow-level Concurrency Control in Step 1, not by anything in this loop. Without that, one run could be deleting while another writes.

> **Why it is numbered `2b` rather than `3`.** It genuinely belongs here in execution order, but the scanning steps below are cross-referenced by number from other documents and from within this one — `Step 5a`, `6b`, `7c`. Inserting a whole step would shift every one of those. `2b` puts it in the right place without moving anything else.

---

## Step 3 — Page the policy sets

**+ New step** → **Do until**.

| Field | Value |
|---|---|
| Condition (raw) | `@equals(variables('isDone'), true)` |
| Count | `60` |
| Timeout | `PT10M` |

A scheduled flow is not answering a PowerApp, so the 120-second budget does not apply and the limits can be generous. 60 pages covers far more than 300 sets.

Inside, in this order:

### 3a. `List_page` — **Invoke an HTTP request**

| Field | Value |
|---|---|
| Method | `GET` |
| URL of the request | `@{variables('nextUri')}` |
| Header `Accept` | `application/json` |

Leave **Retry Policy** at Default here and on `Get_untracked_set`. It covers `429`, which matters more than usual on this flow: a throttle part-way through paging would leave a partial `policySets` array, and Step 5 would read that as a pile of `Missing` drift that does not exist — a confident wrong answer rather than a visible failure.
### 3b. `Merge_sets` — Compose

```
@union(variables('policySets'), coalesce(body('List_page')?['value'], json('[]')))
```

A Compose, not a Set variable — a variable may not reference itself in its own assignment.

### 3c. `Set_policySets` — Set variable → `policySets` = `@outputs('Merge_sets')`

### 3d. `Set_nextUri` — Set variable → `nextUri` = `@{coalesce(body('List_page')?['continuationUri'], '')}`

Use `continuationUri`, not `continuationToken`. Fabric returns the token already percent-encoded, so rebuilding the URL yourself means choosing between passing it raw and double-encoding it — and double-encoding silently returns page 1 forever. `continuationUri` is the same value already assembled by the service.

### 3e. `Set_isDone` — Set variable → `isDone` = `@empty(variables('nextUri'))`

Bare `@expr`, not `@{ }`. Wrapped, it becomes the string `"true"`, never equals the boolean, and the loop spins to its count limit — a slow flow rather than an error.

---

## Step 4 — Reduce both sides to two lists of IDs

**Three separate top-level actions, added one after another with + New step.** They are siblings, not settings inside one another — 4b and 4c are **not** part of the `List rows` action, and nothing here is nested.

| | Action name | What to pick in the designer |
|---|---|---|
| 4a | `List_policy_rows` | **Microsoft Dataverse** → **List rows** |
| 4b | `Select_known_ids` | **Data Operation** → **Select** |
| 4c | `Select_fabric_ids` | **Data Operation** → **Select** |

**Rename each action to the name in that table.** Step 5 refers to them as `body('Select_known_ids')` and `body('Select_fabric_ids')`, and those expressions break if the actions are left as `Select`, `Select 2`.

> **Only 4a and 4b touch Dataverse. 4c does not.** It reads `variables('policySets')` — the array Step 3 built from Fabric — and reshapes it the same way. The two Selects exist so Step 5 can compare like with like: one list of policy set IDs Dataverse knows about, one list of policy set IDs Fabric actually has.

### 4a. `List_policy_rows` — Dataverse **List rows**

| Field | Value |
|---|---|
| Table name | `Capacity Policies` |
| Row count | `5000` |

⋯ → **Settings** → **Pagination On**, threshold `5000`.

### 4b. `Select_known_ids` — **Data Operation → Select**

| Field | Value |
|---|---|
| From | `body('List_policy_rows')?['value']` |
| Map (**text mode**) | `item()?['ubsppcoe_policysetid']` |

### 4c. `Select_fabric_ids` — **Data Operation → Select**

| Field | Value |
|---|---|
| From | `variables('policySets')` |
| Map (**text mode**) | `item()?['id']` |

**Switch the Map box to text mode on both** — the `T` icon on the right of the Map row. A **Select** shows two boxes, key and value, by default; text mode collapses it to one. In key/value mode these produce arrays of *objects*, and the `contains()` tests in Step 5 then never match — which reads as "no drift at all", the most reassuring possible wrong answer.

---

## Step 5 — Find the differences

Four **Filter array** actions. None of them calls Fabric.

### 5a. `Filter_untracked`

| Field | Value |
|---|---|
| From | `variables('policySets')` |
| Condition (advanced) | `@not(contains(body('Select_known_ids'), item()?['id']))` |

**This is the only set that needs a `GET`**, and only to learn its capacity.

### 5b. `Filter_missing`

| Field | Value |
|---|---|
| From | `body('List_policy_rows')?['value']` |
| Condition (advanced) | `@not(contains(body('Select_fabric_ids'), item()?['ubsppcoe_policysetid']))` |

### 5c. `Filter_inactive`

| Field | Value |
|---|---|
| From | `variables('policySets')` |
| Condition (advanced) | `@and(contains(body('Select_known_ids'), item()?['id']), not(equals(item()?['properties']?['status'], 'Active')))` |

Status comes straight from the list response — no extra call.

### 5d. `Filter_capacity_scoped`

| Field | Value |
|---|---|
| From | `variables('policySets')` |
| Condition (advanced) | `@equals(item()?['properties']?['scope']?['type'], 'Capacity')` |

Used by the conflict check in Step 7.

---

## Step 6 — Resolve the untracked ones

**+ New step** → **Apply to each** over `@body('Filter_untracked')`. Rename it `For_each_untracked`.

Set its ⋯ → **Settings** → **Concurrency Control On, Degree of Parallelism 1**. These calls are rare, and serialising them keeps the flow well under the API's rate limits when a tenant has drifted badly.

Inside:

### 6a. `Get_untracked_set` — **Invoke an HTTP request**

| Field | Value |
|---|---|
| Method | `GET` |
| URL of the request | `https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{items('For_each_untracked')?['id']}` |
| Header `Accept` | `application/json` |

Same headers as 3a. **Neither `GET` strictly needs one** — Fabric returns JSON regardless — but keeping the two identical means a difference between them is always a mistake rather than something to puzzle over.

### 6b. `Add_drift_untracked` — Dataverse **Add a new row**

| Field | Value |
|---|---|
| Table name | **`Policy Drift`** (`ubsppcoe_PolicyDrift`) |

Then the columns. **The designer lists them by display name**, which is what the left column below gives; the logical name is beside it so you can confirm you are on the right table — several of these names also exist on `Capacity Policies`.

| Column (as shown) | Logical name | Value |
|---|---|---|
| Kind | `ubsppcoe_driftkind` | `Untracked` |
| Policy set ID | `ubsppcoe_policysetid` | `items('For_each_untracked')?['id']` |
| Capacity ID | `ubsppcoe_capacityid` | `coalesce(body('Get_untracked_set')?['properties']?['scope']?['id'], '')` |
| Display name | `ubsppcoe_displayname` | `items('For_each_untracked')?['displayName']` |
| Detected | `ubsppcoe_detected` | `utcNow()` |
| Details | `ubsppcoe_details` | `concat('Scope ', coalesce(body('Get_untracked_set')?['properties']?['scope']?['type'], 'unknown'), ', status ', coalesce(body('Get_untracked_set')?['properties']?['status'], 'unknown'))` |

> **`ubsppcoe_policysetid` and `ubsppcoe_capacityid` exist on both `Policy Drift` and `Capacity Policies`**, with the same meanings ([CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §2 and §5). Picking the wrong table here writes a malformed capacity row instead of a drift finding. Set **Table name** first and check it before filling anything in.

**Kind is a choice column** — pick `Untracked` from the dropdown rather than typing it. It travels as an integer, not as the label (§1).

`coalesce` on the scope ID because the field can be absent even from a direct `GET` — the PowerShell has the same defence and treats a missing scope as "assume it targets the expected capacity" rather than an error.

---

## Step 7 — Record the rest

Three more **Apply to each** blocks, each with one Dataverse **Add a new row** against **`Policy Drift`** (`ubsppcoe_PolicyDrift`) — the same table and the same six columns as 6b. **None makes a Fabric call, and none needs to.**

> ### Why there is no `GET` here, kind by kind
>
> | Kind | Where its data already is | Why a Fabric call would be wrong |
> |---|---|---|
> | `Missing` | The Dataverse row from `List_policy_rows` — it already carries `ubsppcoe_capacityid` | **The set does not exist in Fabric.** That is the finding. A `GET` would `404` by definition and fail the loop |
> | `Inactive` | `variables('policySets')` — the list response already carries `properties.status` | The status is in hand. A per-set `GET` would re-fetch what Step 3 already read |
> | `Conflict` | `Filter_capacity_scoped`, also from the same list | Same |
>
> **Step 6 is the only place a `GET` is justified**, because an untracked set has no Dataverse row and therefore no capacity ID to report. Everything else was already paged in during Step 3.
>
> This is the cheap-scan property from §0 doing its work: on a healthy tenant the whole flow is **one paged list plus Dataverse reads**, and the Fabric call count scales with the amount of drift, not the size of the estate. Adding a `GET` to this step would quietly convert it into a per-set scan of the entire tenant.

> ### The two loops iterate over different shapes, and that decides every value
>
> This is the thing to get straight before filling anything in:
>
> | Loop | Iterates over | So `items(...)` is | Fields available |
> |---|---|---|---|
> | `For_each_missing` | `body('Filter_missing')` — from **Dataverse** | a `Capacity Policies` **row** | `ubsppcoe_policysetid`, `ubsppcoe_policysetname`, `ubsppcoe_capacityid`, `ubsppcoe_capacityname` |
> | `For_each_inactive` | `body('Filter_inactive')` — from **Fabric** | a **policy set object** | `id`, `displayName`, `properties.status`, `properties.scope` |
>
> Same destination table, two completely different sources. Copying the column values from one loop to the other produces blanks, not errors — `items(...)?['id']` on a Dataverse row is simply null.

**Name each `Apply to each`** as given below. The expressions use `items('For_each_missing')` rather than bare `item()`, which is ambiguous once these sit next to the loop in Step 6.

### 7a. `For_each_missing` — over `body('Filter_missing')`

Inside it, one **Add a new row** named `Add_drift_missing`, Table name **`Policy Drift`**:

| Column | Logical name | Value |
|---|---|---|
| Kind | `ubsppcoe_driftkind` | `Missing` — from the dropdown |
| Policy set ID | `ubsppcoe_policysetid` | `items('For_each_missing')?['ubsppcoe_policysetid']` |
| Capacity ID | `ubsppcoe_capacityid` | `items('For_each_missing')?['ubsppcoe_capacityid']` |
| Display name | `ubsppcoe_displayname` | `coalesce(items('For_each_missing')?['ubsppcoe_policysetname'], items('For_each_missing')?['ubsppcoe_capacityname'], '')` |
| Detected | `ubsppcoe_detected` | `utcNow()` |
| Details | `ubsppcoe_details` | `Policy set recorded in Dataverse no longer exists in the holder workspace.` |

> **The display name comes from our own row, and it has to.** The set is gone from Fabric, so there is no live name to read — `ubsppcoe_policysetname` is the last known one, which is exactly the job that column was given in [CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §3. The `coalesce` falls back to the capacity name because a row written by an older build may not have it.
>
> This is also the **only** kind that arrives with a capacity ID already attached, because it came out of our table rather than Fabric's list.

### 7b. `For_each_inactive` — over `body('Filter_inactive')`

Inside it, one **Add a new row** named `Add_drift_inactive`, Table name **`Policy Drift`**:

| Column | Logical name | Value |
|---|---|---|
| Kind | `ubsppcoe_driftkind` | `Inactive` — from the dropdown |
| Policy set ID | `ubsppcoe_policysetid` | `items('For_each_inactive')?['id']` |
| Capacity ID | `ubsppcoe_capacityid` | `coalesce(items('For_each_inactive')?['properties']?['scope']?['id'], '')` |
| Display name | `ubsppcoe_displayname` | `coalesce(items('For_each_inactive')?['displayName'], '')` |
| Detected | `ubsppcoe_detected` | `utcNow()` |
| Details | `ubsppcoe_details` | `concat('Status is ', coalesce(items('For_each_inactive')?['properties']?['status'], 'unknown'), '. Another policy set may have taken the capacity.')` |

> **Capacity ID is often blank here, and that is accepted.** `properties.scope.id` is frequently absent from the list response (§0), and this flow will not spend a `GET` per set to recover it. The `coalesce` records it when Fabric happens to supply it.
>
> If a populated capacity matters, do **not** add a `GET`. These sets are *tracked*, so the capacity is already sitting in `List_policy_rows` — a `Filter array` inside the loop matching `ubsppcoe_policysetid` against `items('For_each_inactive')?['id']` recovers it with no extra Fabric call. That is the only version of this worth building.

### 7c. `Conflict` — three plain actions, **no `Apply to each`**

7a and 7b loop because they emit **one drift row per item**. 7c emits **one row for the whole finding**, however many sets are involved — so there is nothing to iterate and no loop to add.

| | Action name | What to pick in the designer | Where it goes |
|---|---|---|---|
| i | `Select_scope_ids` | **Data Operation** → **Select** | Top level, after 7b |
| ii | `Condition_has_conflict` | **Control** → **Condition** | Top level, after i |
| iii | `Add_drift_conflict` | **Microsoft Dataverse** → **Add a new row** | **Inside the *Yes* branch** of ii |

Group `Filter_capacity_scoped` by scope ID. Power Automate has no group-by, so the trick is to select the scope IDs and see whether deduping shortens the list.

**i. `Select_scope_ids`** — From `body('Filter_capacity_scoped')`, Map in **text mode**: `coalesce(item()?['properties']?['scope']?['id'], '')`

**ii. `Condition_has_conflict`** — one row in the ordinary two-box editor. **Both sides are expressions**, entered from the ƒx tab:

| Left (expression) | Operator | Right (expression) |
|---|---|---|
| `length(body('Select_scope_ids'))` | **is not equal to** | `length(union(body('Select_scope_ids'), body('Select_scope_ids')))` |

> **The new designer removed *Edit in advanced mode* from the `Condition` card**, so a single `@not(equals(...))` expression cannot be pasted in. Comparing the two lengths directly says the same thing and fits the basic editor natively — it is the better formulation regardless.
>
> `Filter array` **has** kept advanced mode, which is why the conditions in Step 5 are still written as one expression.
>
> **Avoid conditions that compare a boolean to `true` here.** A left side returning a real boolean against a right side typed as the text `true` is the classic silent mismatch. Comparing two integers, as above, has no such trap.

`union` with itself dedupes, so a shorter result means two sets claim the same capacity. **Leave the *No* branch completely empty** — no conflict is the normal case and needs no row.

**iii. `Add_drift_conflict`** — in the **Yes** branch only. Table name **`Policy Drift`**:

| Column | Logical name | Value |
|---|---|---|
| Kind | `ubsppcoe_driftkind` | `Conflict` — from the dropdown |
| Policy set ID | `ubsppcoe_policysetid` | *(leave empty — a conflict is about a capacity, not one set)* |
| Capacity ID | `ubsppcoe_capacityid` | *(leave empty — see below)* |
| Display name | `ubsppcoe_displayname` | `Multiple policy sets scoped to one capacity` |
| Detected | `ubsppcoe_detected` | `utcNow()` |
| Details | `ubsppcoe_details` | `concat('Capacity-scoped sets: ', string(length(body('Select_scope_ids'))), ', distinct capacities: ', string(length(union(body('Select_scope_ids'), body('Select_scope_ids')))), '. Scope IDs: ', join(body('Select_scope_ids'), ', '))` |

**One row, not one per set** — a conflict is a fact about a capacity, not about each set involved. `Capacity ID` is left empty for the same reason: the finding may span more than one, and the IDs are all in `Details`.

> Scope IDs are often blank in the list response, which would make several sets look like duplicates of `''`. Filter those out before comparing, or accept that `Conflict` is a hint that warrants a manual look rather than a precise finding. Given how rare it should be, the hint is enough.

---

## Step 8 — Optional: refresh `status`

The list response carries `properties.status` for every tracked set, so the table's `status` column can be refreshed with no extra Fabric calls.

Do **not** update all 250 rows every run. Filter to the ones whose status differs, then update only those:

- `Filter_status_changed` — From `body('List_policy_rows')?['value']`, condition compares the row's `ubsppcoe_status` against the matching set's status from `variables('policySets')`.

Matching by ID inside a filter expression is awkward in Power Automate. If it turns fiddly, skip this step: `Policy Drift` already reports the `Inactive` case, which is the only status change that matters.

---

## Step 9 — Optional: record that the scan ran

**Build this only if the app shows a drift screen.** It is not needed for the flow to work, and it costs a small table. Decide with the problem in front of you:

> ### The problem it solves
>
> Step 2b deletes before it writes, so **an empty `Policy Drift` table has two very different meanings**: a clean scan found nothing, or a scan died after the delete and before writing. They look identical.
>
> The first is the good news everyone wants. The second means the estate has not been checked at all, and the screen is quietly saying it has.

There are two honest ways to resolve that. **Pick one.**

### Option A — do not build it, and alert on failure instead *(recommended to start)*

Add nothing here. Instead, on the flow's ⋯ → **Settings**, or via a `Send an email` in a parallel branch configured to run **has failed**, notify someone when a run fails — the same treatment [RebuildAllCapacityPolicies](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) already uses for its failures.

Then a failed scan is known by mail rather than by absence, and the drift screen can be labelled *"findings from the last successful scan"* without claiming to be current.

**Cost:** the screen cannot show *when* that scan was. Acceptable while this is a daily job somebody watches; less so once it is forgotten infrastructure.

### Option B — a one-row state table

Create a small table alongside the four in [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md):

| | |
|---|---|
| Schema name | `ubsppcoe_ScanState` |
| Primary name column | `ubsppcoe_scanname` — Text (100) |
| Column | `ubsppcoe_lastrun` — Date and time |

**Seed exactly one row by hand**, with `ubsppcoe_scanname` = `CapacityPolicyDrift`.

Then two actions at the very end of the flow:

1. `Get_scan_state` — Dataverse **List rows** on `ubsppcoe_ScanState`, Filter rows `ubsppcoe_scanname eq 'CapacityPolicyDrift'`, Row count `1`.
2. `Stamp_last_run` — Dataverse **Update a row** on `ubsppcoe_ScanState`, Row ID `first(body('Get_scan_state')?['value'])?['ubsppcoe_scanstateid']`, setting `ubsppcoe_lastrun` = `utcNow()`.

**Look the row up rather than hard-coding its GUID** — the row is created by hand per environment, so a literal ID works in dev and silently fails everywhere else.

> **The timestamp only means anything next to the table.** If the app shows drift rows without it, Option B has bought nothing — the whole point is that *empty plus a fresh timestamp* reads differently from *empty plus a stale one*.

> **Do not use an environment variable for this.** A flow can update one through the Dataverse connector, but environment variable **values** do not travel reliably with a solution export ([OPEN-ISSUES.md](docs/OPEN-ISSUES.md) §8.1) — so the thing recording whether the scan is healthy becomes the thing that breaks on every deployment.

---

## What this flow returns

**Nothing, and it must stay that way.** The Recurrence trigger has no caller waiting, so there is no `Respond to a Power App or flow` action — adding one would fail at runtime with nothing to answer.

The last action is therefore either `Add_drift_conflict` (Step 7c), the optional status refresh (Step 8), or `Stamp_last_run` if you built Option B above. The output of a run *is* the contents of `Policy Drift`.

If the app needs the four counts on a screen, it reads them from the table, not from this flow.

> The **"Scan now"** variant in Step 1 is the exception: a Power Apps (V2) trigger does need a `Respond to a Power App or flow` as its last action. Return four **Text** outputs — `untracked`, `missing`, `inactive`, `conflict` — each `string(length(body('Filter_...')))`. Every field Text, per the trap in [FLOWS.md](docs/FLOWS.md) §4.

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 0 | **Nothing built yet — no policy sets anywhere** | A clean run, zero drift rows, zero Fabric writes. See the warning below before reading anything into it |
| 1 | Healthy tenant | Zero drift rows, and **zero** calls to `Get_untracked_set` in the run history. That is the cheap-scan property working |
| 2 | Create a policy set by hand in the holder workspace | One `Untracked` row, with the capacity resolved |
| 3 | Delete a tracked policy set in the portal | One `Missing` row |
| 4 | Create and activate a replacement on a capacity that already has one | `Inactive` on the old set **and** `Untracked` on the new one — the signature to recognise |
| 5 | Run twice in a row | Same rows, not doubled |
| 6 | More than one page of policy sets | Every set appears. Hard to force at fewer than a few hundred; if you cannot, the loop rests on the same pattern used elsewhere in this repo |

> ### A clean run on an empty estate proves less than it looks
>
> Before any policy set exists, **test 0 and test 1 are indistinguishable — and so is a wrong `ubsppcoe_PolicyHolderWorkspaceId`.** A workspace that exists but is not the holder returns an empty list and a perfectly green run.
>
> So a first clean run tells you the connection authenticates and Dataverse is reachable. It does **not** tell you that you are pointed at the right workspace. **Test 2 is what proves that** — create one policy set by hand in the workspace you believe is the holder and confirm it comes back as `Untracked`. Do that before trusting any later "no drift" result.
>
> Check the run history for `List_page` returning **200 with an empty `value`**, not a `401`, `403` or `404`. Those three mean the identity cannot see the workspace, which is a different problem with the same visible outcome: no drift rows.

Test 1 is the one to check deliberately. If `Get_untracked_set` runs at all on a healthy tenant, the ID matching in Step 5a is broken — most likely because a Select was left in key/value mode and is producing objects instead of strings.
