# Prerequisites — manual administrative work

Everything that must be configured **by hand**, outside the solution, before the app works. None of it is carried by the solution export, so all of it must be repeated in every tenant and every Power Platform environment.

Companion to [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/FLOWS.md](docs/FLOWS.md) and [docs/OPEN-ISSUES.md](docs/OPEN-ISSUES.md).

Last reviewed: 2026-08-07

---

## Summary

| # | Task | Where | Role needed to do it | State |
|---|---|---|---|---|
| **A1** | App registration `sp_fabric_powerapp` (broker) | Entra ID | Application Administrator | ✅ Done |
| **A2** | App registration `gateway_lister_app` (delegated) | Entra ID | Application Administrator | ✅ Done |
| **A3** | Security group `fabric_power_app_grp` containing the broker SP | Entra ID | Groups Administrator | ✅ Done |
| **B1** | **"Service principals can call Fabric public APIs"** enabled, scoped to `fabric_power_app_grp` | Fabric Admin portal | Fabric Administrator | ✅ Done |
| **B2** | Git integration tenant switch enabled | Fabric Admin portal | Fabric Administrator | 🟡 Not verified |
| **C1** | Capacity assigned to every managed workspace | Fabric | Capacity Administrator | 🟡 Assumed |
| **D1** | ADO repo, branch and target folder exist | Azure DevOps | Repo contributor | ➖ Per workspace, owner's job |
| **E1** | Solution imported | Power Platform | System Administrator | Per environment |
| **E2** | Connection references bound to real connections | Power Platform | System Administrator | Per environment |
| **E3** | Environment variable values supplied | Power Platform | System Administrator | 🔴 Not wired up yet |
| **E4** | Client secrets re-entered in every flow | Power Automate | Flow owner | Per environment |
| **E5** | Run-only users configured per flow | Power Automate | Flow owner | Per environment |
| **E6** | Security role `Fabric Workspace Owner` created and assigned to a group team | Power Platform | System Administrator | 🔴 Open |
| **E7** | Connector and canvas app shared with the group | Power Platform | Maker | Per environment |
| **F1** | Owner creates their ADO connection and grants the broker `User` on it | Fabric / the app | Workspace owner | ➖ Self-service, per workspace |

Legend: ✅ done in the current tenant · 🟡 assumed or unverified · 🔴 open, needs action · ➖ recurring, not a one-off

---

## A. Entra ID

### A1 — Broker app registration

`sp_fabric_powerapp` — client ID `a385fde9-1d6a-4e7f-8336-dc7feba5a4bc`, object ID `6f70a764-908f-435b-a930-ffcb375577f3`, tenant `9e929790-272d-4977-a2ab-301443c11ece`.

App-only client credentials. Needs a client secret. **No Azure DevOps rights.**

**Do not add Fabric application permissions.** Fabric does not grant REST access through Entra application permissions — a broker token legitimately shows `roles: (none)` and works fine. Access comes from A3 + B1 plus an object-level role (C1). Adding application permissions achieves nothing and widens the identity for no benefit.

> The object ID, not the client ID, is what `RegisterGitConnection` passes as `principal.id`. Confusing the two produces a role assignment that grants nothing, and connect then fails as though the connection were never shared.

### A2 — Delegated app registration

`gateway_lister_app` — client ID `1c221a2d-9a70-48cc-81b8-e68dfba7afbd`. Backs the custom connector; runs as the signed-in user.

Delegated scopes, published by the **Power BI Service** Entra app (not by a Fabric app):

- `Gateway.Read.All`
- `Connection.ReadWrite.All` — not yet added, see OPEN-ISSUES §9
- `offline_access`

**Grant every scope this connector will ever need in one pass.** Adding one later forces every user to delete and recreate their connection.

**Redirect URI.** Supplied by the custom connector itself — the maker portal issues a redirect URL when the connector is created, and that value is pasted back onto this app registration. No redirect URI needs planning in advance.

### A3 — Security group

`fabric_power_app_grp`, with the **`sp_fabric_powerapp` service principal** as a member — the service principal object, not the app registration.

Paired with B1. Neither works without the other.

---

## B. Fabric tenant settings

Fabric Admin portal → **Tenant settings**. Fabric Administrator role required.

### B1 — Service principals can call Fabric public APIs

Developer settings → **"Service principals can call Fabric public APIs"** → Enabled, scoped to `fabric_power_app_grp`.

**This is the single hardest prerequisite to diagnose.** Without it every app-only Fabric call returns a bare `401 Unauthorized` — *"The caller is not authenticated to access this resource"* — with nothing indicating a tenant setting is the cause.

Telling the two failure classes apart:

| Symptom | Meaning |
|---|---|
| `401` | The SPN cannot call Fabric at all → B1 or A3 is missing |
| `403` | The SPN can call Fabric but has no role on the object → the workspace role or a connection role assignment is missing |

`Workflows/diag-401.ps1` reproduces the check outside Power Automate.

### B2 — Git integration enabled

Git integration must be permitted at tenant level for workspaces to connect to Azure DevOps at all.

**Not verified in this tenant** — connect currently works for the test workspace, which implies it is on, but it has not been checked explicitly and should be confirmed before any new tenant is onboarded.

---

## C. Fabric workspace configuration

> **Workspace Admin for the broker is not a manual task.** The broker SP holds workspace **Admin** through its security group membership, and workspace provisioning is automated to grant that group the Admin role on every new workspace. Nothing to do per workspace. A new tenant does, however, need that provisioning automation in place — connect, disconnect and sync all require Admin, and the app is inert without it.

### C1 — Capacity assigned

Git operations fail with `WorkspaceHasNoCapacityAssigned` on a workspace with no capacity. Assumed satisfied across the estate; confirm as part of the same provisioning automation.

---

## D. Azure DevOps

### D1 — Repo, branch and folder must already exist

Per workspace, and the owner's responsibility. `connect` fails with `GitProviderResourceNotFound` if the target folder is not already present in the branch:

- The folder **must already exist** in the selected branch. The Fabric portal offers a *Create and sync* prompt; the REST API has no equivalent, so the app cannot create it.
- Folder names are **case-sensitive** against what is in the branch.
- The folder must not contain subdirectories unless at least one is a Fabric item directory. A single plain file such as `README.md` is fine.

State these rules on the folder field of the wizard. See OPEN-ISSUES §1.11.

---

## E. Power Platform — per environment

None of this survives solution import. All of it must be redone on every deployment.

### E1 — Import the solution

`WorkspaceSol` (unique name `Cr08ecd`, prefix `crbab`, publisher `Crf5954`).

### E2 — Bind connection references

A connection reference is a pointer; the **connection** holds the credentials and is environment-specific. Each reference must be mapped to a real connection in the target environment, either during the import prompts or immediately after.

### E3 — Supply environment variable values

`ab_TenantId` exists but is **referenced by nothing** — it was created and never wired up. Until the flows use it, tenant and client IDs remain hardcoded in nine flows and must be hand-edited after every import. See OPEN-ISSUES §8.3.

### E4 — Re-enter client secrets

Solution exports scrub secrets: every flow ships with `"clientSecret"` set to `" "`. **Each flow must have its secret re-entered by hand or it will not run.** Nine flows today.

### E5 — Configure run-only users

Per flow, per environment, and **not part of the export**. For each flow the canvas app calls: Power Automate → the flow → **Run only users**.

- Delegated custom connector → **Provided by run-only user**
- Broker SPN HTTP actions → **Use this connection**

Skipping this gives app users permission errors.

### E6 — Security role and group team

The custom connector is solution-aware, so it is a Dataverse row — access needs **table privileges**, not classic connector sharing. A missing role shows up as a `prvReadConnector` error.

In order:

1. Create security role **`Fabric Workspace Owner`** with Read on `Connector`, `Connection Reference`, `crbab_Workspaces`, `crbab_AllowedConnectionType`, and add it to the solution.
2. Create an Entra group → Dataverse **group team**.
3. Assign the role to the team.

### E7 — Share

Share the **connector** and the **canvas app** with the group.

---

## F. Per workspace owner — self-service

### F1 — Connection and role assignment

1. The owner creates their own *Azure DevOps – Source Control* connection in the Fabric UI and is **Owner** on it.
2. The app grants the broker SPN the `User` role on that connection, passing the broker's **object ID** `6f70a764-908f-435b-a930-ffcb375577f3`.

Step 2 runs **delegated as the owner**, because an SPN cannot grant itself a role on a connection. It needs `Connection.ReadWrite.All` on the delegated connector (A2).

> Unresolved: whichever credential the owner puts in the connection determines how long it lasts. Personal OAuth breaks when that person leaves; nothing currently monitors for it. See OPEN-ISSUES §5.2 and §5.3.

---

## Verification

Run in order. Each step isolates the prerequisite above it.

1. **Broker can reach Fabric at all** — `Workflows/diag-401.ps1`. A `401` means A3 or B1; a `403` means the broker has no role on the workspace.
2. **Broker has a workspace role** — `GET /v1/workspaces/{id}/git/connection` should return `200` with `gitConnectionState: NotConnected`, not `403`. Note it returns 200 rather than 404 when disconnected.
3. **Owner's connection is shared with the broker** — `GET /v1/connections/{id}/roleAssignments` should list the broker's object ID.
4. **Folder exists** — browse the branch in ADO before running connect.
5. **End to end** — run `ConnectWorkspaceToGit` and confirm the operation reaches `Succeeded`. Use `Workflows/get-operation.ps1 -OperationId <guid>` on failure; `GitSyncFailed` is a wrapper and the real cause is in `error.moreDetails`.

---

## Known gaps

- **B2** has not been explicitly verified.
- **E3** cannot be completed until the flows reference environment variables.
- Secret rotation is the customer's responsibility (OPEN-ISSUES §2). Note that rotating a secret means redoing **E4** in every environment.
