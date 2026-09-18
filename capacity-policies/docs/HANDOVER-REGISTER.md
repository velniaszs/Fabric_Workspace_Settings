# Capacity policies — handover register

Everything the receiving team inherits that is **not** self-evident from the code: obligations a person must perform, dependencies on other teams, risks accepted deliberately, and gaps that were considered and left unbuilt.

**Nothing here is a defect.** Every entry was decided; the reasoning is in §7 of [CAPACITY-POLICY-FLOWS.md](CAPACITY-POLICY-FLOWS.md), referenced by question number.

> **Read §A first.** Those are the items where *doing nothing* silently produces a wrong estate. The rest describe risk that is already understood.

---

## A. Manual obligations

Things that happen only because a person does them. There is no scheduled flow in this solution.

| # | Obligation | Owner | When |
|---|---|---|---|
| A1 | **Run [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md)** to converge the estate | Dataverse team — Panuganti, Saikirankumar-Reddy | Once during migration; afterwards on demand (Q49) |
| A2 | **Check the holder workspace** — one active policy set per capacity, and it is ours | **Unassigned** | No agreed cadence (Q11) |
| A3 | **Monitor the `workspace provisioning` service account** for credential expiry and role loss | **Unassigned** | Ongoing (Q45) |
| A4 | **Review `Policy Item Types`** as Fabric ships new item types | **Unassigned** | No agreed cadence |
| A5 | **Act on a `Failed` or `Caught` run** of any BAU flow. Nothing retries them | **Unassigned** | Per occurrence |

### Why A1 matters

Five changes fire **no Dataverse event**, so no flow publishes them. They persist until A1 is run:

1. A `Failed` outcome from any event flow that nobody acted on
2. A workspace **moved** between capacities — the flag does not change, so neither Add nor Remove fires (Q17)
3. A `Policy Exceptions` row **hard-deleted** instead of deactivated (Q33)
4. A `Policy Item Types` edit
5. Any rule **edited by hand** in the Fabric portal

### Why A2 cannot be replaced by A1

Running the rebuild does **not** detect a policy set that is no longer in force — it writes rules to the deactivated set, returns `200`, stamps `lastrebuild` and leaves `lasterror` empty. Every signal reports healthy. A2 is the only check that catches it. See §C1.

### Why A3 is not optional

Every Fabric call in the solution authenticates as that one account. If it expires or loses Capacity Admin, the estate-wide rebuild fails against **every** capacity at once, and the run history says `401` rather than naming the connection. See [SECURITY-AND-IDENTITY.md](SECURITY-AND-IDENTITY.md).

---

## B. Dependencies on other teams

| # | Dependency | Owner | Undertaking |
|---|---|---|---|
| B1 | `ubsppcoe_Workspace`, `ubsppcoe_Node`, `Logging` are owned and populated elsewhere | Platform team — Panuganti, Saikirankumar-Reddy | Populate them, and **do not rename columns** (Q18) |
| B2 | Capacity provisioning creates the `ubsppcoe_Node` row | Platform team | Row must exist **before** the capacity is initialised |
| B3 | Whoever provisions a capacity must tell its owner it is **born locked** | Provisioning process | See §C4 |

> **B1 is an undertaking, not a control.** Nothing enforces it and nothing warns us if it lapses. A renamed column makes a filter return nothing, the rebuild emits rule 1 alone, and the capacity **locks down silently** — no error anywhere. There is no notification mechanism; discovery is a user raising a ticket.

**The `Node` row is the hard dependency.** `InitializeCapacityPolicySet` returns `Failed` and creates nothing if it is missing — correct, because a capacity registered without its `node` lookup is permanently un-rebuildable. If provisioning routinely creates the capacity first, expect `Failed` on the first attempt and a re-run once the row appears.

---

## C. Accepted risks

Understood, decided, and deliberately not mitigated.

| # | Risk | Reference |
|---|---|---|
| C1 | **A policy set that is not in force still reports healthy.** Anyone with rights on the holder workspace can deactivate ours or activate a replacement; the rebuild then writes to a dead set and succeeds | Q11 |
| C2 | **Ten of eleven `ubsppcoe_Node` states are untested.** Only `2` = Deleted is confirmed; `ne 2` treats the rest as live. If one means archived or pending, a capacity gets governed that should not have been | Q47 |
| C3 | **Reversing a soft-delete does not restore enforcement.** `InitializeCapacityPolicySet` finds the existing row, returns `AlreadyExists` and reactivates nothing — the capacity returns **ungoverned while looking registered** | [DeleteCapacityPolicySet](../bau/DeleteCapacityPolicySet.md) §3 |
| C4 | **A new capacity is born locked, and nobody decides.** The platform team adds an inventory row; deny-all is in force within minutes, with no screen and no acknowledgement | [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md) §0 |
| C5 | **Nothing retries a `Skipped` capacity.** A Dataverse trigger fires once per change; if Fabric does not yet know about a capacity whose row already exists, it is never initialised and **nothing reports it** | [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md) §0 |
| C6 | **Workspace GUIDs are never validated.** Fabric accepts any well-formed GUID and simply never matches it. A typo or stale entry denies the owner with no error anywhere | Q10 |
| C7 | **An exception follows its workspace to a new capacity** with nobody on that capacity approving it | Q34, Q35 |
| C8 | **A workspace move is not detected.** Neither Add nor Remove fires; the old capacity keeps it until A1 | Q17 |

> **C1 and C6 share a shape, and it is the one to teach a new operator:** the failure presents as *everything looks fine*. Both are invisible to every automated signal in the system.

---

## D. Gaps left unbuilt

Specified or considered, and not delivered. Each is a decision that can be revisited.

| # | Gap | What exists |
|---|---|---|
| D1 | **Drift detection.** No flow observes whether Fabric matches Dataverse | Two optional implementations recorded in [CAPACITY-POLICY-FLOWS.md](CAPACITY-POLICY-FLOWS.md) §7; the full scan spec is preserved in [discarded/SyncCapacityPolicySets.md](../discarded/SyncCapacityPolicySets.md) |
| D2 | **Un-governed capacity sweep.** A capacity whose Node row was written once and never touched is never initialised, and looks identical to one nobody meant to govern | Not specified anywhere |
| D3 | **Alerting.** `Logging` has no message column and nobody watches a table; there is no mail, no SLA, no escalation path | `ubsppcoe_lasterror` holds the error text; the `Logging` row holds the run URL |
| D4 | **Emergency unlock at scale.** The documented procedure uses PowerShell from `C:\GIT\ubs-policies`, a repository **not part of this handover** | [Operations runbook](CAPACITY-POLICY-OPERATIONS-RUNBOOK.md) §8. Either hand that repo over or replace the procedure |
| D5 | **`Policy Exceptions` has no upstream.** No flow derives those rows and no source file ships with this repo | Import template at [input/PolicyExceptions.csv](../input/PolicyExceptions.csv); real GUIDs come from the migration's `fabric_workspaces_exceptions.csv`, if one exists |

---

## E. Environment and deployment

| # | Item | Note |
|---|---|---|
| E1 | **Five environment variables** must be set per environment | Values do **not** travel reliably with a solution export |
| E2 | **Three Dataverse tables** are created by hand in the maker portal | `Capacity Policies`, `Policy Item Types`, `Policy Exceptions` — build sheet in [CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md) §8 |
| E3 | **Three `MIG_` flows are deleted after cutover** | `MIG_RebuildAllCapacityPolicies` is **kept, switched off** — it is A1 |
| E4 | `Logging` column logical names are unrecorded | Acceptable only while the table is insert-only. Never filter or read it back (Q48) |
| E5 | The solution cannot be exported from the customer environment | The flow documents are the specifications the flows were built from |

---

## F. Closed — no action

Recorded so nobody reopens them. Full reasoning in [CAPACITY-POLICY-FLOWS.md](CAPACITY-POLICY-FLOWS.md) §7.

| # | Decision |
|---|---|
| Q45 | The connection authenticates as the **`workspace provisioning` service account** |
| Q48 | `Logging` receives three columns: `Error`, the flow display name, and the run URL |
| Q49 | Rebuild is **operator-initiated**. No Recurrence |
| Q50 | **No flow in this solution runs on a schedule** |
| Q18 | The platform team owns and populates the three tables it controls |
| Q46 | `ubsppcoe_statecode` is a **custom Choice column**, unrelated to Dataverse's system `statecode` |
| — | `SyncCapacityPolicySets` discarded; `ubsppcoe_PolicyDrift` and `ubsppcoe_ScanState` dropped |
