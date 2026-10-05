# Prerequisites — manual administrative work

Everything that must be configured **by hand**, outside the solution, before the app works. None of it is carried by the solution export, so all of it must be repeated in every tenant and every Power Platform environment.

Companion to [docs/ARCHITECTURE.md](ARCHITECTURE.md), [docs/FLOWS.md](FLOWS.md) and [docs/OPEN-ISSUES.md](OPEN-ISSUES.md).

Last reviewed: 2026-08-07

---

## Summary

| # | Task | Where | Role needed to do it | State |
|---|---|---|---|---|
| **A1** | **Service account** for the broker — created, licensed, and exempt from MFA / password expiry / JML review | Entra ID | Identity administrator | ✅ Done |
| **A2** | App registration `SVC_PROD_AT43156_FABRIC_POLICY` (delegated) | Entra ID | Application Administrator | ✅ Done |
| **A3** | ~~Security group `fabric_power_app_grp`~~ | — | — | ➖ **No longer required** — see A3 |
| **B1** | ~~"Service principals can call Fabric public APIs"~~ | — | — | ➖ **No longer required** — see B1 |
| **B2** | Git integration tenant switch enabled | Fabric Admin portal | Fabric Administrator | 🟡 Not verified |
| **C1** | Capacity assigned to every managed workspace | Fabric | Capacity Administrator | 🟡 Assumed |
| **D1** | ADO repo, branch and target folder exist | Azure DevOps | Repo contributor | ➖ Per workspace, owner's job |
| **E1** | Solution imported | Power Platform | System Administrator | Per environment |
| **E2** | Connection references bound to real connections | Power Platform | System Administrator | Per environment |
| **E3** | Environment variable value supplied | Power Platform | System Administrator | Per environment |
| **E4** | **Connections authorised by signing in as the service account** | Power Automate | Flow owner | Per environment |
| **E5** | Run-only users configured per flow | Power Automate | Flow owner | Per environment |
| **E6** | Security role `Fabric Workspace Owner` created and assigned to a group team | Power Platform | System Administrator | 🔴 Open |
| **E7** | Connector and canvas app shared with the group | Power Platform | Maker | Per environment |
| **E8** | Connector tenant ID corrected for the target tenant | Power Platform | Maker | 🔴 Hardcoded |
| **F1** | Owner creates their ADO connection and grants the broker `User` on it | Fabric / the app | Workspace owner | ➖ Self-service |

Legend: ✅ done in the current tenant · 🟡 assumed or unverified · 🔴 open, needs action · ➖ recurring, not a one-off

---

## A. Entra ID

### A1 — The broker service account

A **user account** — email and password. **Not a service principal**: there is no app registration, no client ID and no client secret for the broker.

It signs in on the *HTTP with Microsoft Entra ID (preauthorized)* connection, which attaches the bearer token to every Fabric call. **No Azure DevOps rights. No Entra directory role. No Azure RBAC.**

Four things must be true of the account, and the last three break after go-live rather than during setup:

| | Requirement |
|---|---|
| 1 | **Licensed** for Power Automate and Dataverse — a connector connection needs the account to stay licensed |
| 2 | **Exempt from password expiry and interactive MFA**, or a documented re-authentication process exists |
| 3 | Not subject to a blocking **Conditional Access** policy |
| 4 | **Excluded from joiner-mover-leaver automation** — service accounts do get disabled by lifecycle reviews |

> **All four failures look identical: `401` on every Fabric call at once**, with nothing in the run history naming the connection. If the whole app fails simultaneously, suspect the account before suspecting Fabric.

> **Its directory object ID is still needed.** `AddConnectionRoleAssignment` passes it as `principal.id`, with `principal.type` = **`User`**, to grant the account a role on the owner's Git connection. It is published as the `crbab_BrokerObjectId` environment variable — the name is a leftover from the service-principal design.

### A2 — Delegated app registration

`SVC_PROD_AT43156_FABRIC_POLICY` — backs the custom connector `FabricSetting`; runs as the signed-in user. **Its client ID is a per-tenant value and is not recorded here** — read it from the app registration.

Delegated scopes are published by the **Power BI Service** Entra app (`00000009-0000-0000-c000-000000000000`), not by a Fabric app. Add them under **API permissions → Add a permission → Power BI Service → Delegated permissions**.

These scopes are **user-consentable** — `Gateway.Read.All` and `Connection.ReadWrite.All` both show *Admin consent required: No*, so each user consents at connection creation. Only the `Tenant.*` family needs an administrator. Granting admin consent tenant-wide is optional and suppresses the per-user prompt.

| Scope | Needed by | State |
|---|---|---|
| `Gateway.Read.All` | `ListGateways` | ✅ Added |
| `Connection.ReadWrite.All` | `ListMyConnections`, `AddConnectionRoleAssignment` | ✅ Added, consented 2026-08-07 |
| `offline_access` | token refresh | ✅ Added |

Per the API reference: `GET /connections` accepts `Connection.Read.All` **or** `Connection.ReadWrite.All`; `POST /connections/{id}/roleAssignments` requires `Connection.ReadWrite.All`. One scope therefore covers every connection operation the app needs — do not add both.

**The connector carries its own copy of this list.** The scope on the connector's *Security* tab is a single space-delimited string and must match:

```
Gateway.Read.All Connection.ReadWrite.All offline_access
```

The two are edited separately and neither validates the other. If the connector asks for a scope the app registration does not publish, the connector saves without complaint and the failure appears later, at **connection creation**, as `AADSTS65001` or an invalid-scope error — which reads like a connector bug and is not one. **Always change the app registration first.**

> Editing the OAuth section of the connector's Security tab blanks the client secret and will not save without it. Have the `SVC_PROD_AT43156_FABRIC_POLICY` secret to hand; it lives outside the repo.

**Grant every scope this connector will ever need in one pass.** Adding one later is expensive in a way that is easy to underestimate: consent is stored in Entra as an `oauth2PermissionGrant` keyed on (user, app, resource), and it **outlives the connection**. Deleting and recreating the connection silently reuses the old grant and issues the same narrow token — no prompt, no error, and a `403 InsufficientScopes` at the first call. The grant has to be revoked first, for every existing user, before any of them can reconsent. Procedure and commands: OPEN-ISSUES §9.3. Adding an *operation* later costs nothing.

**Redirect URI.** Supplied by the custom connector itself — the maker portal issues a redirect URL when the connector is created, and that value is pasted back onto this app registration. No redirect URI needs planning in advance.

### A3 — Security group — **no longer required**

`fabric_power_app_grp` existed to satisfy B1, and both were scoped to **service principals**. The broker is a user account, so neither applies.

**Nothing replaces it.** The account's Fabric access comes from a workspace role granted directly to it.

> A group is still a sensible way to *grant* that workspace role at scale — see §C — but it is an ordinary Entra group holding the account, not the `fabric_power_app_grp` developer-settings group.

---

## B. Fabric tenant settings

Fabric Admin portal → **Tenant settings**. Fabric Administrator role required.

### B1 — Service principals can call Fabric public APIs — **not required**

Earlier revisions made this the hardest prerequisite in the system to diagnose. **It no longer applies.** The setting, and every Admin API setting beside it, is scoped to service principals in an allowed security group; the broker is a **user account**, so none of them governs it.

> **Do not enable it "to be safe".** It grants nothing this solution uses, and it widens the tenant for every service principal in whatever group it is scoped to.

Telling the two failure classes apart — the meanings changed with the identity model:

| Symptom | Meaning |
|---|---|
| `401` on **every** call at once | **The connection, not a tenant setting.** The account's password rotated or expired, MFA or Conditional Access blocked it, or it was disabled or unlicensed → re-authenticate the connection (A1) |
| `403` on one object | The account can call Fabric but has no role on that object → the workspace role or a connection role assignment is missing |

The giveaway is **breadth**: everything failing at once is the connection; one thing failing is a role. `Workflows/diag-401.ps1` tested the service-principal path and no longer reproduces anything useful.

### B2 — Git integration enabled

Git integration must be permitted at tenant level for workspaces to connect to Azure DevOps at all.

**Not verified in this tenant** — connect currently works for the test workspace, which implies it is on, but it has not been checked explicitly and should be confirmed before any new tenant is onboarded.

---

## C. Fabric workspace configuration

> **Workspace Admin for the broker is not a manual task.** The broker account holds workspace **Admin** through an Entra group, and workspace provisioning is automated to grant that group the Admin role on every new workspace. Nothing to do per workspace. A new tenant does, however, need that provisioning automation in place — connect, disconnect and sync all require Admin, and the app is inert without it.

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

`WorkspaceSol` (unique name `Cr08ecd`, component prefix `crbab`, publisher `Crf5954`). **Tables are not in this solution** — they carry the `ubsppcoe` prefix and belong to the platform team's shared solution, which must already exist in the target environment.

### E2 — Bind connection references

A connection reference is a pointer; the **connection** holds the credentials and is environment-specific. Each reference must be mapped to a real connection in the target environment, either during the import prompts or immediately after.

### E3 — Supply the environment variable value

One, and it describes the broker identity:

| Variable | Value | Consumed by |
|---|---|---|
| `crbab_BrokerObjectId` | The **service account's directory object ID** — per tenant | `AddConnectionRoleAssignment` |

**"Broker" in the name is a leftover** from the service-principal design; the value is a user account's object ID. It is passed as `principal.id` with `principal.type` = `User`, and the same flow filters existing assignments on it — so a stale value both fails to grant and re-POSTs a duplicate.

Set it at import. The value carried by the export is a **default, not a binding**, so an import that skips the prompt silently keeps pointing at the source tenant.

> **`crbab_TenantId` and `crbab_BrokerClientId` are gone.** Both existed only to build the client-credentials token request. With no token flow there is nothing to parameterise.

### E4 — Authorise the connections as the service account

**Nothing to re-enter, and no secret is scrubbed from any flow** — there is no client-credentials block left to carry one.

Instead, each connection must be **created by signing in as the broker service account** (A1):

| Connection | Connector |
|---|---|
| Fabric | **HTTP with Microsoft Entra ID (preauthorized)** — Base Resource URL and Entra ID Resource URI both `https://api.fabric.microsoft.com` |
| Dataverse | Microsoft Dataverse |
| Mail / profile | Office 365 Users |

> **This is the step most likely to be got wrong on a redeployment, because it fails quietly.** A Fabric connection created by whoever happened to import the solution authenticates as *them*: the flows run, and every workspace that person does not administer simply behaves as though it does not exist. Confirm whose sign-in the connection holds, not merely that one exists.

### E5 — Configure run-only users

Per flow, per environment, and **not part of the export**. For each flow the canvas app calls: Power Automate → the flow → **Run only users**.

- Delegated custom connector → **Provided by run-only user**
- Brokered Fabric actions → **Use this connection**

Skipping this gives app users permission errors.

### E6 — Security role and group team

The custom connector is solution-aware, so it is a Dataverse row — access needs **table privileges**, not classic connector sharing. A missing role shows up as a `prvReadConnector` error.

In order:

1. Create security role **`Fabric Workspace Owner`** with Read on `Connector`, `Connection Reference`, `ubsppcoe_Workspace`, `ubsppcoe_AllowedConnectionType`, and add it to the solution.
2. Create an Entra group → Dataverse **group team**.
3. Assign the role to the team.

### E7 — Share

Share the **connector** and the **canvas app** with the group.

### E8 — Correct the connector's tenant ID

The custom connector's connection parameters hardcode `TenantId` — currently `9e929790-272d-4977-a2ab-301443c11ece` — and that value **is** carried by the solution export. Imported into another tenant it will point at this one, and every connection attempt fails at sign-in.

After import: connector → **Security** → set **Tenant ID** to the target tenant, re-enter the client secret, **Update connector**, then delete and recreate the connection.

Unlike E3, this is not an environment variable and cannot be supplied at import time.

---

## F. Per workspace owner — self-service

### F1 — Connection and role assignment

1. The owner creates their own *Azure DevOps – Source Control* connection in the Fabric UI and is **Owner** on it.
2. The app grants the broker account the `User` role on that connection, passing the account's **object ID** with `principal.type` = **`User`**, read from the `crbab_BrokerObjectId` environment variable (E3) rather than hardcoded.

Step 2 runs **delegated as the owner**, because no identity can grant itself a role on someone else's connection. It needs `Connection.ReadWrite.All` on the delegated connector (A2).

> **Decided 2026-08-11:** whichever credential the owner puts in the connection determines how long it lasts, and that choice stays with the owner. A service principal is recommended — personal OAuth breaks when that person leaves — but nothing enforces it and nothing monitors for expiry: a failed sync surfaces to the owner, who is also the person who can fix it. See OPEN-ISSUES §5.2 and §5.3.

---

## Verification

Run in order. Each step isolates the prerequisite above it.

1. **The connection is live and is the right account** — a throwaway flow doing `GET /v1/workspaces` or `GET /v1/capacities` on the preauthorized connector. A `401` means the connection has lapsed (A1); a short or empty list means it was authorised as the **wrong account**, which is the failure that otherwise hides for weeks.
2. **The account has a workspace role** — `GET /v1/workspaces/{id}/git/connection` should return `200` with `gitConnectionState: NotConnected`, not `403`. Note it returns 200 rather than 404 when disconnected.
3. **Delegated scopes reached the connection** — from the connector's **Test** tab, signed in as yourself, call `ListConnections`. A `403` carrying `x-ms-public-api-error-code: InsufficientScopes` means the consent predates `Connection.ReadWrite.All`; revoke the Entra grant, then recreate the connection (A2, OPEN-ISSUES §9.3). Confirm the fix by reading the grant back rather than by retrying — responses carry `x-ms-apihub-cached-response`, so a repeated identical `403` may be cache. Do this before building anything on top of it; the same failure inside a flow is far harder to read.
4. **Owner's connection is shared with the broker** — `GET /v1/connections/{id}/roleAssignments` should list the account's object ID with type `User`.
5. **Folder exists** — browse the branch in ADO before running connect.
6. **End to end** — run `ConnectWorkspaceToGit` and confirm the operation reaches `Succeeded`. Use `Workflows/get-operation.ps1 -OperationId <guid>` on failure; `GitSyncFailed` is a wrapper and the real cause is in `error.moreDetails`.

---

## Known gaps

- **A2** is granted and consented for the test user only. `user6` and `user8` still hold pre-change grants carrying `Gateway.Read.All` alone and must be revoked before they can use flows 3 or 7 (OPEN-ISSUES §9.3).
- **B2** has not been explicitly verified.
- **E8** has no supported per-environment mechanism; it is a manual edit on every import.
- Secret rotation is the customer's responsibility (OPEN-ISSUES §2). Note that rotating a secret means redoing **E4** in every environment.
