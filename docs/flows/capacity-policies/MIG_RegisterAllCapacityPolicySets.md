# Flow — `MIG_RegisterAllCapacityPolicySets`

**Migration only.** The loop. Walks every eligible Fabric capacity, creates and registers a policy set for each, and leaves them all **deactivated**. Run by hand, once, in tranches.

> **Not built yet.** Specification, not a description of something that exists.

Related: [MIG_InitializeCapacityPolicySet.md](docs/flows/capacity-policies/MIG_InitializeCapacityPolicySet.md) (the child it calls), [MIG_ActivateAllCapacityPolicySets.md](docs/flows/capacity-policies/MIG_ActivateAllCapacityPolicySets.md), [RebuildAllCapacityPolicies.md](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) (the same shape, and migration's rebuild phase), [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §8.

---

## 0. Where this sits in cutover

```
1  MIG_RegisterAllCapacityPolicySets   ← this flow. Estate registered, all Inactive
2  Seed Policy Exceptions              ← human. Must precede any rebuild
3  RebuildAllCapacityPolicies          ← rules built, still nothing enforced
4  MIG_ActivateAllCapacityPolicySets   ← deny-all goes live
```

**Nothing this flow does is enforced.** It creates policy sets with no rules and leaves them deactivated, so a run that half-finishes, or finishes wrong, changes no one's access. That is deliberate, and it is what replaces the `-WhatIf` the PowerShell path had.

> ### Why the source list is Fabric, not Dataverse
>
> The obvious alternative is to loop `ubsppcoe_Node` rows. Don't.
>
> `ubsppcoe_Node` is the platform team's inventory and is not guaranteed to be pruned when a capacity is deleted, so it contains rows for capacities that no longer exist. Iterating it, you discover that one skip at a time and learn nothing you can act on.
>
> Iterating **live capacities** inverts the reporting. You get an explicit list of capacities with **no Node row** — which is the actionable gap, because those are the ones that will fail every rebuild forever until the platform team adds a row. That list is this flow's most valuable output; see §4.

---

## 1. Before you start

- Build [MIG_InitializeCapacityPolicySet](docs/flows/capacity-policies/MIG_InitializeCapacityPolicySet.md) first and run its test 7. This flow is a loop around it.
- Needs the *HTTP with Microsoft Entra ID (preauthorized)* connector for one `GET`. **No Dataverse connection** — every table read and write happens inside the child.
- **Check for duplicate capacity display names before the first run.** Two capacities with the same name produce one policy set name and the second create fails. See [MIG_InitializeCapacityPolicySet.md](docs/flows/capacity-policies/MIG_InitializeCapacityPolicySet.md) Step 5.
- Easiest build path: **copy `RebuildAllCapacityPolicies`** and make two substitutions.

| | `RebuildAllCapacityPolicies` | This flow |
|---|---|---|
| Trigger | Recurrence | **Manually trigger a flow** |
| Source list | `List_policy_rows` — Dataverse | `Get_capacities` — `GET /v1/capacities` |
| Child flow | `RebuildCapacityPolicyRules` | `MIG_InitializeCapacityPolicySet` |
| Outcome buckets | failures | failures **and** `AlreadyExists` |

Everything else transfers unchanged: Degree of Parallelism 1, the arrays declared at the top level, the condition after the child call, the summary at the end.

---

## Step 1 — Create the flow

**Solutions** → **New** → **Automation** → **Cloud flow** → **Instant** → name `MIG_RegisterAllCapacityPolicySets` → trigger **Manually trigger a flow**.

**No inputs.**

> **Manual, not Recurrence.** This is a one-off you supervise. A schedule would eventually re-run it against an estate it has already migrated — harmless, because every capacity would answer `AlreadyExists`, but it would also silently pick up newly-created capacities and register them behind the provisioning app's back.

⋯ → **Settings** → **Concurrency Control On, Degree of Parallelism 1** on the trigger. Two overlapping runs would both see the same unregistered capacities and race to create duplicate policy sets — `AlreadyExists` only protects across runs, not within a race.

---

## Step 2 — Variables

Three `Initialize variable` actions, **at the top level**, before Step 3.

| Rename to | Name | Type | Value |
|---|---|---|---|
| `Initialize_failures` | `failures` | **Array** | *(leave empty)* |
| `Initialize_noNode` | `noNode` | **Array** | *(leave empty)* |
| `Initialize_registered` | `registered` | Integer | `0` |

**They have to be here, not next to the loop.** `Initialize variable` is the one action Power Automate refuses to place inside an `Apply to each`.

> **Three buckets, not one, because the three outcomes need different people.**
>
> | Bucket | Meaning | Who acts |
> |---|---|---|
> | `registered` | Created and registered | Nobody. This is the progress count |
> | `noNode` | Capacity exists in Fabric, no `ubsppcoe_Node` row | **The platform team.** This list is the deliverable |
> | `failures` | Anything else — a create rejected, a duplicate name, a timeout | You, before re-running |
>
> Collapsing `noNode` into `failures` is the easy mistake. It buries the one finding that needs a conversation with another team inside a list of things you can fix yourself, and on an estate with a stale inventory it may be the larger list.
>
> `AlreadyExists` is counted nowhere on purpose — on a re-run it is the majority outcome and listing it drowns everything else. `registered` going up by less than the tranche size is the signal, and the Dataverse table is the record.

---

## Step 3 — The capacities

### 3a. `Get_capacities` — **Invoke an HTTP request**

| Field | Value |
|---|---|
| Method | `GET` |
| URL of the request | `https://api.fabric.microsoft.com/v1/capacities` |
| Header `Accept` | `application/json` |

**No `Authorization` header** — the connector supplies it.

> **This list is scoped to the connection's identity.** A capacity that identity does not administer is simply absent, and this flow will never know it existed. **Check the count against what you expect before proceeding** — if `Filter_eligible` returns 12 and the estate is 200, the identity is wrong and you have found it at the cheapest possible moment. This is **Q45** made concrete.

### 3b. `Filter_eligible` — **Filter array**

| Field | Value |
|---|---|
| From | `body('Get_capacities')?['value']` |
| Condition (advanced) | see below |

```
@and(equals(item()?['state'], 'Active'), equals(substring(concat(toUpper(coalesce(item()?['sku'], '')), 'X'), 0, 1), 'F'))
```

**This is the eligibility check the child no longer does.** Doing it once here, over a list already in memory, replaces one full capacity-list `GET` per capacity.

The SKU test takes the first character and compares two strings rather than using `startsWith`, which returns a boolean and is the classic silent mismatch in this editor. `concat(..., 'X')` guarantees at least one character, because `substring('', 0, 1)` throws on a capacity with a missing `sku`.

> **P, A, EM and PP SKUs are a normal thing to encounter, not an error.** Only Fabric capacities can hold a policy set. They are filtered out here and never counted anywhere — deliberately, because a list of 40 Power BI capacities reported every run is how people learn to ignore the report.

### 3c. `Compose_eligible_count` — **Compose**

```
@{length(body('Filter_eligible'))}
```

Not used by anything downstream. It exists so the run history answers "how many did this run actually consider?" without expanding a 200-element array — which is the first question asked when a tranche looks wrong.

---

## Step 4 — The loop

**Apply to each** over `@body('Filter_eligible')`, renamed `For_each_capacity`.

⋯ → **Settings** → **Concurrency Control On, Degree of Parallelism 1**.

> **Serial, and here it genuinely matters.** Each iteration is a policy set create — a long-running operation — plus two Dataverse round trips. In parallel, 200 of those would hit Fabric hard enough that ordinary throttling becomes indistinguishable from real errors, and a `429` storm mid-migration is the worst possible time to be guessing.
>
> Serial, expect **roughly 10 seconds per capacity**, so 200 capacities is 30–40 minutes. That is fine for a manual flow with no `Respond`. Do not raise the parallelism to shorten it; there is nothing to gain and a bad run costs far more than half an hour.

### 4a. `Run_initialize` — **Run a Child Flow** → `MIG_InitializeCapacityPolicySet`

Pass, in trigger order:

| # | Value |
|---|---|
| 1 | `items('For_each_capacity')?['id']` |
| 2 | `items('For_each_capacity')?['displayName']` |

**Both come from the Fabric list**, so the display name is authoritative rather than something a caller typed.

### 4b. `Switch_outcome` — **Switch**

⋯ → **Configure run after** on `Run_initialize` with **is successful** and **has failed** ticked, so a hard failure of the child lands here instead of abandoning the other 199.

| Field | Value |
|---|---|
| On | `coalesce(body('Run_initialize')?['outcome'], 'Failed')` |

Four branches plus the default:

| Case | Contents |
|---|---|
| `Registered` | `Increment_registered` — **Increment variable** `registered` by `1` |
| `AlreadyExists` | *(empty)* |
| `NoNode` | `Append_no_node` — **Append to array variable** `noNode` |
| `Failed` | `Append_failure` — **Append to array variable** `failures` |
| **Default** | `Append_failure_unknown` — append to `failures`. Catches a child that returned nothing at all |

`Append_no_node`:

```
@{concat(items('For_each_capacity')?['displayName'], ' (', items('For_each_capacity')?['id'], ')')}
```

`Append_failure` and `Append_failure_unknown`:

```
@{concat(items('For_each_capacity')?['displayName'], ' (', items('For_each_capacity')?['id'], '): ', coalesce(body('Run_initialize')?['message'], 'child flow returned no message'))}
```

> **The child emits `NoNode` as a distinct outcome so this Switch can branch on it directly.** An earlier draft matched on the message text with `contains(…, 'No Node row')`, which works and is fragile — an edit to the wording silently reclassifies every capacity in that state. One extra Switch case removes the coupling.
>
> **The Default case is not decoration.** `Run_initialize` is configured to run after **has failed**, so a child that died without responding lands here with a null body. Without a Default, that capacity is counted nowhere and the run reports a clean sweep it did not achieve.

---

## Step 5 — Report

After the loop, at the top level.

### 5a. `Compose_summary` — **Compose**

```
@{concat(
  'Registered: ', string(variables('registered')),
  ' of ', string(length(body('Filter_eligible'))), ' eligible capacities.',
  '\nNo Node row: ', string(length(variables('noNode'))),
  '\nFailed: ', string(length(variables('failures')))
)}
```

### 5b. `Condition_anything_to_report` — **Condition**

| Left (expression) | Operator | Right |
|---|---|---|
| `add(length(variables('failures')), length(variables('noNode')))` | is greater than | `0` |

**Yes** → send a mail or post to Teams with `outputs('Compose_summary')`, then the two lists under their own headings. **Keep them under separate headings** — one goes to the platform team, the other does not.

**No** → empty. But unlike the nightly job, **do read the summary from the run history either way.** This is a supervised one-off, and "registered 187 of 200 with nothing to report" is a contradiction worth noticing.

> **Do not write any of this to `Policy Drift`.** [SyncCapacityPolicySets](docs/flows/capacity-policies/SyncCapacityPolicySets.md) deletes every row in that table at the start of each scan, so anything written here would vanish at an interval nobody is thinking about. The same reasoning as [RebuildAllCapacityPolicies.md](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) §4.

---

## Running it

**In tranches, not all at once.**

There is no batching control in the flow, so the tranche is you: run it, and **cancel it from the run history** once enough capacities have gone through. `AlreadyExists` makes the next run resume where it left off, and the ordering is stable because `GET /v1/capacities` returns a consistent list.

| Tranche | Then |
|---|---|
| First 5 | Stop. Check all five in the portal: no rules, not activated. Check five Dataverse rows: `Node` populated, `Status` = `Inactive` |
| Next ~40 | Stop. Check the `noNode` list is plausible rather than "everything" |
| The rest | Let it run |

**The first tranche is where a systematic error shows up** — a wrong holder workspace, a bad name prefix, an un-deleted Step 8c activating everything. Five capacities is cheap to unpick; 200 is not.

**Nothing here is enforced**, so even a wholly wrong run is recoverable by deleting the policy sets and the `Capacity Policies` rows. That stops being true after [MIG_ActivateAllCapacityPolicySets](docs/flows/capacity-policies/MIG_ActivateAllCapacityPolicySets.md).

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | Run with the loop's **Degree of Parallelism 1** and cancel after 2 iterations | Two policy sets, two rows, both `Inactive`. Nothing else touched |
| 2 | Compare `Compose_eligible_count` against the estate you expect | Equal. **A short list means the connection identity, not the data** — see §3a |
| 3 | Run again immediately | `registered` = `0`, no new policy sets, no failures |
| 4 | A capacity you know has no Node row | Appears in `noNode`, **not** in `failures`, and no policy set was created for it |
| 5 | A paused capacity, and a P-SKU capacity | Absent from `Filter_eligible`. Not counted anywhere, not reported |
| 6 | Inspect any policy set created | **No rules and not activated.** If it has rules, the child still has its Step 8b; if it is active, it still has 8c |
| 7 | Full run, then `ListCapacityPolicySets` | Every capacity present, all `Inactive`, all counts empty |

Test 6 is the one to do by eye in the portal on the first tranche. An activated deny-all policy set is the only outcome here that takes access away from someone, and it is a copy-paste error away.

Test 3 proves the run is restartable, which every other paragraph of this document assumes.

---

## After cutover

**Turn this flow off and delete it**, along with the other two `MIG_` flows. New capacities are registered by the provisioning app calling `InitializeCapacityPolicySet`, which is the BAU path and does activate.
