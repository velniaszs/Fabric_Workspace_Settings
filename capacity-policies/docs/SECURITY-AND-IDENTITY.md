# Capacity policies — security and identity

Who this subsystem authenticates as, what that identity holds, and what breaks when it lapses.

---

## 1. The account

**One identity is used everywhere in this subsystem: the `workspace provisioning` service account.**

| | |
|---|---|
| Type | **A user account** — email and password |
| Used for | **Every** connection: Fabric, Dataverse, and the migration mail |
| Not used | No service principal. No Entra app registration. No client secret |

**It is a service account, not a named person** — deliberate, because the estate-wide rebuild runs against 200–300 capacities and tying that to an individual makes the subsystem one leaver away from stopping.

> ### Because it is a user account, every Fabric and Dataverse call is **delegated**
>
> This determines the whole of §2 and §3. The account acts as itself, with the permissions it personally holds. There is no application identity anywhere in this solution, so:
>
> - **No app registration, no client ID, no client secret** to manage or rotate
> - **No application API permissions** and no admin consent to obtain
> - **The tenant setting *Service principals can use Fabric APIs* is irrelevant** — nothing here is a service principal
> - Everything the account can do, it can do **because a role was granted to it directly**

---

# Part 1 — Fabric

## 2. Fabric requirements

### 2.1 The connection

| | |
|---|---|
| Connector | **HTTP with Microsoft Entra ID (preauthorized)** |
| Action | *Invoke an HTTP request* |
| Base resource | `https://api.fabric.microsoft.com` |
| Created by | **Signing in** as the `workspace provisioning` account |
| Used by | Every flow that calls Fabric |

The connector attaches the bearer token itself. **There is no token flow and no `Authorization` header anywhere in this design.**

> **Never add an `Authorization` header to a Fabric action.** The connector supplies one; a hand-written header is either ignored or breaks the call.

### 2.2 Fabric roles the account must hold

| # | Role | Scope | Why |
|---|---|---|---|
| F1 | **Contributor** (or Admin) | The **holder workspace** — one workspace | A policy set is a Fabric item. Creating and updating items requires it on the workspace that holds them |
| F2 | **Capacity Admin** | **Every managed capacity** | Required to activate a policy set on that capacity, and to see it in `GET /v1/capacities` |

That is the complete list of Fabric grants. Both are granted **directly to the account**.

> **F2 must be granted on every new capacity as it is provisioned.** A capacity the account does not administer is simply absent from `GET /v1/capacities` — the flow reports `Skipped`, which is indistinguishable from the capacity not existing. It is silently ungoverned.

### 2.3 Consent and tenant settings

**No Fabric tenant setting needs changing.** Every API-gating setting — *Service principals can call Fabric public APIs*, and all the Admin API settings — is scoped to service principals in an allowed security group. This connection is a user account, so none applies. Nothing here calls `/v1/admin/*` either.

**One thing must be granted:** the *HTTP with Microsoft Entra ID (preauthorized)* connector signs the account in against `https://api.fabric.microsoft.com` and asks it to consent. If **user consent to applications is disabled** in the tenant, a **tenant administrator must grant consent** before the connection can be created. One-off.

Two environment checks before go-live:

- **DLP policy** must allow *HTTP with Microsoft Entra ID (preauthorized)* and *Microsoft Dataverse* in the same data group, or the flows will not save or run
- **Conditional Access** must not block the account (§2.5)

### 2.4 What the account deliberately does **not** need

This surprises people, and it is worth understanding before anyone "fixes" it by granting more.

**No permission on the workspaces being governed.** Not Contributor, not Viewer, nothing — on any of the thousands of workspaces whose access this subsystem controls.

Whitelisted workspaces are never touched as resources. They are **string values inside `predicate.values`** — data in a rule, not objects being acted upon. Every write path is `/v1/workspaces/{holderWorkspace}/policySets/…`, and the only workspace in that path is the holder.

**Not Fabric Administrator.** That is needed only for `/v1/admin/policySets/*`, which are tenant-scope operations. Nothing here uses them.

> ### The sting that follows from this
>
> **Workspace GUIDs are never validated.** Fabric accepts any well-formed GUID in `workspace.id`. A typo, a deleted workspace, even a workspace from another tenant is stored happily and simply never matches.
>
> Nothing fails. No error appears anywhere. The owner is left with a policy that looks correct and denies them.
>
> Nothing in these flows can fix it — the GUIDs come from `ubsppcoe_Workspace`, which this project never writes. **Validation has to happen where the row is created.**

### 2.5 What breaks a user-account connection

A delegated connection has failure modes an application identity does not. All of them present the same way: `401` on **every** capacity at once.

| Cause | Note |
|---|---|
| **Password rotated or expired** | The connection does not follow a password change. It must be re-authenticated |
| **MFA enforced on the account** | An interactive prompt cannot be answered by a running flow |
| **Conditional Access policy** applied to the account | Location, device or compliance rules will block the sign-in |
| **Account disabled** | Service accounts do get caught in joiner-mover-leaver reviews |
| **Licence removed** | A connector connection needs the account to remain licensed |

> **Exclude this account from interactive-MFA and password-expiry policies, or the subsystem stops on a schedule nobody set.** That is a security decision for whoever owns the account, and it should be a deliberate one.

---

# Part 2 — Dataverse



## 3. Dataverse requirements

### 3.1 The connection

| | |
|---|---|
| Connector | **Microsoft Dataverse** |
| Created by | Signing in as the `workspace provisioning` account |
| Used by | Every flow |

> ⚠ **TO CONFIRM — does the Dataverse connection use the same account?** The intent is one identity everywhere, but this has not been verified in the environment. Open each flow's Dataverse connection and check the owner. If a second identity is in use, everything in §3.2 applies to **that** account instead, and the handover gains a second credential to monitor.

### 3.2 Table privileges required

All at **Organization** depth — the rows belong to another team, so User or Business Unit scope is not sufficient.

| Table | Read | Create | Write | Delete |
|---|---|---|---|---|
| `ubsppcoe_Workspace` | ✅ | — | **Never** | **Never** |
| `ubsppcoe_Node` | ✅ | — | **Never** | **Never** |
| `Capacity Policies` | ✅ | ✅ | ✅ | — |
| `Policy Item Types` | ✅ | — | — | — |
| `Policy Exceptions` | ✅ | — | — | — |
| `Logging` | — | ✅ | **Never** | **Never** |

**No flow deletes a Dataverse row anywhere in this solution.** A retired capacity's row is updated to `Deleted`, never removed.

> ⚠ **TO CONFIRM — which security role carries these privileges?** Unverified. If it is System Administrator, note in the handover that the subsystem does not require it — the table above is the actual need, and a custom role scoped to it is the correct long-term answer.

### 3.3 Trigger scope — the setting that silently does nothing

Nine of the eleven flows fire on Dataverse row changes. **A row trigger defaults to `User` scope, and at that scope it only fires for changes the connection's own account made.**

Every change that matters here is made by the platform team or by an import. **Set `Scope` to `Organization` on every Dataverse trigger**, or the flow simply never runs — with no error, no failed run, and nothing in the run history, because nothing ever triggered.

### 3.4 Two more trigger settings that are not optional

- **`Select columns`** decides *whether the flow fires*, not what the body contains. It is **update-only** — on the `Added` half of *Added or Modified*, it is ignored and every insert is evaluated.
- **`Filter rows`** applies to all events, and is what constrains inserts.

---

## 4. Other connections

| Connection | Used by | Purpose |
|---|---|---|
| Office 365 Outlook | `MIG_` flows only | The migration run reports |

Owned by the same account. It leaves the solution when the three disposable `MIG_` flows are deleted after cutover — `MIG_RebuildAllCapacityPolicies` keeps it for its failure summary.

**Who the reports go to is not in the flows.** All four send actions read `ubsppcoe_PolicyMailRecipients`, a semicolon-separated address list, so recipients change without opening a flow and differ per environment ([CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md) §8.11). **The reports name capacities, workspaces and failure reasons**, so the list is the only control over who sees the estate's shape — a distribution group with managed membership is preferred to addresses typed into a variable, and nothing here restricts where a forwarded mail goes next.

---

## 5. What the solution writes

| Target | Access | Contents |
|---|---|---|
| `ubsppcoe_Workspace` | **Read only. Never written, without exception** | — |
| `ubsppcoe_Node` | **Read only. Never written, without exception** | — |
| `Logging` | **Insert only.** Never read back, never updated, never deleted | `Error`, the flow display name, the run URL |
| `Capacity Policies` | Read and write | Policy set id, status, last rebuild, last error, cached counts |
| `Policy Item Types`, `Policy Exceptions` | Read only by flows | Maintained by hand or by the app |
| Fabric policy sets | Create, replace rules, activate, deactivate, delete | Rule lists rebuilt wholesale from Dataverse |

**Nothing sensitive is logged.** `Logging` carries no error text — there is no message column and one cannot be added. The diagnosis lands in `ubsppcoe_lasterror` on `Capacity Policies`; the `Logging` row records only that a flow failed and where to look.

> **Never write raw `result()` output to a column or a log.** Each entry carries the failed action's `inputs` and `outputs` verbatim. Extract `name`, `code` and `error.message` only.

---

## 6. Failure modes

### Fabric

| Symptom | Cause |
|---|---|
| **`401` on every capacity at once** | The account's password rotated or expired, MFA or Conditional Access blocked it, or the account was disabled or unlicensed. **Not** a Fabric outage — see §2.5 |
| `GET /v1/capacities` returns far fewer capacities than the estate | The account is not **Capacity Admin** on the missing ones. They are invisible, not broken — flows report `Skipped`, indistinguishable from a capacity that does not exist |
| Activation fails, policy set created | Capacity Admin missing on that one capacity |
| Creating a policy set fails | Contributor missing on the **holder workspace** |
| `404 Capacity not found` on deactivate | The capacity is already deprovisioned. `DELETE` on the policy set still works — this is expected, not a permission problem |

### Dataverse

| Symptom | Cause |
|---|---|
| **A flow never fires, and the run history is empty** | Trigger `Scope` is `User`, not `Organization`. Nothing triggered, so there is nothing to find |
| A flow fires on inserts it should ignore | `Select columns` is ignored on the `Added` half. Constrain inserts with `Filter rows` |
| *"To use filtering attributes your trigger must include an update event"* | `Change type` has no *Modified* in it. The error points at the filters; the fault is the dropdown |
| `Write` or `Create` privilege errors on `Logging` | Privileges are not at **Organization** depth |

> **The run history never says "the connection is the problem".** A lapsed credential presents as `401` against every capacity simultaneously. If an estate-wide run fails wholesale, suspect the account before suspecting Fabric — and before suspecting the data.

---

## 7. Ongoing obligations

| # | Obligation | Status |
|---|---|---|
| 1 | Name an owner for the `workspace provisioning` account | **Unassigned** |
| 2 | **Exempt it from password expiry, MFA and Conditional Access**, or renew the connection on every rotation | **Unassigned** |
| 3 | Keep it licensed and enabled — exclude it from leaver reviews | **Unassigned** |
| 4 | Grant **Capacity Admin** on each new capacity | Part of provisioning. Missing it means the capacity is silently ungoverned |
| 5 | Confirm the ⚠ items in §2.3, §3.1 and §3.2 — consent, DLP, Conditional Access, connection owner, security role | **Open** |

These are §A3 of the [handover register](HANDOVER-REGISTER.md). Obligations 1–3 have no owner, and the whole subsystem rests on them.

> **A user-account connection is the single largest operational risk in this design.** It is not a weakness in the flows — it is that one password, one licence and one Conditional Access rule sit between the estate and a total `401`. Whoever accepts this handover should accept that explicitly.
