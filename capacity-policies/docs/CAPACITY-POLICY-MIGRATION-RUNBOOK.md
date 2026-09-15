# Capacity policy migration — runbook

Operational guide for bringing an existing Fabric estate under capacity item-creation policy. Follow it in order. Each phase names what to check before moving on, and what "stop" looks like.

Related: [CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §8 (design and build order), [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) (schema and seeding), the three `MIG_` flow documents in [flows/capacity-policies/](docs/flows/capacity-policies/).

**Once cutover is done, day-to-day operations are in [CAPACITY-POLICY-OPERATIONS-RUNBOOK.md](docs/CAPACITY-POLICY-OPERATIONS-RUNBOOK.md)** — which flow to run when a capacity or workspace is created, deleted or moved.

---

## The shape of it

```
PHASE 0   Pre-flight                    nothing changes
PHASE 1   Register        MIG_RegisterAllCapacityPolicySets     inert
PHASE 2   Seed exceptions                                       inert
PHASE 3   Rebuild rules   RebuildAllCapacityPolicies            inert
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

### 0.1 Turn off the two scheduled flows

Power Automate → **Solutions** → your solution → select the row → **Turn off**.

| Flow | Why |
|---|---|
| `RebuildAllCapacityPolicies` | It would publish rules at a moment you did not choose, before exceptions are seeded |
| `SyncCapacityPolicySets` | Every policy set is deactivated *by design* through this migration, and `Inactive` is a drift kind. A nightly scan would report the whole estate as drift and train whoever reads it to ignore the report |

**Do not turn off `RebuildCapacityPolicyRules`.** It is a child flow, and a flow that is off cannot be called as one.

### 0.2 Confirm the tables

| Table | State required |
|---|---|
| `Capacity Policies` | Exists, empty or nearly so |
| `Policy Item Types` | **Seeded and active.** Rule 2 with an empty `item.type` array is rejected by Fabric |
| `Policy Exceptions` | Exists. Seeding happens in Phase 2 |
| `Policy Drift` | Exists. Nothing writes it during migration |

### 0.3 Confirm the environment variables

| Variable | Typical |
|---|---|
| `ubsppcoe_PolicyHolderWorkspaceId` | The workspace that will hold ~200 policy set items |
| `ubsppcoe_PolicySentinelWorkspaceId` | `00000000-0000-0000-0000-000000000000` |
| `ubsppcoe_PolicyMaxWorkspacesPerRule` | `49` |
| `ubsppcoe_PolicyMaxRulesPerPolicy` | `50` |
| `ubsppcoe_PolicyNamePrefix` | Whatever the policy sets should be called |

A missing one fails at runtime with `The workflow parameter … is not found`, per capacity, all the way through a run.

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

- [ ] Both scheduled flows off
- [ ] `Policy Item Types` seeded and active
- [ ] All five environment variables set
- [ ] Contributor on the holder workspace confirmed
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

`Policy Exceptions` has no upstream — no flow derives those rows, and `ubsppcoe_Workspace` says nothing about them. If the estate has existing exceptions, import them from `fabric_workspaces_exceptions.csv`:

| Column | Value |
|---|---|
| `ubsppcoe_workspacename` | Anything readable. Primary name, no flow reads it |
| `ubsppcoe_workspaceid` | The **Fabric workspace GUID**, from the CSV |
| `ubsppcoe_active` | **Yes** |
| `ubsppcoe_reason`, `ubsppcoe_approvedby` | Whatever the CSV carries |

**Take the `workspace_id` column only.** The CSV's `capacity_id` has no counterpart in the table — the capacity is derived from the workspace's `Node` at rebuild time. But **check the two agree before discarding it**: a CSV row whose workspace now sits under a different Node is an exception that is about to move capacity, quietly, on the first rebuild.

`ubsppcoe_active` defaults to **No**. A row imported with the flag untouched is `null`, and the rebuild's `ubsppcoe_active eq true` filter excludes it — so an exception that appears to do nothing is almost always an unset flag.

**If there are no existing exceptions, skip this phase.**

> **Skipping it when there *are* exceptions is invisible.** The rebuild will not fail; it will simply publish rules without rule 3, and workspaces that were unrestricted become restricted at Phase 5. Nothing reports it.

---

## Phase 3 — Rebuild rules

**Run:** `RebuildAllCapacityPolicies`, manually — turn it **on**, use **Run**, then turn it **off** again.

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

Capacities with `rulecount = 1` are **excluded by design** — activating one locks it completely, so it is a per-capacity decision, not a batch. Handle those individually afterwards, or leave them for the provisioning app.

### 5.2 First tranche — five capacities

**Run:** mode **`Activate`**. Cancel from the run history after about five.

Then, on one of them:

- [ ] Policy set shows **Active** in the portal
- [ ] Its `Capacity Policies` row shows `Status = Active`, `lasterror` empty
- [ ] **Create a governed item in a whitelisted workspace — it works**
- [ ] **Create a governed item in a non-whitelisted workspace — it is refused**

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

### 7.1 Turn the scheduled flows back on

| Flow | |
|---|---|
| `RebuildAllCapacityPolicies` | Nightly convergence. Without it, table edits never reach Fabric |
| `SyncCapacityPolicySets` | Drift detection. It is the only thing that notices a policy set being deactivated, replaced or deleted |

Let one nightly cycle run and read both reports before considering migration closed. The first `SyncCapacityPolicySets` run after cutover is the one that will tell you whether anything was left half-done.

### 7.2 Delete the three `MIG_` flows

Turn off and delete:

- `MIG_RegisterAllCapacityPolicySets`
- `MIG_InitializeCapacityPolicySet`
- `MIG_ActivateAllCapacityPolicySets`

They have no BAU role. `MIG_InitializeCapacityPolicySet` in particular is **unsafe standalone** — it has no capacity eligibility check, because the loop did that — so leaving it in the solution invites someone to run it against a live capacity a year from now.

New capacities are handled by the provisioning app calling `InitializeCapacityPolicySet`, which creates, registers, rebuilds and activates one capacity at a time, where the blast radius is a capacity nobody is using yet.

### 7.3 Hand over what is still outstanding

- The `No Node row` list from Phase 1, to the platform team
- The Phase 4 denial figures and who signed them off
- Any capacity left at `rulecount = 1` and deliberately not activated

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

**The one thing not to do is leave Phase 5 partly done with the scheduled flows still off.** Activated capacities then stop converging to the tables, so a workspace whitelisted in Dataverse never reaches Fabric and its owner cannot create anything. If Phase 5 is going to be paused for more than a day, turn `RebuildAllCapacityPolicies` back on first.
