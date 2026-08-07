# Cloud Flow Reference

All flows live in `Workflows/` as unpacked solution JSON. Do not hand-edit these files — edit in the maker portal and re-export.

Flow numbering (1–8) refers to the Git-integration build order. The eight `*Rules` / `*Policy` / `*Setting` flows predate it and serve the networking screens of the app.

> **No flow that authenticates as a service principal works until the tenant prerequisites are in place.** See [docs/PREREQUISITES.md](docs/PREREQUISITES.md) — A3 and B1 in particular. Symptom when missing: a bare `401` on every Fabric call.

---

## Status

Scope was cut on 2026-08-06 after the Fabric Git permissions table was confirmed: workspace **Contributors can already commit, update and view status in the Fabric UI**. Only connect, disconnect and connection-setting changes need Admin, so only those need brokering.

| # | Flow | Built | State |
|---|---|---|---|
| 1 | GetFabricToken | Yes | **Changes required** — hardcoded tenant/client ID (F1.1) |
| 2 | GetGitOperationStatus | Yes | Rewritten in place from `PollFabricOperation` 2026-08-07 — **not yet exported or verified** (F2.2, F2.4) |
| 3 | ListGitConnections | Yes | **Delete** once flow 7 ships — runs as SPN-A, so it returns the broker's connections, not the caller's (F3.1) |
| 4 | GetWorkspaceGitState | Yes | Keep, but demote to internal guard only (F4.1) |
| 5 | ConnectWorkspaceToGit | Yes | Both sync directions passing end to end 2026-08-07. **Being restructured** into stage 1 — connect + probe, then stop (OPEN-ISSUES §10.6) |
| 6 | DisconnectWorkspaceFromGit | No | To build — renamed for symmetry with flow 5 |
| 7 | ListMyConnections | No | To build — delegated |
| 8 | AddConnectionRoleAssignment | No | To build — delegated, synchronous, no polling |
| 9 | SyncWorkspaceWithGit | No | To build — stage 2, performs `commitToGit` / `updateFromGit` |

**Descoped:** `GetGitSyncStatus`, `CommitWorkspaceToGit`, `UpdateWorkspaceFromGit` — Contributors already do all three in the Fabric UI. Also `ChangeGitConnectionSettings`: there is **no update/PATCH API for a Git connection**, so changing branch or directory is disconnect + reconnect, which the existing two flows already cover.

The `commitToGit` and `updateFromGit` **calls** survive as flow 9. Descoping removed them as standalone user-facing flows only; `initializeConnection` still requires one of them to actually move content.

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

### 2. GetGitOperationStatus

A read. The app asks what state an operation is in; this answers and changes nothing.

| | |
|---|---|
| Trigger | **Power Apps (V2)**, input `operationId` |
| Called by | the canvas app's Refresh button |
| Calls | `GetFabricToken` (child), `GET /v1/operations/{id}`, `GET /v1/operations/{id}/result` |
| Returns | `status`, `percentcomplete`, `errorcode`, `errormessage`, `errordetails`, `requiredaction`, `remotecommithash` |

Rewritten in place from `PollFabricOperation` on 2026-08-07 — renamed rather than rebuilt, so the flow GUID and connection references survive.

**One pass, no loop.**

1. `GetFabricToken` — it fetches its own token. `accessToken` is deliberately *not* a trigger input: passing one would put an SPN credential with tenant-wide Fabric rights inside the canvas app, recoverable by anyone who can open it.
2. `GET /v1/operations/{operationId}`, with an explicit exponential retry policy — this is the one call the UI hits repeatedly.
3. `Succeeded` → `GET /v1/operations/{id}/result` as well, tolerating a 404. Not every Fabric operation has a result.
4. Return state, error detail and, when present, `requiredAction` / `remoteCommitHash`.

**Why `/result` is there.** For `commitToGit` and `updateFromGit` it 404s and is ignored — success or failure is the whole answer. It exists for the one case stage 1 cannot answer synchronously: when `initializeConnection` returns **202**, the body is empty and `/result` is the only source of `requiredAction` and `remoteCommitHash`. That is F5.5, and without it a 202 on initialize is a dead end — workspace connected, nothing synced, no flow knowing which way to sync.

**The trigger is `PowerAppV2`, so this cannot be a child flow.** Child flows must use *Manually trigger a flow*. `ConnectWorkspaceToGit`'s `Run_PollFabricOperation` action was deleted 2026-08-07 for exactly this reason. `GetFabricToken` stays a child flow — a parent may have any trigger, so this flow calling it is fine.

**It does not advance anything.** No state machine, no writes, no starting the next sync call — it reports what Fabric says and nothing more. If the status comes back with a `requiredaction`, it is the **app** that decides to call `SyncWorkspaceWithGit`.

**No sweeper, and nothing waits.** Decided 2026-08-07: an operation nobody looks at is not chased. Fabric completes the sync regardless; the only cost is that no local record shows it finished. See §10.5 in OPEN-ISSUES.

### 3. ListGitConnections

| | |
|---|---|
| Trigger | PowerApp V2, no inputs |
| Calls | `GET /v1/connections` (paginated via `continuationToken`) |
| Returns | `connections`, `count` |

Filters to Azure DevOps Source Control connections. Uses the `cont` / `more` / Compose-merge pagination pattern (see Gotchas).

> **Superseded.** This runs as SPN-A, so it returns connections *SPN-A* can see — not the caller's. The wizard picker must show the owner's own connections, which requires a delegated call. See `ListMyConnections` below and change **F3.1**.

### 4. GetWorkspaceGitState

| | |
|---|---|
| Trigger inputs | `workspaceId` |
| Calls | `GET /v1/workspaces/{id}/git/connection` |
| Returns | `gitConnectionState`, `isConnected`, `gitProviderDetails`, `gitCredentials`, `errorMessage` |

`gitConnectionState` is one of `NotConnected`, `Connected`, `ConnectedAndInitialized`. A disconnected workspace returns **200 with `NotConnected`**, not a 404.

> Contributors can view Git connection details in the Fabric UI, so this is no longer needed as a user-facing screen. Keep it as the pre-flight guard for connect and disconnect. See **F4.1**.

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

**Missing:** the authorization check against `crbab_Workspaces` (F5.9) and the audit row (F5.10). Neither exists in the exported JSON.

The wizard supplies `organizationName` / `projectName` / `repositoryName` derived from `GET /v1/connections/{id}` → `connectionDetails.path`, so the user does not paste a URL.

> **Being restructured into stage 1 — connect and probe only.** From OPEN-ISSUES §10.2 and §10.6:
>
> - **Trigger stays Power Apps (V2)** — the wizard calls it and gets an answer straight back. What changes is the signature: the app creates the audit row first and passes **`auditRowId`**, and the flow reads its parameters from that row instead of from eight positional inputs.
> - **Authorization comes from the row, not the caller.** `_createdby_value` is stamped by Dataverse, so it cannot be forged the way a passed-in email could. Check it against `crbab_Workspaces` and fail closed (F5.9).
> - **Step 5 becomes a probe** — `initializationStrategy: None`, never a strategy chosen in advance. The owner cannot answer "prefer remote or workspace?" before anyone knows whether both sides have content.
> - **Step 6 leaves this flow.** The `act_on_requiredAction` Switch, `CommitToGit`, `Update_from_git` and their operation-ID variables all move to flow 9. This flow reports what the probe found and stops.
>
> Returns `outcome`, `message`, `messageDetails`, and the `requiredAction` the app needs to call flow 9 with — or `NeedsChoice` when both sides have content and only the owner can break the tie.
>
> The name stays accurate: `connect` is this flow's first call, and no other flow makes it.

---

## Changes required to the built flows

Tracked as **F\<flow\>.\<n\>** in the *Issues* table in [docs/OPEN-ISSUES.md](docs/OPEN-ISSUES.md) — one register for the whole project, not a second list. The flow numbers there match the Status table above.

---

## Flows still to build

### 6. DisconnectWorkspaceFromGit

| | |
|---|---|
| Trigger | **Power Apps (V2)**, input `auditRowId` |
| Calls | `POST /v1/workspaces/{id}/git/disconnect` |
| Returns | `outcome`, `message` |

Synchronous — returns `200`, no polling. Same pattern as flow 5: the app creates the audit row, the flow reads `_createdby_value` from it and authorizes against `crbab_Workspaces` before calling Fabric. Guard on `gitConnectionState` being `NotConnected` so a repeat call returns a clean message rather than an error.

Renamed from `DisconnectWorkspaceGit` for symmetry with `ConnectWorkspaceToGit`; the old name read as if "Git" were the object being disconnected.

Also the only route to a **branch or directory change**, since no update API exists. The app must warn that disconnect + reconnect re-runs initialization.

### 7. ListMyConnections — delegated

| | |
|---|---|
| Trigger | PowerApp V2, no inputs |
| Calls | `GET /v1/connections` via the **custom connector**, paginated with `continuationToken` |
| Returns | `connections`, `count` |

Runs as the signed-in user, so it returns only that user's connections — a handful, not thousands. Filter client-side to `connectionDetails.type == "AzureDevOpsSourceControl"`; there is **no server-side type filter**.

Surface `displayName`, `id` and `connectionDetails.path` so the wizard can show the repo URL and derive org / project / repo from it.

Requires the connector to carry `Connection.Read.All` (or `Connection.ReadWrite.All`) — see OPEN-ISSUES §9.

### 8. AddConnectionRoleAssignment — delegated

| | |
|---|---|
| Trigger inputs | `connectionId` |
| Calls | `GET /v1/connections/{connectionId}/roleAssignments`, then `POST` the same path if needed, both via the **custom connector** |
| Returns | `outcome`, `message` |

Grants SPN-A the `User` role on the owner's connection so the broker can reference it by ID.

**Check before granting.** `GET` the role assignments first and look for an entry whose `principal.id` equals SPN-A's object ID. If one exists, skip the `POST` and return `outcome = AlreadyGranted`. The `POST` is documented to return **201 Created**; the docs do not say what a duplicate grant returns, and the wizard is re-runnable, so this is not a hypothetical path. Checking is cheaper than discovering the answer in production.

Body of the `POST`:

```json
{
  "principal": { "id": "<SPN-A object ID>", "type": "ServicePrincipal" },
  "role": "User"
}
```

**No polling.** The API documents only `201`, `429` and error codes — there is no `202`, no `x-ms-operation-id` and no long-running operation. When the call returns, the grant is in effect. This flow stays synchronous and stays out of the request-table pattern (OPEN-ISSUES §10.2).

**This must be delegated.** The API requires the caller to hold `UserWithReshare` or higher on the connection, or Admin on the bound gateway — an SPN cannot self-grant. The owner is Owner on the connection they created, so the delegated call succeeds.

Self-authorizing by construction: the caller can only grant on connections they already control, so no `crbab_Workspaces` check is needed and a PowerApp V2 trigger is acceptable.

Runs on the **final** wizard step, immediately before the write flow is called, so an abandoned wizard leaves no stray grants.

### 9. SyncWorkspaceWithGit

Stage 2. Always called after `ConnectWorkspaceToGit` succeeds — stage 1 connects and reports, stage 2 moves the content.

| | |
|---|---|
| Trigger | **Power Apps (V2)** — `auditRowId`, `requiredAction`, `initializationStrategy` (empty unless the owner had to choose) |
| Calls | `initializeConnection` with the chosen strategy **only** when stage 1 returned `NeedsChoice`, then `commitToGit` or `updateFromGit` |
| Returns | `outcome`, `message`, `messageDetails`, `operationId` |

Inherits `act_on_requiredAction`, `CommitToGit` and `Update_from_git` from flow 5 — moved, not rewritten.

**It does not wait.** The sync returns 202; write `operationId` to the audit row and return. Fabric finishes on its own, and the owner watches with flow 2 if they care.

A separate flow rather than a branch in flow 5, because the workspace is **already connected** by the time it runs — calling `connect` again would fail.

Same authorization pattern: read `_createdby_value` from the audit row, check it against `crbab_Workspaces`, fail closed.

> **`SweepGitRequests` was considered and dropped 2026-08-07.** A background sweeper only earns its keep when a queued request can be stranded. Nothing queues here, and Fabric completes the sync whether or not anyone is watching. Recorded so the idea is not reinvented.

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

**Do-until timeouts report success.** Always add a post-loop condition checking the real terminal state. `ListGateways` is the only flow with a loop left.

**Don't reference loop-internal actions from outside.** Capture values into variables inside the loop instead.

**Renaming an action breaks every expression referencing it.** Rename immediately after adding, before wiring anything.

**The Git folder must already exist in the branch.** `connect` returns `GitProviderResourceNotFound` for a missing folder — the portal's *Create and sync* prompt has no API equivalent. Names are case-sensitive. See OPEN-ISSUES §1.11.

**Git carries metadata, not data.** Updating an empty workspace from a populated folder fails if any item holds a relative OneLake reference to a table that does not exist in the target. The operation is all-or-nothing — one bad item fails the whole sync. See OPEN-ISSUES §1.13.

**`GitSyncFailed` is a wrapper.** The usable cause is in `error.moreDetails` from `GET /v1/operations/{id}`. Use `Workflows/get-operation.ps1`.

**429 handling.** Fabric returns `Retry-After`. Honour it — at 4000 workspaces this will happen.

**Hardcoded tenant and client IDs.** `GetFabricToken` embeds the tenant GUID in the URI and the client ID in the body. These are per-environment values and must become environment variables before the first deployment to a second environment. See F1.1.

**One broker identity.** All app-only calls run as `sp_fabric_powerapp`. `sp_fabric_monit` is a monitoring identity with tenant-wide read/write and must not be used by these flows.
**There is no update API for a Git connection.** Changing branch or directory means `git/disconnect` then `git/connect` and a fresh `initializeConnection`.
