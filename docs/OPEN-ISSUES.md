# Open Issues

Living list of unresolved items. Companion to [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/FLOWS.md](docs/FLOWS.md).

Changes required to the already-built flows are tracked as **C1–C11** in [docs/FLOWS.md](docs/FLOWS.md).

Last reviewed: 2026-08-06

---

## Summary

| # | Issue | Status |
|---|---|---|
| **1.1** | `ConnectWorkspaceToGit` Switch selected on strategy, not `requiredAction` | ✅ Fixed & exported |
| **1.2** | `workspaceHead` sent as `""` when null | 🟡 Correctness only — accepted by the API |
| **1.3** | `ListGateways` `cont` initialised to backticks | ✅ Fixed & exported |
| **1.4** | `ListGateways` 5-page cap | ➖ By design; truncation is silent |
| **1.5** | Stale `shared_webcontents` connection reference | ✅ Fixed & exported |
| **1.6** | Two broker SPNs; standardise on `sp_fabric_powerapp` | 🔴 Open |
| **1.7** | No `crbab_Workspaces` authorization check anywhere | ⏸ Deferred — **blocks sharing the app** |
| **1.8** | `updateFromGit` sent empty `remoteCommitHash` | ✅ Resolved via 1.1 |
| **1.9** | `initializeConnection` may return 202 with empty body | 🔴 Open — silent no-op |
| **1.10** | `conflictResolutionPolicy` hardcoded to `PreferRemote` | 🟡 Open — low impact |
| **1.11** | Connect requires the repo folder to already exist | ➖ By design — stated in the wizard |
| **1.12** | Poll success check compares against `"Succeeded "` (trailing space) | 🔴 Open — every run reports `Failed` |
| **1.13** | `updateFromGit` failed — item references a OneLake table absent from the target workspace | ➖ Root-caused — platform limitation, not a flow defect |
| **2** | Secrets in repo, `.gitignore` deleted, rotation outstanding | 🔴 Open |
| **3.1** | Broker SPN not enabled for Fabric APIs | ✅ Resolved |
| **3.2** | Broker SPN workspace Admin across ~4000 workspaces | 🔴 Open — largest operational dependency |
| **3.3** | Broker SPN object ID (reference) | ℹ Reference |
| **4.1** | Dec 1 2026 Git restriction | ➖ Accepted risk, out of scope |
| **5.1** | Is SPN-B needed? | ➖ Decided — dropped |
| **5.2** | Credential type inside the owner's connection | 🔴 Open |
| **5.3** | Expired connection credentials go unnoticed | 🟡 Open |
| **5.4** | `PATCH myGitCredentials` redundant? | 🟡 Open — test then remove |
| **6.1** | 429 / throttling | ➖ Decided; defaults verified in place |
| **6.2** | Do-until timeouts report success | 🟡 Open — `PollFabricOperation` |
| **7** | End-to-end test scenario | 🟡 Partially executed |
| **8.1** | Connection references arrive unbound on import | 🟡 Open |
| **8.2** | Run-only settings do not survive import | 🟡 Open |
| **8.3** | Hardcoded tenant / client IDs; `ab_TenantId` unused | 🔴 Open |
| **8.4** | Post-import checklist | ⏸ Deferred |
| **9** | Custom connector scopes + operations | 🔴 Open — must be **one pass** |
| **10** | Flows, tables and screens not yet built | 🔴 Open |

Legend: ✅ done · ➖ decided/accepted · 🟡 open, non-blocking · 🔴 open, needs action · ⏸ deliberately deferred · ℹ reference

**Do first:** §2 secrets (`.gitignore` restored, rotation), then 1.6 broker SPN consolidation.

---

## 1. Bugs — fix first

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

### 1.2 `workspaceHead` sent as `""` when null — CORRECTNESS ONLY

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

**Fix — delete the property from `Update_from_git`.** It is optional in `updateFromGit` and only provides optimistic concurrency; the flow calls initialize seconds earlier and is the sole writer.

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

Remaining, carried into 1.10: `conflictResolutionPolicy` is still hardcoded in the update branch. `remoteCommitHash` stays mapped from `Initialize_connection` — it is populated whenever that branch is legitimately reached.

### 1.9 `initializeConnection` may return 202 with an empty body

The API documents both `200` (with `InitializeGitConnectionResponse`) and `202 Accepted` (long-running, `Location` + `x-ms-operation-id`, **no body**).

`ConnectWorkspaceToGit` assumes 200 and reads `requiredAction`, `workspaceHead` and `remoteCommitHash` straight off the response. On a 202 all three resolve to empty, the Switch falls through to `default`, and the flow reports `Connected` having synced nothing — the same silent failure as 1.1, from a different direction.

Handle the 202: poll the operation via `PollFabricOperation`, then fetch the result before branching.

### 1.10 `conflictResolutionPolicy` hardcoded in the update branch

`Update_from_git` always sends `conflictResolutionPolicy: PreferRemote`, regardless of the strategy the user selected in the wizard.

Low impact — `UpdateFromGit` is only required when the workspace side is empty, so conflicts are unlikely. But if it is ever reached with content on both sides it silently overrides the user's choice. Map it from the strategy input, or document that update always prefers remote.

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

### 1.12 Poll success check compares against `"Succeeded "` — every run reports Failed

In `ConnectWorkspaceToGit`, the `Condition` inside `Has_operation` evaluates:

```
@body('Run_PollFabricOperation')?['status']  equals  "Succeeded "
```

The literal carries a **trailing space**, so it can never match. The `else` branch always runs and `outcome` is always set to `Failed` with the poll's `errormessage`, regardless of what actually happened.

Found 2026-08-07 while diagnosing 1.13, where it happened to give the correct answer by accident. Until it is fixed, no run outcome from this flow can be trusted in either direction.

Fix: delete the trailing space, then re-export.

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
- **The generic message is useless to an end user.** `GitSyncFailed` / *"Failed to sync between Git and the workspace"* says nothing. `error.moreDetails` names the item and the reason, so `PollFabricOperation` must surface it (C7e).

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

### 1.6 Two different broker service principals (FLOWS.md C1)

`GetFabricToken` requests its token with client ID `a385fde9-1d6a-4e7f-8336-dc7feba5a4bc` (`sp_fabric_powerapp`). All eight networking flows use `b5c04c9c-0588-418f-8f60-2d83d38cb635` (`sp_fabric_monit`).

**Decision 2026-08-06: standardise on `sp_fabric_powerapp`.** `sp_fabric_monit` holds `Tenant.Read.All` / `Tenant.ReadWrite.All`; an application surfaced to 4000 workspace owners must not execute on a tenant-wide identity. `sp_fabric_powerapp` is kept deliberately minimal.

Actions:

1. Repoint the eight networking flows to `sp_fabric_powerapp`. Preferred method: delete the inline `Initialize_variable clientSecret` + token HTTP block from each and call `GetFabricToken` as a child flow instead — one identity, one place to change, and it removes eight copies of the secret.
2. Grant `sp_fabric_powerapp` whatever the networking endpoints need, and nothing more. Establish exactly which permissions those are before granting — the point of the switch is lost if it ends up with the same breadth as `sp_fabric_monit`.
3. Add `sp_fabric_powerapp` to the *Service principals can use Fabric APIs* security group (see 3.1).
4. Grant `sp_fabric_powerapp` workspace **Admin** on managed workspaces (see 3.2).
5. Use `sp_fabric_powerapp`'s **object ID** — not `sp_fabric_monit`'s — in `RegisterGitConnection`. Granting the wrong principal produces a connect failure that looks like a Fabric bug.
6. Retest `Workflows/list gateways spn.ps1` with the new identity; its current Unauthorized result was against a different SPN.

Open: whether `sp_fabric_monit` retains any role in this solution. If not, remove it from the docs and stop maintaining its secret here.

### 1.7 Missing authorization check (FLOWS.md C8)

`ConnectWorkspaceToGit` contains no Dataverse lookup. There is no `ListRecords` action anywhere in `Workflows/`. Nothing currently stops a caller from connecting a workspace they do not own — the flow acts on whatever `workspaceId` it is handed.

This is the whole point of the Dataverse authorization boundary in ARCHITECTURE.md §3, and it is not implemented.

**Decision 2026-08-06: build later.** Accepted for now on the basis that the app is not yet shared with owners.

This must land before the app is shared with anyone outside the build team. Until then the flow URL is the only thing standing between a caller and any of the 4000 workspaces, and flow URLs are recoverable by anyone who can open the app.

What "later" has to include:

1. Create the request table; move `ConnectWorkspaceToGit` and `DisconnectWorkspaceGit` onto a Dataverse row-created trigger so `createdby` is stamped server-side.
2. Look up `crbab_Workspaces` for the target `workspaceId`; proceed only if `createdby` matches `crbab_primary_owner` or `crbab_secondary_owner`. **Fail closed** — no row found means deny, not allow.
3. Write the denial to `crbab_GitAuditLog` as well as the success.

The canvas app filtering the workspace list is **not** authorization — it is a convenience. The check has to be server-side.

---

## 2. Security — unresolved

- **`.gitignore` has been deleted.** A `git add .` would commit everything below.
- Plaintext secrets in `Workflows/list gateways spn.ps1`, `Workflows/test rest.ps1`, and `internal_power_app.txt`.
- Secrets for `gateway_lister_app` and `sp_fabric_powerapp` need **rotating** — they have been exposed in chat and in files. `sp_fabric_monit`'s secret appears in the exported flows too and should be rotated even though it is being retired from this solution.
- Flows carry the SPN secret via an `Initialize_variable clientSecret`. **Decision 2026-08-06: leave as is for now**; migrate to a Key Vault-backed secret environment variable in a later pass. This is deferred, not resolved — the secret still sits in the flow definition and therefore in the exported solution.

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

### 3.2 Broker SPN workspace Admin coverage

`sp_fabric_powerapp` must hold **Admin** on every managed workspace.

Satisfied for the test workspace `e9de0b2d-0cc1-42ed-9395-28da86acfd97` \u2014 `ConnectWorkspaceToGit` gets past `Check_existing`, which it could not do without a workspace role.

**Still open for the other ~4000.** Unclear how Admin is granted at that scale and how it is maintained for newly created workspaces. This is the single largest unplanned operational dependency in the design: the app is useless on any workspace where the broker is not Admin, and there is currently no process that guarantees it.

### 3.3 Broker SPN object ID

`sp_fabric_powerapp` object ID: **`6f70a764-908f-435b-a930-ffcb375577f3`** (from the `oid` claim).

This is the value `RegisterGitConnection` must pass as `principal.id` when granting the broker the `User` role on an owner's connection — **not** the client/application ID `a385fde9-…`. Confusing the two produces a role assignment that silently grants nothing, and connect then fails as if the connection were unshared.

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
- `PollFabricOperation`'s Do-until must tolerate a 429 from `/v1/operations/{id}` without treating it as a terminal state.

Only build custom `Retry-After` handling if testing shows the built-in policy is insufficient.

### 6.2 Do-until timeouts report success

Any Do-until that exits via its own iteration/timeout limit reports success. Every loop needs a post-loop condition asserting the real terminal state. Applies to `PollFabricOperation` and — accepted rather than fixed — `ListGateways` (see 1.4).

---

## 7. Test scenario — partially executed

Workspace `e9de0b2d-0cc1-42ed-9395-28da86acfd97`, one **Notebook** named `TestSync`. Repo `skscontoso/fabric/fabricrepo2`, branch `main` (**must be empty**), directory `test`.

Steps 5 and 6 have been exercised while diagnosing 1.1 and 1.2. The remaining steps are untested.

1. As the owner (Contributor) in the Fabric UI, confirm **connect is unavailable** — proves the app is necessary.
2. Confirm the owner *can* see Git status and commit/update controls once connected — proves the scope reduction is right.
3. Owner creates the ADO connection; confirm they are **Owner** on it. Record the ID and check `GET /v1/connections/{id}` → `connectionDetails.path` to settle the URL format.
4. Delegated call adds SPN-A as `User`; verify via `GET .../roleAssignments`.
5. Run `ConnectWorkspaceToGit` with strategy `PreferWorkspace`. Expect `requiredAction: CommitToGit` → Switch matches (**only after fixing 1.1**) → 202 → poll to `Succeeded`.
6. Verify in ADO:
   ```
   test/TestSync.Notebook/.platform
   test/TestSync.Notebook/notebook-content.py
   ```
   Empty `test/` plus a success outcome means 1.1 is still live.
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

### 8.3 Hardcoded per-environment values (FLOWS.md C2)

Every token-acquiring flow hardcodes environment-specific values:

- tenant GUID `9e929790-…` in the token URI — `GetFabricToken` plus all eight networking flows
- the SPN client ID in the request body — and it is not the same client ID in all of them, see 1.6
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
- grant the broker SPN workspace **Admin** on the managed workspaces in that environment (3.2)
- share the connector, app and security role with the target environment's group team (ARCHITECTURE §6)

---

## 9. Custom connector work

Not yet done, and **must all be published in one pass before rollout** — adding a scope later forces every user to delete and recreate their connection.

- Add delegated `Connection.ReadWrite.All` to `gateway_lister_app` alongside `Gateway.Read.All`.
- Scope field on the Security tab becomes: `Gateway.Read.All Connection.ReadWrite.All offline_access`.
- Add operations: `GET /connections`, `GET /connections/{connectionId}`, `POST /connections/{connectionId}/roleAssignments`.
- Front-load any other scope this connector will ever need.
- Delete and recreate the existing connection afterwards; re-point the connection reference and re-save affected flows.
- Confirm tenant consent policy allows this, or arrange admin consent before rollout.

---

## 10. Not yet built

- `ListMyConnections` (delegated) — `GET /v1/connections`, filter to `AzureDevOpsSourceControl`, paginate with `continuationToken` (no server-side type filter).
- `RegisterGitConnection` (delegated) — grant SPN-A `User` on the connection; runs on the **final** wizard step. Self-authorizing, so a PowerApp V2 trigger is acceptable.
- `DisconnectWorkspaceGit` (SPN-A) — synchronous; allow with a warning.
- `crbab_GitAuditLog` table.
- Canvas app wizard screens.

**Descoped** (Contributors can already do these in the UI): `GetGitSyncStatus`, `CommitWorkspaceToGit`, `UpdateWorkspaceFromGit` as standalone flows, and `ChangeGitConnectionSettings` (use disconnect + connect). Note the `commitToGit` / `updateFromGit` **calls** remain inside `ConnectWorkspaceToGit` because initialize requires them.

**Also descoped:** `crbab_GitConnection` and `crbab_WorkspaceGitMapping` tables — Fabric owns that state and the GET APIs return it live.

**Superseded:** `ListGitConnections` (built) runs as the broker SPN, so it returns the SPN's connections rather than the caller's. Retire it or rebuild it as `ListMyConnections` on the delegated connector. See FLOWS.md C4.
