# Open Issues

Living list of project items. Companion to [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/FLOWS.md](docs/FLOWS.md) and [docs/PREREQUISITES.md](docs/PREREQUISITES.md).

Two tables, split by whether anything still has to be done. **Open** is the work list. **Closed** is everything settled — kept because the reasoning is worth not relitigating.

Flow work is `F<flow>.<n>`, where the flow number matches the Status table in [docs/FLOWS.md](docs/FLOWS.md) — `FN` = the pre-existing networking flows, `FA` = applies to every flow. Everything else keeps its section number. The § at the end of each row is where the detail lives.

Legend: 🔴 open, needs action · 🟡 open, non-blocking · ⏸ deliberately deferred · ✅ done · ➖ decided/accepted · ℹ reference

Last reviewed: 2026-08-07

---

## Open — action required

| ID | Area | Item | Why | Status |
|---|---|---|---|---|
| **F1.1** | GetFabricToken | Move tenant ID and client ID to environment variables; wire up the unused `ab_TenantId` | Hardcoded per-environment values need hand-editing after every import | 🔴 Open · §8.3 |
| **F2.2** | GetGitOperationStatus | Return `error.moreDetails` from `GET /v1/operations/{id}`, not just `errorcode` / `errormessage` | `GitSyncFailed` is a wrapper; `moreDetails` names the failing item | � Built 2026-08-07, not exported · §1.13 |
| **F2.4** | GetGitOperationStatus | Drop the `Do_until`, rename the flow, switch the trigger to `PowerAppV2`, call `GetFabricToken` internally, add `GET /operations/{id}/result` | A read the app can call directly; `/result` is the only source of `remoteCommitHash` | � Built 2026-08-07, not exported · §6.2 |
| **F3.1** | ListGitConnections | Retire, or rebuild as `ListMyConnections` on the delegated connector | It lists the broker's connections; the picker must list the caller's | 🔴 Open · §10 |
| **F4.1** | GetWorkspaceGitState | Demote from app-facing to internal guard — keep the flow, drop the screen | Contributors already see connection details in the Fabric UI | 🟡 Open · §10 |
| **F5.5** | ConnectWorkspaceToGit | Handle a **202** from `initializeConnection` — poll before reading `requiredAction` | On 202 the body is empty, every field resolves blank and the flow silently no-ops | 🔴 Open · §1.9 |
| **F5.6** | ConnectWorkspaceToGit | Delete `options` (`allowOverrideItems: true`) from `Update_from_git`. `conflictResolution` already removed | The app must not consent to overwriting the owner's items | 🔴 Open · §1.10 |
| **F5.7** | ConnectWorkspaceToGit | Add a `ConnectedSyncPending` outcome. **Only if** a refusal returns a synchronous 4xx: also make the Response reachable on failure | `Failed` is wrong when the workspace is connected; a 4xx aborts before `Respond_to_a_Power_App_or_flow` | 🟡 Open · §1.10 |
| **F5.8** | ConnectWorkspaceToGit | Test whether `PATCH myGitCredentials` is redundant; delete it, or make it failure-tolerant | `connect` already carries `myGitCredentials` in its body | 🟡 Open · §5.4 |
| **F5.9** | ConnectWorkspaceToGit | Add the `crbab_Workspaces` ownership check; move to the Dataverse request-row trigger | PowerApp V2 cannot prove caller identity — **blocks sharing the app** | ⏸ Deferred · §1.7 |
| **F5.10** | ConnectWorkspaceToGit | Write an audit row to `crbab_GitAuditLog` (table not yet created) | No record of who connected what | 🔴 Open · §10 |
| **5.2** | Design | Decide the credential type inside the owner's connection | Personal OAuth breaks when the owner leaves or the token expires | 🔴 Open · §5.2 |
| **5.3** | Design | Expired connection credentials go unnoticed | The workspace stays connected but syncs fail, and nobody is watching | 🟡 Open · §5.3 |
| **7** | Test | End-to-end test scenario | Both sync directions pass; steps 1–4, 7–8 untested | 🟡 In progress · §7 |
| **8.1** | ALM | Connection references arrive unbound on import | The reference travels with the solution, the connection does not | 🟡 Open · §8.1 |
| **8.2** | ALM | Run-only settings do not survive import | Must be re-applied per flow, per environment, or users hit permission errors | 🟡 Open · §8.2 |
| **8.4** | ALM | Write the post-import checklist | Needed before the first import into a second environment; needs a named owner | ⏸ Deferred · §8.4 |
| **9** | Connector | Add scopes and connection operations | Must be **one pass** — a later scope forces every user to recreate their connection | 🔴 Open · §9 |
| **10** | Build | Flows, tables and screens not yet built | `ListMyConnections`, `AddConnectionRoleAssignment`, `DisconnectWorkspaceFromGit`, `SyncWorkspaceWithGit`, `crbab_GitAuditLog`, wizard | 🔴 Open · §10 |

**Do first:** F5.6, then F5.5. F5.9 authorization must land before the app is shared with anyone.

---

## Closed — no action required

| ID | Area | Item | Why | Outcome |
|---|---|---|---|---|
| **FN.1** | 8 networking flows | Replace each inline token block with a `GetFabricToken` child-flow call | They ran as `sp_fabric_monit`, which holds `Tenant.Read/ReadWrite.All`. An app used by 4000 owners must not run on a tenant-wide identity | ✅ Done & exported 2026-08-07 · §1.6 |
| **FN.2** | ListGateways | `cont` initialised to backticks | Iteration 1 sent `continuationToken=%60%60` | ✅ Fixed 2026-08-06 · §1.3 |
| **FN.3** | ListGateways | 5-page cap on the Do-until | Accepted bound, but a truncated list is indistinguishable from a complete one | ➖ By design · §1.4 |
| **F5.1** | ConnectWorkspaceToGit | Switch on `requiredAction`, not the initialization strategy | Nothing synced while the flow reported success | ✅ Done & exported 2026-08-06 · §1.1 |
| **F5.2** | ConnectWorkspaceToGit | Delete `workspaceHead` from the `Update_from_git` body | `@{ }` rendered a null as `""`, which is not a valid SHA | ✅ Done & exported 2026-08-07 · §1.2 |
| **F5.3** | ConnectWorkspaceToGit | Empty `remoteCommitHash` sent to `updateFromGit` | Resolved by F5.1 | ✅ Resolved · §1.8 |
| **F5.4** | ConnectWorkspaceToGit | Poll comparison used `"Succeeded "` with a trailing space | It could never match, so every run reported `Failed` | ✅ Done & exported 2026-08-07 · §1.12 |
| **FA.1** | All HTTP + child-flow actions | Confirm the retry policy is not **None** | 429 at 4000 workspaces | ➖ Defaults verified in place · §6.1 |
| **F2.1** | GetGitOperationStatus | Post-loop condition asserting a real terminal status | Built, then made moot — the loop it guarded is being deleted | ➖ Superseded 2026-08-07 · §6.2 |
| **F2.3** | GetGitOperationStatus | Tolerate a 429 inside the polling loop | No loop left to protect; a throttled single GET is the retry policy's job | ➖ Superseded 2026-08-07 · §6.1 |
| **1.5** | Solution | Stale `shared_webcontents` connection reference | Pointed at a connector that is no longer part of the solution | ✅ Fixed & exported · §1.5 |
| **1.11** | Canvas app | State the folder rules on the wizard's folder field | `connect` fails with `GitProviderResourceNotFound` if the folder is absent; names are case-sensitive | ➖ By design · §1.11 |
| **1.13** | Platform | `updateFromGit` blocked by an item's OneLake dependency | Git stores metadata, not data — a fresh workspace cannot be rebuilt from Git alone | ➖ Root-caused · §1.13 |
| **2** | Security | Secrets in the repo — working tree and full history verified clean | Rotation is the customer's; Key Vault migration deferred | ➖ Closed on our side · §2 |
| **3.1** | Prerequisite | Broker SPN not enabled for Fabric APIs | Entra group + tenant setting; a bare 401 on every call without it | ✅ Resolved · §3.1 |
| **3.2** | Prerequisite | Broker SPN workspace Admin across ~4000 workspaces | Group membership plus automated workspace provisioning | ✅ Resolved · §3.2 |
| **3.3** | Reference | Broker SPN object ID `6f70a764-…` | `AddConnectionRoleAssignment` must pass the **object** ID, not the client ID | ℹ Reference · §3.3 |
| **4.1** | Platform | Dec 1 2026 Git restriction | Contributor covers the role half; sensitivity labels may still block items | ➖ Accepted risk · §4.1 |
| **5.1** | Design | Is SPN-B needed? | Owners have ADO access and create their own connections | ➖ Dropped · §5.1 |
| **6.1** | Reliability | 429 / throttling | Defaults verified in place; covered by the HTTP retry policy | ➖ Decided · §6.1 |

---

## 1. Flow issues — detail

### 1.1 `ConnectWorkspaceToGit` Switch never matches (critical) — FIXED & EXPORTED

**Fixed 2026-08-06, verified in the export.** `act_on_requiredAction` switches on `@body('Initialize_connection')?['requiredAction']` with case values `CommitToGit` and `UpdateFromGit`. Solution version `1.0.0.6`.

How it presented, kept because the failure mode is silent and could recur:

```
strategy = PreferRemote
  → Switch matched Case_2 ("PreferRemote")   ← selecting on strategy, not requiredAction
  → POST .../git/updateFromGit
  → remoteCommitHash = ""   (remote branch empty)
  → Fabric had returned requiredAction = CommitToGit
```

The strategy governs how Fabric *resolves* initialization. `requiredAction` is Fabric telling you which direction to sync afterwards. They are different things and must not be conflated.

### 1.2 `workspaceHead` sent as `""` when null — FIXED & EXPORTED

Both sync branches interpolate `workspaceHead` into the request body:

```json
"workspaceHead": "@{body('Initialize_connection')?['workspaceHead']}"
```

`@{ }` is string interpolation, so a null renders as `""` — the property is always present and never omitted. `"@expr"` without braces would preserve a real JSON `null`, which the spec explicitly permits.

**Test 2026-08-07 — commit branch is safe.** Disconnected a workspace containing items, reconnected to an existing but empty repo folder. `initializeConnection` returned:

```json
{
  "requiredAction": "CommitToGit",
  "workspaceHead": "b8e29bbfd18e4d5f3e01dcf7c4dc2c65665f6023",
  "remoteCommitHash": null
}
```

`workspaceHead` reflects the **workspace**, not the branch, and is populated whenever the workspace has items. `requiredAction: CommitToGit` only occurs when the workspace has content, so that branch can never receive a null. No change needed there.

**Test 2026-08-07 — update branch confirmed, impact is cosmetic.** New empty workspace (`ab_demo_git`, `18e8e8e8-f0f8-4196-9462-60a7989076ce`) connected to a folder containing committed Fabric items. `initializeConnection` returned:

```json
{ "requiredAction": "UpdateFromGit", "workspaceHead": null, "remoteCommitHash": "72000a6c…" }
```

and `Update_from_git` sent:

```json
{ "remoteCommitHash": "72000a6c…", "workspaceHead": "", … }
```

The call returned **202**, and the long-running operation then failed — but for an unrelated reason (1.13, an item referencing a missing OneLake table). The operation reached model validation, which means `""` passed request validation and the API accepted it.

So this is a correctness defect, not a functional one. `""` is still not a valid SHA and the tolerance is undocumented, so it should not be relied on.

**Fixed 2026-08-07, verified in the export.** The property was deleted from the `Update_from_git` body — it is optional in `updateFromGit` and only provides optimistic concurrency, and the flow calls initialize seconds earlier as the sole writer.

The `CommitToGit` branch still sends it, which is correct: that branch only fires when the workspace has items, so `workspaceHead` is always populated there.

Test: empty workspace → connect to a folder with committed Fabric items → expect `requiredAction: UpdateFromGit`, then read `workspaceHead` in the initialize output and the rendered `Update_from_git` inputs. If it is null there, drop the braces on that one line.

### 1.8 `updateFromGit` sends an empty `remoteCommitHash` — RESOLVED VIA 1.1

Observed 2026-08-06. Root cause was 1.1, not a missing field mapping — fixing the Switch resolved it.

```json
{
  "remoteCommitHash": "",
  "workspaceHead": "06bb1ba53db1003e159ae6fdea0919a77914d50a",
  "conflictResolution": { "conflictResolutionType": "Workspace", "conflictResolutionPolicy": "PreferRemote" },
  "options": { "allowOverrideItems": true }
}
```

Per the spec, `remoteCommitHash` is **required** and `workspaceHead` is **optional** — the body has the requiredness backwards.

**Root cause is not a missing mapping.** `initializeConnection` returns `remoteCommitHash` only when the remote branch has commits. An empty value alongside a populated `workspaceHead` means the workspace has content and the **remote branch is empty**, in which case `requiredAction` is `CommitToGit`. Calling `updateFromGit` there is meaningless — there is nothing to update from.

So this was bug 1.1 surfacing: the Switch selected the branch from the **initialization strategy** instead of from `requiredAction`. The strategy tells Fabric how to resolve initialization; Fabric then reports which direction to sync. Only `requiredAction` may drive the Switch.

Remaining, carried into 1.10: `conflictResolution` is still hardcoded in the update branch, and is now slated for removal. `remoteCommitHash` stays mapped from `Initialize_connection` — it is populated whenever that branch is legitimately reached.

### 1.9 `initializeConnection` may return 202 with an empty body

The API documents both `200` (with `InitializeGitConnectionResponse`) and `202 Accepted` (long-running, `Location` + `x-ms-operation-id`, **no body**).

`ConnectWorkspaceToGit` assumes 200 and reads `requiredAction`, `workspaceHead` and `remoteCommitHash` straight off the response. On a 202 all three resolve to empty, the Switch falls through to `default`, and the flow reports `Connected` having synced nothing — the same silent failure as 1.1, from a different direction.

Handle the 202: the operation ID comes back in the `x-ms-operation-id` header, and `GET /v1/operations/{id}/result` — not the operation state — is the only source of `requiredAction` and `remoteCommitHash`. `GetGitOperationStatus` returns both, so the app has what it needs; what is still missing is anything that acts on them.

### 1.10 `conflictResolution` hardcoded — DECIDED: remove it

`Update_from_git` sends a fixed `conflictResolutionPolicy: PreferRemote` plus `options.allowOverrideItems: true`, regardless of what the user chose in the wizard.

**Decision 2026-08-07: delete both from the request body** (F5.6). The app should not make a destructive choice on the owner's behalf. Per the API reference, omitting them makes Fabric refuse to start rather than overwrite:

| Property | Documented behaviour when omitted |
|---|---|
| `conflictResolution` | *"If items are in conflict and a conflict resolution is not specified, the update operation will not start."* |
| `options.allowOverrideItems` | *"When incoming items are present and the allow override items is not specified or is provided as false, the update operation will not start."* Default `false`. |

The happy path is unaffected: `UpdateFromGit` after a first connect normally targets an empty workspace, where there is nothing to conflict with and no incoming items to override. Only the ambiguous cases change, and those get handed to the owner — who can resolve them in the Fabric UI, with visibility of the actual items, since the workspace is connected by then and *Update from Git* only needs Contributor.

**Open question — which failure path does a refusal take?** Unknown, and it decides whether anything else is needed:

- **202 then a failed operation** (what 1.13 did). The flow now returns as soon as the sync starts, so the refusal surfaces on the owner's next Refresh as a `Failed` operation with `moreDetails`. Nothing to build in the write flow.
- **Synchronous 4xx.** The HTTP action fails, the Switch fails, `Has_operation` (`runAfter: act_on_requiredAction [Succeeded]`) is skipped, and `Respond_to_a_Power_App_or_flow` (`runAfter: Is_not_connected [Succeeded]`) never runs — so the app gets a bare flow failure with no `outcome` and no `message`. This is F5.7.

The documented synchronous error codes for `updateFromGit` are `WorkspaceHeadMismatch`, `MissingDependency`, `PotentialDuplicateDisplayNameAndType`, `DependencyDeletionFailed`, `InsufficientPrivileges` and friends — **no conflict code among them** — and 1.13 showed validation happening inside the LRO. That points at the first path, but it is not confirmed. **Test before building F5.7.**

**Either way, the outcome should not read `Failed`.** Connect and initialize both succeeded, so the workspace *is* connected. Reporting `Failed` invites a retry, which then returns `AlreadyConnected` and reads like a broken app. A `ConnectedSyncPending` outcome directing the owner to *Source control* in the Fabric UI is worth adding regardless of which path the refusal takes.

**Accepted trade-off.** The wizard already asks for a strategy, so a user who picks `PreferRemote` with content on both sides has stated an intent the app will now decline to act on. Narrowing that is deliberate: never overwrite on a guess.

### 1.11 `connect` requires the target folder to already exist — BY DESIGN

Not a defect. A platform restriction the app inherits, accepted 2026-08-07.

Connecting with `directoryName: "test-nullhead"` — a folder not present in `fabricrepo2` on `main` — fails at the `Connect` call:

```json
{
  "errorCode": "GitProviderResourceNotFound",
  "message": "The requested operation can't be completed because the Git provider resource could not be found using the provided Git connection details.",
  "isRetriable": false
}
```

The portal handles this with a *Create and sync* prompt. The REST API has no equivalent flag in `AzureDevOpsDetails`, so a missing folder is an error.

Rules the user must satisfy:

- The folder must already exist in the selected branch.
- Folder names are **case-sensitive** against what is in the branch.
- The folder must not contain subdirectories unless at least one is a Fabric item directory. A folder holding a single plain file (e.g. `README.md`) is fine.

**Resolution:** state these rules as description text on the folder field of the wizard page. No flow change.

### 1.12 Poll success check compared against `"Succeeded "` — FIXED & EXPORTED

In `ConnectWorkspaceToGit`, the `Condition` inside `Has_operation` evaluates:

```
@body('Run_PollFabricOperation')?['status']  equals  "Succeeded "
```

The literal carries a **trailing space**, so it can never match. The `else` branch always runs and `outcome` is always set to `Failed` with the poll's `errormessage`, regardless of what actually happened.

Found 2026-08-07 while diagnosing 1.13, where it happened to give the correct answer by accident. Until it was fixed, no run outcome from this flow could be trusted in either direction.

**Fixed 2026-08-07, verified in the export.** The action itself was deleted later the same day (§6.2), so this is history — kept because the failure mode is invisible and the lesson is not: a trailing space in a comparison literal silently inverts a flow's entire outcome.

### 1.13 `updateFromGit` into an empty workspace fails on items with OneLake dependencies — ROOT-CAUSED

Test 2026-08-07, empty workspace `ab_demo_git` updating from a folder containing committed items. `Update_from_git` returned 202; the operation then failed. `GET /v1/operations/{id}` gave the real cause:

```json
{
  "errorCode": "GitSyncFailed",
  "message": "Failed to sync between Git and the workspace",
  "moreDetails": [{
    "errorCode": "ModelValidationError",
    "message": "[DataSourceSchemaFetchFailed] Failed to fetch schema for data source 'publicholidays'. Cannot resolve OneLake table reference for relative path 'publicholidays'.",
    "relatedResource": { "resourceType": "GraphIndex", "resourceId": "ac744682-…" }
  }]
}
```

A graph query set holds a **relative** OneLake reference to a table `publicholidays`. Relative paths resolve within the same workspace. The table exists in the source workspace `ab_demo_5` but not in the empty target, so model validation fails.

Not a flow defect. Three consequences that do matter:

- **Git stores metadata, not data.** A workspace whose items reference OneLake tables cannot be reconstructed into an empty workspace from Git alone. At 4000 workspaces this will be routine whenever a fresh workspace is pointed at a populated folder.
- **`updateFromGit` is all-or-nothing.** One unresolvable item failed the entire operation. `allowOverrideItems` does not help — this is model validation, not conflict resolution.
- **The generic message is useless to an end user.** `GitSyncFailed` / *"Failed to sync between Git and the workspace"* says nothing. `error.moreDetails` names the item and the reason, so `GetGitOperationStatus` must surface it (F2.2).

Use `Workflows/get-operation.ps1` to retrieve this detail for any operation ID.

### 1.3 `ListGateways` — `cont` initialised to backticks — FIXED

**Verified fixed 2026-08-06.** `Initialize_variable_2` now declares `cont` as a string with **no `value` property**, so it starts empty and iteration 1 sends `continuationToken=` rather than `%60%60`.

### 1.4 `ListGateways` — 5-page cap — BY DESIGN

**Decision 2026-08-06: works as designed.** The Do-until exit expression is still:

```
@or(equals(variables('more'), false), greaterOrEquals(variables('pageCount'), 5))
```

Accepted as a deliberate bound. Residual, unaddressed: when the cap is what stops the loop, the flow returns **success with a silently truncated list** — neither the flow nor the app can tell that apart from a complete result. If gateway counts ever approach five pages, either surface a "more results exist" flag from `more`, or raise the cap. Not actioned.

### 1.5 Stale connection reference — FIXED

**Verified fixed 2026-08-06.** `customizations.xml` contains **zero** matches for `sharedwebcontents` / `shared_webcontents`. A single connection reference remains, `ab_sharedgateway5flst5fapp5fcon5fe4e6bd1abcd77fac5f0c1c5dd7f4e428ac_51f02`, pointing at the custom connector — which is correct.

### 1.6 Two different broker service principals (FN.1) — FIXED & EXPORTED

`GetFabricToken` requested its token as `sp_fabric_powerapp` (`a385fde9-…`) while all eight networking flows used `sp_fabric_monit` (`b5c04c9c-…`).

**Decision 2026-08-06: standardise on `sp_fabric_powerapp`.** `sp_fabric_monit` holds `Tenant.Read.All` / `Tenant.ReadWrite.All`; an application surfaced to 4000 workspace owners must not execute on a tenant-wide identity.

**Fixed 2026-08-07, verified in the export** (solution `1.0.0.8`). Each networking flow had its inline `Initialize_variable clientSecret` → token `HTTP` → `Parse_JSON` block deleted and replaced with a `GetFabricToken` child-flow call, with downstream calls rewired from `body('Parse_JSON')?['access_token']` to `variables('accessToken')`.

Verified across `Workflows/`:

| Check | Result |
|---|---|
| `b5c04c9c` (`sp_fabric_monit`) | **Zero matches** — retired from the solution |
| Flows holding a `clientSecret` | **1** (`GetFabricToken`), down from 9 |
| Token client ID | `a385fde9-…` only |
| Flows calling `GetFabricToken` | 10 |
| Dangling `Parse_JSON` / `body('HTTP')` references | None |

Side benefit: one secret instead of nine, so PREREQUISITES E4 shrinks to a single flow per environment.

Remaining, carried forward:

1. **Confirm `sp_fabric_powerapp` can actually reach the networking endpoints.** This is the first time those flows run as that identity, so this is the likely next failure. Grant only what they need — the point of the switch is lost if it ends up as broad as `sp_fabric_monit`.
2. Retest `Workflows/list gateways spn.ps1` under the new identity; its Unauthorized result was against the retired SPN.
3. `sp_fabric_monit` now has **no role in this solution**. Remove it from the docs and stop maintaining its secret here.

### 1.7 Missing authorization check (F5.9)

`ConnectWorkspaceToGit` contains no Dataverse lookup. There is no `ListRecords` action anywhere in `Workflows/`. Nothing currently stops a caller from connecting a workspace they do not own — the flow acts on whatever `workspaceId` it is handed.

This is the whole point of the Dataverse authorization boundary in ARCHITECTURE.md §3, and it is not implemented.

**Decision 2026-08-06: build later.** Accepted for now on the basis that the app is not yet shared with owners.

This must land before the app is shared with anyone outside the build team. Until then the flow URL is the only thing standing between a caller and any of the 4000 workspaces, and flow URLs are recoverable by anyone who can open the app.

What "later" has to include:

1. Create the audit table (`crbab_GitAuditLog`, §10.3); have the canvas app create the row **before** calling the write flow, so `createdby` is stamped server-side, and have `ConnectWorkspaceToGit` and `DisconnectWorkspaceFromGit` read their parameters and their actor from that row.
2. Look up `crbab_Workspaces` for the target `workspaceId`; proceed only if `createdby` matches `crbab_primary_owner` or `crbab_secondary_owner`. **Fail closed** — no row found means deny, not allow.
3. Write the denial to `crbab_GitAuditLog` as well as the success.

The canvas app filtering the workspace list is **not** authorization — it is a convenience. The check has to be server-side.

**Note, 2026-08-07.** An earlier version of this issue also claimed the fix removed a 120-second timeout ceiling. It no longer does — the write flows stay synchronous to the app and simply stop waiting for Fabric (§10.2). This is a security task and nothing else.

---

## 2. Security — repo clean; rotation is the customer's

**Verified 2026-08-07:**

- `.gitignore` **is present** and excludes `*.ps1`, `.vscode/`, `tests/`.
- No `.ps1` or `.txt` file is tracked. `internal_power_app.txt` lives outside the repo.
- Since 1.6, only **`GetFabricToken`** carries a `clientSecret`, and the export scrubs it to `"value": " "`. No live secret in the working tree.
- `git log -S` across all branches finds **no commit** containing any of the three secrets. History is clean.

Remaining:

- **Secret rotation is the customer's responsibility** — out of scope for this work. Decision 2026-08-07.
- Flows carry the secret via an `Initialize_variable clientSecret` in `GetFabricToken`. **Decision 2026-08-06: leave as is for now**; migrate to a Key Vault-backed secret environment variable in a later pass. Deferred, not resolved — the secret still sits in the flow definition and therefore in any export taken from a working environment.
- The scrubbed `" "` value means `GetFabricToken` needs its secret re-entered before anything runs in a freshly imported environment. Belongs in the post-import checklist (8.4).
- `*.ps1` being ignored means the helper scripts referenced in ARCHITECTURE §9, including `get-operation.ps1`, are **not in the repo**. Either force-add the ones that contain no credentials (`git add -f`) or accept that they are local-only and note it.

---

## 3. Blocking prerequisites

### 3.1 Broker SPN not enabled for Fabric APIs — RESOLVED

**Resolved 2026-08-06.** `ConnectWorkspaceToGit` now runs past `Check_existing`; the 401 is gone.

What fixed it:

1. Entra security group **`fabric_power_app_grp`** created, with the **`sp_fabric_powerapp` service principal** added as a member.
2. Fabric Admin portal → Tenant settings → Developer settings → **"Service principals can call Fabric public APIs"** → Enabled, scoped to that group.

Diagnosis that led there, kept because the same symptom will recur in every new environment:

| | |
|---|---|
| Token request | succeeded |
| `aud` | `https://api.fabric.microsoft.com` |
| `appid` | `a385fde9-…` (`sp_fabric_powerapp`) |
| `idtyp` | `app` |
| `roles` | *(none)* — **normal, not the fault** |
| Fabric call | `401 Unauthorized` |

The empty `roles` claim is expected: Fabric does not grant API access through Entra application permissions. `401` means the SPN cannot call Fabric at all; `403` would mean it can, but lacks a role on the object.

Reproduce with `Workflows/diag-401.ps1`. **This configuration is per-tenant and must be repeated in every environment** — see 8.4.

### 3.2 Broker SPN workspace Admin coverage — RESOLVED

`sp_fabric_powerapp` must hold **Admin** on every managed workspace — connect, disconnect and sync all require it.

**Resolved 2026-08-07.** The broker SP is a member of a security group, and workspace provisioning is automated to grant that group the Admin role on every new workspace. No per-workspace manual step, and new workspaces are covered as they are created.

Carried into PREREQUISITES §C as an environment-level dependency rather than a task: a new tenant needs the equivalent provisioning automation before the app works there.

### 3.3 Broker SPN object ID

`sp_fabric_powerapp` object ID: **`6f70a764-908f-435b-a930-ffcb375577f3`** (from the `oid` claim).

This is the value `AddConnectionRoleAssignment` must pass as `principal.id` when granting the broker the `User` role on an owner's connection — **not** the client/application ID `a385fde9-…`. Confusing the two produces a role assignment that silently grants nothing, and connect then fails as if the connection were unshared.

---

## 4. Time-sensitive

### 4.1 December 1, 2026 Git integration restriction

From the Fabric docs:

> Starting December 1, 2026, users without read-write permissions on workspace items can't use Git integration. This restriction can result in loss of access to certain items because of sensitivity labels and protection policies applied to those items.

Owners will be **Contributors**, which resolves the role half of this. The residual risk is **sensitivity labels and protection policies** — an item a Contributor cannot read/write due to a label will block Git operations regardless of workspace role.

**Decision 2026-08-06: accepted risk, out of scope.** Item-level label issues are for workspace users to resolve; the app will not work around them. Re-open only if it turns out to block a significant number of workspaces.

---

## 5. Design decisions still open

### 5.1 Is SPN-B needed at all?

SPN-B was intended as the Git identity inside the Fabric connection, so owners without Azure DevOps access could still connect. **Owners now have ADO access and create their own connections**, so that role no longer exists. SPN-B has not been registered or onboarded.

**Decision 2026-08-06: dropped.** No registration, no ADO onboarding, no secret to manage. Remove all references from architecture docs.

This leaves 5.2 unanswered — connections will carry whatever credentials the owner supplies. If a durable shared identity is later required, it would be a new decision, not a revival of SPN-B.

### 5.2 Credential type inside the connection

If owners use personal OAuth credentials, the connection breaks when they leave or their token expires. Across ~4000 workspaces that is continuous breakage.

Options: personal OAuth (simplest, fragile), a shared service principal (durable — this is the surviving justification for SPN-B), or a service-account PAT (durable, needs rotation).

Decide and publish as guidance even if not enforced.

### 5.3 Expired/broken connection credentials go unnoticed

When credentials expire the workspace stays connected but syncs fail. Nobody is watching, and owners have no reason to look. This may be the one genuine use for a periodic SPN-A job.

### 5.4 `PATCH myGitCredentials` — necessary or redundant?

`ConnectWorkspaceToGit` calls `PATCH .../git/myGitCredentials` after `connect`, but `connect` already carries `myGitCredentials: { source: "ConfiguredConnection", connectionId }` in its body, and the setting is per-identity (SPN-A's own).

**Decision 2026-08-06: test, then remove if redundant.**

Actions:
1. Run `ConnectWorkspaceToGit` with the PATCH step temporarily disabled.
2. Call `GET /v1/workspaces/{id}/git/myGitCredentials` immediately after `connect`.
3. If it already returns `source: ConfiguredConnection` with the correct `connectionId`, **delete the PATCH action** from the flow and re-export.
4. If it does not, keep the PATCH but set its run-after to tolerate failure, so it cannot abort a run that has already connected successfully.

---

## 6. Reliability

### 6.1 429 / throttling

No explicit throttling handling in any flow. Fabric returns `Retry-After`.

**Decision 2026-08-06: add retries now.**

Power Automate HTTP actions have a built-in retry policy (default: exponential, 4 retries) covering 429 and 5xx.

**Verified 2026-08-06:** no `retryPolicy` block appears in any file under `Workflows/`, so every HTTP and child-flow action is on the **default** policy. Nothing is set to `None`. The exposure is smaller than first assumed.

Remaining actions:

- Raise the retry count on the Fabric calls above the default 4 if testing shows it is needed.

Only build custom `Retry-After` handling if testing shows the built-in policy is insufficient.

**F2.3 closed 2026-08-07, superseded.** It asked the `Do_until` to tolerate a 429 without treating it as terminal. The loop is being deleted (§6.2), so there is no iteration left to protect — a single GET that gets throttled is the **HTTP action's retry policy's** job, which is exactly what this section already covers. Set the policy on `Get_operation_state` explicitly rather than relying on the default, since this is the one call the UI hits repeatedly.

### 6.2 The polling loop has been removed

**Superseded 2026-08-07.** This section used to say that any Do-until exiting via its own limit reports success, and that the polling flow needed a post-loop condition asserting the real terminal state. That fix was built — and is now moot, because the loop itself is gone.

A loop only made sense while a caller was blocked waiting for the answer to be *final*. Once nothing waits for the sync to finish (§10.2), a looping flow is the wrong shape: it holds a run open, cannot be re-entered, and gives the Refresh button nothing to call. `PollFabricOperation` was renamed and rewritten in place as single-shot **`GetGitOperationStatus`** — flow 2 — on 2026-08-07.

Deleted with the loop: the `TimedOut` status, the `attempts` counter and output, the `Delay`, and the post-loop assertion that F2.1 asked for. **F2.1 is closed as superseded, not as done.**

The child-flow call in `ConnectWorkspaceToGit` was deleted in the same change — necessarily, because the new `PowerAppV2` trigger **cannot be a child flow**; child flows must use *Manually trigger a flow*. Nothing was lost: flow 5 no longer waits, so it had nothing to poll.

**Not yet exported**, so none of this is verified against the JSON. F2.2 and F2.4 stay open until it is.

The underlying warning still stands for `ListGateways`, which keeps its loop — accepted rather than fixed, see 1.4.

---

## 7. Test scenario — core path passing

Workspace `e9de0b2d-0cc1-42ed-9395-28da86acfd97`, one **Notebook** named `TestSync`. Repo `skscontoso/fabric/fabricrepo2`, branch `main`, directory `test`.

**2026-08-07: both sync directions now pass end to end**, after fixing 1.1, 1.2 and 1.12.

- `CommitToGit` — workspace with items → existing empty repo folder. `requiredAction: CommitToGit`, operation `Succeeded`, items present in ADO.
- `UpdateFromGit` — empty workspace `ab_demo_git` → folder holding committed items. `requiredAction: UpdateFromGit`, operation `Succeeded` once the folder excluded the item with the unresolvable OneLake dependency (1.13).

Steps 1–4, 7 and 8 remain untested.

1. As the owner (Contributor) in the Fabric UI, confirm **connect is unavailable** — proves the app is necessary.
2. Confirm the owner *can* see Git status and commit/update controls once connected — proves the scope reduction is right.
3. Owner creates the ADO connection; confirm they are **Owner** on it. Record the ID and check `GET /v1/connections/{id}` → `connectionDetails.path` to settle the URL format.
4. Delegated call adds SPN-A as `User`; verify via `GET .../roleAssignments`.
5. Run `ConnectWorkspaceToGit` with strategy `PreferWorkspace`. Expect `requiredAction: CommitToGit` → 202 → poll to `Succeeded`. ✅ **Passing 2026-08-07.**
6. Verify in ADO:
   ```
   test/TestSync.Notebook/.platform
   test/TestSync.Notebook/notebook-content.py
   ```
   ✅ **Verified.** A success outcome with an empty `test/` would have meant 1.1 was still live.
7. Edit the notebook in ADO, then as the **owner** use the Fabric UI's *Update from Git*. Success confirms commit/update stay out of scope. Failure means they return.
8. With the PATCH step disabled, call `GET .../git/myGitCredentials` after `connect` — see 5.4.

---

## 8. ALM / deployment

**Decision 2026-08-06: the solution will be deployed to multiple environments.** Everything below is therefore in scope, not theoretical.

### 8.1 Connection references arrive unbound on import

A connection reference is a pointer; the actual **connection** holds credentials and is environment-specific. Exporting a solution carries the reference but not the connection. On import into test/prod, each reference must be mapped to a real connection in the target environment — prompted during import, or fixed afterwards.

### 8.2 Run-only settings do not survive import

For each flow called by the canvas app, every connection is either *Use this connection* (runs as the flow owner's connection) or *Provided by run-only user* (each app user supplies their own). These are per-flow, per-environment settings and are **not** part of the exported solution.

After every import someone must open each flow → **Run only users** → set them again. Otherwise app users hit permission errors.

For this solution: the delegated custom connector must be *Provided by run-only user*; SPN-A HTTP actions use the embedded connection.

### 8.3 Hardcoded per-environment values (F1.1)

Every token-acquiring flow hardcodes environment-specific values:

- tenant GUID `9e929790-…` in the token URI — now only in `GetFabricToken`, since 1.6 collapsed the nine token blocks into one
- the SPN client ID in the same request body
- the Fabric API host and scope

`ab_TenantId` already exists in `environmentvariabledefinitions/` and is **referenced by nothing**. It was created and never wired up.

Environment variable *values* can be supplied at import time, which is the supported way to vary these per environment. Without this, every import needs each flow opened and hand-edited — nine flows, every deployment, silently wrong if missed.

Actions:

1. Wire `ab_TenantId` into the token URI of every flow.
2. Add an environment variable for the broker client ID — after 1.6 is decided.
3. Leave the secret as an `Initialize_variable` for now (§2), but plan the Key Vault secret variable in the same pass so the flows are only reworked once.

### 8.4 Post-import checklist

**Decision 2026-08-06: to be written later.** Not blocking, but it must exist before the first import into a second environment, and it needs a named owner.

Must cover, at minimum:

- map every connection reference to a connection in the target environment (8.1)
- re-apply **Run only users** on every app-facing flow (8.2)
- supply environment variable values for tenant, client ID and secret (8.3)
- create the Entra group (`fabric_power_app_grp` equivalent) with the broker SPN as a member, and enable **"Service principals can call Fabric public APIs"** scoped to it — see 3.1. Nothing works without this and the failure is a bare 401
- confirm workspace provisioning in that environment grants the broker SPN's security group workspace **Admin** (3.2)
- share the connector, app and security role with the target environment's group team (ARCHITECTURE §6)

---

## 9. Custom connector work

Scope and consent are done as of 2026-08-07; operations remain. The one-pass rule below still governs any future change — see §9.3 for what a late scope change actually costs.

### 9.1 Scope — done

- ✅ Delegated `Connection.ReadWrite.All` added to `gateway_lister_app` alongside `Gateway.Read.All` and consented. Verified in the Entra grant, not just the portal.
- Scope field on the connector's Security tab becomes: `Gateway.Read.All Connection.ReadWrite.All offline_access`.
- **One scope covers everything.** Per the API reference, `GET /connections` accepts `Connection.Read.All` *or* `Connection.ReadWrite.All`, and `POST .../roleAssignments` requires `ReadWrite`. Do not add both.
- Front-load any other scope this connector will ever need.
- The app registration and the connector hold **separate copies** of the scope list and neither validates the other. Change the app registration first; a connector asking for an unpublished scope saves cleanly and fails later at connection creation.

### 9.2 Operations

`GET /connections`, `GET /connections/{fabricConnectionId}`, `POST /connections/{fabricConnectionId}/roleAssignments`, `GET /connections/{fabricConnectionId}/roleAssignments`.

> **The path parameter cannot be called `connectionId`.** The Swagger validator rejects it — `ConnectionIdParameterNotAllowed`, "A parameter cannot be named as 'connectionId'" — because Power Platform reserves that name for binding an action to its connection. Every Fabric connection API documents the path as `{connectionId}`, so copying from the reference fails. The placeholder name is arbitrary; only the value is substituted, so `{fabricConnectionId}` produces an identical request.

The role-assignment `GET` is for idempotency: `AddConnectionRoleAssignment` returns **201** and the docs do not say what happens when the assignment already exists. Reading the list first avoids finding out the hard way on every re-run of the wizard. Adding an *operation* later is safe — only a new **scope** is expensive — but it is cheaper to do it in the same pass.

### 9.3 Changing a scope invalidates every existing consent — verified 2026-08-07

**Deleting and recreating the Power Platform connection is not enough.** Consent lives in an Entra `oauth2PermissionGrant` keyed on (user, client app, resource). It survives the connection entirely, and a new connection silently reuses it — no prompt, same narrow token.

Symptom: `403` with `x-ms-public-api-error-code: InsufficientScopes`. That code is worth knowing precisely — it means the token was accepted but its `scp` claim lacks the scope. A plain `403` without it means a missing role on the object instead.

The grant must be **revoked first**, per user:

```powershell
$spId = az ad sp show --id 1c221a2d-9a70-48cc-81b8-e68dfba7afbd --query id -o tsv
az rest --method get --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$spId'" `
  --query "value[].{id:id, principalId:principalId, scope:scope}" -o json
az rest --method delete --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/<id>"
```

Then delete and recreate the connection, which forces a fresh consent prompt, and re-run the `GET` to confirm the new scope is present. Self-service equivalent for a user without Graph rights: **myapps.microsoft.com** → the app → **Remove**.

**Rollout consequence.** Revocation is per user, so a scope added after go-live means every existing user must be revoked and must reconsent. With ~4000 workspaces this is not a footnote. It is the reason for the one-pass rule at the top of this section.

Confirm tenant consent policy allows user consent for these scopes, or arrange admin consent before rollout.

### 9.4 Diagnosing scope problems

Three commands beat portal archaeology, which is where an afternoon went on 2026-08-07:

1. Read the grants — `oauth2PermissionGrants` filtered by the connector's SP object ID (`aa7ae000-45ee-4740-98a6-041213afc2b4`). This is what the token will actually contain.
2. Compare against `Connector/ab_gateway-5flst-5fapp-5fcon_connectionparameters.json` in a fresh export. That file is what drives the authorize request; if the scope is not there, the Security tab never saved.
3. Only then look at the portal.

The Entra portal's *Enterprise applications → Permissions* blade shows the same data, but revoke is a per-row `⋯` that appears on hover and only for Cloud Application Administrator — easy to conclude the option does not exist.

> Editing the OAuth section of the Security tab blanks the client secret and will not save without it. A silent non-save here looks exactly like a consent problem.


---

## 10. Not yet built

### 10.1 Flows

- `ListMyConnections` (delegated) — `GET /v1/connections`, filter to `AzureDevOpsSourceControl`, paginate with `continuationToken` (no server-side type filter). **Stays synchronous.**
- `AddConnectionRoleAssignment` (delegated) — grant SPN-A `User` on the connection; runs on the **final** wizard step, before the write flow is called. Self-authorizing. **Stays synchronous** — the API returns 201 with the role assignment in the body; it is not a long-running operation, so there is no operation ID and nothing to poll.
- `DisconnectWorkspaceFromGit` (SPN-A) — synchronous against Fabric; authorizes from the audit row like every other write flow.
- **`SyncWorkspaceWithGit`** — stage 2; performs `commitToGit` / `updateFromGit`, and re-initializes with a strategy first when stage 1 could not decide (§10.6).
- **`GetGitOperationStatus`** — built 2026-08-07 as flow 2; single-shot, read-only status for the app's Refresh button. See §10.5.
- Canvas app wizard screens, including the progress view and the stage-2 choice screen (§10.6).

### 10.2 Interactive, not queued — decided 2026-08-07

The app calls the write flows **directly** and gets an answer back. An earlier design queued requests through a `crbab_GitRequest` table on a Dataverse row-created trigger; that is dropped. It bought asynchrony nobody needed, and cost the app its return value, a few seconds of trigger latency, and a second artifact to correlate when debugging.

The 120-second inbound limit is not the constraint it looked like, because **no flow waits for a Git sync any more**. A write flow starts the operation and returns; Fabric finishes it whether or not anyone is watching.

```
App   Patch(GitAuditLog, Defaults(...), {WorkspaceId, Action: "Connect", ...})  →  auditRowId
App   ConnectWorkspaceToGit.Run(auditRowId)
        |
        v
Flow  1. Get a row (auditRowId) → _createdby_value, and every parameter
      2. ownership check against crbab_Workspaces (F5.9) — else Outcome = Denied, stop
      3. connect + initializeConnection probe, strategy None (§10.6)
      4. update the row: Outcome, RequiredAction, Message
        |
        v
App   ← outcome, message, messageDetails, requiredAction     (immediately)
App   SyncWorkspaceWithGit.Run(auditRowId, requiredAction, strategy?)
        |                                     ↑ only when outcome was NeedsChoice
        v
Flow  commitToGit / updateFromGit → 202, write OperationId, return — do not wait
        |
        v
App   Refresh button → GetGitOperationStatus(operationId)
```

**Identity comes from the row, not from the caller.** This is the one job the Dataverse trigger was doing that still has to be done. A canvas app writes to Dataverse **as the signed-in user**, so `createdby` on that row is stamped by the platform and cannot be forged the way a passed-in email or UPN could. The flow reads it back and authorizes against it. The client supplies only a row ID.

Because the flow reads *all* its parameters from the row, there is nothing else to spoof. A caller who fabricates their own row gets their own `createdby` and fails the ownership check on a workspace they do not own. A caller who points at somebody else's row can at worst replay an action that was already authorized — mark rows consumed on first use if that matters.

What still gets resolved: F5.9 (authorization), F5.10 (audit), F5.7 (`ConnectedSyncPending` becomes a normal outcome the app can act on).

**What does not get resolved: the double-click.** With no queue there is no in-flight row to reject against. The guard is the existing already-connected check — a second click gets `AlreadyConnected` rather than a duplicate connect. Disable the button on click; treat anything tighter as a UI problem, not a data one.

**`AddConnectionRoleAssignment` runs before all of this**, delegated, from the app. The broker cannot use the connection until the owner grants it, and only the owner can do that. It returns 201, never 202.

### 10.3 `crbab_GitAuditLog` — the only table

| Column | Type | Notes |
|---|---|---|
| `crbab_WorkspaceId` | Text | Target workspace |
| `crbab_Action` | Choice | `Connect` \| `Sync` \| `Disconnect` |
| `crbab_ConnectionId` | Text | Owner's connection |
| `crbab_Organization` / `Project` / `Repository` / `Branch` / `Directory` | Text | Connect parameters |
| `crbab_InitializationStrategy` | Choice | `None` \| `PreferRemote` \| `PreferWorkspace` — set by stage 2 only |
| `crbab_Outcome` | Choice | `Requested` \| `Denied` \| `Started` \| `NeedsChoice` \| `ConnectedSyncPending` \| `Failed` |
| `crbab_OperationId` | Text | **Nullable** — a 200 produces none |
| `crbab_Message` | Multiline | Shown to the owner |
| `crbab_ErrorDetails` | Multiline | `error.moreDetails` from F2.2 |

`createdby` and `createdon` come free and are the authorization anchor (§10.2).

### 10.4 Why one table and not two

**The row is written by the app at `Requested`, and updated once by the flow.** Two writes, then it stops moving. That is a compromise on audit purity — a strictly append-only log never updates — but a request row and an audit row that differ only in whether the flow has run yet is one table, not two. What matters is preserved: *who* asked, *what* they asked for, and *whether they were allowed*, all recorded before the flow acts, so a denial is as durable as a success.

**The outcome recorded is the attempt, not the result.** Nothing waits for the Fabric operation, so `Started` is often the last thing written. Accepted deliberately: authorization is the thing that needs an audit trail, and it is fully decided by the time that row is updated.

Optionally, when the owner hits Refresh and `GetGitOperationStatus` comes back terminal, the **app** can patch the outcome onto the row. It runs as the owner, who owns the row, so this needs no extra flow and no extra privilege — and the log picks up final outcomes for anyone who bothers to look.

### 10.5 `GetGitOperationStatus` — single-shot, built 2026-08-07

The old loop was right when a flow had to return a finished answer; it was wrong once nothing waits. A looping flow holds a run open, cannot be re-entered, and gives the UI nothing to call. It is now **stateless and single-shot**:

1. Trigger: **Power Apps (V2)**, input `operationId`.
2. Fetch its own token via `GetFabricToken` — it no longer receives one from a parent.
3. `GET /v1/operations/{operationId}` — **one call, no `Delay`, no `Do_until`**.
4. If `Succeeded`, `GET /v1/operations/{operationId}/result` as well.
5. Return `status`, `percentcomplete`, `errorcode`, `errormessage`, `errordetails`, `requiredaction`, `remotecommithash`.

Called by the canvas app's Refresh button, and by nothing else. It is a **read**: one `GET`, no writes, nothing advanced, no next call. No concurrency guard needed, and nothing breaks if the owner mashes the button.

**No sweeper, and nothing waits — decided 2026-08-07.** An operation nobody looks at is not chased. Fabric completes the sync on its own; a request that no one refreshes simply has no local record of having finished. The cost is accepted: `Started` may be the last outcome ever written (§10.3), and the UI must say *"last known: Running"* rather than implying it is live.

**`Succeeded` is not the end of the story.** `GET /v1/operations/{id}` returns *state only* — `status`, `percentComplete`, `error`. The payload comes from a **separate** `GET /v1/operations/{id}/result`. For a 202 `initializeConnection` that result is where `requiredAction` and `remoteCommitHash` live, and `remoteCommitHash` is the only required field of `updateFromGit`. So a 202 on initialize leaves the sync unstarted until someone reads `/result` and acts on it — which is why **F5.5 is not closed by this flow returning `requiredaction`**; something still has to make the follow-up call. Simplest resolution: the app, on Refresh, sees `requiredaction` and calls `SyncWorkspaceWithGit` to finish the job.

`Retry-After` on the 202 is 30 seconds; that is what the UI should suggest before a re-click of Refresh.

### 10.6 Staged connect — let the owner decide

`initializeConnection` takes `initializationStrategy`, documented as the strategy "when content exists on **both** the remote side and the workspace side." Today the flow passes a strategy chosen in the wizard *before* anyone knows whether it matters. That asks the owner a question they cannot yet answer, and silently overwrites one side when they guess wrong.

`RequiredAction` has exactly three values — `None`, `UpdateFromGit`, `CommitToGit`. **There is no `Conflict` value.** So Fabric reports the unambiguous cases as a `requiredAction`, and the ambiguous one has to arrive as the documented error `MissingInitializationPolicy`. That gives a clean probe.

**Stage 1** — `connect`, then `initializeConnection` with `initializationStrategy: None`:

| Probe result | Meaning | Stage 1 returns |
|---|---|---|
| `requiredAction: None` | both sides empty, or already in sync | `Succeeded` — no stage 2 needed |
| `requiredAction: UpdateFromGit` | workspace empty, repo has content | `UpdateFromGit`; sync down, no data can be lost |
| `requiredAction: CommitToGit` | workspace has content, repo empty | `CommitToGit`; sync up, nothing to overwrite |
| error `MissingInitializationPolicy` | **both** have content | `NeedsChoice` — ask the owner first |

**Stage 2 always runs — `SyncWorkspaceWithGit`.** Stage 1 connects and reports; stage 2 moves the content. For `UpdateFromGit` and `CommitToGit` the app calls it straight through with the `requiredAction` stage 1 returned. For `NeedsChoice` the app first shows what stage 1 found and offers `PreferRemote` (repo wins, workspace items are replaced) or `PreferWorkspace` (workspace wins, repo is overwritten) in the owner's words, not the API's — then passes the answer to the same flow, which re-calls `initializeConnection` with that strategy before syncing.

It is a separate flow, not a branch in `ConnectWorkspaceToGit`, because the workspace is **already connected** by the time it runs — calling `connect` again would fail. The cost is one extra app→flow round trip on every connect; the gain is that each flow does one thing and the ambiguous case needs no special path.

Two consequences worth stating plainly:

- **Stage 1 mutates.** `connect` has already succeeded when the probe fails, so an owner who abandons at stage 2 leaves the workspace connected but not initialized. That is exactly `ConnectedSyncPending`, which makes **F5.7 unconditional and central** — not an edge case but a normal resting state with its own UI, offering resume or disconnect.
- **The repo side cannot be inspected without connecting.** Fabric exposes no "is this directory empty" call. `GET /v1/workspaces/{workspaceId}/items` can tell the wizard whether the *workspace* is empty before anything is touched, but the repo side is only knowable through the probe.

**To verify by test:** that both-non-empty with `initializationStrategy: None` really returns `MissingInitializationPolicy`. The error name and the strategy's own documentation both point that way, but no sample shows it. `ab_demo_5` (has items) against `fabricrepo2/test` (has content) is the test.

### 10.7 Open questions

- Retention on `crbab_GitAuditLog`. It is the audit record, so the answer is probably "never", but somebody has to say so.
- App users need **Create** on `crbab_GitAuditLog`, and **Read** on their own rows — security-role work under §6. The flow's SPN needs **Read/Write** on all rows.
- **Consumed rows.** Whether to stamp a row as used on first read, so an audit row ID cannot be replayed into a second flow run (§10.2). Low risk, cheap to add.
- **Concurrency.** The app writes the row once, the flow updates it once. The only real race is a double-click, and the already-connected check covers it (§10.2).

**Descoped** (Contributors can already do these in the UI): `GetGitSyncStatus`, `CommitWorkspaceToGit`, `UpdateWorkspaceFromGit` as standalone flows, and `ChangeGitConnectionSettings` (use disconnect + connect). Note the `commitToGit` / `updateFromGit` **calls** remain inside `ConnectWorkspaceToGit` because initialize requires them.

**Also descoped:** `crbab_GitConnection` and `crbab_WorkspaceGitMapping` tables — Fabric owns that state and the GET APIs return it live.

**Superseded:** `ListGitConnections` (built) runs as the broker SPN, so it returns the SPN's connections rather than the caller's. Retire it or rebuild it as `ListMyConnections` on the delegated connector. See F3.1.
