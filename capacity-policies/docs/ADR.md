# Capacity policies — decision log

Every architectural decision taken on this subsystem, numbered and dated. This is the *why*; [CAPACITY-POLICY-FLOWS.md](CAPACITY-POLICY-FLOWS.md) is the *what*.

**Read this before changing anything structural.** Several decisions here were reversed once already after being made on an assumption — Q13, Q40 and Q46 in particular — and the reasoning is what stops that happening a third time.

Open items that need an owner are also listed, with their owners, in [HANDOVER-REGISTER.md](HANDOVER-REGISTER.md).

---
## Decisions taken 2026-09-02

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
| Q13 | Are the Fabric GUIDs the row keys? | **No, on neither table.** On `ubsppcoe_Node` the key is `ubsppcoe_nodeid` and the capacity GUID sits in `ubsppcoe_nodeuniqueid`. On `ubsppcoe_Workspace` the key is `ubsppcoe_workspaceuniqueid` and the Fabric id is `ubsppcoe_workspaceid`. Both need a `List rows` + filter. **Revised 2026-09-09** — the 2026-09-07 revision said the Node key *was* the capacity GUID, and that was wrong; see Q40 and Q41 |
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
| Q32 | Who writes `PolicyException`? | **By hand in the maker portal, or the app through the Dataverse connector. No flow.** The rebuild only reads it, and [RebuildOnExceptionChange](../bau/RebuildOnExceptionChange.md) publishes the edit — neither writes a row. **Revoke by setting `ubsppcoe_active` to No; do not delete the row**, or nothing publishes the change at all |
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
| Q42 | What prefix do the four new tables use? | **`ubsppcoe_`, the same as the platform team's.** Not `crbab_`, which belongs to the workspace-settings canvas app and is unrelated to policy rules. The consequence is that **the prefix no longer indicates ownership**: state every read-only rule by table name. Two logical names — `ubsppcoe_workspaceid` and `ubsppcoe_workspacename` — now exist on two tables each, both times meaning the same thing, so the collisions are harmless; see [CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md) §0 |
| Q43 | What is the `Node` lookup on `ubsppcoe_Workspace`? | **`ubsppcoe_nodeid`, filtered and read as `_ubsppcoe_nodeid_value`.** This closes Q19 — no name is outstanding. Note the near miss with `ubsppcoe_nodeuniqueid` (an ordinary column on the Node row holding the **capacity** GUID) and with our own `ubsppcoe_node` on `CapacityPolicy`. The two lookups hold the **Node row** GUID; `ubsppcoe_nodeuniqueid` does not. Revised 2026-09-09 |

### Decisions taken 2026-09-08

| # | Question | Answer |
|---|---|---|
| Q44 | How do the flows authenticate to Fabric? | **The *HTTP with Microsoft Entra ID (preauthorized)* connector**, action *Invoke an HTTP request*, on every Fabric call. The connector attaches the bearer token. **`GetPolicyToken` is retired**, along with the client secret, the tenant/client-id environment variables, and every `Authorization` header. Eight flows become seven |
| Q45 | What identity does that connection use? | **Answered 2026-09-18 — the `workspace provisioning` service account.** See the 2026-09-18 table below |

### Decision taken 2026-09-15

| # | Question | Answer |
|---|---|---|
| Q46 | What are the real logical names of the soft-delete columns, and are they Boolean or Choice? | **Both tables use a column called `ubsppcoe_statecode`, and both are Choices, not Booleans.** On `ubsppcoe_Workspace`, `1` = Active and `2` = Deleted. On `ubsppcoe_Node`, `2` = Deleted and the other **ten of eleven options are live states**. So the two tables need *different* tests — `eq 1` for workspaces, `ne 2` for nodes — and the placeholder `ubsppcoe_isdeleted ne true` was wrong in name *and* in operator. All six filters rewritten; [CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md) §1 is authoritative. **`ubsppcoe_statecode` is a custom column and has nothing to do with Dataverse's system `statecode`** |

### Decisions taken 2026-09-18

| # | Question | Answer |
|---|---|---|
| Q45 | Which identity does the connector connection authenticate as? | **The `workspace provisioning` service account.** A service account, not a named person — so no leaver stops the estate-wide rebuild. Every Fabric role in §5 is granted to it: Contributor on the holder workspace, Capacity Admin on every managed capacity. **Granting is unblocked.** Residual, and now an operations task rather than a design question: the account needs a named owner and its credential expiry needs monitoring, because a lapse presents as `401` on every capacity at once |
| Q49 | Operator-initiated rebuild, or does the nightly Recurrence come back? | **Operator-initiated. No Recurrence.** Migration is a single run; anything it leaves behind is fixed by hand at the time, and ongoing change is carried by the per-event BAU flows. [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md) stays in the solution, switched off, as the repair tool. **What this accepts** is that the five cases which fire no event — a `Failed` event-flow run nobody acts on, a `Node` move (Q17), a hard-deleted `PolicyException` row, a `Policy Item Types` edit, and any rule edited by hand in the portal — persist until somebody runs that flow. BAU does not cover them, because there is no event for it to fire on |
| Q50 | Does the solution contain any scheduled flow at all? | **No.** Every flow is either Dataverse row-triggered or manual, plus one Power Apps read. `SyncCapacityPolicySets` was the only Recurrence flow and it is **discarded** — [discarded/SyncCapacityPolicySets.md](../discarded/SyncCapacityPolicySets.md) — along with the `Policy Drift` table it was the sole writer of. **The cost is detection, not correction:** a policy set deactivated, replaced or deleted outside these flows is now invisible, because a rebuild writes to it and reports success. That is Q11, and it wants a named owner doing a periodic manual check of the holder workspace |
| Q48 | What do the four Catch blocks write to `Logging`? | **Table `Logging`, three columns, picked from the designer dropdowns by display name.** `Log Category` = the literal `Error`; `Log Source Name` = `workflow()?['tags']?['flowDisplayName']`; `Log Source URL` = the run link built with `concat('https://flow.microsoft.com/manage/environments/', workflow()?['tags']?['environmentName'], '/flows/', workflow()?['name'], '/runs/', workflow()?['run']?['name'])`. **The logical names remain unrecorded and that is fine** — the table is insert-only, so nothing ever filters it or reads a row back. [CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md) §5a is authoritative |
| Q47 | What do the other ten `ubsppcoe_Node` statecode options mean? | **Not pursued. `ne 2` stands.** Only `2` = Deleted is confirmed and every other option is treated as live. Accepted deliberately rather than answered — if one of the ten turns out to mean archived, pending or rejected, `ne 2` is too generous and [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md) will govern a capacity it should have left alone. The symptom would be a capacity locked down that nobody expected to be governed |
| Q18 | Who owns the three tables we do not control, and what are they responsible for? | **The platform team owns and populates `ubsppcoe_Workspace`, `ubsppcoe_Node` and `Logging`, and is responsible for not changing column names.** That is the agreement this design rests on. **It is an undertaking, not a control** — nothing enforces it and nothing warns us if it lapses, so the failure modes stay worth knowing: a renamed column makes a filter return nothing and the rebuild emits rule 1 alone, locking the capacity silently; a widened *meaning* for `ubsppcoe_oapenabled` whitelists workspaces nobody intended, with every signal reporting healthy. Neither is detectable from this side. **Put the owning team and a named contact in the handover** |

### Still open
Ordered by what they block. **No column name blocks the build any more** — Q19 closed on 2026-09-07, Q46 on 2026-09-15. **Q45, Q47, Q48 and Q49 closed on 2026-09-18. Nothing blocks the build.** What remains is operational: who owns the manual obligations, and who tells us when the platform team's tables change.

| # | Question | Blocks |
|---|---|---|
| **Q48** | ~~What do the Catch blocks write to `Logging`?~~ **Answered 2026-09-18** — see the decisions table above and [CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md) §5a | ~~Flow build~~ Closed |
| **Q18** | ~~Who owns `ubsppcoe_Workspace`, and how are we told before a column is renamed?~~ **Answered 2026-09-18** — the platform team owns and populates `ubsppcoe_Workspace`, `ubsppcoe_Node` and `Logging`, and is responsible for not renaming columns. **Contact: Panuganti, Saikirankumar-Reddy.** Residual: **no notification mechanism exists**, so a breach is discovered as a capacity that has silently locked down | ~~Pre-launch~~ Agreement |
| **Q47** | ~~What do the other ten `ubsppcoe_statecode` options on `ubsppcoe_Node` mean?~~ **Closed 2026-09-18 by acceptance, not by an answer** — `ne 2` stands, all ten treated as live. The residual risk now lives in Q18 | ~~Pre-launch~~ Accepted |
| **Q45** | ~~Which identity does the connector connection authenticate as?~~ **Answered 2026-09-18 — the `workspace provisioning` service account**, and granting is unblocked. Residual: the account needs a named owner and expiry monitoring | ~~Flow build~~ Operations |
| **Q9** | ~~Who seeds `CapacityWorkspace`?~~ **Resolved by Q12** — there is nothing to seed. Replaced by: who signs off the pre-cutover reconciliation between `fabric_workspaces.csv` and `ubsppcoe_oapenabled`? **Narrowed 2026-09-10:** this applies to the **script** migration path only. Under a flow-driven migration no CSV is read, `ubsppcoe_Workspace` is the source of truth from the first publish, and the question does not arise. Seeding `PolicyException` still does, on both paths | Cutover |
| **Q16** | ~~Nothing triggers a rebuild when somebody edits `PolicyException`.~~ **Answered 2026-09-16 by [RebuildOnExceptionChange](../bau/RebuildOnExceptionChange.md)** — yes, it needed a modified-row trigger. Narrowed to: a `Node` **move** still fires nothing, which is Q17 | Post-launch |
| **Q33** | ~~Does taking an exception away need a flow of its own?~~ **Answered 2026-09-16 — yes.** [RebuildOnExceptionChange](../bau/RebuildOnExceptionChange.md) fires on both directions of `ubsppcoe_active`. Residual: a **hard delete** of the row still fires nothing, so *deactivate, do not delete* is now procedure rather than preference | Post-launch |
| **Q35** | An exception follows its workspace to a new capacity with nobody on that capacity approving it (§3). Acceptable, or does `PolicyException` need a `capacity` lookup and a re-approval step on move? | Post-launch |
| **Q49** | ~~Operator-initiated rebuild, or does the Recurrence come back?~~ **Answered 2026-09-18 — operator-initiated, no Recurrence.** **Owner: the Dataverse team (Panuganti, Saikirankumar-Reddy), one run during migration.** Accepted deliberately: nothing converges the estate on its own afterwards, and the five no-event cases persist until somebody runs [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md) again | ~~Pre-launch~~ Owned |
| **Q17** | A `Node` move needs remove-then-add from the app. If it makes only the add call, the workspace stays whitelisted on the old capacity, and nothing reports it. Is that acceptable, or does the move need to be detected rather than declared? **Sharper since Q49 was settled** — there is deliberately no scheduled run behind it, so a missed call is permanent until a manual rebuild | Post-launch |
| **Q10** | Should the app confirm against Fabric that a workspace exists and is on the capacity? The `Node` lookup answers it from the CMDB's point of view, but the CMDB can lag the real assignment, and a stale GUID is published verbatim and matches nothing — see §5 | Flow 3 |
| **Q11** | **Nothing detects a policy set that is no longer in force. Accepted 2026-09-18; two optional implementations are specified below if it ever needs closing.** Anyone with rights on the holder workspace can deactivate our set, or create a replacement and activate it — Fabric allows only one active set per capacity, so ours is deactivated rather than removed and still looks present. **Every signal then reports healthy while the capacity is governed by something else, or by nothing.** A rebuild does not correct it and cannot see it: `replaceByPolicy` writes our rules to the deactivated set, returns `200`, and stamps `lastrebuild` with `lasterror` empty | Accepted — optional |
| **Q29** | `capacity_id` on `CapacityPolicy` and the `node` lookup now hold the **same GUID** (Q41), so they can only disagree if one was written wrong. Should the drift scan assert they match, or is that too cheap a check to bother stating? | Post-launch |

> ### Q11 — the two optional implementations
>
> **Neither is built, and neither is part of the handover.** They are recorded so that closing Q11 later is a decision rather than a design exercise.
>
> **Option 1 — detect.** A periodic manual check: open the holder workspace and confirm one active policy set per capacity, ours. No build, no cost, and it depends entirely on somebody remembering. Automating it means rebuilding the discarded scan — [discarded/SyncCapacityPolicySets.md](../discarded/SyncCapacityPolicySets.md) is the complete specification, and its `Inactive` + `Untracked` pair is exactly this signature.
>
> **Option 2 — correct, and never detect at all.** [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md) §6 calls `activate` with `allowReplace=true` on every capacity it rebuilds, taking the capacity back whether or not anything took it. Cheaper than Option 1 and needs no new flow — but it is a flow that **silently seizes capacities**, so a replacement set somebody created deliberately is overwritten with no record that it existed. That is why §6 leaves it off by default and asks for the decision to be stated rather than defaulted into.
>
> **They are not alternatives so much as different questions.** Option 1 tells you somebody intervened; Option 2 undoes the intervention without ever telling you. If the concern is governance — *who changed this* — only Option 1 answers it.
