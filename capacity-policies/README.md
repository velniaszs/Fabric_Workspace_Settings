# Capacity policies

Governs **which Fabric item types can be created, in which workspaces, on which capacity** — by publishing `ItemCreation` policy sets to Fabric from desired state held in Dataverse.

A capacity under this system is **closed by default**. Nothing governed can be created on it until a workspace is explicitly whitelisted. Power BI items are not governed and are unaffected.

> **This is not the workspace-settings app.** It shares the tenant and the Fabric REST conventions, nothing else. That app is documented in [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).

---

## How it works, in one page

**Dataverse holds the desired state. Fabric holds nothing that is not rebuilt from it.**

Every publish is a **full rebuild** of one capacity's rule list via `replaceByPolicy` — never a partial edit. Whatever was in Fabric is overwritten, including rules somebody added by hand. That is what makes Dataverse the source of truth in practice rather than only in intent.

Each capacity gets one policy set, held in a **single holder workspace**, scoped to that capacity, containing up to three kinds of rule:

| Rule | What it does |
|---|---|
| **1 — deny all** | An `Allow` rule that can never match (`workspace.id AnyOf [00000000-…-0]`). Fabric has no `Deny` effect, so this is how "refuse everything not allowed below" is expressed. **Always emitted, even when a capacity has no whitelisted workspaces** |
| **2..n — whitelist** | `workspace.id AnyOf […]` **AND** `item.type AnyOf […]`. The listed workspaces may create the governed item types |
| **3 — exceptions** | `workspace.id AnyOf […]` with **no item-type condition** — those workspaces may create *anything*. Supersedes rule 2 rather than adding to it |

Workspaces are chunked **49 per rule**; the service ceiling is **50 rules per policy**.

> **The single most dangerous property in the design:** a policy with *no* rules is not an empty allow-list, it is an **unenforced policy** — the capacity silently unlocks. Rule 1 must always be emitted.

**Membership is derived, never stored.** A workspace is whitelisted because `ubsppcoe_oapenabled` is true on its row and its `Node` lookup points at the capacity. No flow here writes either column — both belong to the platform team.

---

## Where to start

| If you are… | Read |
|---|---|
| New to this | This file, then [docs/CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §1–§4 |
| Responding to a change in the estate | [docs/CAPACITY-POLICY-OPERATIONS-RUNBOOK.md](docs/CAPACITY-POLICY-OPERATIONS-RUNBOOK.md) |
| Running the one-off cutover | [docs/CAPACITY-POLICY-MIGRATION-RUNBOOK.md](docs/CAPACITY-POLICY-MIGRATION-RUNBOOK.md) |
| Building or repairing a table | [docs/CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) |
| Editing a flow | The flow's own document in [bau/](bau/) or [migration/](migration/), plus [docs/PLATFORM-FINDINGS.md](docs/PLATFORM-FINDINGS.md) |
| Taking this over | [docs/HANDOVER-REGISTER.md](docs/HANDOVER-REGISTER.md) — obligations, dependencies, accepted risks |
| Something is broken | [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |
| Granting access, or diagnosing a `401` | [docs/SECURITY-AND-IDENTITY.md](docs/SECURITY-AND-IDENTITY.md) |
| Asking *why is it like this* | §7 of [docs/CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) — the Q1–Q50 decision log |

---

## The flows

Eleven flows. **No flow in this solution runs on a schedule** — every trigger is a Dataverse row change or a manual start.

### BAU — seven

| Flow | Trigger | Purpose |
|---|---|---|
| [RebuildCapacityPolicyRules](bau/RebuildCapacityPolicyRules.md) | Manual (child) | **The only writer of rules.** Rebuilds one capacity from the tables |
| [InitializeCapacityPolicySet](bau/InitializeCapacityPolicySet.md) | `ubsppcoe_Node` added/modified | Creates, registers, builds and **activates** a new capacity's policy set |
| [AddWorkspaceToPolicy](bau/AddWorkspaceToPolicy.md) | `ubsppcoe_Workspace`, `oapenabled eq true` | Publishes a workspace becoming whitelisted |
| [RemoveWorkspaceFromPolicy](bau/RemoveWorkspaceFromPolicy.md) | `ubsppcoe_Workspace`, `oapenabled ne true` or soft-deleted | Publishes a workspace losing its whitelist |
| [RebuildOnExceptionChange](bau/RebuildOnExceptionChange.md) | `Policy Exceptions` added/modified | Publishes an exception being granted or revoked |
| [DeleteCapacityPolicySet](bau/DeleteCapacityPolicySet.md) | `ubsppcoe_Node` soft-deleted | Stands down a retired capacity's policy set. **The only flow that removes enforcement** |
| [ListCapacityPolicySets](helper/ListCapacityPolicySets.md) | Power Apps (V2) | What the app reads. One table read, no Fabric calls |

### Migration — four

Run by hand during cutover. Three are deleted afterwards; `MIG_RebuildAllCapacityPolicies` is **kept, switched off**.

| Flow | Purpose |
|---|---|
| [MIG_RegisterAllCapacityPolicySets](migration/MIG_RegisterAllCapacityPolicySets.md) | Walks `GET /v1/capacities`, registers each |
| [MIG_InitializeCapacityPolicySet](migration/MIG_InitializeCapacityPolicySet.md) | The child it calls. **Unsafe standalone** — no eligibility check |
| [MIG_RebuildAllCapacityPolicies](migration/MIG_RebuildAllCapacityPolicies.md) | Rebuilds the whole estate in one pass. **The only estate-wide repair tool** |
| [MIG_ActivateAllCapacityPolicySets](migration/MIG_ActivateAllCapacityPolicySets.md) | Puts deny-all into force. Has a `Report` dry-run mode |

---

## The tables

Six, all carrying the `ubsppcoe_` prefix — **so the prefix does not tell you who owns what.** Ownership is stated by table name, always.

| Table | Ours? | Access |
|---|---|---|
| `ubsppcoe_Workspace` | No — platform team | **Read only. Never written, without exception** |
| `ubsppcoe_Node` | No — platform team | **Read only. Never written, without exception** |
| `Logging` | No — platform team | **Insert only.** Never read, never updated |
| [`Capacity Policies`](docs/CAPACITY-POLICY-TABLES.md) | Yes | Read and written — policy set id, last rebuild, last error, cached counts |
| [`Policy Item Types`](input/PolicyItemTypes.csv) | Yes | Read by the rebuild. Maintained by hand |
| [`Policy Exceptions`](input/PolicyExceptions.csv) | Yes | Read by the rebuild. Maintained by hand |

Both hand-maintained tables have CSV import templates in [input/](input/).

---

## Things that will surprise you

**Nothing converges the estate on its own.** There is no scheduled rebuild. The event flows publish their own change, but five cases fire no event at all and persist until somebody runs `MIG_RebuildAllCapacityPolicies`: a failed event-flow run, a workspace **moved** between capacities, a hard-deleted exception row, a `Policy Item Types` edit, and any rule edited by hand in the portal.

**Deactivate an exception, never delete it.** A deleted row cannot be read, so the capacity cannot be derived and nothing publishes the change — the workspace keeps unrestricted creation indefinitely.

**A new capacity is born locked.** `InitializeCapacityPolicySet` activates deny-all immediately, and a brand-new capacity has no whitelisted workspaces. Whoever provisions it must say so on screen, or the first user files a bug and somebody "fixes" it by deactivating the policy set.

**Workspace GUIDs are never validated.** Fabric accepts any well-formed GUID in `workspace.id`. A typo or a stale entry is stored happily and simply never matches — no error, anywhere, and the owner is left with a policy that looks correct and denies them.

**A policy set that is not in force still reports healthy.** If someone deactivates ours or activates a replacement, the rebuild writes its rules to the dead set and returns `200`. Nothing detects this — see Q11.

---

## Folder layout

```
capacity-policies/
  README.md      this file
  docs/          design, schema, and the two runbooks
  bau/           the six business-as-usual flow documents
  helper/        ListCapacityPolicySets — read-only, app-facing
  migration/     the four MIG_ cutover flows
  input/         CSV import templates for the two hand-maintained tables
  discarded/     designs that were abandoned. NOT part of the handover
```

> **`discarded/` is kept deliberately.** It records what was considered and rejected — a scheduled drift scan, a token flow, a scopes sandbox — so the same ground is not covered twice. None of it should be built.

---

## Status

Every flow is **built in the customer environment**. The documents here are the specifications they were built from.

**Obligations, dependencies and known gaps are in [docs/HANDOVER-REGISTER.md](docs/HANDOVER-REGISTER.md)** — read §A before operating anything, because those are the items where doing nothing silently produces a wrong estate.
