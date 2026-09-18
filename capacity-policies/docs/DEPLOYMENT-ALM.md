# Capacity policies — deployment and ALM

What the solution contains, what travels with an export, and how source control works.

> **For the step-by-step procedure — prerequisites, flows, tables, seeding, order of operations — use [DEPLOYMENT-RUNBOOK.md](DEPLOYMENT-RUNBOOK.md).** This document covers what is in the solution and what does not travel with it.

---

## 1. What is in the solution

| Component | Count | Note |
|---|---|---|
| Cloud flows | 11 | 7 BAU (incl. `ListCapacityPolicySets`), 4 `MIG_` |
| Dataverse tables | 3 | `Capacity Policies`, `Policy Item Types`, `Policy Exceptions` |
| Environment variables | 5 | §3 |
| Connection references | 3 | Fabric HTTP, Dataverse, Office 365 Outlook |

**Publisher prefix is `ubsppcoe`.** Not `crbab` — that belongs to the workspace-settings canvas app and is a different solution entirely.

### Not in the solution, and required to exist first

| Dependency | Owner |
|---|---|
| `ubsppcoe_Workspace`, `ubsppcoe_Node` | Platform team |
| `Logging` | Platform team |
| The holder workspace in Fabric | This project |

A target environment without the platform team's tables cannot run any of this — the flows read them on every path.

> ⚠ **TO CONFIRM:** the solution's name, whether it is managed or unmanaged, and whether the three tables live in the same solution as the flows.

---

## 2. What does and does not travel

| Travels | Does **not** travel |
|---|---|
| Flow definitions | **Environment variable *values*** |
| Table and column schema | **Connections** — must be created and authorised per environment |
| Environment variable *definitions* | Table **data** — both hand-maintained tables need seeding |
| Connection *references* | The holder workspace, and Fabric roles on it |

**The two that catch people:** environment variable values and connections. A solution imports cleanly with neither, and the flows then fail at runtime — a blank variable silently builds a URL with a missing segment rather than erroring.

---

## 3. Environment variables

All five are **Text**, created inside the solution so they inherit the `ubsppcoe_` prefix.

| Display name | Schema name | Value |
|---|---|---|
| `PolicyHolderWorkspaceId` | `ubsppcoe_PolicyHolderWorkspaceId` | The workspace holding the PolicySet items |
| `PolicySentinelWorkspaceId` | `ubsppcoe_PolicySentinelWorkspaceId` | `00000000-0000-0000-0000-000000000000` |
| `PolicyMaxWorkspacesPerRule` | `ubsppcoe_PolicyMaxWorkspacesPerRule` | `49` |
| `PolicyMaxRulesPerPolicy` | `ubsppcoe_PolicyMaxRulesPerPolicy` | `50` |
| `PolicyNamePrefix` | `ubsppcoe_PolicyNamePrefix` | `pol_` |

**Set a Current Value, not only a Default Value.** A variable with neither resolves to blank without erroring.

**Both numeric ones are Text deliberately** — the flows wrap them in `int(...)`. A Dataverse *Number* variable returns a value the expression engine handles inconsistently.

**There is no policy-name variable.** `ItemCreation` is a literal in the rebuild body. Do not create a sixth variable unless you also parameterise that body.

---

## 4. Deploying to a new environment

**Superseded by [DEPLOYMENT-RUNBOOK.md](DEPLOYMENT-RUNBOOK.md) §7**, which carries the full order of operations including the identity, Fabric and Dataverse prerequisites this section omitted.

The one step worth repeating here, because it is the one that is missed:

> **Check every Dataverse trigger's Scope is `Organization`, not `User`.** A flow left at `User` scope never fires for the platform team's edits, produces no error and no run history, and looks perfectly healthy.

---

## 5. Post-cutover

| Action | Flow |
|---|---|
| Delete | `MIG_RegisterAllCapacityPolicySets`, `MIG_InitializeCapacityPolicySet`, `MIG_ActivateAllCapacityPolicySets` |
| **Keep, switched off** | `MIG_RebuildAllCapacityPolicies` — the only estate-wide repair tool |

`MIG_InitializeCapacityPolicySet` is **unsafe standalone** — it has no capacity eligibility check, because the loop did that. Leaving it in the solution invites someone to run it against a live capacity a year from now.

---

## 6. Source control

**The solution cannot be exported from the customer environment**, so:

- There is no flow JSON in this repository, and no automated pipeline
- **The flow documents in [bau/](../bau/), [helper/](../helper/) and [migration/](../migration/) are the specification** — they are what a rebuild would be done from
- Changes made in the environment do not propagate back here. **A flow edited without updating its document leaves the two out of step, with nothing to detect it**

> If export ever becomes possible, reconcile each flow document against its exported definition before trusting the action names and `runAfter` details — then the repository can become authoritative rather than descriptive.
