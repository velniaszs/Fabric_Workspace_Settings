# Capacity policy migration — runbook

Operational guide for bringing an existing Fabric estate under capacity item-creation policy. Follow it in order. Each phase names what to check before moving on, and what "stop" looks like.

Related: [CAPACITY-POLICY-FLOWS.md](CAPACITY-POLICY-FLOWS.md) §8 (design and build order), [CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md) (schema and seeding), the four `MIG_` flow documents in [migration/](../migration/).

**Once cutover is done, day-to-day operations are in [CAPACITY-POLICY-OPERATIONS-RUNBOOK.md](CAPACITY-POLICY-OPERATIONS-RUNBOOK.md)** — which flow to run when a capacity or workspace is created, deleted or moved.

---

## The shape of it

```
PHASE 0   Pre-flight                    nothing changes
PHASE 1   Register        MIG_RegisterAllCapacityPolicySets     inert
PHASE 2   Seed exceptions                                       inert
PHASE 3   Rebuild rules   MIG_RebuildAllCapacityPolicies        inert
PHASE 4   Review gate                   nothing changes         ← decision point
PHASE 5   Activate        MIG_ActivateAllCapacityPolicySets     ENFORCEMENT BEGINS
PHASE 6   Verify
PHASE 7   Clean up
```

> ### Everything before Phase 5 is reversible
>
> Phases 1 to 3 create policy sets, write Dataverse rows and publish rules — and **none of it is enforced**, because the policy sets are deactivated. A wrong run is undone by deleting items and rows, and nobody notices.
>
> **Phase 5 ends that.** Rule 1 is a deny-all baseline: an `Allow` rule whose condition can never match, present so that anything not allowed by a later rule is refused. An activated policy set with rule 1 and no whitelist denies **all governed item creation** on that capacity. Power BI items are unaffected.
>
> Do not compress the phases. The gap between them is where the mistakes get caught.

---

## Phase 0 — Pre-flight

Nothing here changes anything. All of it is cheaper to do now than to discover in Phase 5.

### 0.1 Confirm no flow is armed

Power Automate → **Solutions** → your solution.

**There is no scheduled flow to turn off.** `SyncCapacityPolicySets` was the only Recurrence flow in the design and it was discarded on 2026-09-18 — [discarded/SyncCapacityPolicySets.md](../discarded/SyncCapacityPolicySets.md). If one exists in your environment, it is a leftover from an earlier build: turn it off and delete it.

`MIG_RebuildAllCapacityPolicies` is **manual**, so there is no schedule to stop — but leave the flow turned **off** until Phase 3, which turns it on, runs it, and turns it off again. An enabled manual flow is one stray button press from publishing rules at a moment you did not choose, before exceptions are seeded.

**The Dataverse-triggered BAU flows are the ones to watch.** `InitializeCapacityPolicySet`, `AddWorkspaceToPolicy`, `RemoveWorkspaceFromPolicy` and `RebuildOnExceptionChange` fire on row changes, so they act without anybody pressing anything — including on the `Policy Exceptions` rows seeded in Phase 2. Turn them **off** for the duration and back on at Phase 7.

**Do not turn off `RebuildCapacityPolicyRules`.** It is a child flow, and a flow that is off cannot be called as one.

### 0.2 Confirm the tables

| Table | State required |
|---|---|
| `Capacity Policies` | Exists, empty or nearly so |
| `Policy Item Types` | **Seeded and active.** Rule 2 with an empty `item.type` array is rejected by Fabric |
| `Policy Exceptions` | Exists. Seeding happens in Phase 2 |

`Policy Drift` is **not** part of the solution — dropped on 2026-09-18, its only writer having been discarded.

### 0.3 Confirm the environment variables

| Variable | Typical |
|---|---|
| `ubsppcoe_PolicyHolderWorkspaceId` | The workspace that will hold ~200 policy set items |
| `ubsppcoe_PolicySentinelWorkspaceId` | `00000000-0000-0000-0000-000000000000` |
| `ubsppcoe_PolicyMaxWorkspacesPerRule` | `49` |
| `ubsppcoe_PolicyMaxRulesPerPolicy` | `50` |
| `ubsppcoe_PolicyNamePrefix` | Whatever the policy sets should be called |
| `ubsppcoe_PolicyApiBeta` | **No** — set it to `Yes` only once the capacity-policy API is in public-preview beta ([API-BETA-SWITCH.md](API-BETA-SWITCH.md)) |

A missing one fails at runtime with `The workflow parameter … is not found`, per capacity, all the way through a run.

**`ubsppcoe_PolicyApiBeta` pointing the wrong way fails differently** — every Fabric call is rejected by the service rather than by the flow engine, so the run history shows a per-capacity `400`/`404` with nothing naming the variable. Confirm it before a migration run, not during one.

### 0.4 Confirm permissions on the connection identity

| Needed | For | Checked in |
|---|---|---|
| **Contributor on the holder workspace** | Creating policy sets | Phase 1 |
| **Capacity Admin on every capacity** | Activating | **Phase 5 — not before** |

Capacity Admin is the one that bites late. It is not exercised until Phase 5, and a gap in it shows up as a per-capacity failure there. If it can be confirmed in advance from the Fabric admin portal, do so.

### 0.5 Check for duplicate capacity display names

Policy set names are derived as `<prefix><capacity display name>`, and Fabric rejects a duplicate with `ItemDisplayNameAlreadyInUse`.

List the capacities and look for repeats. If there are any, append the capacity-ID suffix unconditionally in `MIG_InitializeCapacityPolicySet` Step 5a:

```
concat(parameters('PolicyNamePrefix (ubsppcoe_PolicyNamePrefix)'), triggerBody()['text_1'], ' (', substring(triggerBody()['text'], 0, 8), ')')
```

Names are cosmetic. Doing it for every capacity costs nothing and removes the failure mode.

### 0.6 Delete leftovers from testing

Any policy set in the holder workspace created while building the flows, and any `Capacity Policies` row pointing at it. A leftover set produces a name collision in Phase 1; a leftover row makes that capacity return `AlreadyExists` and be silently skipped.

**Checklist before Phase 1**

- [ ] `MIG_RebuildAllCapacityPolicies` off, and the four Dataverse-triggered BAU flows off
- [ ] `Policy Item Types` seeded and active
- [ ] All six environment variables set, with `ubsppcoe_PolicyApiBeta` pointing the right way for the API's current release stage
- [ ] Contributor on the holder workspace confirmed
- [ ] Decided whether the **holder workspace sits on a governed capacity** — if it does, its `Policy Exceptions` row is mandatory in Phase 2
- [ ] Duplicate display names checked
- [ ] Test leftovers deleted

---

## Phase 1 — Register

**Run:** `MIG_RegisterAllCapacityPolicySets`, manually.

Creates one policy set per eligible capacity, with **no rules**, **deactivated**, and writes a `Capacity Policies` row for each with `Status = Inactive`.

### 1.1 First, check the candidate count

Start the run and let it reach `Compose_eligible_count`, then look at that value.

**If it is materially smaller than the estate you expect, stop and cancel.** `GET /v1/capacities` is scoped to the connection's identity — a capacity that identity does not administer is simply absent, and the flow will never know it existed. A short list is an identity problem, not a data problem, and this is the cheapest possible moment to find it.

### 1.2 Run the first tranche — five capacities

Let it run, then **cancel from the run history** after about five iterations.

Verify, by eye:

| Check | Where | Expected |
|---|---|---|
| Policy set exists | Holder workspace, Fabric portal | Five new items |
| **No rules** | Open one | Empty rule list |
| **Not activated** | Open one | Inactive |
| Dataverse row | `Capacity Policies` | Five rows |
| **`Node` populated** | Open a row | A Node lookup, not blank |
| `Status` | Same row | `Inactive` |
| Counts empty | Same row | `lastrebuild`, `rulecount`, `workspacecount` blank |

**An activated policy set here means the flow still has the BAU flow's Step 8c** — stop and fix it before continuing. That is deny-all in force on a capacity nobody approved.

**A blank `Node` means the lookup bind is wrong.** That capacity is registered and permanently un-rebuildable. Fix the bind, delete the rows and sets, start Phase 1 again.

### 1.3 Run the rest, in tranches

Re-run the flow. Already-registered capacities return `AlreadyExists` and are skipped, so each run resumes where the last stopped.

Suggested: ~40 next, check the `noNode` list is plausible rather than "everything", then the remainder.

### 1.4 Read the report

The email carries three numbers and two lists.

| Bucket | Meaning | Action |
|---|---|---|
| Registered | Created this run | None |
| **No Node row** | Capacity exists in Fabric, no `ubsppcoe_Node` row | **Hand the list to the platform team.** Nothing was created for these; they cannot be migrated until a Node row exists |
| Failed | Duplicate name, permission, timeout | Fix, then re-run |

Re-run until `Failed` is empty. `No Node row` may stay non-empty — those capacities are simply out of scope until someone else acts.

**Rollback:** delete the policy sets from the holder workspace and the `Capacity Policies` rows. Nothing else has happened.

---

## Phase 2 — Seed `Policy Exceptions`

**Nothing to run.** A data import, and it **must happen before Phase 3**.

`Policy Exceptions` has no upstream — no flow derives those rows, and `ubsppcoe_Workspace` says nothing about them. Use [input/PolicyExceptions.csv](../input/PolicyExceptions.csv) as the import template; its headers are the Dataverse logical names, so the mapping is column-for-column.

> **Delete its three `EXAMPLE` rows first.** They carry placeholder GUIDs that match no workspace, so importing them grants nothing — but they leave junk in a table whose whole value is being short enough to review by eye.

Fill it from the estate's existing exceptions — `fabric_workspaces_exceptions.csv`, if the migration has one:

| Column | Value |
|---|---|
| `ubsppcoe_workspacename` | Anything readable. Primary name, no flow reads it |
| `ubsppcoe_workspaceid` | The **Fabric workspace GUID**, from the CSV |
| `ubsppcoe_active` | **Yes** |
| `ubsppcoe_reason`, `ubsppcoe_approvedby` | Whatever the CSV carries |

**Take the `workspace_id` column only.** The CSV's `capacity_id` has no counterpart in the table — the capacity is derived from the workspace's `Node` at rebuild time. But **check the two agree before discarding it**: a CSV row whose workspace now sits under a different Node is an exception that is about to move capacity, quietly, on the first rebuild.

### The holder workspace goes in first

**The workspace named by `ubsppcoe_PolicyHolderWorkspaceId` needs its own exception row**, and it is the one row that does not come from the estate's CSV.

That workspace holds every policy set item. If it sits on a capacity this system governs, rule 1's deny-all applies to it like any other — and the thing it blocks is **creating policy set items**, which is what [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md) Step 6 does for every capacity provisioned from here on. **The subsystem locks itself out of its own store.**

| Column | Value |
|---|---|
| `ubsppcoe_workspacename` | The holder workspace's name — label it clearly, this row must never be revoked by mistake |
| `ubsppcoe_workspaceid` | The GUID in `ubsppcoe_PolicyHolderWorkspaceId` |
| `ubsppcoe_active` | **Yes** |
| `ubsppcoe_reason` | *Holds the policy set items. Excepting it prevents the policy system locking itself out* |
| `ubsppcoe_approvedby` | Whoever owns this subsystem |

**Two things have to be true for the row to do anything**, and both are easy to miss:

1. The holder workspace needs a **`ubsppcoe_Workspace` row under the Node of the capacity it sits on**. The rebuild joins exceptions to that table, so with no row there is no rule 3 entry — and no error either. Ask the platform team if it is absent.
2. Its capacity must be one this system governs. **If the holder workspace sits on a capacity with no `ubsppcoe_Node` row, nothing governs it and the exception is harmless but unnecessary** — confirm which case you are in rather than assuming.

> **Put the holder workspace on an ungoverned capacity if you have the choice.** The exception is the fix for a self-inflicted dependency; not creating the dependency is better. This row exists because the holder often has nowhere else to live.

`ubsppcoe_active` defaults to **No**. A row imported with the flag untouched is `null`, and the rebuild's `ubsppcoe_active eq true` filter excludes it — so an exception that appears to do nothing is almost always an unset flag.

**If there are no existing exceptions, skip this phase.**

> **Skipping it when there *are* exceptions is invisible.** The rebuild will not fail; it will simply publish rules without rule 3, and workspaces that were unrestricted become restricted at Phase 5. Nothing reports it.

---

## Phase 3 — Rebuild rules

**Run:** `MIG_RebuildAllCapacityPolicies`, manually — turn it **on**, use **Run**, then turn it **off** again.

Iterates every `Capacity Policies` row with a policy set and publishes rule 1, the whitelist chunks and the exception rule for each. Stamps `lastrebuild`, `lasterror`, `rulecount`, `workspacecount` and `exceptioncount`.

**Still nothing is enforced.** Every policy set is deactivated.

Expect 200 capacities to take a while — each is a handful of Dataverse reads and one `replaceByPolicy` call, run serially.

### Check afterwards

- [ ] The failure summary is empty, or every entry is understood
- [ ] Every row has a `lastrebuild` timestamp
- [ ] Open one capacity in the portal: rule 1 present, plus a whitelist rule if it has enabled workspaces
- [ ] If you seeded exceptions, open a capacity that has one: rule 3 present with **one** condition and no `item.type`

**Rollback:** none needed. Rules on a deactivated policy set do nothing. Re-running fixes anything.

---

## Phase 4 — Review gate

**Nothing to run. This is the decision point, and it is the reason the phases are separate.**

Activating a policy set puts rule 1 into force. For every workspace **not** in rule 2 or rule 3, item creation stops. So the question is:

> **How many workspaces will lose the ability to create items?**

Per capacity:

```
workspaces under the Node          (all of them, whatever the flag says)
  − workspacecount                    (in rule 2 — stamped by Phase 3)
  − exceptioncount                    (in rule 3 — stamped by Phase 3)
= workspaces that will be denied
```

The first number is not stamped anywhere. It comes from `ubsppcoe_Workspace` filtered on `_ubsppcoe_nodeid_value`, per capacity.

### Why `rulecount` alone is not the answer

`rulecount = 1` bundles two opposite situations:

| | Workspaces under Node | Enabled | Verdict |
|---|---|---|---|
| Unused capacity | 0 | 0 | **Activate.** Nothing to break |
| Live capacity, flag not rolled out | 40 | 0 | **Do not activate.** 40 teams lose item creation |

And `rulecount > 1` is not automatically safe either: a capacity with 500 workspaces where 2 are flagged produces rules, passes every filter, and denies 498.

### The buckets and what to do

| Signal | Action |
|---|---|
| `lastrebuild` empty, or `lasterror` populated | **Blocker.** Phase 3 did not complete. Fix and re-run it. Should be zero |
| Denied = 0 | Activate |
| Denied small, and nameable | Get those workspaces flagged by the platform team, or add `Policy Exceptions` rows. **Re-run Phase 3.** Then activate |
| Denied large, across many capacities | **Stop.** This is not a cutover step. It is a question about whether `ubsppcoe_oapenabled` rollout is complete enough to enforce on, and it needs a decision above this project |

**Get the outcome of this phase written down and agreed.** It is the sign-off that the removed CSV reconciliation used to represent, and it is the only artefact that says a human looked at who was about to lose access.

> **`MIG_ActivateAllCapacityPolicySets` in `Report` mode gives a partial view for free** — per capacity it lists rule count, whitelisted workspace count and exception count. What it cannot show is the *total* workspaces per Node, so read it as a smell test rather than sign-off. A capacity with many rules and few whitelisted workspaces is the shape to look at first.

---

## Phase 5 — Activate

**This is the step that changes access. Announce it before you run it.**

### 5.1 Dry run

**Run:** `MIG_ActivateAllCapacityPolicySets`, mode **`Report`**.

Makes no Fabric call and no Dataverse write. Check the run history action list to confirm that — `Activate` should show as skipped.

Read the list. Is the count what Phase 4 led you to expect?

Capacities with `rulecount = 1` **are included** — changed 2026-09-17. They activate with the deny-all baseline and nothing whitelisted, which is a governed capacity with nothing yet allowed on it. Only rows with an **empty** `rulecount` are excluded, because those were never rebuilt.

> **So Phase 4 is the only thing standing between a `rulecount = 1` capacity and a total lock.** The filter no longer catches it. If the run list contains a capacity where `ubsppcoe_oapenabled` was never rolled out, activating it stops item creation for every team on it — and nothing downstream will query that decision.

### 5.2 First tranche — five capacities

**Run:** mode **`Activate`**. Cancel from the run history after about five.

Then, on one of them:

- [ ] Policy set shows **Active** in the portal
- [ ] Its `Capacity Policies` row shows `Status = Active`, `lasterror` empty
- [ ] **Create a governed item in a whitelisted workspace — it works**
- [ ] **Create a governed item in a non-whitelisted workspace — it is refused**
- [ ] **If the holder workspace sits on this capacity: create an item in it — it works.** That is the Phase 2 exception doing its job, and the failure mode it prevents is the policy system being unable to create policy sets for the next capacity

Those last two are the acceptance test for the entire project. Everything else proves the machinery ran; only these prove it did the right thing.

**Stop here if either is wrong.** Five capacities is recoverable. Two hundred is an incident.

### 5.3 The rest

**Run:** mode `Activate` to completion. Expect **~20 minutes per 200 capacities** — the loop carries a 6-second delay because the activation endpoints are limited to 10 requests per minute. That is the floor; raising parallelism cannot help, because the limit is per tenant.

### 5.4 Read the report

Failures leave the row `Inactive` with `lasterror` populated, and are **not enforced** — those capacities are simply still ungoverned. Re-running picks up only rows still marked `Inactive`, so it is safe.

The likeliest failure here is **Capacity Admin** missing on a capacity. It is the first time that permission is exercised at scale.

### Rollback

Per capacity, using the scripts in `C:\GIT\ubs-policies`:

1. `deactivate_policy_set.ps1 -WorkspaceId <holder> -PolicySetId <id>`
2. Set that row's `ubsppcoe_status` back to `Inactive`

**Know this before you start**, not while people are complaining.

---

## Phase 6 — Verify

- [ ] `ListCapacityPolicySets`, or the table directly: every migrated capacity present, `Status = Active`, `lastrebuild` recent, `lasterror` empty
- [ ] Spot-check three capacities in the portal: rule 1 present, whitelist rules match `workspacecount`
- [ ] A workspace that was in the exceptions CSV can still create anything on its capacity
- [ ] Nobody is reporting refusals they should not be getting

---

## Phase 7 — Clean up

### 7.1 Turn the BAU flows back on

Turn on the four Dataverse-triggered flows switched off in Phase 0.1:

| Flow | Fires on |
|---|---|
| `InitializeCapacityPolicySet` | `ubsppcoe_Node` added/modified |
| `AddWorkspaceToPolicy` | `ubsppcoe_Workspace`, `oapenabled` becoming true |
| `RemoveWorkspaceFromPolicy` | `ubsppcoe_Workspace`, `oapenabled` ceasing to be true, or soft-deleted |
| `RebuildOnExceptionChange` | `Policy Exceptions` added/modified |

**This is the moment BAU starts.** From here, row changes publish themselves.

Leave `MIG_RebuildAllCapacityPolicies` **off**. It is manual, so there is no schedule to restore — but keep it in the solution; §7.2 does not delete it.

> **Nothing converges the estate on its own after cutover, and nothing observes it either.** The per-event flows publish their own change, but a failed one, a `Node` move, a hard-deleted exception row and any hand-edited rule all persist until somebody runs `MIG_RebuildAllCapacityPolicies` — **Q49**. And since the drift scan was discarded, a policy set deactivated, replaced or deleted outside the flows is not detected at all — **Q11**. Both in [ADR.md](ADR.md).

**Before considering migration closed**, run `MIG_RebuildAllCapacityPolicies` once more and read its summary. It is the only estate-wide check there is, and it is what tells you whether anything was left half-done.

### 7.2 Delete the three disposable `MIG_` flows

Turn off and delete:

- `MIG_RegisterAllCapacityPolicySets`
- `MIG_InitializeCapacityPolicySet`
- `MIG_ActivateAllCapacityPolicySets`

**Keep `MIG_RebuildAllCapacityPolicies`**, turned off. It carries the prefix but is not disposable — nothing else rebuilds more than one capacity at a time, and the operations runbook sends people to it.

The other three have no BAU role. `MIG_InitializeCapacityPolicySet` in particular is **unsafe standalone** — it has no capacity eligibility check, because the loop did that — so leaving it in the solution invites someone to run it against a live capacity a year from now.

New capacities are handled by the provisioning app calling `InitializeCapacityPolicySet`, which creates, registers, rebuilds and activates one capacity at a time, where the blast radius is a capacity nobody is using yet.

### 7.3 Hand over what is still outstanding

- The `No Node row` list from Phase 1, to the platform team
- The Phase 4 denial figures and who signed them off
- Any capacity activated at `rulecount = 1`, and whether that was because it is genuinely unused or because the flag is not rolled out yet

---

## If you have to stop halfway

| Stopped after | State | What is enforced |
|---|---|---|
| Phase 1 | Policy sets exist, no rules, deactivated | Nothing |
| Phase 2 | Same | Nothing |
| Phase 3 | Rules published, deactivated | Nothing |
| Phase 4 | Same | Nothing |
| **Phase 5, partway** | Some capacities active | **Only the activated ones** |

Stopping before Phase 5 is free — leave it, or delete the sets and rows.

Stopping partway through Phase 5 is stable, not broken: activated capacities are governed, the rest are as they were. Re-run mode `Activate` to finish, or roll back the activated ones individually.

**The one thing not to do is leave Phase 5 partly done and walk away.** Activated capacities are governed by whatever Phase 3 published. The per-event flows keep individual changes flowing, but **nothing re-converges the estate on its own**, so a gap left here stays until a person closes it. If Phase 5 is going to be paused for more than a day, run `MIG_RebuildAllCapacityPolicies` before you stop and again before you resume.
