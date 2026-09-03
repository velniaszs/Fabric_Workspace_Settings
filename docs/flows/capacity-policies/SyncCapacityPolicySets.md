# Flow — `SyncCapacityPolicySets`

Scans the holder workspace, reconciles what Fabric actually holds against the `Capacity Policies` table, and records the differences. Detects policy sets created, replaced or deleted outside the flows.

> **Not built yet.** Specification, not a description of something that exists.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md), [GetPolicyToken.md](docs/flows/capacity-policies/GetPolicyToken.md), [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md).

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

- Build [GetPolicyToken.md](docs/flows/capacity-policies/GetPolicyToken.md) first.
- Needs a **Dataverse connection**.
- Substitute your publisher prefix for `crbab_`, and pick tables and columns from the dropdowns rather than typing them.

### A fourth table — `Policy Drift`

| Column | Logical name | Type |
|---|---|---|
| Kind | `crbab_driftkind` | Choice — `Untracked`, `Missing`, `Inactive`, `Conflict` |
| Policy set ID | `crbab_policysetid` | Text |
| Capacity ID | `crbab_capacityid` | Text — blank until resolved |
| Display name | `crbab_displayname` | Text (primary) |
| Detected | `crbab_detected` | Date and time |
| Details | `crbab_details` | Multiline text |

Findings are rewritten each run, so this table is a **current state**, not a log. If an audit trail is wanted, add a second table and append instead — but do not make one table try to be both.

> **This flow is the only writer, and that follows from the wipe.** Step 8 deletes every row before writing new ones, so anything another flow contributed would disappear at the next scan without warning. [RebuildAllCapacityPolicies](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) reports its failures by mail and through `last_error` on each capacity row for exactly this reason.

---

## Step 1 — Create the flow

**Solutions** → **New** → **Automation** → **Cloud flow** → **Scheduled**. Name it `SyncCapacityPolicySets`. Recurrence: once daily, outside business hours.

> **If you want a "Scan now" button in the app instead**, use a **Power Apps (V2)** trigger with no inputs and add a `Respond to a Power App or flow` at the end returning the four counts. The body is identical. In steady state it returns well inside the 120-second budget; on a badly drifted tenant it will not, which is the argument for the schedule doing the work and the app reading `Policy Drift`.

Then ⋯ → **Settings** → **Concurrency Control** → **On**, **Degree of Parallelism = 1**. Two overlapping scans would both rewrite the drift table.

---

## Step 2 — Token and variables

1. **Run a Child Flow** → `GetPolicyToken`, left named `Run_a_Child_Flow`.
2. `Initialize_variable` — `accessToken`, String, `body('Run_a_Child_Flow')?['access_token']`.
3. `Initialize_policySets` — `policySets`, Array, empty.
4. `Initialize_nextUri` — `nextUri`, String:

```
@{concat('https://api.fabric.microsoft.com/v1/workspaces/', parameters('PolicyHolderWorkspaceId (ab_PolicyHolderWorkspaceId)'), '/policySets?recursive=true')}
```

5. `Initialize_isDone` — `isDone`, Boolean, `false`.

Seeding `nextUri` with the first page URL keeps the loop body uniform — one HTTP action serves the first page and every continuation.

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

### 3a. `List_page` — HTTP

| Field | Value |
|---|---|
| Method | `GET` |
| URI | `@{variables('nextUri')}` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
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

## Step 4 — Read what Dataverse thinks

### 4a. `List_policy_rows` — Dataverse **List rows**

| Field | Value |
|---|---|
| Table name | `Capacity Policies` |
| Row count | `5000` |

⋯ → **Settings** → **Pagination On**, threshold `5000`.

### 4b. `Select_known_ids` — Select

| Field | Value |
|---|---|
| From | `body('List_policy_rows')?['value']` |
| Map (**text mode**) | `item()?['crbab_policysetid']` |

### 4c. `Select_fabric_ids` — Select

| Field | Value |
|---|---|
| From | `variables('policySets')` |
| Map (**text mode**) | `item()?['id']` |

Text mode on both. In key/value mode these produce arrays of objects, and `contains()` in Step 5 then never matches.

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
| Condition (advanced) | `@not(contains(body('Select_fabric_ids'), item()?['crbab_policysetid']))` |

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

### 6a. `Get_untracked_set` — HTTP

| Field | Value |
|---|---|
| Method | `GET` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ab_PolicyHolderWorkspaceId)')}/policySets/@{items('For_each_untracked')?['id']}` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |

### 6b. `Add_drift_untracked` — Dataverse **Add a new row**

| Column | Value |
|---|---|
| Kind | `Untracked` |
| Policy set ID | `items('For_each_untracked')?['id']` |
| Capacity ID | `coalesce(body('Get_untracked_set')?['properties']?['scope']?['id'], '')` |
| Display name | `items('For_each_untracked')?['displayName']` |
| Detected | `utcNow()` |
| Details | `concat('Scope ', coalesce(body('Get_untracked_set')?['properties']?['scope']?['type'], 'unknown'), ', status ', coalesce(body('Get_untracked_set')?['properties']?['status'], 'unknown'))` |

`coalesce` on the scope ID because the field can be absent even from a direct `GET` — the PowerShell has the same defence and treats a missing scope as "assume it targets the expected capacity" rather than an error.

---

## Step 7 — Record the rest

Three more **Apply to each** blocks, each adding rows to `Policy Drift`. None makes a Fabric call.

| Loop over | Kind | Capacity ID | Details |
|---|---|---|---|
| `body('Filter_missing')` | `Missing` | the row's `crbab_capacityid` | `Policy set recorded in Dataverse no longer exists in the holder workspace.` |
| `body('Filter_inactive')` | `Inactive` | blank | `concat('Status is ', coalesce(item()?['properties']?['status'], 'unknown'), '. Another policy set may have taken the capacity.')` |

For `Conflict`, group `Filter_capacity_scoped` by scope ID. Power Automate has no group-by, so use a Select of scope IDs and check for duplicates:

- `Select_scope_ids` — From `body('Filter_capacity_scoped')`, map (text mode) `coalesce(item()?['properties']?['scope']?['id'], '')`
- **Condition:** `@not(equals(length(body('Select_scope_ids')), length(union(body('Select_scope_ids'), body('Select_scope_ids')))))`

`union` with itself dedupes, so a shorter result means duplicates exist. On **Yes**, add a single `Conflict` row listing the duplicated IDs rather than one row per set — a conflict is a fact about a capacity, not about each set involved.

> Scope IDs are often blank in the list response, which would make several sets look like duplicates of `''`. Filter those out before comparing, or accept that `Conflict` is a hint that warrants a manual look rather than a precise finding. Given how rare it should be, the hint is enough.

---

## Step 8 — Clear the previous run first

Findings are current state, so stale rows must go **before** new ones are written. Put this immediately after Step 2, not at the end:

1. `List_old_drift` — Dataverse **List rows** on `Policy Drift`, row count `5000`, pagination on.
2. **Apply to each** over `body('List_old_drift')?['value']` → Dataverse **Delete a row**, Row ID `items('For_each_old_drift')?['crbab_policydriftid']`.

Deleting first means a failed scan leaves an empty table rather than yesterday's answers wearing today's date. An empty drift table with a stale `last_run` is obviously wrong; stale rows that look current are not.

Record the run time somewhere the app can see — a single-row settings table, or an environment variable updated at the end.

---

## Step 9 — Optional: refresh `status`

The list response carries `properties.status` for every tracked set, so the table's `status` column can be refreshed with no extra Fabric calls.

Do **not** update all 250 rows every run. Filter to the ones whose status differs, then update only those:

- `Filter_status_changed` — From `body('List_policy_rows')?['value']`, condition compares the row's `crbab_status` against the matching set's status from `variables('policySets')`.

Matching by ID inside a filter expression is awkward in Power Automate. If it turns fiddly, skip this step: `Policy Drift` already reports the `Inactive` case, which is the only status change that matters.

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | Healthy tenant | Zero drift rows, and **zero** calls to `Get_untracked_set` in the run history. That is the cheap-scan property working |
| 2 | Create a policy set by hand in the holder workspace | One `Untracked` row, with the capacity resolved |
| 3 | Delete a tracked policy set in the portal | One `Missing` row |
| 4 | Create and activate a replacement on a capacity that already has one | `Inactive` on the old set **and** `Untracked` on the new one — the signature to recognise |
| 5 | Run twice in a row | Same rows, not doubled |
| 6 | More than one page of policy sets | Every set appears. Hard to force at fewer than a few hundred; if you cannot, the loop rests on the same pattern used elsewhere in this repo |

Test 1 is the one to check deliberately. If `Get_untracked_set` runs at all on a healthy tenant, the ID matching in Step 5a is broken — most likely because a Select was left in key/value mode and is producing objects instead of strings.
