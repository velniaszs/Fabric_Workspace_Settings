# Architecture & Handoff

Read this first. It carries the design decisions, identities, and open issues needed to resume work. Per-flow detail lives in [docs/FLOWS.md](docs/FLOWS.md).

---

## 1. Problem

Roughly 4000 Fabric workspaces. Workspace **owners** need to configure Git integration themselves, but:

- Fabric's Git APIs require **Workspace Admin**, which owners do not have and will not be granted
- Owners are Contributors, so they can commit and update once connected — but cannot connect, disconnect, or change connection settings
- Owners must not be able to touch workspaces they don't own

Solution: a Power Platform app that brokers the calls through a privileged service principal, with **Dataverse as the authorization boundary**.

### What the app does and does not do

The Fabric Git permission table settles the scope. Contributors can already **commit, update from Git, view connection details and see Git status** in the Fabric UI. Only three operations need Admin: **connect, disconnect, and changing connection settings**.

The app therefore brokers connect and disconnect only. Everything else stays in the Fabric UI where the owner already has rights. This removed four planned flows and two planned tables.

### Wizard

1. Pick a workspace from `crbab_Workspaces` (only rows where the caller is primary or secondary owner).
2. Pick a connection — **delegated** call, so only the caller's own connections appear. Filtered client-side to `AzureDevOpsSourceControl`. Shows name, URL and ID.
3. Confirm org / project / repo **derived** from `connectionDetails.path` — no URL pasting. Branch defaults to `main`; directory defaults to `/` and is editable, with a hint for shared repos. Choose the initialization strategy, with a warning and wiki links.
4. On the final step only: grant SPN-A on the connection (delegated), then connect (SPN-A).

Granting on the last step means an abandoned wizard leaves no stray role assignments.

---

## 2. Identity model

Two identities, deliberately separated.

### SPN-A — `sp_fabric_powerapp` (`a385fde9-1d6a-4e7f-8336-dc7feba5a4bc`)

The Fabric broker. App-only client credentials. Workspace Admin on all managed workspaces. **No Azure DevOps rights at all.** Executes every app-only Fabric REST call.

> **Decision 2026-08-06, implemented 2026-08-07.** `sp_fabric_monit` (`b5c04c9c-0588-418f-8f60-2d83d38cb635`) holds `Tenant.Read.All` / `Tenant.ReadWrite.All` and is deliberately **not** used as the broker — an app exposed to 4000 workspace owners must not run on a tenant-wide identity.
>
> All flows now acquire their token from `GetFabricToken`, which uses `sp_fabric_powerapp`. `b5c04c9c` appears nowhere in `Workflows/`; `sp_fabric_monit` has no role in this solution. See OPEN-ISSUES §1.6.

Keep SPN-A's grants to the minimum the flows actually need: workspace Admin on managed workspaces, plus whatever the networking endpoints require. Do not add tenant-scoped application permissions.

Fabric REST access for an SPN is *not* granted by Entra application permissions. **Confirmed by testing on 2026-08-06** — a token with an empty `roles` claim is normal and works fine, while adding application permissions in the app registration does nothing. Access requires both of:

1. **Entra security group** `fabric_power_app_grp`, with the `sp_fabric_powerapp` **service principal** as a member
2. Fabric Admin portal → Tenant settings → Developer settings → **"Service principals can call Fabric public APIs"** → Enabled, scoped to that group

plus a Fabric-side role on the target object (workspace role, gateway role, connection role).

This is a **hard prerequisite for every app-only flow**, and it is environment-specific — the group and the tenant setting must be recreated in every tenant the solution is deployed to. Symptom when missing: `401 Unauthorized`, *"The caller is not authenticated to access this resource"*, on every Fabric call. A `403` means this part is satisfied and only the object-level role is missing.

`Workflows/diag-401.ps1` reproduces the check outside Power Automate and is the fastest way to tell the two apart.

### Git identity

Owners have Azure DevOps access and **create their own** *Azure DevOps – Source Control* connections. The connection carries the Git credentials; SPN-A is granted the `User` role on it and references it by ID without ever seeing the secret.

A dedicated Git service principal ("SPN-B") was considered and **dropped** — it only existed to supply Git credentials for owners who couldn't reach ADO, which is no longer the case.

Open: whichever credential the owner puts in the connection determines durability. Personal OAuth breaks when that person leaves. See docs/OPEN-ISSUES.md §5.2.

Consequence either way: ADO shows the commit as pushed by the connection's identity, not the requester.

### `gateway_lister_app` (`1c221a2d-9a70-48cc-81b8-e68dfba7afbd`)

Delegated app behind the custom connector. Runs as the signed-in user so gateway listings reflect what that user can actually see.

Tenant: `9e929790-272d-4977-a2ab-301443c11ece`

> Secrets are in the user's OneDrive `internal_power_app.txt`, outside the repo. Rotation is the customer's responsibility. Inside the solution only `GetFabricToken` holds a secret; moving it to a Key Vault-backed environment variable is deferred. See OPEN-ISSUES §2.
---

## 3. Authorization boundary

Fabric cannot answer "does this user own this workspace?" — owners hold no Fabric role, so `roleAssignments` returns nothing useful. The ownership record lives in Dataverse.

**`crbab_Workspaces`** (exists): `crbab_workspace_id`, `crbab_workspace_name`, `crbab_primary_owner`, `crbab_primary_owner_email`, `crbab_secondary_owner`, `crbab_secondary_owner_email`

Every flow that acts on a workspace must first confirm the caller appears as primary or secondary owner. Fail closed.

### The PowerApp V2 trigger cannot prove identity

The app passes the user identity as a parameter, and anyone who can reach the flow URL can forge it. Acceptable for reads. **Not acceptable for writes.**

For `ConnectWorkspaceToGit`, `SyncWorkspaceWithGit` and `DisconnectWorkspaceFromGit`, use the **audit-row pattern**:

1. The app writes a row to `crbab_GitAuditLog` — as the signed-in user, so Dataverse stamps `createdby`
2. The app calls the flow, passing only that row's ID
3. The flow reads the row: `_createdby_value` cannot be forged, and neither can the parameters beside it
4. The flow authorizes `createdby` against `crbab_Workspaces`, then acts
5. The flow updates the row with the outcome and returns it to the app

The flow keeps its PowerApp V2 trigger, so the app still gets an immediate answer. Identity is trusted because of *where it was read from*, not because of who called.

Read flows may stay on PowerApp V2 with no row at all.

> **Not built yet. Decision 2026-08-06: defer.** No flow currently performs any `crbab_Workspaces` lookup. `ConnectWorkspaceToGit` acts on whatever `workspaceId` it receives. This is acceptable only while the app is limited to the build team \u2014 it must land before the app is shared. See OPEN-ISSUES \u00a71.7.

`AddConnectionRoleAssignment` is the exception: it is self-authorizing, because the Fabric API only lets a caller grant roles on a connection they already control. PowerApp V2 is fine there.

---

## 4. Solution & components

| | |
|---|---|
| Display name | `WorkspaceSol` |
| Unique name | `Cr08ecd` |
| Prefix | `crbab` |
| Publisher | `Crf5954` |

**Existing tables:** `crbab_Workspaces`, `crbab_AllowedConnectionType`

`crbab_Workspaces` is populated externally — out of scope here.

**Planned tables:** `crbab_GitAuditLog` (who did what, when, outcome) and the request table backing the write pattern in §3. Create via maker portal, never by editing `customizations.xml`.

**Dropped:** `crbab_GitConnection` and `crbab_WorkspaceGitMapping`. Fabric owns that state and the GET APIs return it live — caching it only creates a second source of truth to reconcile.

**Canvas app:** `CanvasApps/crbab_app5_baf10_DocumentUri.msapp`. Data sources are the 8 networking/gateway flows plus Dataverse `Workspaceses`, `Users`, `AllowedConnectionTypes`.

---

## 5. Custom connector — `gateway_lst_app_con`

Schema name `ab_gateway-5flst-5fapp-5fcon` (note the `ab_` prefix, not `crbab_`). Solution-aware, so it lives in the Dataverse `connector` table (OTC 372), not in the classic connector store.

Connection reference: `ab_sharedgateway5flst5fapp5fcon5fe4e6bd1abcd77fac5f0c1c5dd7f4e428ac_51f02`.

| Field | Value |
|---|---|
| Scheme | HTTPS |
| Host | `api.fabric.microsoft.com` |
| Base URL | `/v1` |
| Operation path | `/gateways` |
| Operation ID | `ListGateways` |
| Query param | `continuationToken` (string, optional) |
| Security | Azure Active Directory |
| Login URL | `https://login.microsoftonline.com` |
| Tenant ID | `9e929790-272d-4977-a2ab-301443c11ece` |
| Resource URL | `https://api.fabric.microsoft.com` |
| Scope | `Gateway.Read.All offline_access` |
| Enable on-behalf-of login | No |

**Why the Base URL is `/v1` and not the full path:** if the base URL already contains the path, the operation path resolves to empty and validation fails with `paths/ : The path is not valid`.

**Scope forms.** Fabric delegated scopes are published by the **Power BI Service** Entra app (that is where you find them in the portal, not under a Fabric app). Both `https://api.fabric.microsoft.com` and `https://analysis.windows.net/powerbi/api` are valid identifier URIs on it; the documented form is the latter. With the *Azure Active Directory* security type the connector prepends the Resource URL, so the short scope is correct. With **Generic OAuth 2**, the scope must be fully qualified or consent silently closes with no error:

```yaml
security:
  - oauth2-auth:
      - https://analysis.windows.net/powerbi/api/Gateway.Read.All offline_access
securityDefinitions:
  oauth2-auth:
    type: oauth2
    flow: accessCode
    authorizationUrl: https://login.microsoftonline.com/9e929790-272d-4977-a2ab-301443c11ece/oauth2/v2.0/authorize
    tokenUrl: https://login.microsoftonline.com/9e929790-272d-4977-a2ab-301443c11ece/oauth2/v2.0/token
```

The single space-delimited scope key is the connector UI's own encoding — it is not malformed.

**Editing security.** `security` and `securityDefinitions` are regenerated from the Security tab. Edits made in the Swagger Editor are discarded. Change the Scope field on the Security tab.

**Testing.** The Test tab is inert until *Update connector* is clicked, and is unreliable for solution-aware connectors. Test from a flow instead.

---

## 6. Sharing model

A solution-aware connector is a Dataverse row, so access needs **table privileges**, not classic connector sharing. Users hitting `prvReadConnector` errors are missing the security role.

Required, in order:

1. Security role **`Fabric Workspace Owner`** with Read on `Connector`, `Connection Reference`, `crbab_Workspaces`, `crbab_AllowedConnectionType` — add it to the solution
2. Entra group → Dataverse **group team** → assign the role to the team
3. Share the **connector** with the group
4. Share the **canvas app** with the group
5. Flows called by the app: Run-only users → connections set to **Provided by run-only user** for the delegated connector, **Use this connection** for SPN-A HTTP actions

Run-only connection settings do **not** survive solution import. Re-apply after every deployment.

---

## 7. Fabric Git API facts

| Endpoint | Notes |
|---|---|
| `GET /v1/workspaces/{id}/git/connection` | 200 + `NotConnected` when disconnected, not 404 |
| `POST .../git/connect` | Synchronous |
| `PATCH .../git/myGitCredentials` | Per-identity; SPN-A must set `ConfiguredConnection` |
| `POST .../git/initializeConnection` | Returns `requiredAction`, `workspaceHead`, `remoteCommitHash` |
| `GET .../git/status` | May return 202 on a cold workspace |
| `POST .../git/commitToGit` | 202 + `x-ms-operation-id` |
| `POST .../git/updateFromGit` | 202 + `x-ms-operation-id` |
| `POST .../git/disconnect` | Synchronous |
| `GET /v1/operations/{id}` and `/result` | LRO polling |

- `gitConnectionState`: `NotConnected` | `Connected` | `ConnectedAndInitialized`
- `requiredAction`: `CommitToGit` | `UpdateFromGit` | `None`
- `workspaceHead` reflects the **workspace**, not the branch. Populated whenever the workspace holds items — including on a first-ever connect to an empty folder. **Null on a workspace that has never synced and holds nothing**, which is the `UpdateFromGit` case. `remoteCommitHash` is the one that is null when the remote is empty. Both verified 2026-08-07.
- **`directoryName` must already exist in the branch.** The portal offers a *Create and sync* prompt when the folder is missing; the REST API has no equivalent and returns `GitProviderResourceNotFound`. Case-sensitive. The folder must also contain no subdirectories unless at least one is a Fabric item directory.
- **Sync operations are all-or-nothing and validate item models.** An item with a relative OneLake reference to a table absent from the target workspace fails the entire operation with `GitSyncFailed`; the real cause is in `error.moreDetails` from `GET /v1/operations/{id}`.
- `GET /v1/gateways/{id}/roleAssignments` needs `ConnectionCreator` or higher; roles are `Admin`, `ConnectionCreatorWithResharing`, `ConnectionCreator`; principals are `User` or `Group`
- **There is no update/PATCH for a Git connection.** Changing branch or directory = disconnect + connect + initialize.

### Sync request bodies — which fields are actually required

| API | Required | Optional |
|---|---|---|
| `commitToGit` | `mode` | `workspaceHead`, `comment`, `items` |
| `updateFromGit` | **`remoteCommitHash`** | `workspaceHead`, `conflictResolution`, `options` |

`workspaceHead` is optional in both and *"may be null only after Initialize Connection"*. Sending a stale one returns `WorkspaceHeadMismatch`.

**`initializeConnection` returns `remoteCommitHash` only when the remote branch has commits.** Empty `remoteCommitHash` + populated `workspaceHead` means the remote is empty and `requiredAction` will be `CommitToGit`. Never branch on the initialization strategy — the strategy tells Fabric how to resolve initialization; `requiredAction` tells you which direction to sync.

`initializeConnection` can also return **202 with no body**, in which case none of the three fields exist and the operation must be polled first.

### Required workspace role per Git operation

| Operation | Role |
|---|---|
| Connect to Git repo | **Admin** |
| Disconnect from Git repo | **Admin** |
| Sync workspace with Git repo | **Admin** |
| Switch branch / change any connection setting | **Admin**; Member/Contributor only if the workspace setting *Allow users with at least Contributor role to change Git branch* is on |
| View Git connection details | Admin, Member, Contributor |
| See workspace Git status | Admin, Member, Contributor |
| Commit workspace changes to Git | Contributor + write on all items + item owner (if the tenant switch is on) + build on external dependencies |
| Update from Git | Same as commit |
| Branch out to another workspace | Admin, Member, Contributor |

This table is why the scope was cut to connect and disconnect.

### Connection APIs

`POST /v1/connections/{connectionId}/roleAssignments` — the caller must hold **UserWithReshare or higher on the connection, or Admin on the bound gateway**. Scope `Connection.ReadWrite.All`. Supports principal type `ServicePrincipal`. **An SPN cannot self-grant**, which is why `AddConnectionRoleAssignment` runs delegated as the connection's owner.

`GET /v1/connections/{connectionId}` — the caller must have permission on the connection, or admin on the gateway. Scope `Connection.Read.All` or `Connection.ReadWrite.All`. Returns `connectionDetails: { type, path }`; for ADO Source Control `path` is the repo URL, so org / project / repo are derived rather than typed.

`GET /v1/connections` has **no server-side type filter** — paginate on `continuationToken` and filter client-side.

### Creating the ADO connection

Owners create their own connection in the Fabric UI. This body is reference only, for scripted setup:

```json
{
  "displayName": "<name>",
  "connectivityType": "ShareableCloud",
  "connectionDetails": {
    "creationMethod": "AzureDevOpsSourceControl.Contents",
    "type": "AzureDevOpsSourceControl",
    "parameters": [
      { "dataType": "Text", "name": "url",
        "value": "https://dev.azure.com/<org>/<project>/_git/<repo>/" }
    ]
  },
  "credentialDetails": {
    "credentials": {
      "credentialType": "ServicePrincipal",
      "tenantId": "...",
      "servicePrincipalClientId": "...",
      "servicePrincipalSecret": "..."
    }
  }
}
```

The trailing slash on the repo URL matters.

---

## 8. Test environment

| | |
|---|---|
| Workspace | `e9de0b2d-0cc1-42ed-9395-28da86acfd97` |
| Fabric connection | `16261289-5d36-4470-b878-2720b3babdfa` |
| Gateway | `420ba247-04b4-4abb-a831-92a96f57871d` |
| ADO org / project / repo | `skscontoso` / `fabric` / `fabricrepo2` |
| Branch / directory | `main` / `test` |
| Init strategy | `PreferRemote` |

---

## 9. Helper scripts (`Workflows/`)

| Script | Purpose | State |
|---|---|---|
| `check role.ps1` | Lists gateway role assignments; decodes `oid` from the JWT to avoid a Graph dependency | Working |
| `list gateways delegated authcode.ps1` | Authorization-code flow via `HttpListener` on `http://localhost:8400/`; prints `upn`/`oid`/`scp` then pages `/v1/gateways` | Working — requires `http://localhost:8400/` registered as a **Web** redirect URI on `gateway_lister_app` |
| `list gateways spn.ps1` | App-only client credentials | Token succeeds, gateway call returns **Unauthorized** — needs the tenant setting plus a gateway role |
| `list gateways delegated.ps1` | Device code flow | **Dead end.** Device code is public-client only; a confidential client always gets `AADSTS7000218`, and passing `client_secret` does not help |
| `test rest.ps1` | Ad-hoc | Contains a plaintext secret |
| `get-operation.ps1` | `GET /v1/operations/{id}` for a Fabric LRO; expands `error.moreDetails`, which names the item behind a wrapper code such as `GitSyncFailed`. Reads the secret from a local notes file by label and never prints it | Working |

---

## 10. Open issues

Maintained separately in [docs/OPEN-ISSUES.md](docs/OPEN-ISSUES.md) — bugs, security, blocking prerequisites, undecided design points, ALM, and the untested end-to-end scenario.

The two that gate everything else:

1. **`ConnectWorkspaceToGit` never syncs content** while reporting success (§1.1). Every connect made so far is suspect.
2. **Plaintext secrets are in the repo and `.gitignore` is deleted** (§2). Rotate and restore before any commit.

---

## 11. Next steps

Flow-level work is tracked as **F\<flow\>.\<n\>** in the *Issues* table in OPEN-ISSUES.

1. Delete `options` from `Update_from_git` (**F5.6**), then handle the 202 from `initializeConnection` (**F5.5**)
2. Surface `error.moreDetails` from `GetGitOperationStatus` (**F2.2**)
3. Move tenant ID, client ID and secret to environment variables (**F1.1**) — multi-environment deployment is confirmed
4. Update the custom connector in **one pass**: add `Connection.ReadWrite.All`, add the three connection operations, then delete and recreate the connection (OPEN-ISSUES §9)
5. Create the `Fabric Workspace Owner` security role and wire up the group team, connector share and app share (§6)
6. Create `crbab_GitAuditLog` and the request table for the write pattern (§3)
7. Run the end-to-end test scenario (OPEN-ISSUES §7)
8. Build `ListMyConnections`, `AddConnectionRoleAssignment`, `DisconnectWorkspaceGit`
9. Move write flows onto the Dataverse request-row trigger (**F5.9**) — required before the app is shared
11. Add the Git wizard screens to the canvas app
12. Decide whether the `ListGateways` 5-page cap needs a "more results" indicator (OPEN-ISSUES §1.4)
