# Open Issues

Living list of unresolved items. Companion to [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/FLOWS.md](docs/FLOWS.md).

Changes required to the already-built flows are tracked as **C1–C11** in [docs/FLOWS.md](docs/FLOWS.md).

Last reviewed: 2026-08-06

---

## 1. Bugs — fix first

### 1.1 `ConnectWorkspaceToGit` Switch never matches (critical)

In [Workflows/ConnectWorkspaceToGit-1E895D49-DA8F-F111-8076-70A8A530AE85.json](Workflows/ConnectWorkspaceToGit-1E895D49-DA8F-F111-8076-70A8A530AE85.json), the `act_on_requiredAction` Switch evaluates:

```
@body('Initialize_connection')?['requiredAction']
```

but its case values are `PreferWorkspace` and `PreferRemote` — those are `initializationStrategy` inputs, not `requiredAction` outputs. `requiredAction` returns `CommitToGit`, `UpdateFromGit` or `None`.

Result: no case ever matches, every run falls to `default`, `outcome` is set to `Connected`, and **no content is ever synced** — while the flow reports success.

Fix in the designer: change the case values to `CommitToGit` and `UpdateFromGit`. The action bodies inside each branch are already correct.

### 1.2 `CommitToGit` sends null `workspaceHead`

Same flow. The `CommitToGit` branch always sends `workspaceHead` from the initialize response, but that branch fires precisely when the remote branch is **empty**, where `workspaceHead` is null. The property should be omitted, not sent as null.

Power Automate can't conditionally omit a property inline — build the body in a Compose and pass `@outputs('Compose')`.

Confirm against a real empty branch first; the API may tolerate it.

### 1.3 `ListGateways` — `cont` initialised to backticks

Around line 79 of [Workflows/ListGateways-4469367C-AD89-F111-AB0F-7C1E528D41FB.json](Workflows/ListGateways-4469367C-AD89-F111-AB0F-7C1E528D41FB.json), `cont` is initialised to two literal backtick characters rather than empty, producing `?continuationToken=%60%60` on the first iteration.

### 1.4 `ListGateways` — 5-page cap

The Do-until exit condition includes `greaterOrEquals(variables('pageCount'), 5)`, silently truncating results at five pages. A Do-until that exits on its own limit reports success.

### 1.5 Stale connection reference

`crbab_sharedwebcontents_0b635` (connector `shared_webcontents`) is at line 3829 of `customizations.xml`. The `.msapp` was unpacked and verified to contain **zero** references to it — the dependency is stale.

Fix: re-save `ListGateways` without the `InvokeHttp` action, delete the connection reference in the maker portal, re-publish the app, re-export. Do not hand-edit `customizations.xml`.

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

### 3.1 Broker SPN not enabled for Fabric APIs — CONFIRMED, blocking

**Confirmed 2026-08-06.** `ConnectWorkspaceToGit` fails at `Check_existing` with `401 Unauthorized` / *"The caller is not authenticated to access this resource"*. Reproduced outside Power Automate with `Workflows/diag-401.ps1`, using the exact credentials from `GetFabricToken`:

| | |
|---|---|
| Token request | **succeeds** |
| `aud` | `https://api.fabric.microsoft.com` |
| `appid` | `a385fde9-1d6a-4e7f-8336-dc7feba5a4bc` (`sp_fabric_powerapp`) |
| `tid` | `9e929790-272d-4977-a2ab-301443c11ece` |
| `idtyp` | `app` |
| `roles` | *(none)* |
| `GET /v1/workspaces/{id}/git/connection` | **401 Unauthorized** |

The flow wiring is correct — the token is valid and correctly scoped. Fabric is rejecting the service principal.

**`roles` being empty is not the fault.** Fabric does not grant API access through Entra application permissions; an app-only Fabric token legitimately carries no roles. Adding application permissions in the app registration will not fix this.

**401 vs 403 is the tell.** 403 would mean authenticated but lacking a role on the object. 401 means the SPN is not permitted to call Fabric APIs at all — the tenant setting.

Fix:

1. Add the `sp_fabric_powerapp` **service principal** to an Entra security group.
2. Fabric Admin portal → Tenant settings → Developer settings → **Service principals can use Fabric APIs** → enable, scoped to that group.
3. Wait for propagation (~15 min), re-run `diag-401.ps1`.
4. A **403** at this point is progress — it means authentication now succeeds and only the workspace role is missing. Go to 3.2.

This blocks the entire test scenario in §7, including the 1.1 Switch bug, because `Check_existing` gates every downstream action.

### 3.2 Broker SPN workspace Admin coverage

`sp_fabric_powerapp` must hold **Admin** on every managed workspace. Unclear how this is granted for existing workspaces and maintained for new ones.

For testing, grant it Admin on `e9de0b2d-0cc1-42ed-9395-28da86acfd97` — `GET .../git/connection` should then return **200** with `NotConnected`.

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

Power Automate HTTP actions have a built-in retry policy (default: exponential, 4 retries) covering 429 and 5xx. Action required:

- Confirm the policy is not set to **None** on any HTTP action.
- Raise the retry count on the Fabric calls.
- Child-flow (`Workflow` type) actions have their own retry settings — check those too.
- `PollFabricOperation`'s Do-until must tolerate a 429 from `/v1/operations/{id}` without treating it as a terminal state.

Only build custom `Retry-After` handling if testing shows the built-in policy is insufficient.

### 6.2 Do-until timeouts report success

Any Do-until that exits via its own iteration/timeout limit reports success. Every loop needs a post-loop condition asserting the real terminal state. Applies to `PollFabricOperation` and `ListGateways`.

---

## 7. Test scenario — not yet executed

Workspace `e9de0b2d-0cc1-42ed-9395-28da86acfd97`, one **Notebook** named `TestSync`. Repo `skscontoso/fabric/fabricrepo2`, branch `main` (**must be empty**), directory `test`.

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
- verify the broker SPN holds the tenant setting and workspace Admin in that environment (§3)
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
