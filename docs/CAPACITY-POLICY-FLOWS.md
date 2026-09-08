# Capacity policy flows — plan

Plan for the Power Automate flows that operate the capacity-scoped `ItemCreation` policy sets currently managed by PowerShell in the **`ubs-policies`** repository (`C:\GIT\ubs-policies`).

**Architecture decided 2026-09-02: desired state in Dataverse, rules rebuilt with `replaceByPolicy`. Revised 2026-09-03: the desired state is the existing `ubsppcoe_Workspace` table, read-only, plus an exception list this project owns. Revised 2026-09-07: the column that decides whitelist membership is `ubsppcoe_oapenabled`.** Eight flows, two existing tables read and four new tables created. Nothing is built yet.

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
| **Rule 3 — exceptions.** One condition and one only: `workspace.id AnyOf [≤49 ids]`, **no `item.type` condition**, so the listed workspaces may create **any** item type. Named `Unrestricted item creation for exception workspaces (i/n)`. Emitted only when the capacity has exceptions | `migrate_policy_sets.ps1` lines 559–580, `-ExceptionCsvPath`, `fabric_workspaces_exceptions.csv` |
| The exception list is **not cross-checked against the whitelist**. The two are independent lists and a workspace may be in either, both, or neither | `Migration-Steps.md` |
| **49 workspaces per rule**, then a new rule. Rules named `... (1/3)`, `(2/3)` — exceptions chunk the same way, with their own numbering | `-MaxWorkspacesPerRule` |
| **50 rules per policy** is the ceiling | `-MaxRulesPerPolicy`; API states "maximum 50 policies of each type" |
| Rule display names are capped at **60 characters** by the service | `Get-RuleDisplayName` |
| `PATCH policyRules/{id}` **replaces the whole `conditions` array** — rebuild every condition, not just the edited one | `remove_workspace_from_rule.ps1` |
| An empty `values` list is rejected (`PropertyMinCount`) — delete the rule instead | same |
| Only **F SKU** capacities can host a policy set | `-CapacitySkuPattern 'F*'` |
| Auth is **app-only client credentials**, scope `https://api.fabric.microsoft.com/.default` | `FabricPolicies.Common.ps1` |

Item types come from `fabric_item_types.csv`; workspace whitelists from `fabric_workspaces.csv`; exceptions from `fabric_workspaces_exceptions.csv`. **None of the three is reachable from a flow** — see §6.

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

The cost is a drift story if somebody edits rules by hand in the portal, or edits `OapEnabled` without triggering a rebuild. Both are covered by the scheduled flows in §4.

### The invariant that makes this safe

`replaceByPolicy` **overwrites every rule of the given policy**, including rule 1. So:

> **The rebuild must never emit an empty rule list.** A capacity with zero whitelisted workspaces still gets rule 1 on its own. Rule 1 grants nothing, but its presence is what keeps the policy in force — a policy with no rules at all is not an empty allow-list, it is an unenforced policy, and the capacity silently unlocks.

This is the single most dangerous line of code in the design. It should be a hard-coded first element of the rules array, not a loop that happens to run at least once.

---

## 3. The tables

**Decision 2026-09-03: the desired state is not a new table.** It already exists, in the two tables the platform team maintains — `ubsppcoe_Workspace` and `ubsppcoe_Node`. The rebuild reads them directly. The planned `CapacityWorkspace` junction table is **dropped**; building it would have been a second copy of a list that is already mastered, with a synchronisation problem attached.

So: **two existing tables are read, four new tables are created** — `CapacityPolicy`, `PolicyItemType`, `PolicyException`, and `PolicyDrift` for §4's scan. Create the new ones in the maker portal, never by editing `customizations.xml`.

> **Decision 2026-09-07: the new tables use the `ubsppcoe_` prefix too** — `ubsppcoe_CapacityPolicy`, `ubsppcoe_PolicyItemType`, `ubsppcoe_PolicyException`, `ubsppcoe_PolicyDrift`. This section keeps using the short conceptual names; the logical names are in [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md).
>
> **The cost is that the prefix stops being a boundary marker.** Ours and theirs now look alike, so every "never write this" rule below is stated by **table name**. Do not restate any of them as a rule about `ubsppcoe_` columns — that sentence is now true of tables we write on every rebuild.

> **The build sheet is [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md)** — every column, type, logical name and schema-level rule in one place. This section is the reasoning behind it; that file is what you build from.

### `ubsppcoe_Workspace` and `ubsppcoe_Node` — the desired state (existing, **read-only**)

`ubsppcoe_Node` is the capacity. `ubsppcoe_Workspace` points at it through a lookup.

| Table | Column | Purpose here |
|---|---|---|
| `ubsppcoe_Node` | `ubsppcoe_nodename` | Primary name — the Node's display name. **Not** the capacity id |
| `ubsppcoe_Node` | row key — `ubsppcoe_nodeuniqueid` | **This is the Fabric capacity id.** The platform team supplies it on create |
| `ubsppcoe_Workspace` | `ubsppcoe_workspacename` | Primary name — the workspace's display name |
| `ubsppcoe_Workspace` | workspace GUID column | The Fabric workspace id — **`ubsppcoe_workspaceid`**, which is *not* the row key |
| `ubsppcoe_Workspace` | `ubsppcoe_nodeid` — the `Node` lookup | Which capacity the workspace belongs to. Filtered as `_ubsppcoe_nodeid_value` |
| `ubsppcoe_Workspace` | `OapEnabled` — `ubsppcoe_oapenabled` | **Boolean. The filter that selects rule 2 members** |

> **`ubsppcoe_oapenabled` is a boolean, and it is three-valued in practice.** `true` puts the workspace in **rule 2**. `false` **and null** both leave it out of every whitelist — it is not added explicitly anywhere, and rule 1's deny-all is what then applies to it. *(Decision 2026-09-07, replacing the earlier `FabricEnabled` column: the flag the rebuild reads is `ubsppcoe_oapenabled`, and nothing else on the workspace row is consulted.)*
>
> A Dataverse filter of `ubsppcoe_oapenabled eq true` already excludes both `false` and null, so no separate null handling is needed anywhere. Do **not** write the negation as `ne true` in the hope of catching nulls in the other direction — nothing in this design needs the complement of the whitelist.

> ## No flow in this design writes to `ubsppcoe_Workspace` or `ubsppcoe_Node`. Ever.
>
> **`OapEnabled` is not ours.** It is an internal flag meaning *this workspace has OAP enabled and gets the rest of the Fabric treatment*. Capacity policy is one **consumer** of it, and a late one. Writing to it would repurpose a field that other systems already act on, and the blast radius of that is nothing to do with policy rules.
>
> Same for the `Node` lookup, and same for every other column on either table. These flows **read, filter, and rebuild**. If a build step ever wants an `Update a row` against **`ubsppcoe_Workspace` or `ubsppcoe_Node`**, the design has been misread. Name the two tables when you state this rule — since 2026-09-07 the prefix is shared with tables we do write.
>
> The only Dataverse tables these flows write are the **new** ones this project creates — `CapacityPolicy` and `PolicyDrift`. `PolicyException` is ours too, but no flow writes it either — see below. *(See Q25: the instruction was "we do not insert or change any Dataverse data", and this design reads it as covering the platform team's tables. Writing our own state tables is still assumed, because the policy set id has to be stored somewhere. If it was meant literally, say so — the consequence is resolving every policy set from Fabric on every run, which §5 explains does not fit the Power Apps budget.)*

> **The two tables treat their Fabric GUID in opposite ways, and both are surprising.** Three consequences the flows must respect:
>
> - **A capacity id *does* resolve to a Node row directly**, because `ubsppcoe_nodeuniqueid` is the Fabric capacity GUID. `Get a row by ID`, one call — not a `List rows` against some separate capacity column.
> - **The `Node` lookup on a workspace therefore holds a capacity id.** Filtering workspaces by capacity is `_ubsppcoe_nodeid_value eq <capacityId>`, an unquoted GUID against the underscore-prefixed navigation column. Not `ubsppcoe_nodeid eq '…'`, which is not a queryable column and returns a `400`.
> - **On the workspace table the two are separate, and named the wrong way round.** The row key is `ubsppcoe_workspaceuniqueid`; the Fabric workspace GUID is **`ubsppcoe_workspaceid`**. Everything published into `predicate.values` comes from the latter. A row key sent instead is a well-formed GUID that Fabric accepts and never matches — a denied capacity with no error anywhere. See [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §1.

### The membership rule

> A workspace goes into a **rule 2..n** whitelist for capacity *C* **if and only if** its `Node` lookup resolves to *C* **and** `ubsppcoe_oapenabled` is **`true`**.
>
> `false` **or null** means no rule — the workspace is **not added explicitly** to anything, and rule 1 refuses it by default. The two are not distinguished anywhere, and no flow needs to tell them apart.
>
> A workspace goes into **rule 3** for capacity *C* **if and only if** its `Node` lookup resolves to *C* **and** it has an active `PolicyException` row. `OapEnabled` is not consulted.
>
> No Node at all — never set, or the workspace row deleted — puts it in **no rule on any capacity**. Not a separate rule, not rule 1; simply absent, and rule 1 refuses it by default.

**Both rules are keyed on the same `Node` lookup, and that is the point.** A workspace that moves capacity, or is deleted, drops out of *every* rule of the old capacity on its next rebuild — rule 3 included. Nothing has to remember to clean it up.

Whitelist membership is **entirely derived**. Rule 3 membership is half derived: the grant is ours, the capacity it lands on is not.

### `PolicyException` — rule 3, the unrestricted list (new)

**Decision 2026-09-03, reversing an earlier one: exceptions are being built, as a table this project owns.** They were previously dropped as "out of scope and undefined" on the grounds that the only place suggested for them was a column on `ubsppcoe_Workspace`. That objection stands — and is exactly why this is a table of ours instead.

The mechanism is not new. `migrate_policy_sets.ps1` already has it, as `-ExceptionCsvPath` reading `fabric_workspaces_exceptions.csv`, and the flows must reproduce it or the migrated estate and the BAU rebuild will disagree on their first night.

| Column | Type | Purpose |
|---|---|---|
| *primary name* | Text | The workspace name, so the grid is readable. Not used by any flow |
| `workspace_id` | Text | The Fabric workspace GUID. **The whole key of the row** |
| `workspace_name` | Text | Documentation only |
| `reason` | Text | Why this workspace is unrestricted |
| `approved_by` | Text | Who agreed to it |
| `active` | Yes/No | So an exception can be revoked without deleting the history of it |

> ### There is no capacity column, deliberately
>
> An exception says *"this workspace may create anything"*. **Which capacity that applies to is not stored — it is read from the workspace's `Node` lookup at rebuild time**, exactly as the whitelist is.
>
> That is what makes a capacity move behave correctly with no cleanup step. The workspace leaves the old capacity's rule 3 the moment the old capacity is rebuilt, and joins the new capacity's rule 3 when that one is rebuilt. A deleted workspace leaves every rule everywhere. **The exception row survives the move**, so a workspace that comes back, or moves on again, is still unrestricted wherever it lands.
>
> A `capacity` lookup on this table would store the same fact twice and let the two disagree — and the copy that went stale would be ours, sitting in a rule on a capacity the workspace had left.

> ### The cost: an exception follows the workspace, without re-approval
>
> This is the part to be sure about. Someone approves an exception for a workspace on capacity A; the workspace is later moved to capacity B by a process that knows nothing about this table; it arrives on B able to create anything, and nobody on B agreed to that.
>
> The design accepts it, because the alternative — per-capacity approval — means every capacity move silently *revokes* an exception instead, and a workspace that legitimately needs one goes quietly restricted until someone notices it cannot create what it used to.
>
> **If re-approval on move is wanted, that is a `capacity` lookup on this table plus a rule that a mismatch drops the row from rule 3 — say so and it is a small change.** Until then, `PolicyException` is a list of permanently trusted workspaces, and the review of it is a periodic human one, not something a flow enforces.

#### What rule 3 actually grants

> Rule 3 is `workspace.id AnyOf [≤49 ids]` with **no `item.type` condition**, effect `Allow`. That is the whole rule.
>
> An excepted workspace can create **any** item type the `ItemCreation` policy governs. It does not get a wider item-type list — it gets **no item-type list**, which is why `PolicyItemType` is irrelevant to it. Retiring a governed type, or adding one, changes nothing for these workspaces.

Four consequences follow, and all four are worth stating before anyone builds it.

**An exception supersedes the whitelist rather than supplementing it.** Rules are all `Allow` and are ORed, so a workspace in both lists is simply unrestricted; the narrower rule 2 match adds nothing. There is no conflict to resolve and no precedence to implement. The PowerShell does not cross-check the two lists either, and neither should the rebuild.

**`OapEnabled` is not consulted, but the `Node` lookup is.** A row here grants a workspace the platform team has *not* OAP-enabled — that is deliberate, and it makes this **the only thing in the design that can widen access without the owning team**. What it cannot do is grant on a capacity the workspace does not belong to, because the capacity comes from their data and not from ours. `reason` and `approved_by` are columns because of the first half of that sentence, not niceties.

**Deriving the capacity also validates the GUID, which rule 2 cannot do.** §5 explains that Fabric accepts any well-formed GUID in `workspace.id` and silently never matches a wrong one. A mistyped GUID here has **no `ubsppcoe_Workspace` row**, so it resolves to no Node, so it reaches no capacity's rule 3 at all. That is a better failure than rule 2's — nothing is published — but it is still silent, so the screen that creates these rows should confirm the workspace exists rather than letting the rebuild swallow it.

**It costs rules against the 50-rule ceiling.** Total = 1 + `ceil(enabled / 49)` + `ceil(exceptions / 49)`. Exceptions are expected to be a handful per capacity, so this is usually one extra rule, but the rebuild's limit check must count them or an over-large capacity fails at Fabric with an opaque error instead of at the flow with a sentence.

#### No flow writes this table

**Decision: rows are created by hand in the maker portal, or by the app through the Dataverse connector.** No `AddPolicyException` / `RemovePolicyException` flow is being built. The rebuild reads the table; that is the whole of this project's involvement.

> **The consequence is a delay, and it is asymmetric.** Writing a row does not publish it — nothing triggers a rebuild. A new exception takes effect at the **nightly** run in §4, unless whoever wrote the row also calls a flow that rebuilds that capacity.
>
> Granting late is an inconvenience. **Revoking late is not.** Clearing `active`, or deleting the row, leaves the workspace able to create anything until the nightly rebuild runs. Anyone taking an exception away because of an incident has to force a rebuild rather than assume the row edit did it, and the screen that edits these rows should say so.
>
> This makes **Q16** — nothing triggers a rebuild on a data change — materially more pointed than it was when every input was owned elsewhere. It is now our own table that goes stale.

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
| `exception_count` | Whole number | Active `PolicyException` rows as of the last rebuild. Stamped by flow 0 |
| `rule_count` | Whole number | Rules published by the last rebuild, rule 1 included |

> **The three counts are a cache, and they exist for one reason: flow 2.** Counting enabled workspaces per Node at read time is a query per capacity, 200–300 of them inside a 120-second budget. The rebuild has already computed all three, so stamping them costs nothing and turns flow 2 into a single table read.
>
> They are **as of the last rebuild**, not live. An `OapEnabled` change made this morning, or an exception row added at lunchtime, is not reflected until that capacity is rebuilt. Show them next to `last_rebuild` so the staleness is visible rather than implied — a count with no timestamp beside it will be read as current.

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
> A Dataverse lookup stores the target's **row GUID**, not its primary name. So a node being renamed in `ubsppcoe_nodename` cannot break the link, which storing the name would.
>
> It also removes a step from the rebuild. Reading `CapacityPolicy` by `capacity_id` yields the policy set id **and** the Node row GUID in one `List rows` call, so no flow but flow 1 touches `ubsppcoe_Node` at all. Filter workspaces directly on `_ubsppcoe_nodeid_value eq <the lookup value>`.
>
> Since Q41, that lookup value is the capacity id itself, so the rebuild could equally filter on its own trigger input. Keep reading it from the row: it is the value that proves a Node was linked, and it localises the assumption in one place if the platform team ever changes how Nodes are keyed.
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

This is `fabric_item_types.csv`, live. Read by the rebuild flow on every run, so adding a governed item type is a row plus a rebuild, not a code change. **It has no effect on rule 3**, which carries no `item.type` condition at all.

### What reading the existing tables costs

It removes a seeding problem and introduces a coupling one.

| | |
|---|---|
| **Gone** | No `CapacityWorkspace` to seed at cutover, and no way for it to drift from the platform team's list. The whole "unseeded table wipes the whitelist" failure mode disappears — see Q9 |
| **Gone** | No membership writes at all. Nothing in this design can put a workspace into a **whitelist** except the owning system setting `OapEnabled` and `Node`. Rule 3 is the deliberate exception to that, and it is a separate list rather than a way into rule 2 |
| **New** | Whitelist changes originate **outside these flows entirely**. A bulk import, a CMDB sync, or someone setting `OapEnabled` by hand changes what the rules should be, with no flow running. Every rebuild is therefore reactive, and the trigger question in §4 is the whole story |
| **New** | Moving a workspace's `Node` lookup silently moves it between whitelists. **Two** capacities then need rebuilding — the old one and the new one. The Power App that performs the move is the only thing that knows both, which is why it has to call remove against the old capacity and add against the new |
| **New** | A schema change to `ubsppcoe_Workspace` by another team can break the rebuild. Column renames, or `ubsppcoe_oapenabled` ceasing to be a boolean, would both do it quietly |
| **New** | `OapEnabled` means *"this workspace gets the Fabric treatment"*, not *"this workspace is whitelisted for item creation"*. They coincide today. If the owning team ever widens or narrows the flag's meaning for OAP reasons, capacity policy changes with it and nobody will connect the two |

> **Cutover, restated.** Migration seeds ~200 existing policy sets from `fabric_workspaces.csv`. From the moment BAU starts, `OapEnabled` is the truth. **Before cutover, reconcile the two: list every workspace in `fabric_workspaces.csv` whose row has `ubsppcoe_oapenabled` `false` or null, and every `ubsppcoe_oapenabled` = `true` workspace absent from the CSV.** The first rebuild of each capacity silently resolves every one of those disagreements in favour of Dataverse. That is correct behaviour and it is exactly why the differences must be seen and signed off first, not discovered afterwards as a capacity that stopped working.
>
> **`fabric_workspaces_exceptions.csv` needs the same treatment, and has no fallback.** Rule 3 membership is not derived from anything, so an exception that was migrated but never copied into `PolicyException` disappears on the first rebuild — quietly, and from a workspace that until then could create anything.
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

**No flow writes a whitelist, because there is no whitelist to write.** Membership is derived from `OapEnabled` and `Node` (§3), so flows 3 and 4 are **read-only against Dataverse**: they check that the state the caller assumes is actually true, then republish the rules. **No flow writes `PolicyException` either** — that table is ours, but rows are created by hand or by the app, and every flow here only reads it.

### Why add and remove still exist as separate flows

Once the writes went, both reduced to a call to the rebuild, and collapsing them into one `RefreshCapacityPolicy` was considered and **rejected**.

A bare refresh cannot say anything about the workspace the caller just handled. It republishes rules and reports a count, so an app that then says *"workspace added to the policy"* is asserting something no flow checked — and a workspace whose `OapEnabled` was never set produces exactly the same successful response. The validation is the value; the rebuild is the easy part.

Keeping the two names also keeps the app's vocabulary, and gives the **`Node` move** a natural shape: `RemoveWorkspaceFromPolicy` against the old capacity, `AddWorkspaceToPolicy` against the new one. Two whitelists change, so two calls are needed, and expressing it as remove-then-add makes the old-capacity call — the one that is otherwise forgotten — part of the obvious sequence.

### They validate in opposite directions

This is the part to get right, and it is not symmetry for its own sake.

| | `AddWorkspaceToPolicy` | `RemoveWorkspaceFromPolicy` |
|---|---|---|
| No row for that workspace | `NotFound`, **no rebuild** | `Removed`, **rebuild** |
| `Node` points at another capacity | `WrongCapacity`, no rebuild | `Removed`, rebuild |
| `OapEnabled` `false` or null | `NotEnabled`, no rebuild | `Removed`, rebuild |
| `OapEnabled` `true` | `Added`, rebuild | `StillEnabled`, rebuild **and warn** |
| An active `PolicyException` row, **workspace still on this capacity** | `Added`, rebuild — it was already unrestricted | `StillExcepted`, rebuild **and warn** |
| An active `PolicyException` row, **workspace already moved or deleted** | `NotFound` / `WrongCapacity` as above | `Removed` — the rebuild drops it from rule 3 too |

Add **refuses** when reality does not match the request, because rebuilding and reporting success would tell a user they have access they do not have.

Remove **proceeds anyway**, because republishing current truth can only narrow or preserve access, never widen it. Refusing to rebuild on a row that looks odd would leave live access that somebody has asked to take away — the wrong way to be cautious for a leaver or an incident.

> **`NotEnabled` will be the common outcome, not an exceptional one.** It occurs whenever provisioning runs ahead of whatever sets `OapEnabled`, and those are different systems. The app must present it as a normal state with a clear "who sets this" message, or it will generate tickets for something working as designed. **A null flag and an explicit `false` both land here**, and the message should not try to tell them apart — neither is whitelisted.

> **`StillExcepted` is the one that must not be reported as a removal.** An excepted workspace is in rule 3, which never looks at `OapEnabled` — so clearing the flag takes it out of rule 2 and changes nothing about what it can create. Remove must check `PolicyException` and say so, or the app confirms something that did not happen.
>
> It only arises while the workspace is **still on this capacity**. The usual reasons for calling remove — a capacity move or a deleted workspace — take the `Node` with them, and the rebuild then drops the workspace from rule 2 and rule 3 alike. `StillExcepted` is the narrower case of somebody clearing `OapEnabled` and expecting that to be the end of it.

### Why both scheduled flows exist

The nightly rebuild makes Dataverse the source of truth in practice, not just in intent: hand-edited rules, a deleted rule, even a removed rule 1 are all overwritten within a day.

It also converges every `OapEnabled` or `Node` change that reached Dataverse without anyone calling the refresh — which, since the flag is owned elsewhere and editable by bulk import, is not an edge case. **It is the only backstop for a whole class of change this project cannot see happen.**

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
3. Read the workspace IDs — `ubsppcoe_Workspace` where the `Node` lookup matches **and** `ubsppcoe_oapenabled` is `true` — the active item types from `PolicyItemType`, and the exception workspaces: active `PolicyException` rows whose workspace is **on this capacity's Node**, OAP-enabled or not.
4. Build the rules array:
   - **Always** rule 1 first — `workspace.id AnyOf [sentinel]`, `Allow`.
   - Then chunk the workspaces into groups of 49; one rule per chunk, each with `workspace.id AnyOf [chunk]` **and** `item.type AnyOf [itemTypes]`, named `Approved Fabric item types for whitelisted workspaces (i/n)`, truncated to 60 characters.
   - Then chunk the exceptions the same way; one rule per chunk with `workspace.id AnyOf [chunk]` **and nothing else**, named `Unrestricted item creation for exception workspaces (i/n)`. No exceptions → no rule 3 at all.
5. If the total exceeds 50 rules — `1 + ceil(enabled/49) + ceil(exceptions/49)` — → `Failed` before calling Fabric, so the caller gets a readable reason rather than a rejected request.
6. `POST /v1/workspaces/{holderWs}/policySets/{policySetId}/policyRules/replaceByPolicy` with `{ policy: "ItemCreation", policyRules: [...] }`.
7. Stamp `last_rebuild`, `last_error`, `workspace_count`, `exception_count` and `rule_count` on `CapacityPolicy`. The counts are what flow 2 reads.

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
3. **Resolve the `ubsppcoe_Node` row** for this capacity — a direct `Get a row by ID` on the capacity GUID, since that is the Node row key. No row → `Failed`. This is the only flow that does this lookup; every later flow reads the resulting `node` lookup instead.
4. `POST /v1/workspaces/{holderWs}/policySets` with `{ displayName: "pol_<sanitised name>", description, creationPayload: { scope: { type: "Capacity", id: capacityId } } }`.
5. Handle **202** — create is a long-running operation. Poll `GET /v1/operations/{x-ms-operation-id}` to a terminal state, then read the result. A `201` carries the policy set directly.
6. Write the `CapacityPolicy` row: `capacity_id`, `capacity_name`, the **`node` lookup**, `policy_set_id` and `policy_set_name`.
7. Call `RebuildCapacityPolicyRules`. A brand-new capacity normally has no OAP-enabled workspaces yet, so that emits **rule 1 alone** — the intended default, and it exercises the empty path on day one.
8. Activate — `POST /v1/workspaces/{holderWs}/policySets/{id}/activate`, body `{ scopeId: capacityId, scopeType: "Capacity" }`. Tolerate `PolicySetIsAlreadyActive`. `PolicySetActivationConflict` means another set already owns the capacity and needs `allowReplace` — do **not** pass it blindly; surface it and let a human decide.

> **Step 3 must come before step 4.** Creating the policy set first and then discovering there is no Node row leaves an orphaned set in Fabric that nothing maps back to. Resolve the cheap, reversible thing before the expensive, irreversible one.

> **Confirmed: the capacity is born locked.** Rule 1 blocks creation of every governed item type; Power BI items are not governed and stay creatable. That is the intended posture.
>
> **What unlocks a workspace is `OapEnabled`, not a flow.** No flow in this design can grant access — flow 3 only publishes what the platform team's data already says. So a newly provisioned capacity stays locked until its workspaces are OAP-enabled by that separate process, and the provisioning app must say so plainly. Otherwise the first user to open a new capacity files a bug, and the team it needs to reach is not this one.

Sanitise the display name exactly as `ConvertTo-ItemDisplayName` does: replace `\ / : * ? " < > |` with `_`, strip control characters, trim, cap at 256, and strip trailing dots and spaces. Fabric rejects trailing dots silently.

### Flow 2 — `ListCapacityPolicySets`

| | |
|---|---|
| Trigger | Power Apps (V2), no inputs |
| Returns | `policysetsjson`, `errormessage` |

Reads `CapacityPolicy` and returns it. **No Fabric calls, and no second table.**

Per row: `capacityId`, `capacityName`, `policySetId`, `policySetName`, `status`, `workspaceCount`, `exceptionCount`, `ruleCount`, `lastRebuild`, `lastError`.

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
3. `ubsppcoe_oapenabled` is `false` or null → `NotEnabled`, stop. Say who sets the flag.
4. Otherwise call `RebuildCapacityPolicyRules` and return `Added`.

No capacity-size checks. **These flows publish policies; they do not manage how many workspaces a capacity has.** Splitting into multiple rules at 49 is not a size check — it is ordinary behaviour, done on every rebuild (flow 0, step 4). The 50-rule service limit is guarded once, inside the rebuild, purely so an over-large capacity fails with a sentence rather than an opaque Fabric error — nothing warns, forecasts, or blocks ahead of it.

### Flow 4 — `RemoveWorkspaceFromPolicy`

| | |
|---|---|
| Trigger | Power Apps (V2) — `capacityId`, `workspaceId` |
| Returns | `outcome` (`Removed`, `StillEnabled`, `StillExcepted`, `Failed`), `message` |

1. Find every row for that workspace GUID — plural, because a duplicate that is still enabled keeps it in the rules.
2. Any of them still `ubsppcoe_oapenabled` = `true` **and still on this capacity** → `StillEnabled`, **and rebuild anyway**, warning that the workspace remains whitelisted.
3. Still on this capacity **and** carrying an active `PolicyException` row → `StillExcepted`, rebuild anyway, and warn that it can still create **anything** — the exception ignores `OapEnabled`.
4. Otherwise → `Removed`, rebuild. A missing row, or a `Node` that now points elsewhere, counts as removed — and takes the workspace out of **every** rule of this capacity, rule 3 included.

> **The common call is a capacity move or a workspace deletion**, and in both the `Node` has already changed or gone. That is precisely the case where nothing is left behind: rule 2 and rule 3 are both keyed on the `Node` lookup, so one rebuild clears the workspace out of both. The `PolicyException` row itself stays — it is a statement about the workspace, not about the capacity it happened to be on, so if the workspace turns up on another capacity the exception applies there once that capacity is rebuilt.

There is no `NotFound`: a workspace with no row is not whitelisted, which is exactly what the caller wanted.

The cases that made this awkward incrementally are gone. There is no last-workspace-in-a-rule problem, because rules are not edited — they are regenerated, and a chunk that would be empty simply is not emitted. The `PropertyMinCount` error that `remove_workspace_from_rule.ps1` has to refuse cannot arise.

> **Neither flow rolls anything back, because neither writes anything.** A failed rebuild leaves Dataverse and the previously published rules exactly as they were. What changes is the reporting: after a failed remove, **access that should be gone is still live** until the nightly run, and the message has to say so. An operator taking access away for a leaver needs to know whether it took effect now or tonight.

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
| Exceptions — rule 3 | `PolicyException` table | Ours, written by hand or by the app. No flow writes it |
| Desired state | `ubsppcoe_Workspace` — `Node` lookup + `ubsppcoe_oapenabled` | Existing table, owned elsewhere |
| Capacity → Node row | `ubsppcoe_Node` — the row key **is** the capacity GUID | Existing table, owned elsewhere |
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
| Q12 | Where does the workspace whitelist live? | **The existing `ubsppcoe_Workspace` table.** `Node` lookup gives the capacity, `ubsppcoe_oapenabled` = `true` gives membership. `CapacityWorkspace` is dropped — see §3 |
| Q13 | Are the Fabric GUIDs the row keys? | **On `ubsppcoe_Node`, yes** — `ubsppcoe_nodeuniqueid` is the capacity GUID, so a capacity resolves to a Node row in one direct read. **On `ubsppcoe_Workspace`, no** — the key is `ubsppcoe_workspaceuniqueid` and the Fabric id is `ubsppcoe_workspaceid`. Revised 2026-09-07; see Q40 and Q41 |
| Q14 | What about `ubsppcoe_oapenabled` = `false`, or null? | **No rule at all.** Not a deny rule, not an explicit entry in rule 1 — simply absent from the whitelist, and rule 1's deny-all is what catches it. `false` and null are treated identically |
| Q15 | An exception column and rule 3? | **Reinstated, revised.** Rule 3 is being built — but as `PolicyException`, a table this project owns, **not** a column on `ubsppcoe_Workspace`. See §3 and Q30–Q32 |
| Q20 | Should the flows return `policy_set_id`? | **Yes** — flows 0 and 1 return it. It is already in a variable, so it is free, and it puts the set that was written on the run record beside the outcome. **Not** flows 3 and 4: it would be blank on their two most common outcomes |
| Q21 | Should `policy_set_id` be copied onto `ubsppcoe_Node`? | **No.** A second uncontrolled copy of a key, and it would make these flows writers to a table they otherwise only read. A lookup on `CapacityPolicy` → `ubsppcoe_Node` gives the same navigation — see §3 |
| Q23 | May any flow write `OapEnabled`, the `Node` lookup, or any column on the platform team's two tables? | **No. Never.** `ubsppcoe_oapenabled` is an internal flag for OAP settings and the wider Fabric treatment; capacity policy is a downstream consumer of it. Whitelisting is derived, and no flow here can set or clear it. **Scope this to `ubsppcoe_Workspace` and `ubsppcoe_Node` by name** — since Q42 the prefix covers our own tables too |
| Q24 | Do add and remove survive, given they can no longer write? | **Yes, as read-only validators.** Collapsing them into one `RefreshCapacityPolicy` was considered and rejected: a bare refresh cannot report on the workspace the caller named, so the app could not honestly say what it did — see §4 |
| Q22 | Separate `CapacityPolicy` table, or columns on `ubsppcoe_Node`? | **Separate table, with a `node` lookup to it.** Ownership, write churn, lifecycle and deletion all decide against merging — the 1:1 cardinality is the weakest argument in play. See §3 |
| Q28 | What does the `node` lookup buy? | Renames cannot break it (it stores the row GUID, not the name), Node → policy navigation works from their side with no column added to their table, and the rebuild drops a query. Flow 1 sets it; a blank lookup makes the rebuild **fail closed** |
| Q25 | May the flows write our own `CapacityPolicy` table? | **Yes.** "No Dataverse writes" covers the platform team's tables only. `CapacityPolicy` is this project's, and it has to be written — the policy set id, the health of the last rebuild and the cached counts exist nowhere else |
| Q26 | Aggregated `workspaceCount`, or stamped? | **Stamped** by flow 0 on every rebuild, into `workspace_count`, `exception_count` and `rule_count`. Flow 2 becomes one table read. The counts are as of the last rebuild, so they are always shown beside `last_rebuild` |
| Q27 | Do we manage the workspaces-per-capacity limit? | **No**, but we do **chunk**. Rules are split at 49 workspaces on every rebuild, exactly as `migrate_policy_sets.ps1` does — that is normal operation. What we do not do is warn, forecast or pre-check as a capacity grows; the 50-rule service limit is guarded once inside the rebuild so it fails readably |
| Q30 | What does rule 3 grant? | **Unrestricted item creation.** `workspace.id AnyOf [≤49]` with **no `item.type` condition** — confirmed against `migrate_policy_sets.ps1` lines 559–580. It supersedes rule 2 rather than supplementing it, and `PolicyItemType` does not apply to it |
| Q31 | Where do exceptions live, and does an exception need `OapEnabled`? | **`PolicyException`, a new table of ours, keyed on the workspace GUID alone. No** — an exception ignores `ubsppcoe_oapenabled`. It does **not** ignore the `Node` lookup: the capacity an exception applies to is derived from it, exactly as the whitelist is |
| Q32 | Who writes `PolicyException`? | **By hand in the maker portal, or the app through the Dataverse connector. No flow.** The rebuild only reads it. The cost is that a row edit does not publish itself — taking an exception away in particular is not live until a rebuild runs, see §3 and Q16 |
| Q34 | What happens to an exception when the workspace moves capacity or is deleted? | **It leaves the old capacity's rule 3 on the next rebuild, because rule 3 is keyed on the `Node` lookup — and the row stays.** So the workspace is unrestricted on whichever capacity it lands on, with no re-approval. Accepted deliberately; the alternative silently revokes exceptions on every move. See the two boxes in §3 |

### Decisions taken 2026-09-07

| # | Question | Answer |
|---|---|---|
| Q36 | Which column decides rule 2 membership? | **`ubsppcoe_oapenabled`**, a boolean on `ubsppcoe_Workspace`. It replaces the `FabricEnabled` column every earlier revision of this document named; that column is no longer read by anything here |
| Q37 | What does `true` mean, and what do `false` and null mean? | `true` → the workspace is chunked into **rule 2..n** for its Node's capacity. `false` **and null** → it is **not added to any rule**, explicitly or otherwise, and rule 1's deny-all refuses it. The two are not distinguished by any flow or message |
| Q38 | Does null need handling in the filters? | **No.** `ubsppcoe_oapenabled eq true` already excludes `false` and null in Dataverse `$filter`. Do not add `and ubsppcoe_oapenabled ne null`, and do not use `ne true` anywhere — nothing needs the complement of the whitelist |
| Q39 | Does this change rule 3? | **No.** Exceptions never consulted the flag and still do not. Only the `Node` lookup and an active `PolicyException` row decide rule 3 |
| Q40 | What are the row keys and the Fabric workspace GUID column? | **Row keys are `ubsppcoe_nodeuniqueid` and `ubsppcoe_workspaceuniqueid`. The Fabric workspace GUID is `ubsppcoe_workspaceid`** — the opposite of the Dataverse convention, and the opposite of what this document assumed until now. Every filter and every value published to Fabric uses `ubsppcoe_workspaceid` |
| Q41 | And the Fabric capacity GUID on `ubsppcoe_Node`? | **It is the row key, `ubsppcoe_nodeuniqueid`.** There is no separate column. A capacity id resolves to a Node row with `Get a row by ID`, and `_ubsppcoe_nodeid_value` on a workspace row is therefore itself a capacity id — workspaces can be filtered by capacity in one hop |
| Q42 | What prefix do the four new tables use? | **`ubsppcoe_`, the same as the platform team's.** Not `crbab_`, which belongs to the workspace-settings canvas app and is unrelated to policy rules. The consequence is that **the prefix no longer indicates ownership**: state every read-only rule by table name. Two logical names — `ubsppcoe_workspaceid` and `ubsppcoe_workspacename` — now exist on two tables each, both times meaning the same thing, so the collisions are harmless; see [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §0 |
| Q43 | What is the `Node` lookup on `ubsppcoe_Workspace`? | **`ubsppcoe_nodeid`, filtered and read as `_ubsppcoe_nodeid_value`.** This closes Q19 — no name is outstanding. Note the near miss with `ubsppcoe_nodeuniqueid` (the Node row key) and with our own `ubsppcoe_node` on `CapacityPolicy`: three similar names, all resolving to the same capacity GUID |

### Still open

Ordered by what they block. **Nothing here blocks the flow build any more** — Q19, the last one that did, closed on 2026-09-07 when the final column name was confirmed.

| # | Question | Blocks |
|---|---|---|
| **Q18** | Who owns `ubsppcoe_Workspace`, and how are we told before a column is renamed, `ubsppcoe_oapenabled` stops being a boolean, or its **meaning** widens for OAP reasons? Any of the three breaks or silently redefines the whitelist | Pre-launch |
| **Q9** | ~~Who seeds `CapacityWorkspace`?~~ **Resolved by Q12** — there is nothing to seed. Replaced by: who signs off the pre-cutover reconciliation between `fabric_workspaces.csv` and `ubsppcoe_oapenabled`, and who raises the corrections, given we cannot make them ourselves (§3)? | Cutover |
| **Q16** | Nothing triggers a rebuild when the owning system changes `ubsppcoe_oapenabled` or moves a `Node` — **or when somebody edits `PolicyException`, which is our own table**. Nightly convergence is currently the only backstop. Acceptable, or does this need a Dataverse modified-row trigger? | Post-launch |
| **Q33** | Taking an exception away is not live until a rebuild runs (§3). Is "deactivate the row and force a rebuild" a good enough procedure, or does it need a flow of its own after all? | Post-launch |
| **Q35** | An exception follows its workspace to a new capacity with nobody on that capacity approving it (§3). Acceptable, or does `PolicyException` need a `capacity` lookup and a re-approval step on move? | Post-launch |
| **Q17** | A `Node` move needs remove-then-add from the app. If it makes only the add call, the workspace stays whitelisted on the old capacity until the nightly run, and nothing reports it. Is that acceptable, or does the move need to be detected rather than declared? | Post-launch |
| **Q10** | Should the app confirm against Fabric that a workspace exists and is on the capacity? The `Node` lookup answers it from the CMDB's point of view, but the CMDB can lag the real assignment, and a stale GUID is published verbatim and matches nothing — see §5 | Flow 3 |
| **Q11** | What reconciles drift if someone edits rules in the portal? A scheduled compare-and-report, or compare-and-correct? | Post-launch |
| **Q29** | `capacity_id` on `CapacityPolicy` and the `node` lookup now hold the **same GUID** (Q41), so they can only disagree if one was written wrong. Should the nightly scan assert they match, or is that too cheap a check to bother stating? | Post-launch |

---

## 8. Suggested build order

One document per flow in [flows/capacity-policies/](docs/flows/capacity-policies/); build them in this order.

1. **The four new tables** — `Capacity Policies`, `Policy Item Types`, `Policy Exceptions`, `Policy Drift` — plus the environment variables in §6. **Build them from [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md)**, which carries every column and type. Seed `Policy Item Types` from `fabric_item_types.csv`, and `Policy Exceptions` from `fabric_workspaces_exceptions.csv` if one is in use. Every column read from `ubsppcoe_Workspace` and `ubsppcoe_Node` is now confirmed (Q19 closed), so no filter is blocked on a name.
2. **[GetPolicyToken](docs/flows/capacity-policies/GetPolicyToken.md)** — client credentials, secret in a Key Vault-backed variable rather than inline. A **different** principal from the workspace-settings broker; do not reuse it.
3. **[SyncCapacityPolicySets](docs/flows/capacity-policies/SyncCapacityPolicySets.md)** — read-only against Fabric. Proves the token, the permissions and the Dataverse wiring with nothing at risk.
4. **[RebuildCapacityPolicyRules](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md)** — the writer. Test on one throwaway capacity. Exercise the **zero-enabled-workspace** case first and confirm it emits rule 1 alone; that is the path that silently unlocks a capacity if it is wrong. Then blank the policy row's **`node` lookup**, and confirm it fails rather than emitting rule 1. Add one `Policy Exceptions` row last and confirm rule 3 appears with **one** condition.
5. **[InitializeCapacityPolicySet](docs/flows/capacity-policies/InitializeCapacityPolicySet.md)** — end to end on the same throwaway capacity, including activation. Confirms Capacity Admin is sufficient (§5).
6. **[AddWorkspaceToPolicy](docs/flows/capacity-policies/AddWorkspaceToPolicy.md)**, then **[RemoveWorkspaceFromPolicy](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md)** — build add first and copy it. Verify the validation outcomes before the happy path: `NotEnabled` on add and `StillEnabled` on remove are the two that a bare rebuild wrapper could not report, and they are the reason both flows exist.
7. **[ListCapacityPolicySets](docs/flows/capacity-policies/ListCapacityPolicySets.md)** — late because it reads the counts flow 0 stamps, so it is only meaningful once rebuilds have run. Nothing depends on it, but it is what the app actually renders.
8. **[RebuildAllCapacityPolicies](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md)** — last, and only once a single-capacity rebuild is trusted. Time a full run at production scale before relying on the schedule.

Read-only first, one capacity before many — the order `Migration-Steps.md` already prescribes for the scripts, and it applies unchanged here.

### Cutover

Migration and BAU must not overlap on the same capacity. For each capacity, in order:

1. `migrate_policy_sets.ps1` creates and activates the policy set.
2. **Seed `CapacityPolicy`** with the migrated `policy_set_id`.
3. **Reconcile `ubsppcoe_oapenabled` against `fabric_workspaces.csv`** and get the differences signed off — both directions: CSV entries whose row is `false` or null, and `true` rows absent from the CSV.
4. **Seed `PolicyException` from `fabric_workspaces_exceptions.csv`**, if the migration used one. Take the `workspace_id` column only — the CSV's `capacity_id` has no counterpart in the table, because the capacity is derived from the workspace's `Node` (§3). **Check the two agree before discarding it:** a CSV row whose workspace now sits under a different Node is an exception that is about to move capacity, quietly, on the first rebuild. Nothing derives these rows, so a missed one is an unrestricted workspace that the first flow-driven rebuild silently restricts — the reverse of the risk in step 3, and just as invisible.
5. Only then let the flows manage that capacity.

Steps 2 to 4 are not optional and not follow-ups. The first flow-driven rebuild takes Dataverse as the truth and resolves every disagreement in its favour, silently and without a diff. A capacity missing its `policy_set_id` fails safe — the rebuild refuses and says so. A capacity whose `ubsppcoe_oapenabled` flags disagree with the CSV, or whose exceptions were never seeded, does **not** fail; it quietly changes access. See §3 and Q9.
