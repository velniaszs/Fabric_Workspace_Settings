# Capacity policy flows — plan

Plan for the Power Automate flows that operate the capacity-scoped `ItemCreation` policy sets currently managed by PowerShell in the **`ubs-policies`** repository (`C:\GIT\ubs-policies`).

**Architecture decided 2026-09-02: desired state in Dataverse, rules rebuilt with `replaceByPolicy`.** Five flows and three tables. Nothing is built yet.

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

Add and remove edit **rows in a table**. A single writer flow then rebuilds every rule for that capacity in one call, exactly as `migrate_policy_sets.ps1` does. No flow ever edits a live rule in place.

Why, against the incremental alternative that was considered and rejected:

| | Incremental `PATCH` (rejected) | Rebuild from table (chosen) |
|---|---|---|
| Concurrency | `PATCH` replaces the conditions array wholesale and the API has **no ETag or `If-Match`**. Two simultaneous adds and one silently disappears | A row-level problem in Dataverse, which has optimistic concurrency |
| Chunking at 49 | Re-derived on every call, from partial information | Recomputed from the full list every time, so it cannot drift |
| Rule names `(1/3)` | Go stale as rules come and go | Regenerated on every rebuild |
| Relationship to the PowerShell | Diverges | Same algorithm |
| Auditability | The policy set is the only record | The table is queryable, and answers flow 2 without calling Fabric |

The cost is one table plus a drift story if somebody edits rules by hand in the portal. That is covered by the reconciliation flow in §8.

### The invariant that makes this safe

`replaceByPolicy` **overwrites every rule of the given policy**, including rule 1. So:

> **The rebuild must never emit an empty rule list.** A capacity with zero whitelisted workspaces still gets rule 1 on its own. Rule 1 grants nothing, but its presence is what keeps the policy in force — a policy with no rules at all is not an empty allow-list, it is an unenforced policy, and the capacity silently unlocks.

This is the single most dangerous line of code in the design. It should be a hard-coded first element of the rules array, not a loop that happens to run at least once.

---

## 3. The tables

Three Dataverse tables. Create them in the maker portal, never by editing `customizations.xml`.

### `CapacityPolicy` — one row per capacity

| Column | Purpose |
|---|---|
| `capacity_id` | Key |
| `capacity_name` | For display and for the policy set name |
| `policy_set_id` | Written by flow 1. **This is the `capacity_id → policy_set_id` map** that makes §5 a non-problem |
| `status` | Last known activation status |
| `last_rebuild` | Timestamp of the last successful rebuild |
| `last_error` | Blank when healthy |

### `CapacityWorkspace` — the desired state

| Column | Purpose |
|---|---|
| `capacity_id` | |
| `workspace_id` | |

One row per pair. This is `fabric_workspaces.csv`, live.

### `PolicyItemType` — the governed item types

| Column | Purpose |
|---|---|
| `item_type` | A Fabric `ItemType` enum value, sent verbatim |
| `item_name` | Documentation only |
| `active` | So a type can be retired without deleting history |

This is `fabric_item_types.csv`, live. Read by the rebuild flow on every run, so adding a governed item type is a row plus a rebuild, not a code change.

> **Cutover matters more than it looks.** Migration seeds ~200 existing policy sets from the CSVs. The moment BAU starts, the rebuild flow treats these tables as the truth. **If the tables are not seeded from `fabric_workspaces.csv` and the migrated `policy_set_id` values at cutover, the first add or remove on any capacity will rebuild its rules from an almost-empty table and wipe that capacity's whitelist.** Seeding is part of the migration, not a follow-up.

---

## 4. The seven flows

Build instructions are one file per flow in [flows/capacity-policies/](docs/flows/capacity-policies/). The summaries here are design intent; the per-flow files are the specification and win on any detail.

| Flow | Trigger | Purpose |
|---|---|---|
| [GetPolicyToken](docs/flows/capacity-policies/GetPolicyToken.md) | Manual (child) | App-only token for the policy SPN |
| [RebuildCapacityPolicyRules](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) | Manual (child) | **The only writer of rules.** Rebuilds one capacity from the tables |
| [InitializeCapacityPolicySet](docs/flows/capacity-policies/InitializeCapacityPolicySet.md) | Power Apps (V2) | Creates, registers, builds and activates a new capacity's policy set |
| [AddWorkspaceToPolicy](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) | Power Apps (V2) | Row in, rebuild |
| [RemoveWorkspaceFromPolicy](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md) | Power Apps (V2) | Rows out, rebuild |
| [RebuildAllCapacityPolicies](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) | Recurrence | Nightly convergence of every capacity to the tables |
| [SyncCapacityPolicySets](docs/flows/capacity-policies/SyncCapacityPolicySets.md) | Recurrence | Detects drift the rebuild cannot fix |

Only two flows are user-facing writes, and neither of them touches a policy rule — both edit a Dataverse row and call the rebuild.

### Why both scheduled flows exist

The nightly rebuild makes Dataverse the source of truth in practice, not just in intent: hand-edited rules, a deleted rule, even a removed rule 1 are all overwritten within a day. It also converges any add or remove whose rebuild failed at the time.

What it **cannot** fix is drift in the policy set itself — ours deactivated, replaced, or deleted. In those cases the rebuild writes rules to a set that is not in force and reports success. That is precisely what the scan detects, and why the two are complementary rather than redundant.

### Flow 0 — `RebuildCapacityPolicyRules`

The **only** flow that writes rules. Flows 1, 3 and 4 call it.

| | |
|---|---|
| Trigger | **Manually trigger a flow** — `capacityId` |
| Returns | `outcome`, `rulecount`, `workspacecount`, `message` |

> **The trigger must be *Manually trigger a flow*, not Power Apps (V2).** A child flow can only be invoked by `Run a Child Flow` if its trigger is the manual one. This solution already learned that the hard way — `GetGitOperationStatus` had to stop being a child flow when its trigger became `PowerAppV2` ([FLOWS.md](docs/FLOWS.md) §2).

1. Look up `policy_set_id` from `CapacityPolicy`. Missing → `Failed`, tell the caller to run flow 1 first.
2. Read the workspace IDs from `CapacityWorkspace` for this capacity, and the active item types from `PolicyItemType`.
3. Build the rules array:
   - **Always** rule 1 first — `workspace.id AnyOf [sentinel]`, `Allow`.
   - Then chunk the workspaces into groups of 49; one rule per chunk, each with `workspace.id AnyOf [chunk]` **and** `item.type AnyOf [itemTypes]`, named `Approved Fabric item types for whitelisted workspaces (i/n)`, truncated to 60 characters.
4. If the total exceeds 50 rules → `Failed` before calling Fabric. The ceiling is **49 whitelist rules × 49 workspaces = 2401 workspaces per capacity**.
5. `POST /v1/workspaces/{holderWs}/policySets/{policySetId}/policyRules/replaceByPolicy` with `{ policy: "ItemCreation", policyRules: [...] }`.
6. Stamp `last_rebuild` / `last_error` on `CapacityPolicy`.

Set **concurrency control to 1**. Two rebuilds of the same capacity overlapping would be last-writer-wins against Fabric even though the table is consistent.

### Flow 1 — `InitializeCapacityPolicySet`

Called by the capacity-provisioning Power App immediately after it creates a capacity.

| | |
|---|---|
| Trigger | Power Apps (V2) — `capacityId`, `capacityDisplayName` |
| Returns | `outcome` (`Created`, `AlreadyExists`, `Skipped`, `Failed`), `policysetid`, `message` |

1. Resolve the capacity — `GET /v1/capacities`; confirm it exists, is `Active`, and the SKU matches `F*`. A non-Fabric SKU returns `Skipped`, not `Failed`.
2. Row already in `CapacityPolicy` with a `policy_set_id` → `AlreadyExists`, stop.
3. `POST /v1/workspaces/{holderWs}/policySets` with `{ displayName: "pol_<sanitised name>", description, creationPayload: { scope: { type: "Capacity", id: capacityId } } }`.
4. Handle **202** — create is a long-running operation. Poll `GET /v1/operations/{x-ms-operation-id}` to a terminal state, then read the result. A `201` carries the policy set directly.
5. Write the `CapacityPolicy` row, including `policy_set_id`.
6. Call `RebuildCapacityPolicyRules`. With no rows in `CapacityWorkspace` yet, that emits **rule 1 alone** — which is the intended default and exercises the empty path on day one.
7. Activate — `POST /v1/workspaces/{holderWs}/policySets/{id}/activate`, body `{ scopeId: capacityId, scopeType: "Capacity" }`. Tolerate `PolicySetIsAlreadyActive`. `PolicySetActivationConflict` means another set already owns the capacity and needs `allowReplace` — do **not** pass it blindly; surface it and let a human decide.

> **Confirmed: the capacity is born locked.** Rule 1 blocks creation of every governed item type; Power BI items are not governed and stay creatable. That is the intended posture — flow 3 is what unlocks a workspace. The provisioning app must say so, or the first user to open a new capacity will file a bug.

Sanitise the display name exactly as `ConvertTo-ItemDisplayName` does: replace `\ / : * ? " < > |` with `_`, strip control characters, trim, cap at 256, and strip trailing dots and spaces. Fabric rejects trailing dots silently.

### Flow 2 — `ListCapacityPolicySets`

| | |
|---|---|
| Trigger | Power Apps (V2), no inputs |
| Returns | `policysetsjson`, `errormessage` |

Reads `CapacityPolicy` joined to a workspace count from `CapacityWorkspace`. **No Fabric calls.**

Per row: `capacityId`, `capacityName`, `policySetId`, `status`, `workspaceCount`, `lastRebuild`, `lastError`.

> At **200–300 capacities**, doing this live against Fabric would mean a list plus a `GET` per set to resolve `properties.scope.id` — which the list response frequently omits. That will not fit the **120-second** Power Apps budget. Reading the table is the whole reason the table exists.

Return the payload as **one JSON string** and `ParseJSON` app-side. Keep every Respond field typed string — the trap that cost two flows a field each in [FLOWS.md](docs/FLOWS.md) §4 applies here too.

### Flow 3 — `AddWorkspaceToPolicy`

| | |
|---|---|
| Trigger | Power Apps (V2) — `capacityId`, `workspaceId` |
| Returns | `outcome` (`Added`, `AlreadyPresent`, `Failed`), `message` |

1. Row already in `CapacityWorkspace` → `AlreadyPresent`, stop. No rebuild.
2. Reject if the capacity would exceed **2401** workspaces.
3. Insert the row.
4. Call `RebuildCapacityPolicyRules`.
5. If the rebuild fails, **delete the row again** and return `Failed`. A row that is not reflected in Fabric is worse than no row: flow 2 would report access that does not exist.

The 49-chunking, the new-rule case and the "which rule has space" question all disappear — the rebuild recomputes the whole layout.

### Flow 4 — `RemoveWorkspaceFromPolicy`

| | |
|---|---|
| Trigger | Power Apps (V2) — `capacityId`, `workspaceId` |
| Returns | `outcome` (`Removed`, `NotPresent`, `Failed`), `message` |

1. Row not in `CapacityWorkspace` → `NotPresent`, stop.
2. Delete the row (delete **all** matching rows — see below).
3. Call `RebuildCapacityPolicyRules`.
4. On failure, re-insert and return `Failed`.

The cases that made this awkward incrementally are gone. There is no last-workspace-in-a-rule problem, because rules are not edited — they are regenerated, and a chunk that would be empty simply is not emitted. The `PropertyMinCount` error that `remove_workspace_from_rule.ps1` has to refuse cannot arise.

> **Duplicates are handled by construction.** A workspace appearing twice was a worry under incremental editing. Here the rebuild does a distinct on the workspace list, so even if two rows exist the rules are correct — and step 2 deletes every matching row. Worth a uniqueness key on `(capacity_id, workspace_id)` anyway, so the app cannot create them in the first place.

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

> **The sting: whitelist GUIDs are never validated.** Fabric accepts any well-formed GUID in `workspace.id`. A typo, a deleted workspace, or a workspace from another tenant is stored happily and simply never matches. Nothing fails, and the owner is left with a policy that looks correct and denies them. **Validate the workspace ID in the app before writing the row** — confirm it exists and is actually assigned to that capacity. The API will not do it.

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
| Desired state | `CapacityWorkspace` table | |
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

### Still open

| # | Question | Blocks |
|---|---|---|
| **Q9** | Who seeds `CapacityPolicy` and `CapacityWorkspace` from the migration output, and when? Getting this wrong wipes whitelists on the first BAU edit — see §3 | Cutover |
| **Q10** | Does the provisioning app validate that a workspace exists and is assigned to the capacity before calling flow 3? Fabric will not — see §5 | Flow 3 |
| **Q11** | What reconciles drift if someone edits rules in the portal? A scheduled compare-and-report, or compare-and-correct? | Post-launch |

---

## 8. Suggested build order

One document per flow in [flows/capacity-policies/](docs/flows/capacity-policies/); build them in this order.

1. **The four tables** — `Capacity Policies`, `Capacity Workspaces`, `Policy Item Types`, `Policy Drift` — plus the environment variables in §6. Seed `Policy Item Types` from `fabric_item_types.csv`.
2. **[GetPolicyToken](docs/flows/capacity-policies/GetPolicyToken.md)** — client credentials, secret in a Key Vault-backed variable rather than inline. A **different** principal from the workspace-settings broker; do not reuse it.
3. **[SyncCapacityPolicySets](docs/flows/capacity-policies/SyncCapacityPolicySets.md)** — read-only against Fabric. Proves the token, the permissions and the Dataverse wiring with nothing at risk.
4. **[RebuildCapacityPolicyRules](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md)** — the writer. Test on one throwaway capacity. Exercise the **zero-workspace** case first and confirm it emits rule 1 alone; that is the path that silently unlocks a capacity if it is wrong.
5. **[InitializeCapacityPolicySet](docs/flows/capacity-policies/InitializeCapacityPolicySet.md)** — end to end on the same throwaway capacity, including activation. Confirms Capacity Admin is sufficient (§5).
6. **[AddWorkspaceToPolicy](docs/flows/capacity-policies/AddWorkspaceToPolicy.md)**, then **[RemoveWorkspaceFromPolicy](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md)** — remove is only testable once add can put a workspace in. Verify the compensating delete on a forced rebuild failure.
7. **[RebuildAllCapacityPolicies](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md)** — last, and only once a single-capacity rebuild is trusted. Time a full run at production scale before relying on the schedule.

Read-only first, one capacity before many — the order `Migration-Steps.md` already prescribes for the scripts, and it applies unchanged here.

### Cutover

Migration and BAU must not overlap on the same capacity. For each capacity, in order:

1. `migrate_policy_sets.ps1` creates and activates the policy set.
2. **Seed `CapacityPolicy` and `CapacityWorkspace`** from the migration output and `fabric_workspaces.csv`.
3. Only then let the flows manage that capacity.

Step 2 is not optional and not a follow-up. The first flow-driven add or remove rebuilds from the tables, so an unseeded capacity loses its entire whitelist on the first BAU edit — see §3, Q9.
