# Capacity policy flows — plan

Plan for the Power Automate flows that operate the capacity-scoped `ItemCreation` policy sets currently managed by PowerShell in the **`ubs-policies`** repository (`C:\GIT\ubs-policies`).

**Architecture decided 2026-09-02: desired state in Dataverse, rules rebuilt with `replaceByPolicy`. Revised 2026-09-03: the desired state is the existing `ubsppcoe_Workspace` table, read-only, plus an exception list this project owns. Revised 2026-09-07: the column that decides whitelist membership is `ubsppcoe_oapenabled`. Revised 2026-09-08: Fabric is called through the *HTTP with Microsoft Entra ID (preauthorized)* connector, so there is no token flow.** Seven flows, two existing tables read and four new tables created. Nothing is built yet.

Source material reviewed 2026-09-02, all in `C:\GIT\ubs-policies`: `migrate_policy_sets.ps1`, `add_policy_rule.ps1`, `remove_workspace_from_rule.ps1`, `new_policy_set.ps1`, `list_policy_sets.ps1`, `FabricPolicies.Common.ps1`, `Migration-Steps.md`, and `docs/Fabric-Policies-REST-API-Reference.md`.

> **Different system, same tenant.** This is not the workspace-settings app. It shares the broker-SPN pattern and the Fabric REST conventions documented in [ARCHITECTURE.md](../../docs/ARCHITECTURE.md) §2 and [FLOWS.md](../../docs/FLOWS.md), and should reuse them, but it governs capacities rather than workspace settings.

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
| Auth in the scripts is **app-only client credentials**, scope `https://api.fabric.microsoft.com/.default` | `FabricPolicies.Common.ps1` |

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

The cost is a drift story. An `OapEnabled` edit is covered — it fires its own Dataverse-triggered flow (§4). A rule **edited by hand in the portal** is not: nothing detects it, and it is corrected only when somebody runs [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md). **There is no scheduled flow in this solution** — the scan that would have reported it was discarded on 2026-09-18.

### The invariant that makes this safe

`replaceByPolicy` **overwrites every rule of the given policy**, including rule 1. So:

> **The rebuild must never emit an empty rule list.** A capacity with zero whitelisted workspaces still gets rule 1 on its own. Rule 1 grants nothing, but its presence is what keeps the policy in force — a policy with no rules at all is not an empty allow-list, it is an unenforced policy, and the capacity silently unlocks.

This is the single most dangerous line of code in the design. It should be a hard-coded first element of the rules array, not a loop that happens to run at least once.

---

## 3. The tables

**Decision 2026-09-03: the desired state is not a new table.** It already exists, in the two tables the platform team maintains — `ubsppcoe_Workspace` and `ubsppcoe_Node`. The rebuild reads them directly. The planned `CapacityWorkspace` junction table is **dropped**; building it would have been a second copy of a list that is already mastered, with a synchronisation problem attached.

So: **two existing tables are read, three new tables are created** — `CapacityPolicy`, `PolicyItemType` and `PolicyException`. Create them in the maker portal, never by editing `customizations.xml`.

> **`PolicyDrift` is dropped.** It existed only to hold the scan's findings; the scan was discarded and the table deleted from Dataverse on 2026-09-18 — see [discarded/SyncCapacityPolicySets.md](../discarded/SyncCapacityPolicySets.md). A table with no writer is a table somebody will one day read and believe.

> **Decision 2026-09-07: the new tables use the `ubsppcoe_` prefix too** — `ubsppcoe_CapacityPolicy`, `ubsppcoe_PolicyItemType`, `ubsppcoe_PolicyException`. This section keeps using the short conceptual names; the logical names are in [CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md).
>
> **The cost is that the prefix stops being a boundary marker.** Ours and theirs now look alike, so every "never write this" rule below is stated by **table name**. Do not restate any of them as a rule about `ubsppcoe_` columns — that sentence is now true of tables we write on every rebuild.

> **The build sheet is [CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md)** — every column, type, logical name and schema-level rule in one place. This section is the reasoning behind it; that file is what you build from.

### `ubsppcoe_Workspace` and `ubsppcoe_Node` — the desired state (existing, **read-only**)

`ubsppcoe_Node` is the capacity. `ubsppcoe_Workspace` points at it through a lookup.

| Table | Column | Purpose here |
|---|---|---|
| `ubsppcoe_Node` | `ubsppcoe_nodename` | Primary name — the Node's display name. **Not** the capacity id |
| `ubsppcoe_Node` | row key — `ubsppcoe_nodeid` | Dataverse-generated. What both `Node` lookups store. **Not** the capacity id |
| `ubsppcoe_Node` | `ubsppcoe_nodeuniqueid` | **This is the Fabric capacity id.** An ordinary column, not the row key |
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
> The only Dataverse table these flows write is **`CapacityPolicy`**, which this project creates. `PolicyException` is ours too, but no flow writes it — see below. *(See Q25: the instruction was "we do not insert or change any Dataverse data", and this design reads it as covering the platform team's tables. Writing our own state table is still assumed, because the policy set id has to be stored somewhere. If it was meant literally, say so — the consequence is resolving every policy set from Fabric on every run, which §5 explains does not fit the Power Apps budget.)*

> **Both tables separate their Fabric GUID from their row key, and both name them confusingly.** Three consequences the flows must respect:
>
> - **A capacity id does *not* resolve to a Node row directly.** `ubsppcoe_nodeuniqueid` holds the capacity GUID but is an ordinary column, so it takes a `List rows` filtered on `ubsppcoe_nodeuniqueid eq <capacityId>` — never `Get a row by ID`, which looks up `ubsppcoe_nodeid` and finds nothing. *(Corrected 2026-09-09; every earlier revision claimed the opposite.)*
> - **The `Node` lookup on a workspace holds a Node row GUID, not a capacity id.** Filtering workspaces by capacity is `_ubsppcoe_nodeid_value eq <nodeRowId>`, an unquoted GUID against the underscore-prefixed navigation column — so the capacity must be resolved to its Node row first. Not `ubsppcoe_nodeid eq '…'`, which is not a queryable column and returns a `400`.
> - **On the workspace table the two are separate, and named the wrong way round.** The row key is `ubsppcoe_workspaceuniqueid`; the Fabric workspace GUID is **`ubsppcoe_workspaceid`**. Everything published into `predicate.values` comes from the latter. A row key sent instead is a well-formed GUID that Fabric accepts and never matches — a denied capacity with no error anywhere. See [CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md) §1.

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

> **The consequence is a delay, and it is asymmetric.** Writing a row does not publish it by itself — [RebuildOnExceptionChange](../bau/RebuildOnExceptionChange.md) is what turns the edit into rules, and it fires on *added or modified* only.
>
> Granting late is an inconvenience. **Revoking late is not.** Clearing `active` publishes within a minute; **deleting the row publishes nothing at all**, because a deleted row cannot be read and the capacity cannot be derived — the workspace stays able to create anything until somebody runs [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md). The screen that edits these rows should deactivate, never delete.
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
> **Churn.** An estate-wide rebuild would stamp 200–300 of their rows every run. That is audit history they did not ask for, and if anything of theirs triggers on a modified Node row, we would fire it for every capacity in the estate.
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
> **`capacity_id` is a deliberate exception**, and worth being honest about. It duplicates the capacity GUID that also sits on the Node row. It stays because it is the key every flow is invoked with, and resolving a capacity id through a lookup on every call would cost more than it saves. If the Node's capacity GUID is ever corrected, our copy goes stale — a cheap check for the drift scan to make.

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

## 4. The seven flows

Build instructions are one file per flow — the seven BAU flows in [bau/](../bau/), the four `MIG_` flows in [migration/](../migration/). The summaries here are design intent; the per-flow files are the specification and win on any detail.

| Flow | Trigger | Purpose |
|---|---|---|
| [RebuildCapacityPolicyRules](../bau/RebuildCapacityPolicyRules.md) | Manual (child) | **The only writer of rules.** Rebuilds one capacity from the tables |
| [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md) | **Dataverse — `ubsppcoe_Node` added/modified** | Creates, registers, builds and activates a new capacity's policy set |
| [DeleteCapacityPolicySet](../bau/DeleteCapacityPolicySet.md) | **Dataverse — `ubsppcoe_Node` soft-deleted** | Deactivates and suspends a retired capacity's policy set |
| [ListCapacityPolicySets](../helper/ListCapacityPolicySets.md) | Power Apps (V2) | What the app reads. One table, no Fabric calls |
| [AddWorkspaceToPolicy](../bau/AddWorkspaceToPolicy.md) | **Dataverse — `ubsppcoe_Workspace` added or modified**, `oapenabled eq true` | Publish a workspace becoming whitelisted |
| [RemoveWorkspaceFromPolicy](../bau/RemoveWorkspaceFromPolicy.md) | **Dataverse — `ubsppcoe_Workspace` added or modified**, `oapenabled ne true` or soft-deleted | Publish a workspace losing its whitelist |
| [RebuildOnExceptionChange](../bau/RebuildOnExceptionChange.md) | **Dataverse — `Policy Exceptions` added/modified** | Publish an exception being granted or revoked. **New — closes Q16 and Q33** |

> ### No flow in this solution runs on a schedule — decided 2026-09-18
>
> Every trigger above is either **Dataverse row added/modified** or **manual**, and the four `MIG_` flows below are manual. `SyncCapacityPolicySets` was the one Recurrence flow in the design and it is **discarded** — [discarded/SyncCapacityPolicySets.md](../discarded/SyncCapacityPolicySets.md). `ListCapacityPolicySets` is the one remaining Power Apps (V2) trigger, and it only reads a table.
>
> **What goes with it is detection, not correction.** A rebuild has never been able to fix a policy set that was deactivated, replaced or deleted outside these flows — it writes rules to a set that is not in force and reports success. The scan was the only thing that would have noticed. Nothing does now. That is **Q11**, and it is a deliberate acceptance rather than an oversight.

> ### Retriggered 2026-09-11 and 2026-09-12 — four flows moved off Power Apps
>
> `InitializeCapacityPolicySet`, `AddWorkspaceToPolicy` and `RemoveWorkspaceFromPolicy` were all called by an app. They now fire on Dataverse row changes and **derive** what the caller used to assert. `DeleteCapacityPolicySet` is new. Each flow's own document carries the conversion table and the consequences; the ones that change this design are below.
>
> **`ListCapacityPolicySets` is the only Power Apps flow left.** It reads, so it has a caller by definition.
>
> **Nothing returns an outcome to anyone any more.** The four converted flows have no `Respond`; they write a `Compose` into the run history and, on a caught failure, `ubsppcoe_lasterror`. Every "the app must show the user" instruction in these documents is now unowned — see the note in each.
>
> **Q16 is closed for `ubsppcoe_Workspace` and `ubsppcoe_Node`, and closed for `Policy Exceptions` since 2026-09-16** — [RebuildOnExceptionChange](../bau/RebuildOnExceptionChange.md) gives that table the trigger it lacked. What remains uncovered is a **hard delete** of an exception row, and a `Node` **move**.
>
> **Q17 is closed by soft delete, partially — and reopened by the 2026-09-16 retrigger.** A deleted workspace is now a `Modified` event that `RemoveWorkspaceFromPolicy` can act on. A workspace **moving** capacity still is not: the flag does not change, so neither flow fires, and the old capacity keeps it. That used to be corrected by the nightly rebuild **within a day**; with no schedule it is corrected only when somebody runs [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md). See Q49.
>
> **Two accepted risks live in the flow documents rather than here.** `InitializeCapacityPolicySet` activates a deny-all with nobody deciding, and nothing retries a capacity it skipped. `DeleteCapacityPolicySet` removes enforcement on another team's signal, and nothing restores it when they reverse that signal — if the platform team clears the soft-delete flag, the capacity comes back **ungoverned while looking registered**.

### Plus four `MIG_` flows, which are not part of BAU

Built for cutover and run by hand. Three are **deleted** afterwards; the fourth is kept — see §8.

| Flow | Trigger | Purpose |
|---|---|---|
| [MIG_InitializeCapacityPolicySet](../migration/MIG_InitializeCapacityPolicySet.md) | Manual (child) | Creates and registers one capacity's policy set. **No rules, no activation** |
| [MIG_RegisterAllCapacityPolicySets](../migration/MIG_RegisterAllCapacityPolicySets.md) | Manual | Loops `GET /v1/capacities` and calls the above |
| [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md) | Manual | Rebuilds every capacity's rules in one pass. **Retriggered 2026-09-16 from a nightly Recurrence — and kept after cutover, not deleted** |
| [MIG_ActivateAllCapacityPolicySets](../migration/MIG_ActivateAllCapacityPolicySets.md) | Manual | Activates the estate. `Report` mode is the dry run |

> ## ⚠ Nothing converges the estate automatically any more — 2026-09-16
>
> `RebuildAllCapacityPolicies` ran nightly and was the backstop behind every other flow. It is now [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md), manual, and runs only when somebody starts it.
>
> **Four things that used to self-heal within a day now do not**: a `Failed` outcome from any of the three event flows, a workspace **moving** capacity (**Q17**), a hard-deleted `Policy Exceptions` row, and any rule edited or deleted by hand in the portal — including **rule 1**, whose absence leaves a capacity unenforced.
>
> The event flows still publish their own change immediately, so the ordinary path is unaffected. It is the **failure** path that no longer recovers on its own. See that flow's §0a, and **Q49**.

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

### Why both flows exist

A full rebuild makes Dataverse the source of truth in practice, not just in intent: hand-edited rules, a deleted rule, even a removed rule 1 are all overwritten. **Since 2026-09-16 that happens only when somebody runs [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md)**, and since 2026-09-18 there is no scan to tell you a run is due.

It also converges every `OapEnabled` or `Node` change that reached Dataverse without anyone calling the refresh — which, since the flag is owned elsewhere and editable by bulk import, is not an edge case. **It is the only backstop for a whole class of change this project cannot see happen.**

What it **cannot** fix is drift in the policy set itself — ours deactivated, replaced, or deleted. In those cases the rebuild writes rules to a set that is not in force and reports success. **Nothing detects that any more**, since the scan that would have was discarded; see Q11.

### Flow 0 — `RebuildCapacityPolicyRules`

The **only** flow that writes rules. Flows 1, 3 and 4 call it.

| | |
|---|---|
| Trigger | **Manually trigger a flow** — `capacityId` |
| Returns | `outcome`, `policysetid`, `rulecount`, `workspacecount`, `message` |

> **The trigger must be *Manually trigger a flow*, not Power Apps (V2).** A child flow can only be invoked by `Run a Child Flow` if its trigger is the manual one. This solution already learned that the hard way — `GetGitOperationStatus` had to stop being a child flow when its trigger became `PowerAppV2` ([FLOWS.md](../../docs/FLOWS.md) §2).

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
3. **Resolve the `ubsppcoe_Node` row** for this capacity — a `List rows` filtered on `ubsppcoe_nodeuniqueid eq <capacityId>`, which yields the row key `ubsppcoe_nodeid`. No row → `Failed`. That key is what the `node` lookup is bound to; every later flow reads the resulting lookup instead. [AddWorkspaceToPolicy](../bau/AddWorkspaceToPolicy.md) is the only other flow that resolves it directly.
4. `POST /v1/workspaces/{holderWs}/policySets` with `{ displayName: "pol_<sanitised name>", description, creationPayload: { scope: { type: "Capacity", id: capacityId } } }`.
5. Handle **202** — create is a long-running operation. Poll `GET /v1/operations/{x-ms-operation-id}` to a terminal state, then read the result. A `201` carries the policy set directly.
6. Write the `CapacityPolicy` row: `capacity_id`, `capacity_name`, the **`node` lookup**, `policy_set_id` and `policy_set_name`.
7. Call `RebuildCapacityPolicyRules`. A brand-new capacity normally has no OAP-enabled workspaces yet, so that emits **rule 1 alone** — the intended default, and it exercises the empty path on day one.
8. Activate — `POST /v1/workspaces/{holderWs}/policySets/{id}/activate`, body `{ scopeType: "Capacity", scopeId: capacityId, capacityId: capacityId }`. **`capacityId` is undocumented but required** — without it the preview service returns `PropertyCannotBeDefault`; see `activate_policy_set.ps1`. Tolerate `PolicySetIsAlreadyActive`. `PolicySetActivationConflict` means another set already owns the capacity and needs `allowReplace` — a **query parameter**, `?allowReplace=True`, not a body property. Do **not** pass it blindly; surface it and let a human decide.

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

Return the payload as **one JSON string** and `ParseJSON` app-side. Keep every Respond field typed string — the trap that cost two flows a field each in [FLOWS.md](../../docs/FLOWS.md) §4 applies here too.

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

> **Neither flow rolls anything back, because neither writes anything.** A failed rebuild leaves Dataverse and the previously published rules exactly as they were. What changes is the reporting: after a failed remove, **access that should be gone is still live**, with nothing scheduled to correct it, and the message has to say so. An operator taking access away for a leaver needs to know whether it took effect or not.

---

## 5. Permissions

> **[SECURITY-AND-IDENTITY.md](SECURITY-AND-IDENTITY.md) is authoritative** and splits the requirements by platform. This section is the reasoning behind it.

**Decision 2026-09-08: every Fabric call uses the *HTTP with Microsoft Entra ID (preauthorized)* connector, not the plain `HTTP` action.** The connector attaches the bearer token itself, so there is no token flow, no client secret, and no `Authorization` header anywhere in this design. `GetPolicyToken` is retired.

> ### What that changes, and it is not only plumbing
>
> **The identity stops being a service principal we configured and becomes whatever the connection authenticates as.** Everything in this section hangs off that, so settle it before granting anything:
>
> | | Old — app-only token flow | New — connector connection |
> |---|---|---|
> | Who calls Fabric | The policy SPN, via client credentials | **The connection's identity** |
> | Where the secret lives | An environment variable we manage | Nowhere. The platform holds it |
> | *Service principals can call Fabric public APIs* tenant setting | Hard prerequisite | **Only if the connection is a service principal.** Irrelevant for a user connection |
> | `Item.ReadWrite.All` etc. | Delegated scopes, and therefore **not** the mechanism | **The mechanism, if the connection is delegated** — this inverts |
> | Breaks when | The secret expires | The secret expires **or the connection owner leaves, loses the role, or has the connection revoked** |
>
> **The Fabric-side roles below attach to the connection's identity** — they do not follow the flow. **Settled 2026-09-18 (Q45): that identity is the `workspace provisioning` service account — a *user* account, email and password.** So every call is **delegated**: there is no service principal, no app registration and no client secret anywhere in this solution, and the roles are granted to the account directly.

| Need | Where | Notes |
|---|---|---|
| **Contributor on the holder workspace** | Fabric workspace role, on **one** workspace | Held by the connection's identity. See below |
| **Capacity Admin on every managed capacity** | Capacity role | Confirmed requirement for activating a policy set on that capacity |
| Capacity enumeration | `GET /v1/capacities` | Returns what the **connection's identity** administers, so a capacity it does not administer is simply absent — and flow 1 reads `Skipped` off exactly that list |
| *Service principals can call Fabric public APIs* | Tenant setting | **Not required.** The connection is a user account, not a service principal. That setting, and every Admin API setting, is scoped to SPNs in an allowed security group — see [SECURITY-AND-IDENTITY.md](SECURITY-AND-IDENTITY.md) §2.3 |
| Fabric administrator | only for `/v1/admin/policySets/*` | **Not needed.** Those operations are tenant-scope only; nothing here uses them |

### Contributor is needed on the holder workspace only

Not on the workspaces being whitelisted. Every write path is `/v1/workspaces/{holderWs}/policySets/...`, where `{holderWs}` is the workspace holding the PolicySet **items**. A policy set is a Fabric item like any other, and creating or updating items needs Contributor on the workspace that holds them.

The workspaces in a whitelist are never touched. They are string values inside `predicate.values` — data, not resources. `migrate_policy_sets.ps1` demonstrates this: it takes one `-WorkspaceId` for the holder and reads every whitelisted GUID from a CSV without any permission check.

So the calling identity needs Contributor on **one** workspace, Capacity Admin on the capacities, and **nothing at all** on the thousands of workspaces it grants access to.

> **The sting: whitelist GUIDs are never validated.** Fabric accepts any well-formed GUID in `workspace.id`. A typo, a deleted workspace, or a workspace from another tenant is stored happily and simply never matches. Nothing fails, and the owner is left with a policy that looks correct and denies them.
>
> Nothing in these flows can fix that, because the GUIDs come from `ubsppcoe_Workspace` and we do not write it. A stale or mistyped workspace GUID on an enabled row goes into the rules verbatim and matches nothing. **The validation has to happen where the row is created** — confirm the workspace exists and is actually assigned to that capacity. The API will not do it, and neither will we.

> ### The connection is the `workspace provisioning` service account — settled 2026-09-18
>
> A service account, not a named individual, which is what Q45 asked for. The subsystem therefore does not depend on anybody's personal account, and a leaver does not stop the estate-wide rebuild.
>
> **It is a user account, so the connection carries a user account's failure modes.** A password rotation, an MFA enforcement, a Conditional Access rule, a licence removal or a leaver review all break it — and all of them present as `401` on **every** capacity at once, with nothing in the run history naming the connection. See [SECURITY-AND-IDENTITY.md](SECURITY-AND-IDENTITY.md) §2.5.
>
> So two obligations survive the decision, and both belong to whoever operates this: **name an owner for the account and monitor its credential expiry.**

---

## 6. Configuration

| Setting | Where | Value |
|---|---|---|
| Holder workspace ID | Environment variable | |
| Deny-all sentinel GUID | Environment variable | `00000000-0000-0000-0000-000000000000` |
| `MaxWorkspacesPerRule` | Environment variable | `49` |
| `MaxRulesPerPolicy` | Environment variable | `50` |
| Policy name | **Hard-coded** in the rebuild body | `ItemCreation`. Listed here as an environment variable in an earlier draft, but no flow reads one — see [CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md) §8.11. Parameterise it if the policy type ever needs to vary by environment |
| Name prefix | Environment variable | `pol_` |
| API release stage | Environment variable `ubsppcoe_PolicyApiBeta` — **Two options** | **No**. `Yes` appends `?beta=true` to all six Fabric calls while the API is in public-preview beta — [API-BETA-SWITCH.md](API-BETA-SWITCH.md) |
| Item types | `PolicyItemType` table | |
| Exceptions — rule 3 | `PolicyException` table | Ours, written by hand or by the app. No flow writes it |
| Desired state | `ubsppcoe_Workspace` — `Node` lookup + `ubsppcoe_oapenabled` | Existing table, owned elsewhere |
| Capacity → Node row | `ubsppcoe_Node` — filter `ubsppcoe_nodeuniqueid` to get the key `ubsppcoe_nodeid` | Existing table, owned elsewhere |
| Policy set map | `CapacityPolicy` table | |

The two limits are environment variables so that a service-side change does not need a flow edit. **`PolicyApiBeta` exists for the same reason** — the API's move to beta at public preview, and back at GA, changes only the URL, so a toggle carries both transitions.

Environment variables travel with a solution export; their **values** may not. Same caveat as OPEN-ISSUES §8.1 in this repo.

---

## 7. Decisions

**The decision log has moved to [ADR.md](ADR.md)** — Q1–Q50, dated, including the still-open items.

Open items with owners, accepted risks and known gaps are in [HANDOVER-REGISTER.md](HANDOVER-REGISTER.md).

---
## 8. Suggested build order

One document per flow in [bau/](../bau/) and [migration/](../migration/); build them in this order.

1. **The three new tables** — `Capacity Policies`, `Policy Item Types`, `Policy Exceptions` — plus the environment variables in §6. **Build them from [CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md)**, which carries every column and type. `Policy Drift` is **dropped** — its only writer was discarded (§3). Seed `Policy Item Types` from [input/PolicyItemTypes.csv](../input/PolicyItemTypes.csv), and `Policy Exceptions` from [input/PolicyExceptions.csv](../input/PolicyExceptions.csv) — **a template whose three `EXAMPLE` rows must be deleted first**. Every column read from `ubsppcoe_Workspace` and `ubsppcoe_Node` is now confirmed (Q19 closed), so no filter is blocked on a name.
2. **The connector connection.** Create one *HTTP with Microsoft Entra ID (preauthorized)* connection against `https://api.fabric.microsoft.com` as the **`workspace provisioning` service account** (Q45), and grant that account Contributor on the holder workspace and Capacity Admin on a throwaway capacity. There is no token flow to build — that is the whole of the auth work.
3. **Prove the connection before anything writes.** A throwaway manual flow with a single *Invoke an HTTP request* — `GET https://api.fabric.microsoft.com/v1/capacities` — and nothing else. **This is where a wrong or under-privileged identity surfaces**, as an empty list or a `401`, rather than halfway through the first rebuild. Compare the count against the size of the estate: the list is scoped to the connection's identity, so a short list means the wrong identity and you have found it at the cheapest possible moment. Delete the flow afterwards. *(This step used to be `SyncCapacityPolicySets`, which was discarded on 2026-09-18 — [discarded/SyncCapacityPolicySets.md](../discarded/SyncCapacityPolicySets.md).)*
4. **[RebuildCapacityPolicyRules](../bau/RebuildCapacityPolicyRules.md)** — the writer. Test on one throwaway capacity. Exercise the **zero-enabled-workspace** case first and confirm it emits rule 1 alone; that is the path that silently unlocks a capacity if it is wrong. Then blank the policy row's **`node` lookup**, and confirm it fails rather than emitting rule 1. Add one `Policy Exceptions` row last and confirm rule 3 appears with **one** condition.
5. **[InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md)** — end to end on the same throwaway capacity, including activation. Confirms Capacity Admin is sufficient (§5).
6. **[AddWorkspaceToPolicy](../bau/AddWorkspaceToPolicy.md)**, then **[RemoveWorkspaceFromPolicy](../bau/RemoveWorkspaceFromPolicy.md)** — build add first and copy it. Verify the validation outcomes before the happy path: `NotEnabled` on add and `StillEnabled` on remove are the two that a bare rebuild wrapper could not report, and they are the reason both flows exist.
7. **[RebuildOnExceptionChange](../bau/RebuildOnExceptionChange.md)** — copy `RemoveWorkspaceFromPolicy` and cut it down. Verify `NoWorkspace` before the happy path: a mistyped GUID on an exception row is the only failure in this design that nothing else detects, and it is what makes the flow worth more than same-day publishing.
8. **[ListCapacityPolicySets](../helper/ListCapacityPolicySets.md)** — late because it reads the counts flow 0 stamps, so it is only meaningful once rebuilds have run. Nothing depends on it, but it is what the app actually renders.
9. **[MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md)** — last, and only once a single-capacity rebuild is trusted. Time a full run at production scale so whoever presses the button knows how long to wait.

Read-only first, one capacity before many — the order `Migration-Steps.md` already prescribes for the scripts, and it applies unchanged here.

> ### The three migration flows
>
> **Decided 2026-09-10.** Migration is flow-driven, not script-driven, and lives in three disposable flows carrying a **`MIG_`** prefix. Steps 1–6 above are unchanged; these replace steps 7 and 8.
>
> | # | Build | Purpose |
> |---|---|---|
> | 7 | [MIG_InitializeCapacityPolicySet](../migration/MIG_InitializeCapacityPolicySet.md) | Child, manual trigger. Creates and registers **one** capacity's policy set. No rules, no activation |
> | 8 | [MIG_RegisterAllCapacityPolicySets](../migration/MIG_RegisterAllCapacityPolicySets.md) | The loop. Walks `GET /v1/capacities` and calls the child. Run by hand, in tranches |
> | 9 | *Seed `Policy Exceptions`* | Human. Must precede any rebuild |
> | 10 | [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md) | Migration's rebuild phase. **Keep this one after cutover** — it is the only estate-wide repair tool |
> | 11 | [MIG_ActivateAllCapacityPolicySets](../migration/MIG_ActivateAllCapacityPolicySets.md) | Puts deny-all into force. Has a `Report` dry-run mode |
> | 12 | [ListCapacityPolicySets](../helper/ListCapacityPolicySets.md) | Verification surface, once there is something to verify |
>
> **Why copies rather than a `mode` input on the BAU flows.** A Power Apps (V2) trigger cannot be called by `Run a Child Flow`, so *something* with a manual trigger has to exist. Given that, a separate copy beats branching a tested flow: nothing built and verified for BAU has to be re-tested. **Three of the four are turned off and deleted after cutover**; `MIG_RebuildAllCapacityPolicies` is kept, because nothing else rebuilds more than one capacity at a time.
>
> **Register, rebuild and activate are three separate runs, deliberately.** Everything up to activation is inert — policy sets with no rules, deactivated, change nobody's access — so a half-finished or wholly wrong migration is undone by deleting rows and items. That separation is what replaces the `-WhatIf` the PowerShell path had, and it gives the exceptions seeding a window to happen in.
>
> **The operational sequence lives in [CAPACITY-POLICY-MIGRATION-RUNBOOK.md](CAPACITY-POLICY-MIGRATION-RUNBOOK.md)** — what to run, in what order, what to check between phases, and how to roll each one back.

### Cutover

Migration and BAU must not overlap on the same capacity.

> ### Two migration paths, and only one needs a reconciliation
>
> **Decided 2026-09-10: migration is flow-driven.** The numbered steps below describe the superseded **script** path, kept because the scripts remain the authority on API payloads. Under the flow path, **step 3 disappears entirely.**
>
> The reconciliation is an artefact of the script, not of migration. `migrate_policy_sets.ps1` builds its whitelists from `fabric_workspaces.csv`, so a script migration leaves Fabric holding CSV-derived state while Dataverse holds `ubsppcoe_oapenabled`. Those two can disagree, and the first flow-driven rebuild resolves it in Dataverse's favour without a diff — which is what step 3 exists to make visible first.
>
> Migrate through the flows and no CSV is ever read. Rules are built from `ubsppcoe_oapenabled` on the very first publish, so Fabric's state **is** the table by construction and there is nothing to reconcile. `ubsppcoe_Workspace` was always the source of truth for that flag; the CSV was only ever a snapshot of it taken at an unknown time.
>
> Step 4 does **not** disappear. `Policy Exceptions` has no upstream — nothing derives those rows, so they must be seeded whichever path is taken, and before the first rebuild.
>
> **The flow path, in full:**
>
> | # | Do | Reversible? |
> |---|---|---|
> | 1 | [MIG_RegisterAllCapacityPolicySets](../migration/MIG_RegisterAllCapacityPolicySets.md) — in tranches, checking the first five | Yes — delete the items and rows |
> | 2 | Seed `Policy Exceptions` — [input/PolicyExceptions.csv](../input/PolicyExceptions.csv) is the template; fill it from `fabric_workspaces_exceptions.csv`, `workspace_id` column only | Yes |
> | 3 | [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md) | Yes — nothing is enforced yet |
> | 4 | [MIG_ActivateAllCapacityPolicySets](../migration/MIG_ActivateAllCapacityPolicySets.md) in `Report` mode, and read the list | — |
> | 5 | The same in `Activate` mode, stopping after five to verify | **No.** Deny-all is now in force |
> | 6 | Delete `MIG_InitializeCapacityPolicySet`, `MIG_RegisterAllCapacityPolicySets` and `MIG_ActivateAllCapacityPolicySets`. **Keep `MIG_RebuildAllCapacityPolicies`**, switched off | — |
>
> Steps 1 to 3 change nobody's access. Step 5 changes everyone's.

> ### The inventory tables contain rows Fabric no longer has
>
> Raised 2026-09-10. `ubsppcoe_Node` and `ubsppcoe_Workspace` are the platform team's, and neither is guaranteed to be pruned when a capacity or workspace is deleted. The two cases behave differently.
>
> **A Node row for a dead capacity is already handled.** [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md) Step 4 checks `GET /v1/capacities` and returns `Skipped` unless the capacity exists, is `Active` and is an F-SKU — before anything is created. A migration loop inherits that guard for free, but its summary must separate `Skipped` from `Failed`, or a decommissioned estate reads as a broken run.
>
> **A Workspace row for a deleted workspace is harmless but not free.** Its GUID is published into `predicate.values` unchecked, where Fabric accepts it as well-formed and it never matches. The costs are a `workspacecount` that overstates reality, and dead entries consuming 49-per-rule chunk slots — eventually an extra rule that grants nothing.
>
> **Decision 2026-09-10: `ubsppcoe_Workspace` is trusted as-is. No flow verifies a workspace still exists in Fabric.** The alternative is one Fabric call per workspace per capacity per night, which makes the rebuild depend on read throughput and fails closed on a transient `429` — turning a cosmetic problem into a denied capacity. Pruning the inventory is the platform team's business, and we may not write those tables anyway (§3).
>
> **So drive the migration loop off `GET /v1/capacities`, not off `ubsppcoe_Node`.** Same guard, better reporting: iterating live capacities yields an explicit list of those with **no** Node row, which is the actionable gap — those are the ones that fail at Step 4b and stay permanently un-rebuildable. Iterating Node rows only tells you which ones to ignore.

For each capacity, in order:

1. `migrate_policy_sets.ps1` creates and activates the policy set.
2. **Seed `CapacityPolicy`** with the migrated `policy_set_id` **and the `node` lookup** — bound to `ubsppcoe_nodeid`, not the capacity id (§1). A blank lookup registers the capacity and makes it permanently un-rebuildable.
3. **Reconcile `ubsppcoe_oapenabled` against `fabric_workspaces.csv`** and get the differences signed off — both directions: CSV entries whose row is `false` or null, and `true` rows absent from the CSV. **Script path only.**
4. **Seed `PolicyException` from `fabric_workspaces_exceptions.csv`**, if the migration used one. Take the `workspace_id` column only — the CSV's `capacity_id` has no counterpart in the table, because the capacity is derived from the workspace's `Node` (§3). **Check the two agree before discarding it:** a CSV row whose workspace now sits under a different Node is an exception that is about to move capacity, quietly, on the first rebuild. Nothing derives these rows, so a missed one is an unrestricted workspace that the first flow-driven rebuild silently restricts — the reverse of the risk in step 3, and just as invisible.
5. Only then let the flows manage that capacity.

Steps 2 to 4 are not optional and not follow-ups. The first flow-driven rebuild takes Dataverse as the truth and resolves every disagreement in its favour, silently and without a diff. A capacity missing its `policy_set_id` fails safe — the rebuild refuses and says so. A capacity whose `ubsppcoe_oapenabled` flags disagree with the CSV, or whose exceptions were never seeded, does **not** fail; it quietly changes access. See §3 and Q9.
