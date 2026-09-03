# Capacity policy flows — plan

Plan for the Power Automate flows that operate the capacity-scoped `ItemCreation` policy sets currently managed by PowerShell in the **`ubs-policies`** repository (`C:\GIT\ubs-policies`).

**Architecture decided 2026-09-02: desired state in Dataverse, rules rebuilt with `replaceByPolicy`. Revised 2026-09-03: the desired state is the existing `ubsppcoe_Workspace` table, read-only.** Eight flows, two existing tables read and three new tables created. Nothing is built yet.

Source material reviewed 2026-09-02, all in `C:\GIT\ubs-policies`: `migrate_policy_sets.ps1`, `add_policy_rule.ps1`, `remove_workspace_from_rule.ps1`, `new_policy_set.ps1`, `list_policy_sets.ps1`, `FabricPolicies.Common.ps1`, `Migration-Steps.md`, and `docs/Fabric-Policies-REST-API-Reference.md`.

> **Different system, same tenant.** This is not the workspace-settings app. It shares the broker-SPN pattern and the Fabric REST conventions documented in [ARCHITECTURE.md](docs/ARCHITECTURE.md) §2 and [FLOWS.md](docs/FLOWS.md), and should reuse them, but it governs capacities rather than workspace settings.

---

## 1. What the scripts already establish

The flows must reproduce this model exactly, or they will fight the PowerShell.

| Fact | Source |
|---|---|
| One policy set per capacity, held in a **single holder workspace**, scoped to that capacity | `migrate_policy_sets.ps1` |
| Naming: `pol_<capacityDisplayName>`, sanitised — `_` for `\ / : * ? " < > \|`, trimmed, ≤256 chars | `ConvertTo-ItemDisplayName` |
| **Rule 1 — deny all.** There is no `Deny` effect, so this is an `Allow` rule that can never match: `workspace.id AnyOf [00000000-0000-0000-0000-000000000000]`. It grants nothing; it exists so that anything not allowed by a later rule is refused | `migrate_policy_sets.ps1` step 2 |
| **Rule 2..n — whitelist.** Two conditions, **ANDed**: `workspace.id AnyOf [≤49 ids]` **and** `item.type AnyOf [item types]` | same |
| **49 workspaces per rule**, then a new rule. Rules named `... (1/3)`, `(2/3)` | `-MaxWorkspacesPerRule` |
| **50 rules per policy** is the ceiling | `-MaxRulesPerPolicy`; API states "maximum 50 policies of each type" |
| Rule display names are capped at **60 characters** by the service | `Get-RuleDisplayName` |
| `PATCH policyRules/{id}` **replaces the whole `conditions` array** — rebuild every condition, not just the edited one | `remove_workspace_from_rule.ps1` |
| An empty `values` list is rejected (`PropertyMinCount`) — delete the rule instead | same |
| Only **F SKU** capacities can host a policy set | `-CapacitySkuPattern 'F*'` |
| Auth is **app-only client credentials**, scope `https://api.fabric.microsoft.com/.default` | `FabricPolicies.Common.ps1` |

Item types come from `fabric_item_types.csv`; workspace whitelists from `fabric_workspaces.csv`. **Neither file is reachable from a flow** — see §6.

---

## 2. Architecture — decided: Option B

**Decision 2026-09-02: desired state in Dataverse, rules always rebuilt with `replaceByPolicy`.**

Nothing edits a live rule in place. A single writer flow rebuilds every rule for a capacity in one call, exactly as `migrate_policy_sets.ps1` does, from whatever Dataverse says at that moment.

The original framing was *"add and remove write a row, then rebuild"*. The revised model of §3 removed the write — membership is derived from columns this project does not own — so what remains is the rebuild alone. The argument below is unaffected: it was always about how rules get published, not about who records the intent.

Why, against the incremental alternative that was considered and rejected:

| | Incremental `PATCH` (rejected) | Rebuild from table (chosen) |
|---|---|---|
| Concurrency | `PATCH` replaces the conditions array wholesale and the API has **no ETag or `If-Match`**. Two simultaneous adds and one silently disappears | A row-level problem in Dataverse, which has optimistic concurrency |
| Chunking at 49 | Re-derived on every call, from partial information | Recomputed from the full list every time, so it cannot drift |
| Rule names `(1/3)` | Go stale as rules come and go | Regenerated on every rebuild |
| Relationship to the PowerShell | Diverges | Same algorithm |
| Auditability | The policy set is the only record | The table is queryable, and answers flow 2 without calling Fabric |

The cost is a drift story if somebody edits rules by hand in the portal, or edits `FabricEnabled` without triggering a rebuild. Both are covered by the scheduled flows in §4.

### The invariant that makes this safe

`replaceByPolicy` **overwrites every rule of the given policy**, including rule 1. So:

> **The rebuild must never emit an empty rule list.** A capacity with zero whitelisted workspaces still gets rule 1 on its own. Rule 1 grants nothing, but its presence is what keeps the policy in force — a policy with no rules at all is not an empty allow-list, it is an unenforced policy, and the capacity silently unlocks.

This is the single most dangerous line of code in the design. It should be a hard-coded first element of the rules array, not a loop that happens to run at least once.

---

## 3. The tables

**Decision 2026-09-03: the desired state is not a new table.** It already exists, in the two tables the platform team maintains — `ubsppcoe_Workspace` and `ubsppcoe_Node`. The rebuild reads them directly. The planned `CapacityWorkspace` junction table is **dropped**; building it would have been a second copy of a list that is already mastered, with a synchronisation problem attached.

So: **two existing tables are read, three new tables are created** — `CapacityPolicy`, `PolicyItemType`, and `PolicyDrift` for §4's scan. Create the new ones in the maker portal, never by editing `customizations.xml`.

### `ubsppcoe_Workspace` and `ubsppcoe_Node` — the desired state (existing, **read-only**)

`ubsppcoe_Node` is the capacity. `ubsppcoe_Workspace` points at it through a lookup.

| Table | Column | Purpose here |
|---|---|---|
| `ubsppcoe_Node` | *primary name* | Node Name. **Not** the capacity id |
| `ubsppcoe_Node` | capacity GUID column | The Fabric capacity id. A **separate column**, not the row key — confirm its logical name in the maker portal |
| `ubsppcoe_Workspace` | *primary name* | Workspace Name |
| `ubsppcoe_Workspace` | workspace GUID column | The Fabric workspace id. Again a separate column, not the row key |
| `ubsppcoe_Workspace` | `Node` lookup | Which capacity the workspace belongs to |
| `ubsppcoe_Workspace` | `FabricEnabled` | Yes/No. **The filter that selects rule 2 members** |

> ## No flow in this design writes to `ubsppcoe_Workspace` or `ubsppcoe_Node`. Ever.
>
> **`FabricEnabled` is not ours.** It is an internal flag meaning *this workspace should get OAP settings and the rest of the Fabric treatment*. Capacity policy is one **consumer** of it, and a late one. Writing to it would repurpose a field that other systems already act on, and the blast radius of that is nothing to do with policy rules.
>
> Same for the `Node` lookup, and same for every other column on either table. These flows **read, filter, and rebuild**. If a build step ever wants an `Update a row` against a `ubsppcoe_` table, the design has been misread.
>
> The only Dataverse tables these flows write are the **new** ones this project creates — `CapacityPolicy` and `PolicyDrift`. *(See Q25: the instruction was "we do not insert or change any Dataverse data", and this design reads it as covering the platform team's tables. Writing our own state tables is still assumed, because the policy set id has to be stored somewhere. If it was meant literally, say so — the consequence is resolving every policy set from Fabric on every run, which §5 explains does not fit the Power Apps budget.)*

> **Neither GUID is a row key.** The primary column of both tables is a name, and the Fabric GUID sits in an ordinary column beside it. Two consequences the flows must respect:
>
> - A capacity id does **not** resolve to a Node row directly. The rebuild must look the Node row up by its capacity GUID column, take the row's `ubsppcoe_nodeid`, and only then filter workspaces. Two `List rows` calls, not one.
> - Filtering workspaces by capacity is a **lookup filter** — `_ubsppcoe_node_value eq <node row GUID>`, an unquoted GUID against the underscore-prefixed navigation column. Not `ubsppcoe_node eq '…'`, which is not a queryable column and returns a `400`.

### The membership rule

> A workspace goes into a **rule 2..n** whitelist for capacity *C* **if and only if** its `Node` lookup resolves to *C* **and** `FabricEnabled` is **Yes**.
>
> `FabricEnabled` = No, blank, or no Node at all → the workspace goes into **no rule**. Not a separate rule, not rule 1 — it is simply absent, and rule 1 refuses it by default.

That is the whole of the desired state, and it is **entirely derived**. There is no membership for a flow to write: no link row, no flag, nothing. Whitelisting is a query result, and the only action available to any flow is *recompute it and publish*.

**Rule 3 is out of scope and undefined.** An exception mechanism was briefly considered as a column on `ubsppcoe_Workspace`; it is not being built, and nothing in these flows reads or writes one. If per-workspace overrides are wanted later, that is a new decision — and given the boundary above, an override column would have to live on a table this project owns, not on `ubsppcoe_Workspace`.

### `CapacityPolicy` — one row per capacity (new)

| Column | Type | Purpose |
|---|---|---|
| `capacity_id` | Text | The Fabric capacity GUID. **The key the flows are invoked with** |
| `capacity_name` | Text | For display and for building the policy set name |
| `node` | **Lookup → `ubsppcoe_Node`** | The capacity's inventory record. Set by flow 1 |
| `policy_set_id` | Text | Written by flow 1. **This is the `capacity_id → policy_set_id` map** that makes §5 a non-problem |
| `policy_set_name` | Text | The `pol_<capacity>` display name as created. Lets the drift scan spot a rename without a `GET` per set |
| `status` | Text | Last known activation status |
| `last_rebuild` | DateTime | Timestamp of the last successful rebuild |
| `last_error` | Text | Blank when healthy |
| `workspace_count` | Whole number | Enabled workspaces as of the last rebuild. **Stamped by flow 0** |
| `rule_count` | Whole number | Rules published by the last rebuild, rule 1 included |

> **The two counts are a cache, and they exist for one reason: flow 2.** Counting enabled workspaces per Node at read time is a query per capacity, 200–300 of them inside a 120-second budget. The rebuild has already computed both numbers, so stamping them costs nothing and turns flow 2 into a single table read.
>
> They are **as of the last rebuild**, not live. A `FabricEnabled` change made this morning is not reflected until that capacity is rebuilt. Show them next to `last_rebuild` so the staleness is visible rather than implied — a count with no timestamp beside it will be read as current.

> ### Why this is a separate table and not columns on `ubsppcoe_Node`
>
> It is genuinely one row per capacity, so merging looks tempting. **Cardinality is the weakest argument here** — four things decide it, and all four point the same way.
>
> **Ownership.** `ubsppcoe_Node` belongs to the platform team. Adding our columns to it makes these flows *writers* to their table, which is the boundary set out at the top of this section. And not a one-off schema favour — `last_rebuild` and `last_error` are written on **every** rebuild.
>
> **Churn.** The nightly run would stamp 200–300 of their rows every night. That is audit history they did not ask for, and if anything of theirs triggers on a modified Node row, we would fire it nightly for every capacity in the estate.
>
> **Lifecycle.** A Node row exists for every capacity, including non-F SKUs and capacities we do not govern. A policy row exists only where a policy set does. Merged, every column is nullable and blank becomes ambiguous: not governed, governed but never rebuilt, or cleared by hand. Separate, the **presence of the row** is the answer.
>
> **Deletion.** If a Node row is deleted and recreated, merged columns take `policy_set_id` with them — leaving a live, activated policy set in Fabric that nothing maps back to. Our own row survives that.
>
> The reverse risk is worth naming too: Q18 already covers their schema changes breaking us. Putting our columns on their table would let our changes break them.

> ### The `node` lookup replaces a query, and is safe against renames
>
> A Dataverse lookup stores the target's **row GUID**, not its primary name. So the fact that `ubsppcoe_Node` is keyed on Node Name does not matter — renaming a node cannot break the link, which storing the name would.
>
> It also removes a step from the rebuild. Reading `CapacityPolicy` by `capacity_id` now yields the policy set id **and** the Node row GUID in one `List rows` call, so the separate "resolve the Node row by its capacity GUID column" query disappears. Filter workspaces directly on `_ubsppcoe_node_value eq <the lookup value>`.
>
> **The fail-closed rule is unchanged, only relocated.** An empty lookup means the same thing a missing Node row meant: we cannot see this capacity's workspaces, so **refuse** rather than rebuild from an empty list. Do not let a null lookup fall through to "zero enabled workspaces".

> ### What not to do with `policy_set_id`
>
> It is written **here and nowhere else**, and every flow that knows it returns it (§4). Do not also stamp it onto the `ubsppcoe_Node` row for convenience. That is a second copy of a key that nothing reconciles, and it makes us writers to their table for a display nicety.
>
> The `node` lookup already gives Node → policy navigation for free: related records work from the Node side without a single column being added to it.
>
> **`capacity_id` is a deliberate exception**, and worth being honest about. It duplicates the capacity GUID that also sits on the Node row. It stays because it is the key every flow is invoked with, and resolving a capacity id through a lookup on every call would cost more than it saves. If the Node's capacity GUID is ever corrected, our copy goes stale — a cheap check for the nightly scan to make.

### `PolicyItemType` — the governed item types (new)
| Column | Purpose |
|---|---|
| `item_type` | A Fabric `ItemType` enum value, sent verbatim |
| `item_name` | Documentation only |
| `active` | So a type can be retired without deleting history |

This is `fabric_item_types.csv`, live. Read by the rebuild flow on every run, so adding a governed item type is a row plus a rebuild, not a code change.

### What reading the existing tables costs

It removes a seeding problem and introduces a coupling one.

| | |
|---|---|
| **Gone** | No `CapacityWorkspace` to seed at cutover, and no way for it to drift from the platform team's list. The whole "unseeded table wipes the whitelist" failure mode disappears — see Q9 |
| **Gone** | No membership writes at all. Nothing in this design can put a workspace into a whitelist except the owning system setting `FabricEnabled` and `Node` |
| **New** | Whitelist changes originate **outside these flows entirely**. A bulk import, a CMDB sync, or someone setting `FabricEnabled` by hand changes what the rules should be, with no flow running. Every rebuild is therefore reactive, and the trigger question in §4 is the whole story |
| **New** | Moving a workspace's `Node` lookup silently moves it between whitelists. **Two** capacities then need rebuilding — the old one and the new one. The Power App that performs the move is the only thing that knows both, which is why it has to call remove against the old capacity and add against the new |
| **New** | A schema change to `ubsppcoe_Workspace` by another team can break the rebuild. Column renames, or `FabricEnabled` becoming a choice, would both do it quietly |
| **New** | `FabricEnabled` means *"this workspace gets the Fabric treatment"*, not *"this workspace is whitelisted for item creation"*. They coincide today. If the owning team ever widens or narrows the flag's meaning for OAP reasons, capacity policy changes with it and nobody will connect the two |

> **Cutover, restated.** Migration seeds ~200 existing policy sets from `fabric_workspaces.csv`. From the moment BAU starts, `FabricEnabled` is the truth. **Before cutover, reconcile the two: list every workspace in `fabric_workspaces.csv` whose row has `FabricEnabled` = No or missing, and every `FabricEnabled` = Yes workspace absent from the CSV.** The first rebuild of each capacity silently resolves every one of those disagreements in favour of Dataverse. That is correct behaviour and it is exactly why the differences must be seen and signed off first, not discovered afterwards as a capacity that stopped working.
>
> And since the flag cannot be edited to fix a disagreement, the reconciliation is not a to-do list for us — every correction is a request to whoever owns `ubsppcoe_Workspace`. Budget for that.

---

## 4. The eight flows

Build instructions are one file per flow in [flows/capacity-policies/](docs/flows/capacity-policies/). The summaries here are design intent; the per-flow files are the specification and win on any detail.

| Flow | Trigger | Purpose |
|---|---|---|
| [GetPolicyToken](docs/flows/capacity-policies/GetPolicyToken.md) | Manual (child) | App-only token for the policy SPN |
| [RebuildCapacityPolicyRules](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) | Manual (child) | **The only writer of rules.** Rebuilds one capacity from the tables |
| [InitializeCapacityPolicySet](docs/flows/capacity-policies/InitializeCapacityPolicySet.md) | Power Apps (V2) | Creates, registers, builds and activates a new capacity's policy set |
| [ListCapacityPolicySets](docs/flows/capacity-policies/ListCapacityPolicySets.md) | Power Apps (V2) | What the app reads. One table, no Fabric calls |
| [AddWorkspaceToPolicy](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) | Power Apps (V2) | Verify the workspace qualifies, then rebuild |
| [RemoveWorkspaceFromPolicy](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md) | Power Apps (V2) | Verify it no longer qualifies, then rebuild |
| [RebuildAllCapacityPolicies](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) | Recurrence | Nightly convergence of every capacity to the tables |
| [SyncCapacityPolicySets](docs/flows/capacity-policies/SyncCapacityPolicySets.md) | Recurrence | Detects drift the rebuild cannot fix |

**No flow writes a whitelist, because there is no whitelist to write.** Membership is derived from `FabricEnabled` and `Node` (§3), so flows 3 and 4 are **read-only against Dataverse**: they check that the state the caller assumes is actually true, then republish the rules.

### Why add and remove still exist as separate flows

Once the writes went, both reduced to a call to the rebuild, and collapsing them into one `RefreshCapacityPolicy` was considered and **rejected**.

A bare refresh cannot say anything about the workspace the caller just handled. It republishes rules and reports a count, so an app that then says *"workspace added to the policy"* is asserting something no flow checked — and a workspace whose `FabricEnabled` was never set produces exactly the same successful response. The validation is the value; the rebuild is the easy part.

Keeping the two names also keeps the app's vocabulary, and gives the **`Node` move** a natural shape: `RemoveWorkspaceFromPolicy` against the old capacity, `AddWorkspaceToPolicy` against the new one. Two whitelists change, so two calls are needed, and expressing it as remove-then-add makes the old-capacity call — the one that is otherwise forgotten — part of the obvious sequence.

### They validate in opposite directions

This is the part to get right, and it is not symmetry for its own sake.

| | `AddWorkspaceToPolicy` | `RemoveWorkspaceFromPolicy` |
|---|---|---|
| No row for that workspace | `NotFound`, **no rebuild** | `Removed`, **rebuild** |
| `Node` points at another capacity | `WrongCapacity`, no rebuild | `Removed`, rebuild |
| `FabricEnabled` not set | `NotEnabled`, no rebuild | `Removed`, rebuild |
| `FabricEnabled` set | `Added`, rebuild | `StillEnabled`, rebuild **and warn** |

Add **refuses** when reality does not match the request, because rebuilding and reporting success would tell a user they have access they do not have.

Remove **proceeds anyway**, because republishing current truth can only narrow or preserve access, never widen it. Refusing to rebuild on a row that looks odd would leave live access that somebody has asked to withdraw — the wrong way to be cautious for a leaver or an incident.

> **`NotEnabled` will be the common outcome, not an exceptional one.** It occurs whenever provisioning runs ahead of whatever sets `FabricEnabled`, and those are different systems. The app must present it as a normal state with a clear "who sets this" message, or it will generate tickets for something working as designed.

### Why both scheduled flows exist

The nightly rebuild makes Dataverse the source of truth in practice, not just in intent: hand-edited rules, a deleted rule, even a removed rule 1 are all overwritten within a day.

It also converges every `FabricEnabled` or `Node` change that reached Dataverse without anyone calling the refresh — which, since the flag is owned elsewhere and editable by bulk import, is not an edge case. **It is the only backstop for a whole class of change this project cannot see happen.**

What it **cannot** fix is drift in the policy set itself — ours deactivated, replaced, or deleted. In those cases the rebuild writes rules to a set that is not in force and reports success. That is precisely what the scan detects, and why the two are complementary rather than redundant.

### Flow 0 — `RebuildCapacityPolicyRules`

The **only** flow that writes rules. Flows 1, 3 and 4 call it.

| | |
|---|---|
| Trigger | **Manually trigger a flow** — `capacityId` |
| Returns | `outcome`, `policysetid`, `rulecount`, `workspacecount`, `message` |

> **The trigger must be *Manually trigger a flow*, not Power Apps (V2).** A child flow can only be invoked by `Run a Child Flow` if its trigger is the manual one. This solution already learned that the hard way — `GetGitOperationStatus` had to stop being a child flow when its trigger became `PowerAppV2` ([FLOWS.md](docs/FLOWS.md) §2).

1. Look up the `CapacityPolicy` row by `capacity_id`. Missing → `Failed`, tell the caller to run flow 1 first. This one read yields both `policy_set_id` and the `node` lookup value.
2. **The `node` lookup must be populated** → otherwise `Failed`. Blank means we cannot see which workspaces belong to this capacity, which is not the same as there being none.
3. Read the workspace IDs — `ubsppcoe_Workspace` where the `Node` lookup matches **and** `FabricEnabled` is Yes — and the active item types from `PolicyItemType`.
4. Build the rules array:
   - **Always** rule 1 first — `workspace.id AnyOf [sentinel]`, `Allow`.
   - Then chunk the workspaces into groups of 49; one rule per chunk, each with `workspace.id AnyOf [chunk]` **and** `item.type AnyOf [itemTypes]`, named `Approved Fabric item types for whitelisted workspaces (i/n)`, truncated to 60 characters.
5. If the total exceeds 50 rules → `Failed` before calling Fabric, so the caller gets a readable reason rather than a rejected request.
6. `POST /v1/workspaces/{holderWs}/policySets/{policySetId}/policyRules/replaceByPolicy` with `{ policy: "ItemCreation", policyRules: [...] }`.
7. Stamp `last_rebuild`, `last_error`, `workspace_count` and `rule_count` on `CapacityPolicy`. The last two are what flow 2 reads.

> **Step 2 failing closed is the point.** With a junction table, "no rows" and "no such capacity" were the same thing and both meant rule 1 alone. Reading a foreign table they are different, and an empty `node` lookup — never set, or nulled because the Node row was deleted — looks exactly like a capacity whose workspaces have all been disabled. Falling through would strip a live whitelist on the strength of somebody else's data-entry error and report success. Zero *enabled* workspaces under a Node that resolves is still rule 1 alone, and still correct.

Set **concurrency control to 1**. Two rebuilds of the same capacity overlapping would be last-writer-wins against Fabric even though the table is consistent.

### Flow 1 — `InitializeCapacityPolicySet`

Called by the capacity-provisioning Power App immediately after it creates a capacity.

| | |
|---|---|
| Trigger | Power Apps (V2) — `capacityId`, `capacityDisplayName` |
| Returns | `outcome` (`Created`, `AlreadyExists`, `Skipped`, `Failed`), `policysetid`, `message` |

1. Resolve the capacity — `GET /v1/capacities`; confirm it exists, is `Active`, and the SKU matches `F*`. A non-Fabric SKU returns `Skipped`, not `Failed`.
2. Row already in `CapacityPolicy` with a `policy_set_id` → `AlreadyExists`, stop.
3. **Resolve the `ubsppcoe_Node` row** for this capacity, by its capacity GUID column. No row, or more than one → `Failed`. This is the only flow that does this lookup; every later flow reads the resulting `node` lookup instead.
4. `POST /v1/workspaces/{holderWs}/policySets` with `{ displayName: "pol_<sanitised name>", description, creationPayload: { scope: { type: "Capacity", id: capacityId } } }`.
5. Handle **202** — create is a long-running operation. Poll `GET /v1/operations/{x-ms-operation-id}` to a terminal state, then read the result. A `201` carries the policy set directly.
6. Write the `CapacityPolicy` row: `capacity_id`, `capacity_name`, the **`node` lookup**, `policy_set_id` and `policy_set_name`.
7. Call `RebuildCapacityPolicyRules`. A brand-new capacity normally has no `FabricEnabled` workspaces yet, so that emits **rule 1 alone** — the intended default, and it exercises the empty path on day one.
8. Activate — `POST /v1/workspaces/{holderWs}/policySets/{id}/activate`, body `{ scopeId: capacityId, scopeType: "Capacity" }`. Tolerate `PolicySetIsAlreadyActive`. `PolicySetActivationConflict` means another set already owns the capacity and needs `allowReplace` — do **not** pass it blindly; surface it and let a human decide.

> **Step 3 must come before step 4.** Creating the policy set first and then discovering there is no Node row leaves an orphaned set in Fabric that nothing maps back to. Resolve the cheap, reversible thing before the expensive, irreversible one.

> **Confirmed: the capacity is born locked.** Rule 1 blocks creation of every governed item type; Power BI items are not governed and stay creatable. That is the intended posture.
>
> **What unlocks a workspace is `FabricEnabled`, not a flow.** No flow in this design can grant access — flow 3 only publishes what the platform team's data already says. So a newly provisioned capacity stays locked until its workspaces are Fabric-enabled by that separate process, and the provisioning app must say so plainly. Otherwise the first user to open a new capacity files a bug, and the team it needs to reach is not this one.

Sanitise the display name exactly as `ConvertTo-ItemDisplayName` does: replace `\ / : * ? " < > |` with `_`, strip control characters, trim, cap at 256, and strip trailing dots and spaces. Fabric rejects trailing dots silently.

### Flow 2 — `ListCapacityPolicySets`

| | |
|---|---|
| Trigger | Power Apps (V2), no inputs |
| Returns | `policysetsjson`, `errormessage` |

Reads `CapacityPolicy` and returns it. **No Fabric calls, and no second table.**

Per row: `capacityId`, `capacityName`, `policySetId`, `policySetName`, `status`, `workspaceCount`, `ruleCount`, `lastRebuild`, `lastError`.

> At **200–300 capacities**, doing this live against Fabric would mean a list plus a `GET` per set to resolve `properties.scope.id` — which the list response frequently omits. That will not fit the **120-second** Power Apps budget. Reading the table is the whole reason the table exists.

> **`workspaceCount` is read, not computed** (Q26). Counting enabled workspaces per Node here would be a query per capacity and would blow the same budget for a different reason. Flow 0 stamps the number on every rebuild; this flow reads the column.
>
> The consequence is that it is **as of the last rebuild**. Always render it beside `lastRebuild`, so a stale count reads as stale rather than as fact.

Return the payload as **one JSON string** and `ParseJSON` app-side. Keep every Respond field typed string — the trap that cost two flows a field each in [FLOWS.md](docs/FLOWS.md) §4 applies here too.

### Flow 3 — `AddWorkspaceToPolicy`

| | |
|---|---|
| Trigger | Power Apps (V2) — `capacityId`, `workspaceId` |
| Returns | `outcome` (`Added`, `NotFound`, `WrongCapacity`, `NotEnabled`, `Failed`), `message` |

1. Find the workspace row by its Fabric workspace GUID. No row, or more than one → `NotFound`, stop.
2. Resolve the capacity's Node row; the workspace's `Node` must match it → otherwise `WrongCapacity`, stop. Both inputs are GUIDs, and without this check swapping them rebuilds a capacity the caller never named.
3. `FabricEnabled` not set → `NotEnabled`, stop. Say who sets the flag.
4. Otherwise call `RebuildCapacityPolicyRules` and return `Added`.

No capacity-size checks. **These flows publish policies; they do not manage how many workspaces a capacity has.** Splitting into multiple rules at 49 is not a size check — it is ordinary behaviour, done on every rebuild (flow 0, step 4). The 50-rule service limit is guarded once, inside the rebuild, purely so an over-large capacity fails with a sentence rather than an opaque Fabric error — nothing warns, forecasts, or blocks ahead of it.

### Flow 4 — `RemoveWorkspaceFromPolicy`

| | |
|---|---|
| Trigger | Power Apps (V2) — `capacityId`, `workspaceId` |
| Returns | `outcome` (`Removed`, `StillEnabled`, `Failed`), `message` |

1. Find every row for that workspace GUID — plural, because a duplicate that is still enabled keeps it in the rules.
2. Any of them still `FabricEnabled` → `StillEnabled`, **and rebuild anyway**, warning that the workspace remains whitelisted.
3. Otherwise → `Removed`, rebuild. A missing row counts as removed.

There is no `NotFound`: a workspace with no row is not whitelisted, which is exactly what the caller wanted.

The cases that made this awkward incrementally are gone. There is no last-workspace-in-a-rule problem, because rules are not edited — they are regenerated, and a chunk that would be empty simply is not emitted. The `PropertyMinCount` error that `remove_workspace_from_rule.ps1` has to refuse cannot arise.

> **Neither flow rolls anything back, because neither writes anything.** A failed rebuild leaves Dataverse and the previously published rules exactly as they were. What changes is the reporting: after a failed remove, **access that should have been withdrawn is still live** until the nightly run, and the message has to say so. An operator withdrawing access for a leaver needs to know whether it took effect now or tonight.

---

## 5. Permissions

| Need | Where | Notes |
|---|---|---|
| SPN enabled for Fabric APIs | Tenant setting *Service principals can use Fabric APIs* | Hard prerequisite. Symptom when missing: a bare `401` on every call — same failure mode as PREREQUISITES A3/B1 in this repo |
| **Contributor on the holder workspace** | Fabric workspace role, on **one** workspace | See below |
| **Capacity Admin on every managed capacity** | Capacity role | Confirmed requirement for activating a policy set on that capacity |
| Capacity enumeration | `GET /v1/capacities` | Returns what the principal administers. The Power BI admin API route returns the whole tenant but needs admin rights |
| Fabric administrator | only for `/v1/admin/policySets/*` | **Not needed.** Those operations are tenant-scope only; nothing here uses them |

### Contributor is needed on the holder workspace only

Not on the workspaces being whitelisted. Every write path is `/v1/workspaces/{holderWs}/policySets/...`, where `{holderWs}` is the workspace holding the PolicySet **items**. A policy set is a Fabric item like any other, and creating or updating items needs Contributor on the workspace that holds them.

The workspaces in a whitelist are never touched. They are string values inside `predicate.values` — data, not resources. `migrate_policy_sets.ps1` demonstrates this: it takes one `-WorkspaceId` for the holder and reads every whitelisted GUID from a CSV without any permission check.

So the SPN needs Contributor on **one** workspace, Capacity Admin on the capacities, and **nothing at all** on the thousands of workspaces it grants access to.

> **The sting: whitelist GUIDs are never validated.** Fabric accepts any well-formed GUID in `workspace.id`. A typo, a deleted workspace, or a workspace from another tenant is stored happily and simply never matches. Nothing fails, and the owner is left with a policy that looks correct and denies them.
>
> Nothing in these flows can fix that, because the GUIDs come from `ubsppcoe_Workspace` and we do not write it. A stale or mistyped workspace GUID on an enabled row goes into the rules verbatim and matches nothing. **The validation has to happen where the row is created** — confirm the workspace exists and is actually assigned to that capacity. The API will not do it, and neither will we.

The scopes in the API reference (`Item.ReadWrite.All`, `Tenant.ReadWrite.All`) are **delegated** scopes. For an app-only token they are not the mechanism; Fabric-side roles are. Do not add Entra application permissions expecting them to help — the same finding as ARCHITECTURE §2.

---

## 6. Configuration

| Setting | Where | Value |
|---|---|---|
| Holder workspace ID | Environment variable | |
| Deny-all sentinel GUID | Environment variable | `00000000-0000-0000-0000-000000000000` |
| `MaxWorkspacesPerRule` | Environment variable | `49` |
| `MaxRulesPerPolicy` | Environment variable | `50` |
| Policy name | Environment variable | `ItemCreation` |
| Name prefix | Environment variable | `pol_` |
| Item types | `PolicyItemType` table | |
| Desired state | `ubsppcoe_Workspace` — `Node` lookup + `FabricEnabled` | Existing table, owned elsewhere |
| Capacity → Node row | `ubsppcoe_Node` — capacity GUID column | Existing table, owned elsewhere |
| Policy set map | `CapacityPolicy` table | |

The two limits are environment variables so that a service-side change does not need a flow edit.

Environment variables travel with a solution export; their **values** may not. Same caveat as OPEN-ISSUES §8.1 in this repo.

---

## 7. Decisions taken 2026-09-02

| # | Question | Answer |
|---|---|---|
| Q1 | Does flow 1 activate, locking the capacity? | **Yes.** Rule 1 stops everything except Power BI items. Intended posture; the provisioning app must say so |
| Q2 | How many capacities? | **200–300.** Confirms flow 2 must read the table, not Fabric |
| Q3 | Where does the item-type list live? | **Dataverse** — `PolicyItemType` |
| Q4 | A workspace in several rules? | Cannot arise: one capacity per workspace, one active policy per capacity — and the rebuild does a distinct regardless |
| Q5 | Rights on the capacity to activate? | **Capacity Admin** |
| Q6 | Which architecture? | **Option B** — rebuild the whole rule list |
| Q7 | What triggers flow 1? | A separate **capacity-provisioning Power App** calls it |
| Q8 | Do the scripts stay in use? | **No overlap.** `migrate_policy_sets.ps1` is a one-off for the ~200 existing policies; the flows are BAU afterwards |

### Decisions taken 2026-09-03

| # | Question | Answer |
|---|---|---|
| Q12 | Where does the workspace whitelist live? | **The existing `ubsppcoe_Workspace` table.** `Node` lookup gives the capacity, `FabricEnabled` = Yes gives membership. `CapacityWorkspace` is dropped — see §3 |
| Q13 | Are the Fabric GUIDs the row keys? | **No.** Both tables key on a name column and hold the GUID beside it, so the rebuild resolves capacity → Node row first, then filters workspaces on the lookup |
| Q14 | What about `FabricEnabled` = No? | **No rule at all.** Not a deny rule, not rule 1 — simply absent from the whitelist |
| Q15 | An exception column and rule 3? | **Dropped.** Not being built, and nothing reads or writes one — see §3 |
| Q20 | Should the flows return `policy_set_id`? | **Yes** — flows 0 and 1 return it. It is already in a variable, so it is free, and it puts the set that was written on the run record beside the outcome. **Not** flows 3 and 4: it would be blank on their two most common outcomes |
| Q21 | Should `policy_set_id` be copied onto `ubsppcoe_Node`? | **No.** A second uncontrolled copy of a key, and it would make these flows writers to a table they otherwise only read. A lookup on `CapacityPolicy` → `ubsppcoe_Node` gives the same navigation — see §3 |
| Q23 | May any flow write `FabricEnabled`, the `Node` lookup, or any `ubsppcoe_` column? | **No. Never.** `FabricEnabled` is an internal flag for OAP settings and the wider Fabric treatment; capacity policy is a downstream consumer of it. Whitelisting is derived, and no flow here can grant or withdraw it |
| Q24 | Do add and remove survive, given they can no longer write? | **Yes, as read-only validators.** Collapsing them into one `RefreshCapacityPolicy` was considered and rejected: a bare refresh cannot report on the workspace the caller named, so the app could not honestly say what it did — see §4 |
| Q22 | Separate `CapacityPolicy` table, or columns on `ubsppcoe_Node`? | **Separate table, with a `node` lookup to it.** Ownership, write churn, lifecycle and deletion all decide against merging — the 1:1 cardinality is the weakest argument in play. See §3 |
| Q28 | What does the `node` lookup buy? | Renames cannot break it (it stores the row GUID, not the name), Node → policy navigation works from their side with no column added to their table, and the rebuild drops a query. Flow 1 sets it; a blank lookup makes the rebuild **fail closed** |
| Q25 | May the flows write our own `CapacityPolicy` table? | **Yes.** "No Dataverse writes" covers the platform team's tables only. `CapacityPolicy` is this project's, and it has to be written — the policy set id, the health of the last rebuild and the cached counts exist nowhere else |
| Q26 | Aggregated `workspaceCount`, or stamped? | **Stamped** by flow 0 on every rebuild, into `workspace_count` and `rule_count`. Flow 2 becomes one table read. The counts are as of the last rebuild, so they are always shown beside `last_rebuild` |
| Q27 | Do we manage the workspaces-per-capacity limit? | **No**, but we do **chunk**. Rules are split at 49 workspaces on every rebuild, exactly as `migrate_policy_sets.ps1` does — that is normal operation. What we do not do is warn, forecast or pre-check as a capacity grows; the 50-rule service limit is guarded once inside the rebuild so it fails readably |

### Still open

Ordered by what they block. The first four are the ones that can stop the build.

| # | Question | Blocks |
|---|---|---|
| **Q19** | What are the actual logical names of the capacity GUID, workspace GUID, `Node` lookup and `FabricEnabled` columns? Every flow doc uses placeholders, and a wrong name in a filter can silently return **every** row | Flow build |
| **Q18** | Who owns `ubsppcoe_Workspace`, and how are we told before a column is renamed, `FabricEnabled` changes type, or its **meaning** widens for OAP reasons? Any of the three breaks or silently redefines the whitelist | Pre-launch |
| **Q9** | ~~Who seeds `CapacityWorkspace`?~~ **Resolved by Q12** — there is nothing to seed. Replaced by: who signs off the pre-cutover reconciliation between `fabric_workspaces.csv` and `FabricEnabled`, and who raises the corrections, given we cannot make them ourselves (§3)? | Cutover |
| **Q16** | Nothing triggers a rebuild when the owning system changes `FabricEnabled` or moves a `Node`. Nightly convergence is currently the **only** backstop. Acceptable, or does this need a Dataverse modified-row trigger on `ubsppcoe_Workspace`? | Post-launch |
| **Q17** | A `Node` move needs remove-then-add from the app. If it makes only the add call, the workspace stays whitelisted on the old capacity until the nightly run, and nothing reports it. Is that acceptable, or does the move need to be detected rather than declared? | Post-launch |
| **Q10** | Should the app confirm against Fabric that a workspace exists and is on the capacity? The `Node` lookup answers it from the CMDB's point of view, but the CMDB can lag the real assignment, and a stale GUID is published verbatim and matches nothing — see §5 | Flow 3 |
| **Q11** | What reconciles drift if someone edits rules in the portal? A scheduled compare-and-report, or compare-and-correct? | Post-launch |
| **Q29** | `capacity_id` on `CapacityPolicy` duplicates the capacity GUID on the Node row (§3). Should the nightly scan check the two still agree, or is a corrected Node GUID rare enough to ignore? | Post-launch |

---

## 8. Suggested build order

One document per flow in [flows/capacity-policies/](docs/flows/capacity-policies/); build them in this order.

1. **The three new tables** — `Capacity Policies`, `Policy Item Types`, `Policy Drift` — plus the environment variables in §6. Seed `Policy Item Types` from `fabric_item_types.csv`. Confirm the logical names of every column read from `ubsppcoe_Workspace` and `ubsppcoe_Node` (Q19) before writing any filter.
2. **[GetPolicyToken](docs/flows/capacity-policies/GetPolicyToken.md)** — client credentials, secret in a Key Vault-backed variable rather than inline. A **different** principal from the workspace-settings broker; do not reuse it.
3. **[SyncCapacityPolicySets](docs/flows/capacity-policies/SyncCapacityPolicySets.md)** — read-only against Fabric. Proves the token, the permissions and the Dataverse wiring with nothing at risk.
4. **[RebuildCapacityPolicyRules](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md)** — the writer. Test on one throwaway capacity. Exercise the **zero-enabled-workspace** case first and confirm it emits rule 1 alone; that is the path that silently unlocks a capacity if it is wrong. Then blank the policy row's **`node` lookup**, and confirm it fails rather than emitting rule 1.
5. **[InitializeCapacityPolicySet](docs/flows/capacity-policies/InitializeCapacityPolicySet.md)** — end to end on the same throwaway capacity, including activation. Confirms Capacity Admin is sufficient (§5).
6. **[AddWorkspaceToPolicy](docs/flows/capacity-policies/AddWorkspaceToPolicy.md)**, then **[RemoveWorkspaceFromPolicy](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md)** — build add first and copy it. Verify the validation outcomes before the happy path: `NotEnabled` on add and `StillEnabled` on remove are the two that a bare rebuild wrapper could not report, and they are the reason both flows exist.
7. **[ListCapacityPolicySets](docs/flows/capacity-policies/ListCapacityPolicySets.md)** — late because it reads the counts flow 0 stamps, so it is only meaningful once rebuilds have run. Nothing depends on it, but it is what the app actually renders.
8. **[RebuildAllCapacityPolicies](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md)** — last, and only once a single-capacity rebuild is trusted. Time a full run at production scale before relying on the schedule.

Read-only first, one capacity before many — the order `Migration-Steps.md` already prescribes for the scripts, and it applies unchanged here.

### Cutover

Migration and BAU must not overlap on the same capacity. For each capacity, in order:

1. `migrate_policy_sets.ps1` creates and activates the policy set.
2. **Seed `CapacityPolicy`** with the migrated `policy_set_id`.
3. **Reconcile `FabricEnabled` against `fabric_workspaces.csv`** and get the differences signed off — both directions: CSV entries whose row is not enabled, and enabled rows absent from the CSV.
4. Only then let the flows manage that capacity.

Steps 2 and 3 are not optional and not follow-ups. The first flow-driven rebuild takes `FabricEnabled` as the truth and resolves every disagreement in its favour, silently and without a diff. A capacity missing its `policy_set_id` fails safe — the rebuild refuses and says so. A capacity whose `FabricEnabled` flags disagree with the CSV does **not** fail; it quietly changes access. See §3 and Q9.
