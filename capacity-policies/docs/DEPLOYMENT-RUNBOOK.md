# Capacity policies — deployment runbook

Deploying this subsystem to **another tenant**. Everything that must exist, be created, be populated or be granted, in the order it has to happen.

> **Companion:** [DEPLOYMENT-ALM.md](DEPLOYMENT-ALM.md) covers what travels with a solution export and how source control works. This document is the procedure.

---

## 0. Read this first — two constraints that shape everything

### The solution cannot be exported from the source environment

So there are two possible paths, and they cost very different amounts:

| Path | What it means |
|---|---|
| **Export becomes possible** | Import the solution, then follow §7 from step 4 |
| **Export stays impossible** | **Every flow is rebuilt by hand** in the target tenant, from the flow documents in [bau/](../bau/), [helper/](../helper/) and [migration/](../migration/) |

**Settle this before planning anything.** The second path is the bulk of the work, and the flow documents are the only specification for it.

### The platform team's tables may not exist in the target tenant

Three tables are read and written but **not owned by this project**: `ubsppcoe_Workspace`, `ubsppcoe_Node` and `Logging`. In a different tenant they may be absent, named differently, or carry different columns.

**If any logical name differs, flows must be edited** — every filter, every trigger and every published value is bound to the names in §4.2. This is the single largest unknown in a cross-tenant deployment. Check it first.

---

## 1. What gets deployed

| Component | Count |
|---|---|
| Cloud flows | 11 |
| Dataverse tables to create | 3 |
| Dataverse tables that must already exist | 3 |
| Environment variables | 6 |
| Connections | 3 |
| Fabric workspaces to create | 1 (the holder) |
| Seed data files | 2 |

---

## 2. Prerequisites

### 2.1 Identity

| # | Requirement | Note |
|---|---|---|
| I1 | A **service account** — a user account with email and password | Not a service principal. Everything authenticates as this one account |
| I2 | Licensed for Power Automate and Dataverse | A connector connection needs the account to remain licensed |
| I3 | **Exempt from password expiry and interactive MFA**, or a documented re-authentication process | A rotation silently breaks every Fabric call until the connection is re-authorised |
| I4 | Not subject to a blocking **Conditional Access** policy | Same failure mode |
| I5 | Excluded from joiner-mover-leaver reviews | Service accounts do get disabled by lifecycle automation |

### 2.2 Entra

| # | Requirement |
|---|---|
| E1 | **Admin consent** for the *HTTP with Microsoft Entra ID (preauthorized)* connector, if user consent to applications is disabled in the tenant. One-off, needs a tenant administrator |

No app registration, no client secret, no API permissions to configure — the identity is a user.

### 2.3 Fabric

| # | Requirement | Note |
|---|---|---|
| F1 | A **holder workspace** | Holds every policy set in the tenant. One workspace |
| F2 | Service account is **Contributor** (or Admin) on it | Not on any other workspace |
| F3 | Service account is **Capacity Admin** on every capacity to be governed | Must be repeated for each new capacity, for ever |
| F4 | Capacities are **F SKU** and `Active` | P/A/EM/PP cannot hold a policy set |

**No tenant setting needs changing** — the API-gating settings are scoped to service principals and do not apply.

### 2.4 Power Platform

| # | Requirement | Note |
|---|---|---|
| P1 | A target **environment with Dataverse** | |
| P2 | A **publisher with prefix `ubsppcoe`** | **Do not create a new one with a different prefix** — every logical name in every document would be wrong |
| P3 | **DLP policy** permits the Fabric connector, Dataverse and Office 365 Outlook in the same data group | Otherwise the flows will not save or run |
| P4 | Dataverse **security role** for the service account | §4.3 |

---

## 3. The flows

All eleven. **Build order matters** — each depends on the one above it.

### 3.1 BAU — seven

| # | Flow | Trigger | Notes |
|---|---|---|---|
| 1 | [RebuildCapacityPolicyRules](../bau/RebuildCapacityPolicyRules.md) | **Manual** (child flow) | **Build first.** The only writer of rules; every other flow wraps it. Must be manual — a Power Apps trigger cannot be called as a child |
| 2 | [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md) | Dataverse — `ubsppcoe_Node` added or modified | Creates, registers, rebuilds and **activates** |
| 3 | [AddWorkspaceToPolicy](../bau/AddWorkspaceToPolicy.md) | Dataverse — `ubsppcoe_Workspace` added or modified, `oapenabled eq true` | |
| 4 | [RemoveWorkspaceFromPolicy](../bau/RemoveWorkspaceFromPolicy.md) | Dataverse — `ubsppcoe_Workspace` added or modified, `oapenabled ne true` or soft-deleted | Copy of flow 3 |
| 5 | [RebuildOnExceptionChange](../bau/RebuildOnExceptionChange.md) | Dataverse — `Policy Exceptions` added or modified | Copy of flow 4 |
| 6 | [DeleteCapacityPolicySet](../bau/DeleteCapacityPolicySet.md) | Dataverse — `ubsppcoe_Node` soft-deleted (`statecode eq 2`) | **The only flow that removes enforcement.** Read its §0 before enabling |
| 7 | [ListCapacityPolicySets](../helper/ListCapacityPolicySets.md) | Power Apps (V2) | Read-only. Build last — it reads counts the rebuild stamps |

### 3.2 Migration — four

| # | Flow | Trigger | Notes |
|---|---|---|---|
| 8 | [MIG_InitializeCapacityPolicySet](../migration/MIG_InitializeCapacityPolicySet.md) | Manual (child) | **Unsafe standalone** — no eligibility check |
| 9 | [MIG_RegisterAllCapacityPolicySets](../migration/MIG_RegisterAllCapacityPolicySets.md) | Manual | The registration loop |
| 10 | [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md) | Manual | **Keep after cutover**, switched off |
| 11 | [MIG_ActivateAllCapacityPolicySets](../migration/MIG_ActivateAllCapacityPolicySets.md) | Manual | Has a `Report` dry-run mode |

> **Every Dataverse trigger must have Scope = `Organization`.** At the default `User` scope a flow fires only for changes the service account itself made — so it never fires at all, with no error and an empty run history.

---

## 4. Tables

### 4.1 Create these three

Build sheet with every column and type: [CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md) §8.

| Table | Schema name | Primary column |
|---|---|---|
| Capacity Policies | `ubsppcoe_CapacityPolicy` | `ubsppcoe_capacityname` |
| Policy Item Types | `ubsppcoe_PolicyItemType` | `ubsppcoe_itemname` |
| Policy Exceptions | `ubsppcoe_PolicyException` | `ubsppcoe_workspacename` |

Three things that cannot be fixed later, or are painful to:

- **Set the primary column's logical name on the *New table* screen**, under Advanced options, before saving
- **Do not tick Required on the `ubsppcoe_node` lookup** — flow 2 writes a partial row
- **Set both `ubsppcoe_active` columns to default `No`**

`Policy Drift` is **not** part of this solution. Do not create it.

### 4.2 These must already exist

| Table | Columns this project depends on |
|---|---|
| `ubsppcoe_Workspace` | `ubsppcoe_workspaceuniqueid` (row key), `ubsppcoe_workspaceid` (**Fabric GUID**), `ubsppcoe_oapenabled`, `ubsppcoe_statecode`, `ubsppcoe_nodeid` (lookup) |
| `ubsppcoe_Node` | `ubsppcoe_nodeid` (row key), `ubsppcoe_nodeuniqueid` (**Fabric capacity GUID**), `ubsppcoe_statecode` |
| `Logging` | *Log Category*, *Log Source Name*, *Log Source URL* |

> **Verify every one of these names in the target tenant before building anything.** A renamed column does not error — the filter returns nothing, the rebuild emits the deny-all rule alone, and **the capacity silently locks down**.
>
> Note the two traps: the Fabric workspace GUID is `ubsppcoe_workspaceid`, **not** the row key; and `ubsppcoe_statecode` is a **custom Choice column**, unrelated to Dataverse's system `statecode` — `1` = Active on Workspace, `2` = Deleted on both.

### 4.3 Dataverse privileges

All at **Organization** depth.

| Table | Read | Create | Write |
|---|---|---|---|
| `ubsppcoe_Workspace`, `ubsppcoe_Node` | ✅ | — | **Never** |
| `Capacity Policies` | ✅ | ✅ | ✅ |
| `Policy Item Types`, `Policy Exceptions` | ✅ | — | — |
| `Logging` | — | ✅ | **Never** |

---

## 5. Data to populate

| # | Table | Source | Required? |
|---|---|---|---|
| D1 | `Policy Item Types` | [input/PolicyItemTypes.csv](../input/PolicyItemTypes.csv) — 14 rows | **Yes.** An empty table makes Fabric reject rule 2 |
| D2 | `Policy Exceptions` | [input/PolicyExceptions.csv](../input/PolicyExceptions.csv) — **a template** | Only if the tenant has exceptions |
| D3 | `Capacity Policies` | Written by the flows | No — leave empty |

**Delete the three `EXAMPLE` rows from `PolicyExceptions.csv` before importing.** They carry placeholder GUIDs that match nothing.

**Headers in both files are the Dataverse logical names**, so the import maps column-for-column. Leave the row key unmapped — mapping it turns the insert into an upsert against GUIDs you do not have.

> **Review the item-type list against the target tenant's Fabric version.** The 14 rows were correct when written; a type missing from this table cannot be created in any governed workspace.

---

## 6. Environment variables

Six, created inside the solution so they inherit the prefix. **All Text except the last**, which is a Yes/No toggle.

| Display name | Schema name | Value |
|---|---|---|
| `PolicyHolderWorkspaceId` | `ubsppcoe_PolicyHolderWorkspaceId` | **Per tenant** — the holder workspace GUID |
| `PolicySentinelWorkspaceId` | `ubsppcoe_PolicySentinelWorkspaceId` | `00000000-0000-0000-0000-000000000000` |
| `PolicyMaxWorkspacesPerRule` | `ubsppcoe_PolicyMaxWorkspacesPerRule` | `49` |
| `PolicyMaxRulesPerPolicy` | `ubsppcoe_PolicyMaxRulesPerPolicy` | `50` |
| `PolicyNamePrefix` | `ubsppcoe_PolicyNamePrefix` | `pol_` |
| `PolicyApiBeta` — **Two options** | `ubsppcoe_PolicyApiBeta` | **No**, until the capacity-policy API enters public preview |

**Set a Current Value, not only a Default Value.** A variable with neither resolves to blank and silently builds a malformed URL.

**Both numeric ones are Text deliberately** — the flows cast with `int(...)`.

> **`PolicyApiBeta` switches the API version without a flow edit.** At public preview the capacity-policy endpoints need `?beta=true` appended; at GA they do not. Six URLs end with `@{if(parameters('PolicyApiBeta (ubsppcoe_PolicyApiBeta)'), '?beta=true', '')}`, so each transition is one toggle rather than six flow edits. **Set its Default Value to No as well**, so an import that skips the prompt behaves as today. See [API-BETA-SWITCH.md](API-BETA-SWITCH.md).

---

## 7. Deployment order

1. **Confirm §4.2** — the platform team's three tables exist, with the exact column names. **Stop here if they do not**
2. **Confirm the publisher** prefix is `ubsppcoe` (§2.4 P2)
3. **Create the solution**, then the three tables (§4.1) → **Publish all customizations**
4. **Create the six environment variables** (§6)
5. **Create the service account** and grant its Dataverse security role (§2.1, §4.3)
6. **Create the holder workspace** in Fabric; grant Contributor to the service account (§2.3 F1–F2)
7. **Grant Capacity Admin** on every capacity to be governed (F3)
8. **Create the three connections** as the service account; obtain Entra admin consent if prompted (§2.2)
9. **Smoke-test the connection** — one throwaway flow doing `GET /v1/capacities`. Compare the count against the expected estate. **A short list means the wrong identity or missing Capacity Admin** — the cheapest possible moment to find out. Delete the flow afterwards
10. **Seed `Policy Item Types`** (§5 D1)
11. **Build or import the flows**, in the order in §3
12. **Set every Dataverse trigger's Scope to `Organization`**
13. **Seed `Policy Exceptions`** (§5 D2) — before any rebuild
14. **Leave every flow off** until migration is planned

Then follow [CAPACITY-POLICY-MIGRATION-RUNBOOK.md](CAPACITY-POLICY-MIGRATION-RUNBOOK.md) for cutover.

> **Steps 1–10 change nobody's access.** The first irreversible moment is activation, during migration.

---

## 8. Verification

Before handing the environment over:

- [ ] `GET /v1/capacities` returns the expected number of capacities
- [ ] `Policy Item Types` has 14 active rows
- [ ] All six environment variables have **current** values, and `PolicyApiBeta` reads **No**
- [ ] Every Dataverse trigger Scope reads `Organization`
- [ ] A test rebuild on **one throwaway capacity** publishes rule 1 plus the expected whitelist rules
- [ ] **The zero-workspace case emits rule 1 alone** — the path that silently unlocks a capacity if it is wrong
- [ ] Blanking the `node` lookup makes the rebuild **fail** rather than emit rule 1
- [ ] A `Logging` row appears when a flow's Catch fires
- [ ] `ubsppcoe_lasterror` is written on a failed rebuild

---

## 9. Per-tenant values

Collect these before starting.

| Value | Target tenant |
|---|---|
| Tenant name / ID | |
| Power Platform environment | |
| Solution name | |
| Publisher prefix | `ubsppcoe` |
| Service account UPN | |
| Holder workspace name | |
| Holder workspace GUID | |
| Capacities to govern (count) | |
| Dataverse security role | |
| Platform team contact | |

---

## 10. What is **not** deployed

| Excluded | Why |
|---|---|
| `SyncCapacityPolicySets` | Discarded. No scheduled flow in this solution |
| `ubsppcoe_PolicyDrift`, `ubsppcoe_ScanState` | Dropped — no writer |
| `GetPolicyToken` | Retired. There is no token flow |
| Anything in [discarded/](../discarded/) | Record only |
| The `crbab_` workspace-settings solution | A different system that happens to share the tenant |
