# Flow — `DeleteCapacityPolicySet`

Deactivates and deletes a capacity's policy set when its `ubsppcoe_Node` row is removed, and clears the `Capacity Policies` row that pointed at it.

> **Not built, and not yet agreed.** This is a specification and an argument, not a description of something that exists. **Read §0 before building any of it** — this is the only flow in the design that *removes* enforcement, and it is triggered by another team's delete.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md), [InitializeCapacityPolicySet.md](docs/flows/capacity-policies/InitializeCapacityPolicySet.md) — the flow this undoes, [SyncCapacityPolicySets.md](docs/flows/capacity-policies/SyncCapacityPolicySets.md), [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §2.

---

## 0. The decision this flow needs before it is built

Everything else in this design is fail-closed. A missing Node row refuses a rebuild; a blank lookup refuses a rebuild; an unregistered capacity is left alone. **This flow is the one that takes governance away**, and it does so on a signal nobody in this project controls.

> ### What a soft delete means is knowable, unlike a hard delete
>
> **Revised 2026-09-12.** `ubsppcoe_Node` soft-deletes — a decommissioned capacity keeps its row and its capacity GUID, and gains a flag. That is a **deliberate, explicit act**, not the ambiguous disappearance a hard delete would have been, and it makes this flow far safer to write than the first draft of this document assumed.
>
> It also makes the event **reversible on their side**: clearing the flag restores the capacity. So the question is no longer *what did they mean* but *what should we do that is equally reversible*.

> ### Recommendation: ask Fabric, then delete or suspend accordingly
>
> **Revised 2026-09-12, replacing a weaker recommendation.** An earlier draft said *deactivate, never delete*, on the grounds that deletion is irreversible and an unused policy set is free. **The second half of that was wrong**, and the first half was answering a question that does not need to be guessed at.
>
> A Node soft-delete is an **inventory** event. It does not say whether the Fabric capacity still exists — and that is the only thing that decides what to do here. **`GET /v1/capacities` answers it**, and [InitializeCapacityPolicySet](docs/flows/capacity-policies/InitializeCapacityPolicySet.md) Step 4 already makes exactly that call.
>
> | Fabric says | Meaning | Do |
> |---|---|---|
> | Capacity **absent** | Genuinely deprovisioned. The policy set can never apply to anything again — capacity GUIDs are not reissued | **Delete the policy set.** Keep our row, `status = Deleted` |
> | Capacity **present** | Inventory and Fabric **disagree**. The capacity is live and may still need governing | **Deactivate only**, `status = Suspended`, and report it. Do not delete |
>
> This is the same shape as Step 4 of `InitializeCapacityPolicySet`: the Fabric capacity list is the authority on whether a capacity exists, and the inventory is the authority on whether we should care. Neither answers the other's question.

> ### Why leaving the policy set behind is not free
>
> The earlier draft claimed a deactivated set scoped to a retired capacity costs nothing. Three reasons it does:
>
> **It degrades the detector.** [SyncCapacityPolicySets](docs/flows/capacity-policies/SyncCapacityPolicySets.md) reports policy sets it cannot map to a live capacity as `Untracked` — that is how a genuine orphan is found. Manufacturing them deliberately, one per retired capacity, buries the real ones in noise until nobody reads the report.
>
> **The holder workspace accumulates.** One workspace holds every policy set in the estate, 200–300 of them, and the nightly scan walks all of them inside a fixed budget. Every capacity ever retired would stay in that list permanently.
>
> **The audit value is not in the Fabric item.** Rules are regenerated wholesale on every rebuild, so the item carries no history. Everything worth keeping — policy set name and id, last rebuild, last error, the Node link — is on the `Capacity Policies` row, and **that row is what should be retained**, not the item.

> ### What is genuinely irreversible, and what is not
>
> Deleting the policy set is permanent: a new one has a new id, and every log and row referring to the old id stops resolving. That is a real cost and it is why the *present in Fabric* branch refuses to do it.
>
> But when Fabric says the capacity is gone, **there is nothing to reverse to.** The set could only ever be reactivated against a capacity GUID that no longer exists and will not be reissued. Keeping it is not caution; it is clutter with a story attached.

> ### The `IsDeleted` column name is a PLACEHOLDER
>
> `ubsppcoe_isdeleted` throughout this document is a stand-in. The real logical name has not been supplied — **[CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §1 is the authoritative list** of all six places it appears, and Q46 tracks it as blocking the build.

> ### The row is readable, and that changes the design
>
> A hard delete would have fired a trigger for a row that no longer exists — no capacity GUID, no node name, nothing but the row key. The first draft of this flow was built around finding our `Capacity Policies` row through a **stale `ubsppcoe_node` lookup** that survived the deletion, and around verifying that the relationship's delete behaviour did not null it.
>
> **None of that is needed.** A soft delete is an ordinary `Modified` event: `ubsppcoe_nodeuniqueid` is present, so the capacity id comes straight off the trigger, and the policy row can be found by either the lookup or the capacity id.
>
> **Use the lookup anyway** — `_ubsppcoe_node_value` — for consistency with [RemoveWorkspaceFromPolicy](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md) Step 2b and because it proves the Node link was genuinely established. But read `ubsppcoe_capacityid` off our own row rather than trusting the trigger's copy, for the same reason every other flow does: it is the value `InitializeCapacityPolicySet` wrote, and it is the one Fabric was called with.

---

## 1. Before you start

- Build [InitializeCapacityPolicySet.md](docs/flows/capacity-policies/InitializeCapacityPolicySet.md) first. This flow reverses it, and reuses its connector pattern.
- Needs a **Dataverse connection**, and — for §3 only — the *HTTP with Microsoft Entra ID (preauthorized)* connector.
- §2 makes **no Fabric calls at all**. That is most of why it is the recommended version.

---

## Step 1 — The trigger

**Solutions** → **New** → **Automation** → **Cloud flow** → **Automated** → name `DeleteCapacityPolicySet` → trigger **Microsoft Dataverse — When a row is added, modified or deleted**.

| Field | Value |
|---|---|
| Change type | **Modified** |
| Table name | `Nodes` (`ubsppcoe_Node`) |
| Scope | **Organization** |
| Select columns | `ubsppcoe_isdeleted` |
| Filter rows | `ubsppcoe_isdeleted eq true` |

**`eq true` here, not `ne true`.** This is the one filter in the design that wants the deleted rows rather than the live ones, so the three-valued reasoning inverts: `eq true` matches only rows explicitly flagged, which is exactly right. A null or `false` flag is a live capacity and must not fire this flow.

**`Modified`, not `Deleted`.** A soft delete is a column change. Ticking `Deleted` as well would add a trigger for hard deletes, which this flow cannot service — the row would be unreadable and the capacity underivable. **Leave `Deleted` off**, and accept that a genuine hard delete is invisible here; [SyncCapacityPolicySets](docs/flows/capacity-policies/SyncCapacityPolicySets.md) is what would eventually notice the orphan.

**`Select columns` must contain the flag**, or the flow never fires — the deletion *is* the change being watched for.

⋯ → **Settings** → **Concurrency Control On, Degree of Parallelism 1**.

> **This flow fires for every Node soft-delete in the tenant**, including the many that were never governed. Step 2 is what makes that cheap: one `List rows` that returns nothing, and the run ends.

---

## Step 2 — Find the policy row, if there is one

`Get_policy_row` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Capacity Policies` (`ubsppcoe_CapacityPolicy`) |
| Filter rows | `_ubsppcoe_node_value eq @{triggerOutputs()?['body/ubsppcoe_nodeid']}` |
| Select columns | `ubsppcoe_capacityid,ubsppcoe_capacitypolicyid,ubsppcoe_policysetid,ubsppcoe_policysetname,ubsppcoe_status` |
| Row count | `2` |

The GUID is **unquoted**, as always for a lookup filter.

> **This query is the whole flow's foundation.** `_ubsppcoe_node_value` holds the Node's row key, which the trigger supplies unchanged — a soft-deleted row keeps its key like every other value.
>
> **The first draft of this document worried about the relationship's delete behaviour nulling this lookup.** With a soft delete there is no deletion for Dataverse to cascade, so that concern is gone — along with the test that was written to check it.

`Condition_governed` — **Condition**:

| Left | Operator | Right |
|---|---|---|
| `length(body('Get_policy_row')?['value'])` | is equal to | `1` |

**No** → `outcome` = `NotGoverned`, then a `Compose` and stop. This is the majority path and it is not an error.

Everything below is in the **Yes** branch.

---

## Step 3 — Ask Fabric whether the capacity still exists

### 3a. `Get_capacities` — **Invoke an HTTP request**

| Field | Value |
|---|---|
| Method | `GET` |
| URL of the request | `https://api.fabric.microsoft.com/v1/capacities` |
| Header `Accept` | `application/json` |

`Filter_capacity` — **Filter array**:

| Field | Value |
|---|---|
| From | `body('Get_capacities')?['value']` |
| Condition (advanced) | `@equals(toLower(item()?['id']), toLower(first(body('Get_policy_row')?['value'])?['ubsppcoe_capacityid']))` |

**Match on our own `ubsppcoe_capacityid`, not the trigger's copy.** It is the value `InitializeCapacityPolicySet` wrote and the one Fabric was called with; the Node's `ubsppcoe_nodeuniqueid` should agree but nothing reconciles them (Q29).

> ### This list is scoped to the connection's identity, and that is dangerous here
>
> A capacity the identity does not administer is **absent from this list** — indistinguishable from one that has been deprovisioned. Everywhere else in the design that produces a `Skipped` and no action. **Here it would produce a deletion.**
>
> So the identity losing Capacity Admin — a permissions change, an expired assignment, the Q45 service account being altered — would make every subsequent Node soft-delete destroy a policy set for a capacity that is alive and well.
>
> **Guard it with a sanity check on the list itself**, not just on the one capacity. If `Get_capacities` returns an empty or implausibly short list, treat it as a permissions failure and take the *suspend* branch regardless. A capacity list that has lost every entry is not an estate that was decommissioned overnight.

### 3b. `Condition_capacity_gone` — **Condition**

| Left | Operator | Right |
|---|---|---|
| `length(body('Filter_capacity'))` | is equal to | `0` |

**And** — a second row, joined with `And`:

| Left | Operator | Right |
|---|---|---|
| `length(body('Get_capacities')?['value'])` | is greater than | `0` |

The second row is the sanity check above. Both must hold before anything is deleted: *this capacity is absent* **and** *we could see capacities at all*.

**Yes** → §3c, the delete path.
**No** → §3d, the suspend path.

---

### 3c. Delete — the capacity is genuinely gone

| # | Action | Detail |
|---|---|---|
| 1 | `Delete_policy_set` — **Invoke an HTTP request** | `DELETE .../policySets/{id}` |
| 2 | `Update_policy_row` — Dataverse **Update a row** | `status` = `Deleted`. Runs after the delete on **is successful** only |

The URL takes `@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}` as the workspace and `first(body('Get_policy_row')?['value'])?['ubsppcoe_policysetid']` as the set. **Confirm the `DELETE` route against the scripts in `ubs-policies` before building** — they are the authority on these paths, not the published reference, which [InitializeCapacityPolicySet](docs/flows/capacity-policies/InitializeCapacityPolicySet.md) Step 8c already found incomplete once.

> ## No `Deactivate` in this branch — tested 2026-09-13
>
> Both unknowns are now answered, against a real deprovisioned capacity:
>
> | Question | Answer |
> |---|---|
> | Does `deactivate` work after the capacity is deleted? | **No — `404 NotFound`** |
> | Does `DELETE` on the policy set work anyway? | **Yes** |
>
> ```
> 404 NotFound — NotFound — Capacity 'ed0c3b7b-…' not found.
> {"errorCode":"NotFound","message":"Capacity '…' not found.","isRetriable":false}
> ```
>
> **The 404 is on the *capacity*, not the policy set.** The deactivate endpoint resolves the activation scope before doing anything, and the scope is gone. The set itself is still present and still addressable — which is exactly why the `DELETE` succeeds.
>
> **So a `Deactivate` here would fail on every single run.** This branch only executes when 3b has confirmed the capacity is absent, so the 404 is not an edge case — it is the guaranteed outcome. Attempting it would add an action that always errors, always needs its failure tolerated, and never changes anything.
>
> **This supersedes the tolerated-deactivate construction and the grid that justified it.** That reasoning was correct while both cells were unknown; the test collapsed the grid to one column. Recorded rather than deleted, because the sequence — require it, remove it, tolerate it, remove it again — is the argument for testing early rather than reasoning harder.
>
> **`isRetriable: false`, and a `404` is neither `5xx` nor `429`**, so the default retry policy would not have hammered it. That is the only part of the earlier caution that turned out not to matter.

> ### The Try scope stays clean in this branch, and that is a real gain
>
> No `Deactivate` means no tolerated failure, which means **no *has failed* tick anywhere in 3c** — so no exception to the rule in [AddWorkspaceToPolicy](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) Step 5, and nothing masking `Scope_catch` on this path ([SCOPE-SANDBOX.md](docs/flows/capacity-policies/SCOPE-SANDBOX.md) E3).
>
> Every failure in the delete branch now reaches the Catch, which is what you want from the one flow that destroys things. **3d still carries the exception** — its `Update_policy_row` runs on *has failed* deliberately — so the rule is broken in exactly one place in this flow rather than two.

> ### Update the Dataverse row after the Fabric call, never before
>
> If our row is marked `Deleted` and the Fabric call then fails, the policy set is live with nothing claiming it — the exact orphan [SyncCapacityPolicySets](docs/flows/capacity-policies/SyncCapacityPolicySets.md) exists to find, manufactured by the cleanup flow.
>
> This ordering means a partial failure leaves the row saying `Suspended` or `Active` with the item still present, which is **recoverable**: the next run of this flow finds it and tries again.

> ### Keep the `Capacity Policies` row
>
> Mark it `Deleted`; do not delete it. It is the only record that this capacity was ever governed, which policy set governed it, and when it was stood down — and it is the only way to answer that question six months later. The table is small and rows are cheap.
>
> **Do not clear the `node` lookup either.** It still identifies which Node this was, and the Node row still exists — it is only flagged.

> ### This probably also affects the drift report
>
> **Tested 2026-09-13: `deactivate` on a policy set whose capacity is gone returns `404 Capacity not found`** — the endpoint resolves the activation scope first. Anything else that interrogates a policy set's activation state is likely to hit the same wall.
>
> [SyncCapacityPolicySets](docs/flows/capacity-policies/SyncCapacityPolicySets.md) detects *ours deactivated* as drift, which means it reads activation state. **For a `Suspended` or `Deleted` capacity that read may `404` rather than answer** — so the scan would report an error, or a false drift, for every retired capacity, permanently.
>
> Two things follow, and both belong in that document rather than this one. **`Suspended` and `Deleted` rows should be excluded from the drift comparison**, or the sync reports as problems the two states this flow deliberately creates. And **the sync needs to tolerate a `404` on activation state**, because a capacity can be deprovisioned between our row being written and the scan running.

> ### Update the Dataverse row after the Fabric call, never before
>
> If our row is marked `Deleted` and the Fabric call then fails, the policy set is live with nothing claiming it — the exact orphan [SyncCapacityPolicySets](docs/flows/capacity-policies/SyncCapacityPolicySets.md) exists to find, manufactured by the cleanup flow.
>
> This ordering means a partial failure leaves the row saying `Suspended` or `Active` with the item still present, which is **recoverable**: the next run of this flow finds it and tries again.

> ### Keep the `Capacity Policies` row
>
> Mark it `Deleted`; do not delete it. It is the only record that this capacity was ever governed, which policy set governed it, and when it was stood down — and it is the only way to answer that question six months later. The table is small and rows are cheap.
>
> **Do not clear the `node` lookup either.** It still identifies which Node this was, and the Node row still exists — it is only flagged.

### 3d. Suspend — Fabric still has the capacity

This is the disagreement case: the inventory says retired, Fabric says live. **Deactivate and stop.**

| # | Action | Detail |
|---|---|---|
| 1 | `Deactivate` | As above |
| 2 | `Update_policy_row` | `status` = `Suspended`. Runs after `Deactivate` on **is successful** and **has failed** |

`ubsppcoe_lasterror` carries the disagreement explicitly — something a human can act on:

```
concat('Node soft-deleted ', utcNow(), ' but the capacity is still present in Fabric. Policy set deactivated, item retained. Reconcile the inventory against Fabric before deleting anything. | run ', workflow()?['run']?['name'])
```

**`Update_policy_row` runs on *has failed* here deliberately** — the same exception [InitializeCapacityPolicySet](docs/flows/capacity-policies/InitializeCapacityPolicySet.md) Step 10a makes, and for the same reason: a failed deactivation is a fully handled state worth recording with Fabric's own message rather than routing to the Catch for a generic one.

**`ubsppcoe_status` gains two new values.** It was `Active` / `Inactive`; `Suspended` and `Deleted` are new. Plain text column, so no schema change — but record both in [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §2, and have [ListCapacityPolicySets](docs/flows/capacity-policies/ListCapacityPolicySets.md) render them distinctly from `Inactive`, which means something quite different.

> ### Nothing reactivates a `Suspended` capacity
>
> If the platform team clears the soft-delete flag, [InitializeCapacityPolicySet](docs/flows/capacity-policies/InitializeCapacityPolicySet.md) fires, finds our row and returns `AlreadyExists` without reactivating anything — so the capacity comes back **ungoverned while looking registered**, which is the worst combination in this design.
>
> **That is a gap and it needs a decision.** Either this flow gains a sibling that reactivates when the flag clears, or `InitializeCapacityPolicySet` learns to reactivate a `Suspended` row instead of reporting `AlreadyExists`. The second is cheaper and keeps one flow per event.
>
> It does **not** apply to the `Deleted` branch: there is nothing to reactivate, and a capacity id that returns to Fabric's list after being absent is a situation nobody in this design has thought about.

`Set_outcome` — `Deleted` or `Suspended`, with a message naming the policy set and the capacity.

---

## Step 4 — Record the outcome

`Compose_result` — **Compose**, after **both** scopes on **all four** statuses:

```
@{variables('outcome')} — @{variables('message')}
```

| `outcome` | Meaning | Run ends |
|---|---|---|
| `NotGoverned` | No `Capacity Policies` row for that Node. **The majority path** | Succeeded |
| `Deleted` | Fabric confirmed the capacity is gone. Policy set deleted, row retained | Succeeded |
| `Suspended` | Fabric still has the capacity. Policy set deactivated, item retained, **reconciliation needed** | Succeeded |
| `Failed` | Deactivation failed — **the capacity is still governed**. Recorded on the row | Succeeded |
| `Caught` | An action failed outright | **Failed** |

> **`Suspended` is a disagreement between two systems, and nothing chases it.** The inventory says the capacity is retired; Fabric says it is live. One of them is wrong, and this flow cannot tell which. It ends green, writes a sentence to a column, and moves on.
>
> **That is the outcome most worth routing somewhere a human sees.** `Deleted` is routine and `NotGoverned` is noise, but `Suspended` means a capacity is now ungoverned *and* somebody's records are wrong about it.

> **`Failed` here means the opposite of what it means in the other flows.** Everywhere else a failure means governance was not applied. Here it means governance was not *removed* — the capacity is retired but its policy set is still active and still denying item creation.
>
> That is the **safe** direction to fail, which is why it ends green. But somebody retiring a capacity will be told it is done, and a tenant-wide cleanup ending in fifty unread `Failed` rows is fifty active policy sets on capacities that no longer exist.

---

## Step 5 — Try and Catch

Same shape as [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) Step 7. `Scope_try` wraps Steps 2 and 3; `Scope_catch` runs after it on **has failed**, **is skipped**, **has timed out**; the Catch ends in `Terminate` status **Failed**.

**The Catch cannot write `ubsppcoe_lasterror` here in the usual way.** The row it would write to is the one Step 2 may have failed to find. Guard on a `policyRowId` variable exactly as the other flows do, set it after Step 2, and accept that a failure inside Step 2 records only to the run history.

Keep `Scope_try` **flat** — Step 3 must not sit inside a Condition that can itself fail, or `result('Scope_try')` reports the container rather than the action ([SCOPE-SANDBOX.md](docs/flows/capacity-policies/SCOPE-SANDBOX.md) E1, E10).

> **`Scope_try` here contains a Condition with real work in both branches** — 3c and 3d are not `Set variable` branches, they make Fabric calls. So this flow **cannot** get the flat-scope benefit that [RemoveWorkspaceFromPolicy](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md) gets: a failure inside 3c or 3d is reported as `Condition_capacity_gone` with the generic *"An action failed"* message.
>
> That is accepted rather than fixed, on the same reasoning as [AddWorkspaceToPolicy](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) Step 7b: the run ID in the message is what makes the run findable, and restructuring to recover a better string is not worth it. **But it matters more here**, because this is the only flow that deletes things — so when it fails, knowing exactly which call failed is worth more than usual. If that turns out to hurt in practice, the fix is a nested Try inside each branch, not a flattening.

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | Soft-delete a throwaway Node row with **no** `Capacity Policies` row | `NotGoverned`, run green, nothing written, **no Fabric call** |
| 2 | Soft-delete a governed Node row whose capacity **still exists** in Fabric | `Suspended`. Policy set deactivated and **still present**. `lasterror` names the disagreement |
| 3 | Deprovision a throwaway capacity in Fabric, **then** soft-delete its Node row | `Deleted`. Policy set gone from the holder workspace, `Capacity Policies` row **retained** with `status = Deleted` |
| 3a | *(Answered 2026-09-13 — no longer needs running)* | `deactivate` on a deleted capacity returns `404 Capacity not found`; `DELETE` on the policy set succeeds. See 3c |
| 4 | **Revoke Capacity Admin from the connection identity, then soft-delete a governed Node row** | `Suspended`, **never `Deleted`**. This is the sanity check in 3b — if it deletes, the guard is wrong and a permissions lapse becomes a destructive event |
| 5 | Break `Delete_policy_set`, then run test 3 again | The row must **not** say `Deleted`. If it does, the ordering in 3c is wrong and the flow has manufactured an orphan |
| 6 | After test 2, clear the soft-delete flag on that Node row | [InitializeCapacityPolicySet](docs/flows/capacity-policies/InitializeCapacityPolicySet.md) fires and returns `AlreadyExists`. **The policy set stays deactivated and the capacity stays ungoverned** — the gap named in 3d. Confirm it, then decide who closes it |
| 7 | After test 2, run the nightly rebuild | The capacity is rebuilt as normal — the Node link still resolves. Rules are republished into a **deactivated** set: harmless, but `lastrebuild` keeps moving on a retired capacity. Decide whether the nightly job should skip `Suspended` rows |
| 8 | Soft-delete the same Node row twice | Fires again, deactivates an already-inactive set. Must be harmless |

**Test 4 is the one to write first.** It is the only test where a bug destroys something. `GET /v1/capacities` is scoped to the connection's identity, so *absent from the list* and *we cannot see it* are the same response — and one of those must never reach the delete branch.

**Test 3 needs a real deprovisioned capacity**, which is awkward to arrange and is why it will get skipped. Do not skip it: it is the only test that exercises the branch this flow exists for.

**Test 6 will bite.** Un-deleting is plausible — a capacity retired in error, or a staged decommission reversed — and it currently leaves the capacity registered, ungoverned, and reporting `AlreadyExists` to the one flow that might have fixed it. Nothing in the design owns that transition.
