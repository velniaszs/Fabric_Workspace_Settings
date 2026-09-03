# Flow — `ListCapacityPolicySets`

What the app reads. Returns every managed capacity and the state of its policy set, as one JSON string.

> **Not built yet.** Specification, not a description of something that exists.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §3 and §4, [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md).

---

## 0. Before you start

- Needs a **Dataverse connection**, for reads only.
- **No Fabric calls, no child flows, no token.** This flow reads one table and formats it. If it grows an `HTTP` action, something has gone wrong — see below.
- Build it after [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md), because two of the columns it returns are written by that flow and will be empty until it has run.

> ### One table, one query, no joins
>
> At **200–300 capacities**, both of the obvious richer implementations blow the **120-second** Power Apps budget:
>
> - **Asking Fabric.** A list call plus a `GET` per policy set to resolve `properties.scope.id`, which the list response frequently omits. Hundreds of round trips.
> - **Counting workspaces here.** `ubsppcoe_Workspace` filtered by Node and `FabricEnabled`, once per capacity. Hundreds of Dataverse queries, for a number the rebuild already computed.
>
> So `workspace_count` and `rule_count` are **stamped on `CapacityPolicy` by the rebuild** and simply read here ([CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §3, Q26). This flow is a table read and a projection. Keep it that way.

---

## Step 1 — Create the flow

**Solutions** → your solution → **New** → **Automation** → **Cloud flow** → **Instant** → name `ListCapacityPolicySets` → trigger **Power Apps (V2)**.

**No inputs.** The app gets everything and filters or sorts client-side; at a few hundred rows that is cheaper than a round trip per filter change.

---

## Step 2 — Variables

| Rename to | Name | Type | Value |
|---|---|---|---|
| `Initialize_errorMessage` | `errorMessage` | String | *(empty)* |

---

## Step 3 — Read the table

`List_policy_rows` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Capacity Policies` |
| Select columns | `crbab_capacityid,crbab_capacityname,crbab_policysetid,crbab_policysetname,crbab_status,crbab_workspacecount,crbab_rulecount,crbab_lastrebuild,crbab_lasterror` |
| Sort by | `crbab_capacityname asc` |
| Row count | `5000` |

⋯ → **Settings** → **Pagination On**, threshold `5000`.

**Fill in `Select columns`.** Left blank, Dataverse returns every column on every row — including audit fields and anything added later — which inflates the payload for no benefit and quietly makes the flow slower every time someone adds a column.

**Sort here, not in the app.** Sorting a parsed JSON table in Power Fx is delegable-nothing and runs on every screen redraw.

> **No filter.** Every row in `Capacity Policies` is a capacity this project manages, so there is nothing to exclude. If the table ever gains rows for capacities that were de-provisioned, filter them here rather than teaching the app to ignore them.

---

## Step 4 — Project the rows

`Select_rows` — **Select**:

| Field | Value |
|---|---|
| From | `body('List_policy_rows')?['value']` |

Map, in **key/value mode** — nine entries:

| Key | Value |
|---|---|
| `capacityId` | `item()?['crbab_capacityid']` |
| `capacityName` | `item()?['crbab_capacityname']` |
| `policySetId` | `item()?['crbab_policysetid']` |
| `policySetName` | `item()?['crbab_policysetname']` |
| `status` | `coalesce(item()?['crbab_status'], 'Unknown')` |
| `workspaceCount` | `string(coalesce(item()?['crbab_workspacecount'], 0))` |
| `ruleCount` | `string(coalesce(item()?['crbab_rulecount'], 0))` |
| `lastRebuild` | `coalesce(item()?['crbab_lastrebuild'], '')` |
| `lastError` | `coalesce(item()?['crbab_lasterror'], '')` |

**`coalesce` on every nullable column.** A `null` inside the JSON is not an error, but Power Fx treats a missing property and a null one differently once parsed, and the app then needs two checks where it should need none.

> **`workspaceCount` and `ruleCount` are `string(...)` deliberately.** They are whole numbers in Dataverse, and this is a display payload — the app formats them, it does not do arithmetic on them. Keeping every field the same type makes the `ParseJSON` schema on the app side trivial and removes a class of type-mismatch error that only appears when one row has a null.
>
> If the app ever needs to sort numerically, do it in Step 3's `Sort by`, not by changing the type here.

### `lastRebuild` is what makes the counts honest

The two counts are **as of the last rebuild**, not live. A `FabricEnabled` change made this morning is not reflected until that capacity is next rebuilt.

**The app must show `lastRebuild` next to them.** A count with no timestamp beside it will be read as current, and the first time someone acts on a number that is eighteen hours stale, this flow gets blamed for a cache that is working as designed.

---

## Step 5 — Compose the payload

`Compose_json` — **Compose**:

```
@{string(body('Select_rows'))}
```

`string()` of the array, not the array itself. The Respond field is Text; handing it an array makes Power Automate coerce it, and what arrives app-side is not reliably parseable.

---

## Step 6 — Respond

**Respond to a Power App or flow**, ⋯ → **Configure run after** on `Compose_json` with **is successful** and **has failed** ticked. Two **Text** outputs:

| Output | Value |
|---|---|
| `PolicySetsJson` | `coalesce(outputs('Compose_json'), '[]')` |
| `ErrorMessage` | `variables('errorMessage')` |

**`'[]'` on failure, not blank.** An empty string throws in `ParseJSON`; an empty array parses to zero rows and the app shows an empty list with whatever `ErrorMessage` says. One of those is a screen the user can read.

Both outputs **Text**. A field typed Number or Boolean fails schema validation at runtime and makes *every* output unreadable to the app, not just the bad one — the trap that cost two flows a field each in [FLOWS.md](docs/FLOWS.md) §4.

### Setting `errorMessage`

Add a **Scope** around Steps 3–5 if you want a clean failure path: on `has failed`, set `errorMessage` to something the user can act on and let `PolicySetsJson` fall through to `'[]'`. Without it, a Dataverse outage returns an empty list that looks exactly like a healthy tenant with no capacities.

That distinction matters more here than in most flows, because **empty is a plausible real answer** on day one.

---

## What the app does with it

`ParseJSON` the string, then bind. Every field is text, so the schema is nine strings and nothing else.

| Column | Show it as |
|---|---|
| `status` | The activation state. `Inactive` with a blank `lastError` means activation was never attempted |
| `lastError` | Non-blank is the only unhealthy signal in the payload. Make it visible without a click |
| `workspaceCount` / `ruleCount` | Always beside `lastRebuild` |
| `policySetName` | Useful when someone is looking at the same set in the Fabric portal |

> **A row with a blank `policySetId` should not exist.** Flow 1 writes the row and the id together. If one appears, the row was created by hand or a run failed between the two, and the capacity is unmanaged despite having a record — worth surfacing rather than rendering as a normal entry.

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | Run with several capacities registered | One JSON array, one object per row, sorted by name |
| 2 | Peek code on `Compose_json` | A **string**, not an array. This is the one that silently breaks the app |
| 3 | A capacity that has never been rebuilt | `workspaceCount` and `ruleCount` are `"0"`, not null or missing |
| 4 | A capacity whose last rebuild failed | `lastError` populated, and the row still present |
| 5 | Empty `Capacity Policies` table | `PolicySetsJson` = `[]`, `ErrorMessage` blank. **Not** an error |
| 6 | Break the Dataverse connection | `PolicySetsJson` = `[]` and `ErrorMessage` populated — distinguishable from test 5 |
| 7 | Time a run at production row count | Comfortably inside 120 seconds. If it is not, something has been added that queries per row |
| 8 | Inspect the run's action list | **No `HTTP` action, no child flow, no second `List rows`** |

Tests 5 and 6 are the pair worth writing together: they are the same screen with opposite meanings, and only `ErrorMessage` separates them.

> Testing from the designer reports **`ActionResponseSkipped`** on the Respond action — expected, since nothing is waiting for the response. Read the payload from the action's inputs in the run history.
