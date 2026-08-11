# Cloud Flow Reference

All flows live in `Workflows/` as unpacked solution JSON. Do not hand-edit these files — edit in the maker portal and re-export.

Flow numbering (1–8) refers to the Git-integration build order. The eight `*Rules` / `*Policy` / `*Setting` flows predate it and serve the networking screens of the app.

> **No flow that authenticates as a service principal works until the tenant prerequisites are in place.** See [docs/PREREQUISITES.md](docs/PREREQUISITES.md) — A3 and B1 in particular. Symptom when missing: a bare `401` on every Fabric call.

---

## Status

Scope was cut on 2026-08-06 after the Fabric Git permissions table was confirmed: workspace **Contributors can already commit, update and view status in the Fabric UI**. Only connect, disconnect and connection-setting changes need Admin, so only those need brokering.

| # | Flow | Built | State |
|---|---|---|---|
| 1 | GetFabricToken | Yes | Complete — tenant and client ID are environment variables. Verified in export 2026-08-07 (F1.1 closed) |
| 2 | GetGitOperationStatus | Yes | Complete — verified in export 2026-08-07 (F2.2, F2.4 closed) |
| 3 | ListMyConnections | Yes | **Built and tested 2026-08-07**, delegated. Verified in export (F3.1 closed) |
| 4 | GetWorkspaceGitState | Yes | Complete — app-facing. Decision 2026-08-07: keep as is (F4.1 closed) |
| 5 | ConnectWorkspaceToGit | Yes | **Restructured and tested 2026-08-11** as stage 1 — connect + probe, then stop. All five paths exercised; verified in export |
| 6 | DisconnectWorkspaceFromGit | Yes | **Built and tested 2026-08-10**. Both branches exercised — connected and not connected |
| 7 | AddConnectionRoleAssignment | Yes | **Built and tested 2026-08-10**, delegated. Both condition branches exercised |
| 8 | SyncWorkspaceWithGit | Yes | **Built and tested 2026-08-11.** All six paths exercised; verified in export |

**Descoped:** `GetGitSyncStatus`, `CommitWorkspaceToGit`, `UpdateWorkspaceFromGit` — Contributors already do all three in the Fabric UI. Also `ChangeGitConnectionSettings`: there is **no update/PATCH API for a Git connection**, so changing branch or directory is disconnect + reconnect, which the existing two flows already cover.

The `commitToGit` and `updateFromGit` **calls** survive as flow 8. Descoping removed them as standalone user-facing flows only; `initializeConnection` still requires one of them to actually move content.

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

Tenant ID and client ID come from the `ab_TenantId` and `ab_BrokerClientId` environment variables, both present in the solution — no hand-editing after import. The **secret** is still an `Initialize_variable` inside the flow; exports scrub it to `" "`, so it must be re-entered per environment (PREREQUISITES E4). Migrate to a Key Vault-backed secret variable before production (OPEN-ISSUES §2).

### 2. GetGitOperationStatus

A read. The app asks what state an operation is in; this answers and changes nothing.

| | |
|---|---|
| Trigger | **Power Apps (V2)**, one input — titled `operationId`, underlying key `text` |
| Called by | the canvas app's Refresh button |
| Calls | `GetFabricToken` (child), `GET /v1/operations/{id}`, `GET /v1/operations/{id}/result` |
| Returns | `status`, `percentcomplete`, `errorcode`, `errormessage`, `errordetails`, `requiredaction`, `remotecommithash` |

Rewritten in place from `PollFabricOperation` on 2026-08-07 — renamed rather than rebuilt, so the flow GUID and connection references survive.

> The trigger input's underlying key is `text`; `operationId` is only the display title, and the flow reads `triggerBody()['text']`. Harmless with a single input. If a second is ever added, rename the keys first — `text`, `text_1`, `text_2` bind positionally and are trivial to cross-wire.

**One pass, no loop.**

1. `GetFabricToken` — it fetches its own token. `accessToken` is deliberately *not* a trigger input: passing one would put an SPN credential with tenant-wide Fabric rights inside the canvas app, recoverable by anyone who can open it.
2. `GET /v1/operations/{operationId}`, with an explicit exponential retry policy — this is the one call the UI hits repeatedly.
3. `Succeeded` → `GET /v1/operations/{id}/result` as well, tolerating a 404. Not every Fabric operation has a result.
4. Return state, error detail and, when present, `requiredAction` / `remoteCommitHash`.

**Why `/result` is there.** For `commitToGit` and `updateFromGit` it 404s and is ignored — success or failure is the whole answer. It exists for the one case stage 1 cannot answer synchronously: when `initializeConnection` returns **202**, the body is empty and `/result` is the only source of `requiredAction` and `remoteCommitHash`. That is F5.5, and without it a 202 on initialize is a dead end — workspace connected, nothing synced, no flow knowing which way to sync.

**The trigger is `PowerAppV2`, so this cannot be a child flow.** Child flows must use *Manually trigger a flow*. `ConnectWorkspaceToGit`'s `Run_PollFabricOperation` action was deleted 2026-08-07 for exactly this reason. `GetFabricToken` stays a child flow — a parent may have any trigger, so this flow calling it is fine.

**It does not advance anything.** No state machine, no writes, no starting the next sync call — it reports what Fabric says and nothing more. If the status comes back with a `requiredaction`, it is the **app** that decides to call `SyncWorkspaceWithGit`.

**No sweeper, and nothing waits.** Decided 2026-08-07: an operation nobody looks at is not chased. Fabric completes the sync regardless; the only cost is that no local record shows it finished. See §10.5 in OPEN-ISSUES.

### 3. ListMyConnections — delegated

| | |
|---|---|
| Trigger | PowerApp V2, no inputs |
| Calls | `ListConnections` on the **custom connector**, paginated with `continuationToken` |
| Returns | `connections`, `count` |

Runs as the signed-in user, so it returns only that user's connections — a handful, not thousands. Filters client-side to `connectionDetails.type == "AzureDevOpsSourceControl"`; there is **no server-side type filter**.

Surfaces `displayName`, `id` and `connectionDetails.path` so the wizard can show the repo URL and derive org / project / repo from it.

**As built.** `Initialize_connections` / `_cont` / `_isDone` → `Do_until` containing `list_my_connections` (OpenApiConnection) → `Merge_connections` → the three setters → `Filter_array` → `Select` → respond.

Built on 2026-08-07 by renaming the old broker-side flow in place and swapping its `Http` action for the connector, so it kept its GUID (`98B3E46A-278F-F111-8076-7CED8D76BF1B`) and its pagination logic — the only non-trivial part. The child-flow token call and `access_token` variable went with the rewrite; a delegated connector action carries its own auth.

The connection reference is `runtimeSource: "invoker"`, which is what makes the action run as the caller rather than as the flow owner. Without it the flow would silently return the owner's connections and reintroduce the exact bug F3.1 described.

Requires `Connection.ReadWrite.All` on the connector — see OPEN-ISSUES §9.

### 4. GetWorkspaceGitState

| | |
|---|---|
| Trigger inputs | `workspaceId` |
| Calls | `GET /v1/workspaces/{id}/git/connection` |
| Returns | `gitConnectionState`, `isConnected`, `gitProviderDetails`, `gitCredentials`, `errorMessage` |

`gitConnectionState` is one of `NotConnected`, `Connected`, `ConnectedAndInitialized`. A disconnected workspace returns **200 with `NotConnected`**, not a 404.

**App-facing, and staying that way.** Decision 2026-08-07, reversing F4.1. The wizard calls this first, before showing anything: a workspace that is already connected needs its current org / project / repo / branch displayed and the offered actions changed — disconnect or change settings rather than connect. The app cannot make that decision without reading the state, and sending the owner to the Fabric UI to look it up defeats the point of the wizard.

It is **not** a guard for the write flows. Flow 5 already performs its own inline `GET .../git/connection` in `Check_existing` and branches on `gitConnectionState`; flow 6 should do the same. A flow that authorizes a write must read the state itself, in the same run — a value the app read earlier and passed back in is a value the caller could have altered.

Trigger stays `PowerAppV2`. No change required.

### 5. ConnectWorkspaceToGit — stage 1

Restructured and tested 2026-08-11. Connects the workspace and **probes** for what Fabric wants done, then stops. Flow 8 moves the content.

| | |
|---|---|
| Trigger inputs | `workspaceId`, `connectionId`, `organizationName`, `projectName`, `repositoryName`, `branchName`, `directoryName` |
| Returns | `outcome`, `requiredAction`, `operationId`, `message` |

**As built:**

1. **Token** — child call to `GetFabricToken`, then variables `accessToken`, `outcome` (seeded `Failed`), `message`, `operationId`, `requiredAction` (seeded `None`).
2. **`Check_existing`** — `GET .../git/connection`. The `Is_not_connected` condition tests `gitConnectionState` against `NotConnected`; the else branch answers `AlreadyConnected` and does nothing, rather than silently re-pointing an existing connection.
3. **`Connect`** — `POST .../git/connect` with `gitProviderDetails` (`gitProviderType: AzureDevOps`) and `myGitCredentials: { source: "ConfiguredConnection", connectionId }`.
4. **`Set_credentials`** — `PATCH .../git/myGitCredentials` with the same connection. Probably redundant, since step 3 already carries the same payload, but **kept by decision 2026-08-11** — it has never failed in testing and removing it would mean re-running every stage-1 test to prove nothing regressed. See OPEN-ISSUES §5.4 for the one residual it carries.
5. **`Initialize_connection`** — `POST .../git/initializeConnection` with the body hardcoded to `{"initializationStrategy": "None"}`.
6. **`Set_outcome`, `Set_requiredAction`, `Set_message`, `Set_operationId_probe`** — read the probe's answer into the response variables.

#### The probe

Step 5 sends `None` deliberately. The owner cannot sensibly answer "prefer remote or prefer workspace?" before anyone knows whether both sides even have content — so the flow asks Fabric first and lets the answer drive the question:

| `outcome` | Meaning | What the app does next |
|---|---|---|
| `Connected` | Fabric named a direction, in `requiredAction` | Call flow 8 with that `requiredAction`, no strategy |
| `NeedsChoice` | Both sides hold items; Fabric refuses to guess | Ask the owner, then call flow 8 with their strategy |
| `AlreadyConnected` | Nothing was done | Offer disconnect or change settings |
| `Failed` | `Connect` or the probe errored; raw payload in `message` | Show the error |
| `Pending` | `202` from initialize | Unreachable while Asynchronous Pattern is On; kept as a guard |

**Asynchronous Pattern stays On for `Initialize_connection` — decided 2026-08-11.** Initialize only records a direction, it does not move data, and it has returned synchronously in every test. Letting the connector absorb a rare 202 is simpler than owning a polling loop inside the 120-second response budget. The cost, if a slow initialize ever happens, is that the owner sees `Connected` / `None` and has to run flow 8 by hand — nothing breaks, but nothing moves either.

`NeedsChoice` is derived from `errorCode: MissingInitializationStrategy`, so `Set_outcome` runs after `Initialize_connection` on **Succeeded or Failed** — a `400` here is a successful probe, not a failure.

**Emptiness decides, not difference.** Fabric returns a direction when exactly one side is empty and demands a strategy when both hold items. It does not compare trees: a workspace and directory with identical content still yield `NeedsChoice`, because a fresh connection has no shared history and either side is a plausible source of truth.

#### Failure handling

`Set_outcome_connectfailed` and `Set_message_connectfailed` hang off `Connect` on **Failed** as a parallel branch, and `Respond` runs after `Is_not_connected` on **Succeeded or Failed**.

Without both of those, a failed `Connect` skipped everything downstream and the flow ended with **no response at all** — the app got a hard error and no message. The most likely real-world failure lands exactly there: `GitProviderResourceNotFound`, returned when `directoryName` doesn't already exist in the repo. Git can't store an empty directory, so a first-time connect needs a folder containing at least a placeholder file.

#### Verified 2026-08-11

| Setup | `outcome` | `requiredAction` |
|---|---|---|
| Workspace and directory both populated | `NeedsChoice` | `None` |
| Run again without disconnecting | `AlreadyConnected` | `None` |
| Directory that doesn't exist | `Failed` + `GitProviderResourceNotFound` | `None` |
| Empty workspace, populated directory | `Connected` | `UpdateFromGit` |
| Populated workspace, empty directory | `Connected` | `CommitToGit` |

All three handoffs to flow 8 were then driven from these results, including a first-ever commit into a directory the broker had never written to.

The wizard supplies `organizationName` / `projectName` / `repositoryName` derived from `GET /v1/connections/{id}` → `connectionDetails.path`, so the user does not paste a URL.

> **No authorization check yet.** The flow connects any workspace the broker administers, for any caller who can run it. The audit row and the `crbab_Workspaces` check (F5.9, F5.10) are absent from the exported JSON. Deferred by decision, not oversight — see OPEN-ISSUES §10.3.

---

### 6. DisconnectWorkspaceFromGit

Built and tested 2026-08-10, both branches. Runs as the broker.

| | |
|---|---|
| Trigger | **Power Apps (V2)**, one text input `workspaceId` |
| Calls | `GET /v1/workspaces/{id}/git/connection`, then `POST /v1/workspaces/{id}/git/disconnect` |
| Returns | `outcome`, `message` |

As built:

1. `Run_a_Child_Flow` → `GetFabricToken`, then `Initialize_variable` holding `accessToken` = `@body('Run_a_Child_Flow')?['access_token']`.
2. `Check_existing` — GET the Git connection.
3. `Condition` — `@equals(coalesce(body('Check_existing')?['gitConnectionState'],''), 'NotConnected')`.
4. Yes → respond `NotConnected`, nothing to do.
5. No → `Disconnect` POST with an empty body, then a single Respond whose **run after** covers both *is successful* and *has failed*, reading `outputs('Disconnect')['statusCode']` to choose between `Disconnected` and `Failed`.

Synchronous — returns `200`, no polling. The state guard means a repeat call returns a clean message rather than an error, and the run-after tolerance means a Fabric error reaches the app as a readable message instead of a dead run.

`gitConnectionState` has three values — `NotConnected`, `Connected`, `ConnectedAndInitialized` — so guarding only on `NotConnected` correctly lets both connected states through.

Requires **workspace Admin**, which the broker holds. A `403` here means the broker lost its role on the workspace, not a scope problem.

> **No authorization check yet.** The flow takes `workspaceId` directly and will disconnect any workspace the broker administers, for any caller who can run it. The `crbab_Workspaces` ownership check is deferred by decision, not oversight — see OPEN-ISSUES §10.3.

Renamed from `DisconnectWorkspaceGit` for symmetry with `ConnectWorkspaceToGit`; the old name read as if "Git" were the object being disconnected.

Also the only route to a **branch or directory change**, since no update API exists. The app must warn that disconnect + reconnect re-runs initialization. Disconnecting leaves the ADO folder and its contents untouched.

### 7. AddConnectionRoleAssignment — delegated

Built and tested 2026-08-10. Grants SPN-A the `User` role on the owner's connection so the broker can reference it by ID.

| | |
|---|---|
| Trigger | **Power Apps (V2)**, one text input `connectionId` |
| Calls | `ListConnectionRoleAssignments`, then `AddConnectionRoleAssignment` if needed, both via the **custom connector**, delegated |
| Returns | `outcome` — `Granted` or `AlreadyGranted` — plus `message` |

As built:

1. `ListConnectionRoleAssignments` — `fabricConnectionId` from the trigger input. No `continuationToken` is sent, so only the first page is examined; see below.
2. `Filter_array` — from `@outputs('ListConnectionRoleAssignments')?['body/value']`, where `@equals(item()?['principal']?['id'], parameters('BrokerObjectId (ab_BrokerObjectId)'))`.
3. `Condition` — `@empty(body('Filter_array'))` equals `true`.
4. Yes branch → `AddConnectionRoleAssignment` with `id` = the same environment variable, `type` = `ServicePrincipal`, `role` = `User` → respond `Granted`.
5. No branch → respond `AlreadyGranted`.

**Check before granting.** The `POST` returns **201 Created** and the docs do not say what a duplicate grant returns; the wizard is re-runnable, so this is not a hypothetical path. Both branches were tested against connection `16261289-5d36-4470-b878-2720b3babdfa` by running twice.

**The role-assignment list is not paged through.** Verified in the export 2026-08-11: the call sends no `continuationToken`, so a connection with enough role assignments to spill onto a second page could hide an existing broker grant and trigger a duplicate `POST`. Harmless on today's test connections, which have a handful of assignments each. Worth fixing before a connection shared with a large group goes through the wizard.

The object ID comes from the `ab_BrokerObjectId` environment variable (PREREQUISITES E3). It is **not** `ab_BrokerClientId` — the roleAssignments API wants the service principal's directory object ID, and the client ID is silently wrong rather than rejected.

**No polling.** The API documents only `201`, `429` and error codes — there is no `202`, no `x-ms-operation-id` and no long-running operation. When the call returns, the grant is in effect.

**This must be delegated.** The API requires the caller to hold `UserWithReshare` or higher on the connection, or Admin on the bound gateway — an SPN cannot self-grant. The owner is Owner on the connection they created, so the delegated call succeeds.

Self-authorizing by construction: the caller can only grant on connections they already control, so no `crbab_Workspaces` check is needed and a PowerApp V2 trigger is acceptable.

Runs on the **final** wizard step, immediately before the write flow is called, so an abandoned wizard leaves no stray grants.

---

### 8. SyncWorkspaceWithGit

Built and tested 2026-08-11. Stage 2 — moves content once the workspace is already connected. A separate flow rather than a branch in flow 5, because the workspace is connected by the time it runs and calling `connect` again would fail.

| | |
|---|---|
| Trigger | **Power Apps (V2)** — `text` = `workspaceId`, `text_1` = `requiredAction`, `text_2` = `initializationStrategy` (optional) |
| Calls | `GetFabricToken` (child), `initializeConnection` (conditional), `git/status`, then `commitToGit` or `updateFromGit` |
| Returns | `outcome`, `operationid`, `requiredaction`, `message` |

As built:

1. `Run_a_Child_Flow` → `GetFabricToken`, then six `Initialize variable` actions: `accessToken`, `action`, `operationId`, `outcome` (seeded `Failed`), `message`, and `allowOverride` — a **boolean**, `@equals(triggerBody()?['text_2'],'PreferRemote')`.
2. `Condition_needs_strategy` — `@not(empty(coalesce(triggerBody()?['text_2'],'')))`. Yes branch calls `initializeConnection` with the chosen strategy. No branch is empty.
3. `Get_git_status` — runs after the Condition on **Succeeded or Failed**, because a `409` from initialize is expected and must not stop the flow.
4. `Set_action_final` — derives the action to take. See the table below.
5. `act_on_action` — Switch on `@variables('action')` with cases `CommitToGit`, `UpdateFromGit`, `InitFailed`, and a default meaning nothing to do.
6. `Respond_to_a_Power_App_or_flow` — runs after the Switch on **Succeeded or Failed**.

**Ordering is load-bearing.** `Get_git_status` must stay after `Condition_needs_strategy`: status requires an initialized connection, so on a `NeedsChoice` workspace it only works once initialize has run.

#### `Set_action_final`

Fabric's own answer is not always available, so the action is derived rather than read:

| Situation | Result |
|---|---|
| No strategy passed | the caller's `requiredAction` |
| Initialize succeeded, body carries `requiredAction` | that value |
| Initialize succeeded but body has none (the `202` case) | derived from `git/status` |
| `409 WorkspaceGitConnectionAlreadyInitialized`, `changes` empty | `None` |
| `409`, changes pending | strategy decides direction |
| Any other initialize failure | `InitFailed` |

The `409` rows matter: `initializeConnection` is not idempotent, so any re-run of a connected workspace lands there. Reading `git/status` rather than mapping the strategy blindly is what stops a re-run from firing a pointless sync.

It runs after `Get_git_status` on **Succeeded or Failed**. Status fails when initialize failed and left the connection uninitialized; without the `Failed` branch the Switch and the Response are skipped, and Skipped satisfies neither run-after condition, so the flow would end with no answer at all and the app would see a hard error instead of `outcome: Failed`.

The expression guards every reference with `coalesce(outputs('Initialize_with_strategy')?['statusCode'], 0)`. Logic Apps evaluates function arguments eagerly, so the expression touches that action even on the no-strategy path where it never ran.

#### Request bodies

Both sync bodies are built with `json(concat(...))` as a single expression, because `workspaceHead` must be **present or absent**, never empty:

- `commitToGit` — `mode: All`, a comment, and `workspaceHead` only when `git/status` returned one.
- `updateFromGit` — `remoteCommitHash`, `conflictResolution` (`Workspace` + the chosen policy, defaulting to `PreferRemote`), `options.allowOverrideItems` from the boolean variable, and `workspaceHead` on the same condition.

#### Asynchronous Pattern

`CommitToGit` and `Update_from_git` carry `"operationOptions": "DisableAsyncPattern"`; `Initialize_with_strategy` deliberately does not.

Both sync APIs always return `202`, so with the default setting the action would poll to completion and swallow the operation ID — and on a large workspace it would blow the 120-second limit on the response to the app. `initializeConnection` does not move data (it reports the required action and the sync APIs do the work), so it is fast enough to resolve inline, and leaving the setting on means the normal `200` path yields `requiredAction` directly.

#### Outcomes

| `outcome` | Meaning |
|---|---|
| `Started` | `202` — poll `operationid` with flow 2 |
| `Completed` | other 2xx — nothing to poll |
| `NothingToDo` | already in sync |
| `Failed` | Fabric rejected the call; the raw payload is in `message` |

`Set_operationId_*` and the Response run after **Succeeded or Failed**, so a Fabric error is reported as data rather than failing the run. Verified: a failed sync still returns a response and the run itself shows Succeeded.

Verified paths, 2026-08-11: in-sync no-op; `UpdateFromGit` with `allowOverrideItems` false and true, both unquoted; `NeedsChoice` + `PreferRemote` with changes pending and with none; `PreferWorkspace` → `CommitToGit`; `InitFailed` carrying `MissingInitializationStrategy`; and an operation ID resolved through flow 2 to `Succeeded`.

> **No authorization check yet.** The flow syncs any workspace the broker administers, for any caller who can run it. Deferred by decision — see OPEN-ISSUES §10.3.

> **`SweepGitRequests` was considered and dropped 2026-08-07.** A background sweeper only earns its keep when a queued request can be stranded. Nothing queues here, and Fabric completes the sync whether or not anyone is watching. Recorded so the idea is not reinvented.

---

## Changes required to the built flows

Tracked as **F\<flow\>.\<n\>** in the *Issues* table in [docs/OPEN-ISSUES.md](docs/OPEN-ISSUES.md) — one register for the whole project, not a second list. The flow numbers there match the Status table above.

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

**Empty PowerApp V2 inputs are omitted from the trigger body.** A blank optional input does not arrive as an empty string — the property is absent, and `triggerBody()['text_2']` throws `InvalidTemplate: property 'text_2' doesn't exist`. Use `triggerBody()?['text_2']` for anything optional, and wrap it in `coalesce(…,'')` before `equals` or `empty`.

**Self-reference is illegal.** `Set variable X = union(variables('X'), …)` fails. Use a Compose holding the union, then set the variable from `outputs('Compose')`. See `MergePages` in ListGateways.

**Do-until cannot express OR in the UI.** Switch to advanced mode: `@or(equals(...), equals(...))`, or set a boolean `isDone` flag inside the loop.

**Do-until timeouts report success.** Always add a post-loop condition checking the real terminal state. `ListGateways` is the only flow with a loop left.

**Don't reference loop-internal actions from outside.** Capture values into variables inside the loop instead.

**Renaming an action breaks every expression referencing it.** Rename immediately after adding, before wiring anything.

**An operation marked `x-ms-visibility: internal` is invisible in the flow designer.** It still appears in the custom connector editor, so the connector looks correct while the action simply cannot be added to a flow. The Definition tab has a Visibility dropdown on the *operation* and another on each *parameter*; they mean opposite things. Operations want `none`, and a `Content-Type` header parameter wants `internal` **plus** a default of `application/json` — internal without a default means the header is never sent. Cost an hour on flow 7.

**Environment variables must be inserted from the picker, not typed.** Typing `parameters('X (ab_X)')` into the fx tab creates the reference but not the declaration in the flow's `parameters` block, and the run fails with *The workflow parameter … is not found*. Pick it from the dynamic-content **Environment variable** section, then save. If the variable is missing from the picker, close and reopen the flow from Solutions.

**The Git folder must already exist in the branch.** `connect` returns `GitProviderResourceNotFound` for a missing folder — the portal's *Create and sync* prompt has no API equivalent. Names are case-sensitive. See OPEN-ISSUES §1.11.

**Git carries metadata, not data.** Updating an empty workspace from a populated folder fails if any item holds a relative OneLake reference to a table that does not exist in the target. The operation is all-or-nothing — one bad item fails the whole sync. See OPEN-ISSUES §1.13.

**`GitSyncFailed` is a wrapper.** The usable cause is in `error.moreDetails` from `GET /v1/operations/{id}`. Use `Workflows/get-operation.ps1`.

**Both Git sync APIs are always long-running.** `commitToGit` and `updateFromGit` each return `202` with `x-ms-operation-id`, verified 2026-08-11 — even when the work finishes in under a second (one observed operation completed in 0.34s and still returned `202` with `Retry-After: 20`). An earlier note claiming `commitToGit` returned a synchronous `200` was wrong: that was the HTTP action's Asynchronous Pattern setting resolving the `202` invisibly. Never treat a `200` from these APIs as evidence of synchronous behaviour without first checking that setting.

**Reading the 202 from a Git sync.** Verified on `updateFromGit` 2026-08-11 with Asynchronous Pattern Off. The operation ID arrives as **`x-ms-operation-id`, lowercase**. `Retry-After: 20` is Fabric's own suggested poll interval — honour it instead of inventing a timer. `Location` points at a regional redirect host (`wabi-west-us3-a-primary-redirect.analysis.windows.net`) with `request-redirected: true`, **not** at `api.fabric.microsoft.com`, so use it only as a source for the trailing ID and always poll `https://api.fabric.microsoft.com/v1/operations/{id}`. The `202` body is the literal `null`, not empty. `Access-Control-Expose-Headers` lists exactly which headers are readable: `RequestId,Location,Retry-After,x-ms-operation-id`.

**`workspaceHead` is required once the workspace has one.** The docs say the value "may be null only after Initialize Connection" — that is a rule about *when omission is legal*, not a hint that the field is optional. Omit it on a synced workspace and `updateFromGit` fails `400 WorkspaceHeadMismatch`. Build the body conditionally: include `workspaceHead` when `git/status` returns one, omit it when it returns null. It also means status must be read in the same run as the sync call — a user acting on a stale status screen will hit this error, so the app should treat it as *refresh and retry*, not as a hard failure.

**A null `workspaceHead` has never actually been observed.** The obvious candidate — a first-ever commit into an empty Git folder — does not produce one. Verified 2026-08-11: `ab_demo_5` connected to a fresh `test2` directory holding nothing but a placeholder file, initialized, and the resulting `commitToGit` body still carried `workspaceHead: 2b2c58771e44d370039e6446f6f924783dd4c1c4`. `initializeConnection` derives the head from the workspace's own state; what is or isn't on the remote doesn't affect it. Keep the conditional body as a guard against the documented null, but don't expect the omit branch to run, and don't spend time trying to reproduce it.

**`initializeConnection` is not idempotent.** A second call returns `409 WorkspaceGitConnectionAlreadyInitialized` — verified 2026-08-10. Any flow that initializes must tolerate the 409 and carry on rather than treating it as failure, otherwise a retry after an unrelated error can never get past it. On 409 the strategy maps straight to the action: `PreferRemote` → `UpdateFromGit`, `PreferWorkspace` → `CommitToGit`.

**`updateFromGit` needs two separate consents to overwrite.** `options.allowOverrideItems` grants permission to overwrite; `conflictResolution` says which side wins. Supplying only the first makes Fabric refuse to start with a generic `RequestFailed` / "Unable to process the request" — verified 2026-08-10. `conflictResolutionType` is always `Workspace`; `conflictResolutionPolicy` takes the same `PreferRemote` / `PreferWorkspace` strings as `initializationStrategy`.

**Fabric's error body lies about authentication; the status code doesn't.** A missing `Authorization` header on an HTTP action comes back as `401` with `{"errorCode":"RequestFailed","message":"Unable to process the request"}` — the same generic payload Fabric uses for semantic rejections. Read the status code first: `401` is always a malformed or absent header, never a permission or payload problem. Fabric's own authorization failures are `403 InsufficientPrivileges` or `PrincipalTypeNotSupported`, and `401` is not a documented response for these APIs at all. Cost most of an afternoon on flow 8 chasing `workspaceHead`, Git credentials and service principal item support. Headers are not copied when you duplicate an action — check them on every new HTTP action.

**Asynchronous Pattern hides the 202.** The HTTP action's **Settings → Networking → Asynchronous Pattern** is **On by default**. It silently follows the `Location` header, polls the operation to completion, and reports the final poll as the action's result — so the action shows `200` with a `GET /v1/operations/{id}` status body, and `x-ms-operation-id`, `Location` and `Retry-After` never reach your expressions. This is what made `commitToGit` look synchronous. Turn it **Off** on every Fabric LRO call that should hand an operation ID back to the app. Tells that it is still On: no `Location` header, a body containing `percentComplete`/`blobInfoId`, and a response `Date` seconds later than the operation's own `lastUpdatedTimeUtc`.

**A flow that answers a canvas app has 120 seconds.** The inbound request limit applies to any flow containing *Respond to a PowerApp or flow*; overrunning it surfaces in the app as `504 BadGateway` with inner code `ResponseTimeout`. This is why sync is split into start-plus-poll: flow 8 returns an operation ID immediately and the app calls flow 2 to refresh. Never let a flow block on a Fabric LRO that a real workspace could stretch past two minutes.

**429 handling.** Fabric returns `Retry-After`. Honour it — at 4000 workspaces this will happen.

**Two IDs for one service principal.** `ab_BrokerClientId` is the application ID and goes to the Entra token endpoint; `ab_BrokerObjectId` is the directory object ID and goes to the Fabric roleAssignments API. Swapping them fails at runtime, not at import.

**One broker identity.** All app-only calls run as `sp_fabric_powerapp`. `sp_fabric_monit` is a monitoring identity with tenant-wide read/write and must not be used by these flows.
**There is no update API for a Git connection.** Changing branch or directory means `git/disconnect` then `git/connect` and a fresh `initializeConnection`.
