# Cloud Flow Reference

All flows live in `Workflows/` as unpacked solution JSON. Do not hand-edit these files — edit in the maker portal and re-export.

Flow numbering (1–9) refers to the Git-integration build order. The eight `*Rules` / `*Policy` / `*Setting` flows predate it and serve the networking screens of the app.

---

## Prerequisite for every app-only flow

No flow that authenticates as a service principal will work until both of these exist in the target tenant:

1. Entra security group **`fabric_power_app_grp`** containing the **`sp_fabric_powerapp` service principal**
2. Fabric Admin portal → Tenant settings → Developer settings → **"Service principals can call Fabric public APIs"** → Enabled, scoped to that group

Confirmed working 2026-08-06. Before this was configured, every Fabric call returned `401 Unauthorized` — *"The caller is not authenticated to access this resource"*.

This is **not** granted by Entra application permissions. An app-only Fabric token with an empty `roles` claim is normal.

This must be repeated per environment. It is on the post-import checklist (OPEN-ISSUES §8.4). Diagnose with `Workflows/diag-401.ps1`: 401 = the setting above is missing; 403 = the setting is fine and an object-level role is missing.

---

## Status

Scope was cut on 2026-08-06 after the Fabric Git permissions table was confirmed: workspace **Contributors can already commit, update and view status in the Fabric UI**. Only connect, disconnect and connection-setting changes need Admin, so only those need brokering.

| # | Flow | Built | State |
|---|---|---|---|
| 1 | GetFabricToken | Yes | **Changes required** — wrong SPN, hardcoded tenant/client (C1, C2) |
| 2 | PollFabricOperation | Yes | **Changes required** — post-loop terminal assertion (C3) |
| 3 | ListGitConnections | Yes | **Superseded** — runs as SPN-A; the picker must be delegated (C4) |
| 4 | GetWorkspaceGitState | Yes | Keep, but demote to internal guard only (C5) |
| 5 | ConnectWorkspaceToGit | Yes | Switch bug fixed & exported (v1.0.0.6); `workspaceHead`, 202 handling, authorization and audit still open (C7–C9) |
| 6 | DisconnectWorkspaceGit | No | To build |
| 7 | ~~GetGitSyncStatus~~ | — | **Descoped** — Contributors see status in the UI |
| 8 | ~~CommitWorkspaceToGit~~ | — | **Descoped** — Contributors can commit in the UI |
| 9 | ~~UpdateWorkspaceFromGit~~ | — | **Descoped** — Contributors can update in the UI |
| 10 | ListMyConnections | No | To build — delegated |
| 11 | RegisterGitConnection | No | To build — delegated |

Also descoped: `ChangeGitConnectionSettings`. There is **no update/PATCH API for a Git connection** — changing branch or directory is disconnect + reconnect, which the existing two flows already cover.

The `commitToGit` and `updateFromGit` **calls** stay inside `ConnectWorkspaceToGit`. Descoping removed them as standalone user-facing flows only; `initializeConnection` still requires one of them to actually move content.

---

## Git integration flows

### 1. GetFabricToken

Child flow. Central place to acquire an SPN-A token so the client-credentials block is not copy-pasted into every flow.

| | |
|---|---|
| Trigger | PowerApp V2, no inputs |
| Calls | `POST https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/token` |
| Scope | `https://api.fabric.microsoft.com/.default` |
| Returns | `access_token` |

Secret currently comes from an environment variable. Migrate to Key Vault before production.

### 2. PollFabricOperation

Child flow. Fabric long-running operations return `202` plus an `x-ms-operation-id` header; this polls until terminal.

| | |
|---|---|
| Trigger inputs | `operationId`, `accessToken` |
| Calls | `GET /v1/operations/{operationId}` |
| Returns | `status`, `errorCode`, `errorMessage`, `attempts` |

Terminal states are `Succeeded` and `Failed`. A Do-until that exits on its own limit reports **success**, so the post-loop condition must distinguish a real terminal status from a timeout.

### 3. ListGitConnections

| | |
|---|---|
| Trigger | PowerApp V2, no inputs |
| Calls | `GET /v1/connections` (paginated via `continuationToken`) |
| Returns | `connections`, `count` |

Filters to Azure DevOps Source Control connections. Uses the `cont` / `more` / Compose-merge pagination pattern (see Gotchas).

> **Superseded.** This runs as SPN-A, so it returns connections *SPN-A* can see — not the caller's. The wizard picker must show the owner's own connections, which requires a delegated call. See `ListMyConnections` below and change **C4**.

### 4. GetWorkspaceGitState

| | |
|---|---|
| Trigger inputs | `workspaceId` |
| Calls | `GET /v1/workspaces/{id}/git/connection` |
| Returns | `gitConnectionState`, `isConnected`, `gitProviderDetails`, `gitCredentials`, `errorMessage` |

`gitConnectionState` is one of `NotConnected`, `Connected`, `ConnectedAndInitialized`. A disconnected workspace returns **200 with `NotConnected`**, not a 404.

> Contributors can view Git connection details in the Fabric UI, so this is no longer needed as a user-facing screen. Keep it as the pre-flight guard for connect and disconnect. See **C5**.

### 5. ConnectWorkspaceToGit

The only flow with substantial logic.

| | |
|---|---|
| Trigger inputs | `workspaceId`, `connectionId`, `organizationName`, `projectName`, `repositoryName`, `branchName`, `directoryName`, `initializationStrategy` |
| Returns | `outcome`, `message`, `operationId` |

**As built:**

1. **Token** — child call to `GetFabricToken`.
2. **Guard** — `GET .../git/connection`; abort if already connected rather than silently re-pointing it.
3. **Connect** — `POST .../git/connect` with `gitProviderDetails` (`gitProviderType: AzureDevOps`) and `myGitCredentials: { source: "ConfiguredConnection", connectionId }`.
4. **Set credentials** — `PATCH .../git/myGitCredentials` with the same connection.
5. **Initialize** — `POST .../git/initializeConnection` with the strategy. Response carries `requiredAction`, `remoteCommitHash`, `workspaceHead`.
6. **Follow `requiredAction`** — Switch: `CommitToGit` pushes up, `UpdateFromGit` pulls down, `None` is done. Both return `202` → poll via flow 2.

Step 6 is where naive implementations break: initialize returns 200 but the workspace is **not** synced until the required action runs. The Switch that drives this was broken until 2026-08-06 — see OPEN-ISSUES §1.1.

**Missing:** the authorization check against `crbab_Workspaces` (C8) and the audit row (C9). Neither exists in the exported JSON.

The wizard supplies `organizationName` / `projectName` / `repositoryName` derived from `GET /v1/connections/{id}` → `connectionDetails.path`, so the user does not paste a URL. The trigger signature is unchanged.

---

## Changes required to the built flows

Flows 1–5 exist and are exported. Each item below is a required edit, not a suggestion. Full context in [docs/OPEN-ISSUES.md](docs/OPEN-ISSUES.md).

| ID | Flow | Change | Why |
|---|---|---|---|
| **C1** | 8 networking flows | They authenticate as `sp_fabric_monit` (`b5c04c9c-…`). Repoint them to `sp_fabric_powerapp` (`a385fde9-…`), which `GetFabricToken` already uses. Simplest route: replace the inline token block in each with a child call to `GetFabricToken`. | `sp_fabric_monit` holds `Tenant.Read/ReadWrite.All`. An app used by 4000 owners must not run on a tenant-wide identity. **Decision 2026-08-06** |
| **C2** | GetFabricToken + all 8 networking flows | Tenant ID `9e929790-…` is hardcoded in the token URI and the client ID is hardcoded in the request body. Move both to **environment variables**. `ab_TenantId` already exists in `environmentvariabledefinitions/` and is currently **unused**. | Multi-environment deployment is confirmed; hardcoded values require hand-editing every flow after each import |
| **C3** | PollFabricOperation | Add a post-loop condition asserting a real terminal status. A Do-until that exits on its own iteration limit reports **success**. | Silent false-positive on every long operation |
| **C4** | ListGitConnections | Retire, or rebuild as `ListMyConnections` on the delegated custom connector. | It lists SPN-A's connections; the picker must list the caller's |
| **C5** | GetWorkspaceGitState | Demote from app-facing to internal guard. Keep the flow, drop the screen. | Contributors already see connection details in the Fabric UI |
| ~~**C6**~~ | ConnectWorkspaceToGit | ~~`act_on_requiredAction` case values were `PreferWorkspace` / `PreferRemote`.~~ **Done & exported 2026-08-06.** | Nothing synced while the flow reported success. §1.1 |
| **C7** | ConnectWorkspaceToGit | **Delete** `workspaceHead` from the `Update_from_git` body. It is optional, and interpolation renders a null as `""`. | Correctness; the API accepts `""`. §1.2 |
| ~~**C7b**~~ | ConnectWorkspaceToGit | ~~empty `remoteCommitHash`~~ — resolved by C6. | §1.8 |
| **C7c** | ConnectWorkspaceToGit | Handle a **202** from `initializeConnection` — poll before reading `requiredAction`. | On 202 the body is empty, so every field resolves blank and the flow silently no-ops. §1.9 |
| **C7d** | ConnectWorkspaceToGit | The `Has_operation` condition compares status to `"Succeeded "` — remove the trailing space. | Never matches, so `outcome` is always `Failed`. §1.12 |
| **C7e** | PollFabricOperation | Return `error.moreDetails` from `GET /v1/operations/{id}`, not just `errorcode` / `errormessage`. | `GitSyncFailed` is a wrapper; `moreDetails` names the failing item. §1.13 |
| **C8** | ConnectWorkspaceToGit | Add the `crbab_Workspaces` ownership check before any write, and move the trigger to the Dataverse request-row pattern. **Deferred 2026-08-06 — to be built later.** | The PowerApp V2 trigger cannot prove caller identity — the caller parameter is forgeable. Until this exists the flow will act on any workspace ID it is handed |
| **C9** | ConnectWorkspaceToGit | Write an audit row to `crbab_GitAuditLog` (table not yet created). | No record of who connected what |
| **C10** | All HTTP + child-flow actions | Confirm the retry policy is not **None**; raise retry counts on Fabric calls. | 429 at 4000 workspaces. §6.1 |
| **C11** | ConnectWorkspaceToGit | Test whether the `PATCH myGitCredentials` step is redundant; delete it if so, otherwise set run-after to tolerate failure. | §5.4 |

---

## Flows still to build

### 6. DisconnectWorkspaceGit

| | |
|---|---|
| Trigger inputs | `workspaceId` |
| Calls | `POST /v1/workspaces/{id}/git/disconnect` |
| Returns | `outcome`, `message` |

Synchronous — returns `200`, no polling. Authorize against `crbab_Workspaces` first and write an audit row. Guard on `gitConnectionState` being `NotConnected` so a repeat call returns a clean message rather than an error.

Also the only route to a **branch or directory change**, since no update API exists. The app must warn that disconnect + reconnect re-runs initialization.

### 10. ListMyConnections — delegated

| | |
|---|---|
| Trigger | PowerApp V2, no inputs |
| Calls | `GET /v1/connections` via the **custom connector**, paginated with `continuationToken` |
| Returns | `connections`, `count` |

Runs as the signed-in user, so it returns only that user's connections — a handful, not thousands. Filter client-side to `connectionDetails.type == "AzureDevOpsSourceControl"`; there is **no server-side type filter**.

Surface `displayName`, `id` and `connectionDetails.path` so the wizard can show the repo URL and derive org / project / repo from it.

Requires the connector to carry `Connection.Read.All` (or `Connection.ReadWrite.All`) — see OPEN-ISSUES §9.

### 11. RegisterGitConnection — delegated

| | |
|---|---|
| Trigger inputs | `connectionId` |
| Calls | `POST /v1/connections/{connectionId}/roleAssignments` via the **custom connector** |
| Returns | `outcome`, `message` |

Grants SPN-A the `User` role on the owner's connection so the broker can reference it by ID.

Body:

```json
{
  "principal": { "id": "<SPN-A object ID>", "type": "ServicePrincipal" },
  "role": "User"
}
```

**This must be delegated.** The API requires the caller to hold `UserWithReshare` or higher on the connection, or Admin on the bound gateway — an SPN cannot self-grant. The owner is Owner on the connection they created, so the delegated call succeeds.

Self-authorizing by construction: the caller can only grant on connections they already control, so no `crbab_Workspaces` check is needed and a PowerApp V2 trigger is acceptable.

Runs on the **final** wizard step, immediately before `ConnectWorkspaceToGit`, so an abandoned wizard leaves no stray grants. Make it idempotent — a repeat grant must not fail the run.

---

## Networking flows (pre-existing)

| Flow | Inputs | Endpoint (under `/v1/workspaces/{id}/networking/communicationPolicy`) | Returns |
|---|---|---|---|
| GetOAPSetting | `workspaceId` | (root) | `OAPEnabled` |
| GetOutboundRules | `workspaceId` | `/outbound/connections` | `RulesJson`, `ETag` |
| SetOutboundRules | `workspaceId`, `RulesJson` | `/outbound/connections` | `Status` |
| GetGatewayRules | `workspaceId` | `/outbound/gateways` | `RulesJson` |
| SetGatewayRules | `workspaceId`, `RulesJson` | `/outbound/gateways` | `Status`, `ErrorMessage` |
| GetGitPolicy | `workspaceId` | `/outbound/git` | `GitAction` |
| SetGitPolicy | `workspaceId`, `Action` | `/outbound/git` | `Status` |

`GetOutboundRules` returns an `ETag` that `SetOutboundRules` must echo for optimistic concurrency.

### ListGateways

| | |
|---|---|
| Trigger | PowerApp V2, no inputs |
| Calls | `GET /v1/gateways` via **custom connector** `gateway_lst_app_con` |
| Returns | `GatewaysJson` |

The only flow running in **delegated** (per-user) context. Everything else uses the broker SPN.

The backtick `cont` initialisation and the stale `shared_webcontents` connection reference were both fixed and verified on 2026-08-06. The 5-page cap remains by design — see OPEN-ISSUES §1.4.

---

## Gotchas

**Positional trigger keys.** PowerApp V2 stores inputs as `text`, `text_1`, `text_2`… The name you type is only the `title`. Map them to named variables in the first action.

**Self-reference is illegal.** `Set variable X = union(variables('X'), …)` fails. Use a Compose holding the union, then set the variable from `outputs('Compose')`. See `MergePages` in ListGateways.

**Do-until cannot express OR in the UI.** Switch to advanced mode: `@or(equals(...), equals(...))`, or set a boolean `isDone` flag inside the loop.

**Do-until timeouts report success.** Always add a post-loop condition checking the real terminal state.

**Don't reference loop-internal actions from outside.** Capture values into variables inside the loop instead.

**Renaming an action breaks every expression referencing it.** Rename immediately after adding, before wiring anything.

**The Git folder must already exist in the branch.** `connect` returns `GitProviderResourceNotFound` for a missing folder — the portal's *Create and sync* prompt has no API equivalent. Names are case-sensitive. See OPEN-ISSUES §1.11.

**Git carries metadata, not data.** Updating an empty workspace from a populated folder fails if any item holds a relative OneLake reference to a table that does not exist in the target. The operation is all-or-nothing — one bad item fails the whole sync. See OPEN-ISSUES §1.13.

**`GitSyncFailed` is a wrapper.** The usable cause is in `error.moreDetails` from `GET /v1/operations/{id}`. Use `Workflows/get-operation.ps1`.

**429 handling.** Fabric returns `Retry-After`. Honour it — at 4000 workspaces this will happen.

**Hardcoded tenant and client IDs.** Every token-acquiring flow embeds the tenant GUID in the URI and the client ID in the body. These are per-environment values and must become environment variables before the first deployment to a second environment. See C2.

**One broker identity.** All app-only calls run as `sp_fabric_powerapp`. `sp_fabric_monit` is a monitoring identity with tenant-wide read/write and must not be used by these flows.
**There is no update API for a Git connection.** Changing branch or directory means `git/disconnect` then `git/connect` and a fresh `initializeConnection`.
