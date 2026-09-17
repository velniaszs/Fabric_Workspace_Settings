# Capacity policy — operations runbook

What to run when the estate changes. One section per lifecycle event.

Companion to [CAPACITY-POLICY-MIGRATION-RUNBOOK.md](docs/CAPACITY-POLICY-MIGRATION-RUNBOOK.md), which covers the one-off cutover. This document covers everything after it.

Related: [CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) (design), [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) (schema).

---

## Quick reference

| Event | Run | Who triggers it |
|---|---|---|
| **Capacity created** | `InitializeCapacityPolicySet` | Provisioning app |
| **Capacity deleted** | Manual cleanup — §2. `DeleteCapacityPolicySet` is **specified but not built** | You |
| **Workspace added and to be whitelisted** | `AddWorkspaceToPolicy` | App |
| **Workspace deleted** | `RemoveWorkspaceFromPolicy` | App |
| **Workspace moved between capacities** | `RemoveWorkspaceFromPolicy` on the **old**, then `AddWorkspaceToPolicy` on the **new** | App |
| **Exception granted or revoked** | Edit `Policy Exceptions`, then rebuild — §6 | You |
| **Governed item type added or retired** | Edit `Policy Item Types`, then rebuild — §7 | You |
| **Emergency: unlock a capacity** | §8 | You |

> ### Nothing is self-healing — changed 2026-09-16
>
> `RebuildAllCapacityPolicies` used to run nightly and republish every capacity's rules from the tables, which made a forgotten call a **delay** rather than a permanent wrong state. **That schedule is gone.** It is now `MIG_RebuildAllCapacityPolicies`, manual, and runs only when somebody starts it.
>
> So the flows below are no longer a faster path to an outcome that would have happened anyway — **they are the only thing that publishes the change at all.** If one reports `Failed` and nobody acts, Fabric and Dataverse stay out of step indefinitely.
>
> They still do the second job they always did: **telling you whether the change actually did what you meant.** `NotEnabled` and `StillEnabled` are the whole value; a bare rebuild could not report either.
>
> **What no flow covers**, and now needs a human running `MIG_RebuildAllCapacityPolicies`: a deleted capacity (§2), a workspace **moved** between capacities, a `Policy Exceptions` row **hard-deleted** rather than deactivated, a `Policy Item Types` edit (§7), and any rule edited by hand in the portal. See **Q49** in [CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §7.

---

## 1. A capacity is created

**Run:** `InitializeCapacityPolicySet(capacityId, capacityDisplayName)` — normally from the provisioning app, not by hand.

It creates the policy set, registers it in `Capacity Policies`, builds rules, and **activates**.

### Order matters

The `ubsppcoe_Node` row must exist **before** this runs. Step 4b checks for it and returns `Failed` with nothing created if it is missing — which is the correct outcome, because a capacity registered without its `node` lookup is permanently un-rebuildable.

If provisioning routinely creates the capacity before the platform team's inventory record, expect `Failed` on first attempt and re-run once the Node row appears.

### The capacity is born locked

Rule 1 is a deny-all baseline, and a new capacity has no whitelisted workspaces — so **no governed item creation is possible on it** until a workspace is whitelisted through §3. Power BI items are unaffected.

That is the intended posture, but **the provisioning app must say so on screen.** Otherwise the first person to open the capacity files a bug, and someone "fixes" it by deactivating the policy set.

### Outcomes

| `Outcome` | Meaning |
|---|---|
| `Created` | Done. Capacity is governed and locked |
| `AlreadyExists` | A `Capacity Policies` row already exists. Nothing done |
| `Skipped` | Not found, not `Active`, or not an F SKU. P/A/EM/PP capacities cannot hold a policy set |
| `Failed` | No Node row, or activation failed. The message says which |

A `Failed` from activation still leaves the policy set **registered** — that is deliberate. Do not re-run blindly; check the row first, or you create a second policy set.

---

## 2. A capacity is deleted

**No flow does this yet.** It is manual, and it is the one event with no automation in place.

> ### There is now a design for it — [DeleteCapacityPolicySet.md](docs/flows/capacity-policies/DeleteCapacityPolicySet.md)
>
> It fires on the `ubsppcoe_Node` soft-delete, asks `GET /v1/capacities` whether the capacity is really gone, and then either **deletes** the policy set (`status = Deleted`) or, if Fabric still has the capacity, **deactivates only** (`status = Suspended`) and reports the disagreement.
>
> **It is a specification, not a built flow, and §0 of that document is an open decision** — it is the only flow in the design that removes enforcement, on a signal another team controls. Until it is agreed and built, the manual steps below are the procedure.

### What happens if you do nothing

| Artefact | State | Consequence |
|---|---|---|
| Policy set in the holder workspace | Orphaned | Clutters the workspace; counts against nothing |
| `Capacity Policies` row | Still there, `status = Active` | Every estate-wide rebuild keeps attempting it |
| `ubsppcoe_Node` row | **Soft-deleted** by the platform team — row and capacity GUID retained, a flag set | Our `node` lookup still resolves |

That last one is the correction that matters: the platform team's tables **soft-delete rather than hard-delete**, so the lookup does *not* go null and `RebuildCapacityPolicyRules` does *not* fail closed at Step 5a. It reads the workspaces quite happily and republishes rules to a policy set whose capacity is gone — so the capacity reports `Failed` on the **Fabric call**, with a `404` that looks like an outage, in the summary of **every** estate-wide rebuild until somebody cleans it up. See [MIG_RebuildAllCapacityPolicies.md](docs/flows/capacity-policies/MIG_RebuildAllCapacityPolicies.md) §4.

### Cleanup, in this order

1. **Deactivate** the policy set — `deactivate_policy_set.ps1 -WorkspaceId <holder> -PolicySetId <id>` in `C:\GIT\ubs-policies`. **Only while the capacity still exists** — see below
2. **Delete** the policy set item from the holder workspace
3. **Update** the `Capacity Policies` row to `status = Deleted`

> ### If the capacity is already deprovisioned, skip step 1 — tested 2026-09-13
>
> `deactivate` on a policy set whose capacity is gone returns **`404 NotFound — Capacity '<id>' not found`** (`isRetriable: false`). The 404 is on the **capacity**, not the set: the endpoint resolves the activation scope before doing anything, and the scope no longer exists.
>
> **`DELETE` on the policy set still works.** The set is present and addressable; only its activation scope is missing. So cleanup after a capacity that is already gone is **delete only** — a deactivate attempt would fail every time and change nothing.
>
> Deactivate first only when you are getting ahead of the deprovisioning, i.e. the capacity is still in `GET /v1/capacities`.

**Do not delete the row.** Update it. `SyncCapacityPolicySets` would report an untracked policy set if the row went before the item, and six months later the row is the only record that this capacity was ever governed, by which policy set, and when it was stood down — the same reasoning as [DeleteCapacityPolicySet.md](docs/flows/capacity-policies/DeleteCapacityPolicySet.md) §3c. Rows are cheap.

**Update the row after the Fabric call, not before.** A row saying `Deleted` with the item still present is an orphan that nothing will chase; a row still saying `Active` with the item gone is loud — the next estate-wide rebuild `404`s and you come back and finish the job.

---

## 3. A workspace is added, and should be whitelisted

**Run:** `AddWorkspaceToPolicy(capacityId, workspaceId)`.

### Preconditions, none of which this project controls

1. A `ubsppcoe_Workspace` row exists, with `ubsppcoe_workspaceid` = the **Fabric workspace GUID**
2. Its `Node` lookup points at the right capacity
3. **`ubsppcoe_oapenabled` = true**

That third one is the platform team's flag, not ours. **No flow in this design can set it** — capacity policy is a downstream consumer of it.

### Outcomes

| `Outcome` | Meaning | Rebuild ran? |
|---|---|---|
| `Added` | Whitelisted and rules republished | Yes |
| `NotFound` | No workspace row, or more than one | **No** |
| `WrongCapacity` | Its `Node` points elsewhere | **No** |
| `NotEnabled` | `ubsppcoe_oapenabled` is `false` or null | **No** |
| `Failed` | The rebuild failed. **Nothing will retry it** — re-run the flow, or `RebuildCapacityPolicyRules` for that capacity | Yes, and it failed |

**`NotEnabled` is the common one**, and it is not an error — it happens whenever provisioning runs ahead of whatever sets the flag. The remedy is with the platform team, and the message says so.

The flow deliberately **does not rebuild** on `NotEnabled`. Rebuilding would be harmless, but returning success after a no-op is how an app ends up telling someone they have access they do not have.

---

## 4. A workspace is deleted

**Run:** `RemoveWorkspaceFromPolicy(capacityId, workspaceId)`.

Works whether or not the `ubsppcoe_Workspace` row still exists — a missing row is `Removed`, because a workspace that does not exist is certainly not whitelisted. That is the deliberate asymmetry with §3, where a missing row is a refusal.

### Outcomes

| `Outcome` | Meaning |
|---|---|
| `Removed` | No longer qualifies, rules now say so |
| `StillEnabled` | `ubsppcoe_oapenabled` is **still true**, so it remains whitelisted. Rules republished as they stand |
| `StillExcepted` | An active `Policy Exceptions` row keeps it able to create **anything** on this capacity |
| `Failed` | Rules not republished. **Access may still be live, and nothing will retry** — re-run it |

**`StillEnabled` and `StillExcepted` are successes carrying a warning.** The flow did everything it could; the workspace is still in the rules. If the app shows a green tick for either, someone will believe access was removed when it was not.

They need different remedies: `StillEnabled` points at the platform team's flag; `StillExcepted` is our own table, so see §6.

### If you skip the call

A deleted workspace whose inventory row is also deleted disappears from the rules at the next rebuild of that capacity. If the row **survives** with `oapenabled = true`, its dead GUID stays in rule 2 indefinitely — harmless, because Fabric accepts a well-formed GUID that never matches, but it inflates `workspacecount` and consumes chunk slots.

That is accepted: `ubsppcoe_Workspace` is trusted as-is and no flow verifies a workspace still exists in Fabric. Pruning is the platform team's business.

---

## 5. A workspace moves to a different capacity

**Two whitelists change, so this is two calls, in this order:**

```
1  RemoveWorkspaceFromPolicy(oldCapacityId, workspaceId)
2  AddWorkspaceToPolicy(newCapacityId, workspaceId)
```

The old-capacity call is the one that gets forgotten, which is exactly why the operation is expressed as remove-then-add rather than as a single "move".

### It works whichever order the Node actually changed

If the platform team has **already** repointed the `Node`, step 1 still returns `Removed` and still republishes the old capacity's rules — dropping the workspace, because rules are keyed on the `Node` lookup rather than on any stored membership. Nothing needs to be done to the old capacity's data.

If the Node has **not** yet changed, step 2 returns `WrongCapacity` and does nothing. Re-run it after the move.

### Exceptions follow the workspace automatically

An active `Policy Exceptions` row is scoped to a capacity only by the workspace's current `Node`, so a move takes the exception with it: it leaves the old capacity's rule 3 and joins the new one's, on the next rebuild of each. **No row is edited, and no re-approval happens** — which is the intended behaviour, and worth knowing when approving an exception in the first place.

### If you forget the old-capacity call

The old capacity keeps granting until something rebuilds it, and **no flow fires on a move** — so nothing will, until you make the call above or someone runs `MIG_RebuildAllCapacityPolicies`. This used to self-heal overnight; since the rebuild lost its schedule it does not heal at all. For a move made to *take access away*, that is open-ended exposure rather than a day of it.

---

## 6. An exception is granted or revoked

**No flow writes `Policy Exceptions`.** Rows are created by hand in the maker portal or by the app. [RebuildOnExceptionChange](docs/flows/capacity-policies/RebuildOnExceptionChange.md) **reads** the row and republishes that capacity.

### To grant

1. Add a row: `ubsppcoe_workspaceid` = the Fabric workspace GUID, `ubsppcoe_active` = **Yes**, plus `ubsppcoe_reason` and `ubsppcoe_approvedby`
2. Nothing else. `RebuildOnExceptionChange` fires on the row and rebuilds that capacity within a minute — check its run for `Rebuilt`

`ubsppcoe_active` defaults to **No**. A row created with the toggle untouched is `null` and the rebuild's `eq true` filter excludes it — **a new exception that appears to do nothing is almost always an unset flag.**

The workspace must also have a `ubsppcoe_Workspace` row under the target capacity's Node, or the join in the rebuild finds nothing and no rule 3 entry appears. `RebuildOnExceptionChange` reports that as `NoWorkspace` — which is the check that catches a mistyped GUID.

### To revoke

1. Set `ubsppcoe_active` to **No**
2. Nothing else. The same flow fires and republishes

> **Do not delete the row — this is now operationally load-bearing, not just about history.** `RebuildOnExceptionChange` triggers on *added or modified*; a deleted row cannot be read, so the capacity it belonged to is not derivable and **no rebuild happens at all**. The workspace keeps unrestricted creation until somebody runs `MIG_RebuildAllCapacityPolicies` across the estate.
>
> Deactivating publishes in a minute. Deleting publishes never.

`ubsppcoe_oapenabled` is not consulted for rule 3 at all — an exception grants a workspace the platform team has not enabled. That is deliberate, and it is why this table is the only thing in the design that can widen access without them.

---

## 7. A governed item type is added or retired

Edit `Policy Item Types`, then rebuild. This is estate-wide, not per capacity.

**To add:** a row with `ubsppcoe_itemtype` set to the Fabric item type string, `ubsppcoe_active` = Yes.

**To retire:** set `ubsppcoe_active` to No. Note the flag is **per row** — if the same item type appears on several rows, clearing one removes nothing, because the others still contribute it.

Then run `MIG_RebuildAllCapacityPolicies` to apply it everywhere. **There is no scheduled run to fall back on** — until you run it, the edit changes nothing in Fabric.

> **Adding an item type restricts, it does not widen.** A newly governed type can only be created in whitelisted workspaces from the next rebuild onward. Expect refusals from teams that were creating it freely the day before, and announce it.

Rule 3 is unaffected either way — exception workspaces have no `item.type` condition and can create everything regardless.

---

## 8. Emergency — unlock a capacity

If a capacity is wrongly locked and people are blocked:

```powershell
# C:\GIT\ubs-policies
.\deactivate_policy_set.ps1 -WorkspaceId <holderWorkspaceId> -PolicySetId <policySetId>
```

Then set that capacity's `ubsppcoe_status` to `Inactive` in `Capacity Policies`.

Deactivated, the policy set enforces nothing and the capacity behaves as it did before governance. The rules stay published and correct, so re-activating later needs no rebuild.

**Do not delete the policy set** — that loses the registration and makes recovery a re-run of §1.

**Do not delete rules to unlock.** A policy with **zero** rules is not an empty allow-list; it is an unenforced policy — which happens to have the same effect, but leaves an activated set with no baseline that the next rebuild will silently re-lock.

### Then find out why

| Symptom | Likely cause |
|---|---|
| Whole capacity locked, `rulecount` = 1 | No workspace has `ubsppcoe_oapenabled = true`. §3 |
| One workspace refused, others fine | That workspace is not whitelisted, or its `Node` points elsewhere |
| Everything refused across many capacities | An item type was added in §7, or `Policy Item Types` was mis-seeded |
| Was working, now is not | Read `lasterror` and `lastrebuild` on the row, then the flow run history |

---

## What to watch, ongoing

| Signal | Where | Means |
|---|---|---|
| `MIG_RebuildAllCapacityPolicies` failure summary | Mail, after each manual run | Capacities whose rules are stale |
| `SyncCapacityPolicySets` drift report | Scheduled mail | A policy set deactivated, replaced, deleted or untracked |
| `lasterror` non-empty | `Capacity Policies` | That capacity's last rebuild failed |
| `lastrebuild` growing stale | `Capacity Policies` | Nothing has rebuilt that capacity. **No longer self-correcting** — an estate-wide rebuild only happens when someone runs it |
| `Inactive` + `Untracked` together | Drift report | **Someone created a replacement policy set and activated it.** The rebuild is now writing rules to a set that is not in force, and reporting success |

That last pair is the one to act on immediately. It is the only state in which everything reports healthy while the capacity is governed by something nobody in this system controls.
