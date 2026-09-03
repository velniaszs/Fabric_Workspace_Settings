# Flow — `RebuildAllCapacityPolicies`

Scheduled. Rebuilds every capacity's rules from Dataverse, on a nightly or weekly cycle. The backstop that makes Dataverse genuinely the source of truth rather than merely the intended one.

> **Not built yet.** Specification, not a description of something that exists.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md), [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md), [SyncCapacityPolicySets.md](docs/flows/capacity-policies/SyncCapacityPolicySets.md).

---

## 0. What this fixes, and what it cannot

Every rule in every managed capacity is regenerated from the tables. Anything an operator changed by hand in the portal is overwritten.

| Drift | Fixed by this flow? |
|---|---|
| Rules edited by hand | **Yes.** Overwritten wholesale |
| A rule deleted by hand | **Yes.** Regenerated |
| Rule 1 removed | **Yes** — and this matters most, because a policy with no rules is unenforced, not empty |
| A flag that a failed `AddWorkspaceToPolicy` or `RemoveWorkspaceFromPolicy` never applied | **Yes.** Converges Fabric to Dataverse |
| A `FabricEnabled` or `Node` edit made **outside** these flows | **Yes**, and this is now the common case \u2014 `ubsppcoe_Workspace` is owned by another team and nothing triggers a rebuild when they change it |
| A workspace **moved** to a different Node | **Yes**, but only because every capacity is rebuilt. Neither the old nor the new capacity is rebuilt at the time of the move |
| A missing or blank `node` lookup on the policy row | **No.** The rebuild refuses that capacity and reports it — deliberately, see [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) Step 5a |
| Our policy set **deactivated**, another one active | **No** — see §4 |
| Our policy set **deleted** | **No.** The rebuild 404s |
| A policy set created by hand for a capacity we already manage | **No** |

The last three are exactly what [SyncCapacityPolicySets.md](docs/flows/capacity-policies/SyncCapacityPolicySets.md) detects. Run both: this one converges what it can, the scan reports what it cannot.

> **This flow carries more weight than it did.** When the whitelist lived in a table only these flows wrote to, nightly convergence was a safety net. Now it is the **only** thing that applies an out-of-band `FabricEnabled` change. If a same-day guarantee is needed, that is a Dataverse-modified trigger on `ubsppcoe_Workspace`, not a shorter recurrence here — see Q16 in [CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §7.

---

## 1. Before you start

- Build [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) first. This flow is a loop around it.
- Needs a **Dataverse connection**. No direct Fabric calls.

---

## Step 1 — Create the flow

**Solutions** → **New** → **Automation** → **Cloud flow** → **Scheduled**. Name it `RebuildAllCapacityPolicies`.

Recurrence: nightly, outside business hours. Each run processes the **whole estate** — see §5 before considering otherwise.

Nightly rather than weekly, because the interval is the **worst-case delay on a failed removal reaching Fabric** ([RemoveWorkspaceFromPolicy.md](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md) §6).

⋯ → **Settings** → **Concurrency Control On, Degree of Parallelism 1**. A run that overlaps its predecessor would have two loops rebuilding the same capacities.

⋯ → **Settings** → **Concurrency Control On, Degree of Parallelism 1**. A run that overlaps its predecessor would have two loops rebuilding the same capacities.

---

## Step 2 — The capacities to process

`List_policy_rows` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Capacity Policies` |
| Filter rows | `crbab_policysetid ne null` |
| Sort by | `crbab_lastrebuild asc` |
| Row count | `5000` |

Pagination **On**, threshold `5000`. **Process the whole estate every run** — 250 capacities is not a large loop, and the retry policy absorbs throttling by waiting rather than failing.

A row without a `policy_set_id` was never initialised. Skipping it here keeps the run log clean — those belong to `InitializeCapacityPolicySet`, and a nightly job reporting the same 3 known-uninitialised capacities as failures every night is how people learn to ignore the report.

### Why sort by `crbab_lastrebuild` if there is no cap?

Because it costs nothing and makes a truncated run degrade well. If a run is cancelled, hits a quota, or is stopped by hand, the capacities it did not reach are the ones with the **oldest** timestamps — so the next run starts with exactly those. Without the sort, an interrupted run leaves an arbitrary subset stale and the next run may pick the same ones it already did.

Nulls sort first on ascending order, so a capacity that has **never** been rebuilt jumps the queue. That is the behaviour you want, for free.

> **Do not add a row-count cap unless measurement demands it.** An earlier draft of this document capped the batch at 100 for no better reason than caution about an undocumented rate limit. That is premature: it introduces a starvation failure mode that is invisible in the run history — if `crbab_lastrebuild` is not being stamped, the same capacities are rebuilt every night and the rest never are, and everything looks healthy — and it multiplies the worst-case delay on a failed removal by the number of batches. If §5 shows throttling is genuinely severe, capping is the lever; the sort is already in place to make it safe.

---

## Step 3 — The loop

**Apply to each** over `@body('List_policy_rows')?['value']`, renamed `For_each_capacity`.

⋯ → **Settings** → **Concurrency Control On, Degree of Parallelism 1**.

> **Serial, deliberately.** 250 capacities in parallel would hit Fabric's rate limits hard, and a `429` storm makes ordinary throttling look like real errors. Serial, each rebuild is one `replaceByPolicy` call — a few seconds each, so a full run is minutes. Raise the parallelism only if a run genuinely does not finish in its window, and raise it to 4, not 20. See §5.

Inside:

### 3a. `Run_rebuild` — **Run a Child Flow** → `RebuildCapacityPolicyRules`

Pass `items('For_each_capacity')?['crbab_capacityid']`.

Configure this action's **run after** so the loop continues past a failure — leave the default, but wrap what follows so a single bad capacity does not abandon the other 299.

### 3b. `Condition_failed` — **Condition**, run after `Run_rebuild` on **is successful** and **has failed**

| Left | Operator | Right |
|---|---|---|
| `coalesce(body('Run_rebuild')?['outcome'], 'Failed')` | is not equal to | `Rebuilt` |

**Yes** → append a line to a failure collection:

`Append_failure` — **Append to array variable** `failures`:

```
@{concat(items('For_each_capacity')?['crbab_capacityname'], ' (', items('For_each_capacity')?['crbab_capacityid'], '): ', coalesce(body('Run_rebuild')?['message'], 'child flow failed'))}
```

Declare `failures` as an empty Array variable before the loop.

The child flow already stamps `last_rebuild` and `last_error` on each row, so per-capacity detail is queryable without reading run history. The array exists only for the summary in Step 4.

---

## Step 4 — Report

After the loop, a **Condition** on `@greater(length(variables('failures')), 0)`.

**Yes** → send a mail or post to Teams — whatever your operational routing is. Include the count and the lines.

> **Do not write these to `Policy Drift`.** An earlier draft of this document suggested it; that was a mistake, for three reasons.
>
> **The rows would vanish.** [SyncCapacityPolicySets](docs/flows/capacity-policies/SyncCapacityPolicySets.md) deletes every row in that table at the start of each scan, because its findings are current state rather than a log. Anything this flow wrote would silently disappear on the next run, at an interval nobody is thinking about.
>
> **`Missing` means something else.** In the drift table it means *a policy set recorded in Dataverse no longer exists in Fabric*. "The rebuild failed for this capacity" is a different fact with a different remedy, and overloading the kind would make the scan's own output untrustworthy.
>
> **One table, one writer.** Two flows writing a table that one of them wipes wholesale is a race with no upside.
>
> Per-capacity detail is already recorded where it belongs: `last_error` and `last_rebuild` on the capacity's own `Capacity Policies` row, stamped by the child flow on every attempt. That is queryable, survives the scan, and is what [ListCapacityPolicySets](docs/flows/capacity-policies/ListCapacityPolicySets.md) surfaces. This step only needs to raise a human's attention to the summary.

**Do not send anything on a clean run.** A nightly "all fine" mail is unread within a fortnight, and its absence then means nothing. Report exceptions; use `last_rebuild` on the table to prove the run happened.

> A capacity whose policy set was **deleted** in the portal appears here every night, because the rebuild will keep 404ing. That is correct — it is a real problem needing a human to re-run `InitializeCapacityPolicySet` — but it will also be the noisiest failure. Fix those promptly rather than letting them train people to ignore the report.

---

## 5. Will it time out?

Three separate limits, and only one of them is a real risk.

| Limit | Applies here? |
|---|---|
| **120-second response budget** | **No.** That applies to flows answering a caller synchronously — Power Apps or HTTP request-response. A Recurrence-triggered flow has no such budget |
| **Flow run duration** | **No.** A cloud flow run may last up to 30 days. 250 serial rebuilds at a few seconds each is minutes, not hours |
| **`Run a Child Flow` waiting on `Respond`** | **Only per call.** Each child invocation must answer within the request-response timeout of roughly 120 seconds. One capacity's rebuild is a handful of Dataverse reads and a single POST, so this is never close — but it is why the child flow must not grow a polling loop |
| **`Apply to each` item cap** | **No.** The cap is far above a few hundred |
| **Throttling — `429`** | **Yes. This is the one.** |

### Throttling is the real constraint

The Policy Rules operations do not document a per-minute limit the way the Admin operations do (10/minute), but that is absence of documentation, not absence of a limit. The stronger evidence is in the PowerShell: `migrate_policy_sets.ps1` carries an `Invoke-WithRetry` wrapper that retries **only** on `429`, honours `Retry-After`, and counts throttle events across a run. Nobody writes that speculatively.

A nightly job doing 250 `replaceByPolicy` calls back to back is exactly the shape that triggers it.

Three defences, in order of how much they buy:

**Leave the retry policy at Default.** It retries `408`, `429` and `5xx` — 4 attempts, exponential backoff — with no configuration. Expected to be enough on its own: a throttled run takes longer, and a scheduled flow has the time. The only mistake here is setting it to **None**.

**Add a Delay if throttling proves heavy.** A `Delay` of 1–2 seconds at the end of each loop iteration caps the request rate. It is preventive where retries are reactive, and it never leaves a capacity unprocessed. Check the run history for retry counts first — an unnecessary delay across 250 iterations buys minutes of runtime for nothing.

**Cap the batch — last resort.** Set the Step 2 row count to a fixed number and let the oldest-first sort spread the estate over several runs. It bounds the run time, but at a real cost:

| Cost | Why it matters |
|---|---|
| Starvation is invisible | If the child flow stops stamping `crbab_lastrebuild`, the same capacities are rebuilt every run and the rest never are. The run history looks perfectly healthy throughout |
| Slower convergence | The worst-case delay for a failed `RemoveWorkspaceFromPolicy` to reach Fabric becomes *number of batches × interval*. At 100 per night on 250 capacities, up to three days |

If withdrawal of access is ever security-driven, do not cap. Give the app a "rebuild now" button that calls `RebuildCapacityPolicyRules` directly for one capacity instead — the child flow already does exactly that, so it is a button, not a feature.

None of this is worth building before test 7 below shows it is needed.

### `Run a Child Flow` is not retried

The retry policy protects the HTTP call **inside** the child. It does nothing for this loop: if a capacity's rebuild exhausts its retries, `Run_rebuild` returns a failure and Step 3b records it.

That is the intended behaviour, not an omission. The capacity keeps its old `crbab_lastrebuild`, so the oldest-first sort puts it near the front of tomorrow's run, and the failure appears in tonight's report. Wrapping the loop body in a Do-until retry would re-enter a rebuild the service has already throttled — pushing on a door it just held shut, and turning a visible failure into a longer, quieter one.

### Action quotas

Every action counts against a per-24-hour request quota that depends on the licence tier. The rebuild is roughly 20 actions per capacity plus a handful in the loop, so 250 capacities is around 5,000–6,000 actions per run — comfortably clear of any tier, even with the drift scan running the same night. Worth confirming against your own licence rather than assuming, but this is not the constraint.

Dataverse service-protection limits are not a concern at this volume either — a few hundred reads spread across a run of several minutes.

---

## 6. Should this re-activate?

**Not by default.** The decision deserves stating rather than defaulting into.

If our policy set has been deactivated and another is active on the capacity, this flow rebuilds rules on a set that is **not in force**. It reports success, and the capacity is governed by something else entirely. That is the `Inactive` + `Untracked` pair `SyncCapacityPolicySets` exists to catch.

The flow *could* call `activate` with `allowReplace=true` and take the capacity back every night. Do not turn that on without deciding it explicitly:

| For | Against |
|---|---|
| The estate converges on the intended policy with no human involvement | It silently overrides a deliberate act by someone with legitimate rights on the capacity |
| Drift cannot persist | A nightly fight between two automations, or between automation and an admin, that nobody observes because both sides "succeed" |

If it is turned on, it must be **loud** — every takeover reported, with the ID of the policy set that was displaced. A silent takeover is indistinguishable from a healthy run, right up until someone asks why their policy set stopped working.

Recommended: leave it off, let the scan report it, and have a human decide per case. Revisit if the report shows the same capacities recurring.

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | Run against 2–3 test capacities | All rebuilt; `last_rebuild` updated on each row |
| 2 | Edit a rule by hand, then run | The manual edit is gone |
| 3 | Delete rule 1 by hand, then run | Rule 1 is back. **The most important test here** |
| 4 | Delete a policy set in the portal, then run | That capacity reports a failure, the others still complete |
| 5 | A row with a blank `policy_set_id` | Skipped silently, not reported as a failure |
| 6 | Clean run | **No notification sent** |
| 7 | Time a full run at production scale, and check the history for `429` retries | Confirms the run fits its window and shows how hard the retry policy is working. This is the measurement that decides whether §5's delay or cap is ever needed |

Test 4 is what proves the loop is resilient. A single failing capacity aborting the rest turns one small problem into an estate-wide one, and it will not be noticed until the morning.

Test 7 is the one to run before deciding anything about throttling. Both remedies in §5 cost something, and neither is worth paying for on a suspicion.
