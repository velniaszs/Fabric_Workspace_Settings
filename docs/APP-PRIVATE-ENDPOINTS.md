# Managed private endpoints — investigation

Design investigation for a **Private endpoints** element on the app's networking screen, matching what the Fabric UI offers at *Workspace settings → Network security → Managed private endpoints*.

Reference: [Create and use managed private endpoints](https://learn.microsoft.com/en-us/fabric/security/security-managed-private-endpoints-create), [Overview](https://learn.microsoft.com/en-us/fabric/security/security-managed-private-endpoints-overview), [REST API — Managed Private Endpoints](https://learn.microsoft.com/en-us/rest/api/fabric/core/managed-private-endpoints).

Related: [ARCHITECTURE.md](docs/ARCHITECTURE.md) §2, §3, §5, [FLOWS.md](docs/FLOWS.md), [APP-OUTBOUND-TAB.md](docs/APP-OUTBOUND-TAB.md), [CUSTOM-CONNECTOR.md](docs/CUSTOM-CONNECTOR.md), [OPEN-ISSUES.md](docs/OPEN-ISSUES.md) §10.3.

Status: **investigation only — nothing built.** Verified against the Microsoft Learn docs on 2026-09-02.

---

## 1. Answers up front

| Question | Answer |
|---|---|
| Which flows? | Three new ones: `ListPrivateEndpoints`, `CreatePrivateEndpoint`, `DeletePrivateEndpoint`. A fourth, `GetPrivateEndpoint`, is optional and probably unnecessary — see §4.4 |
| Which APIs? | `GET`, `POST`, `DELETE` on `/v1/workspaces/{workspaceId}/managedPrivateEndpoints` — nothing else |
| Delegated calls needed? | **No.** All three run app-only as SPN-A, exactly like the existing networking flows |
| Custom connector changes needed? | **No.** No new operations, no new scopes, no re-consent, no new connection reference |
| New Fabric permissions needed? | **None.** SPN-A already holds workspace Admin, which is the highest role any of these APIs require |
| **Azure permissions needed?** | **None, for us.** Neither SPN-A nor the owner needs any Azure RBAC on the target resource. The Azure-side rights sit entirely with the *approver* — see §3.2 |
| New tenant setting? | **No.** There is no tenant switch for managed private endpoints — verified against the tenant settings index, §6.1 |
| Polling / operation IDs? | **No.** These are not long-running operations in the Fabric sense. There is no `x-ms-operation-id` and `GetGitOperationStatus` is not involved |
| Duplicate handling? | **Both rules are server-enforced**, confirmed 2026-09-02: `DuplicatePrivateEndpointName` for the name, `DuplicateTargetPrivateLinkResourceId` for the (resource ID + sub-resource) pair. Both `400`. The flow carries no duplicate logic; the app checks inline purely for the field-level error. See §5.5 |
| Can `targetSubresourceType` be derived? | **Mostly, but the field stays.** 1:1 for ~15 types, 1:many for storage, Cosmos, Synapse, Purview and Databricks — where the resource ID cannot distinguish them. See §5.6 |

The short version: this is the **easiest** feature added to the app so far. It is three HTTP calls on one resource, all app-only, all covered by a role the broker already has.

---

## 2. The APIs

Base: `https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/managedPrivateEndpoints`

| # | Call | Fabric role required | Response | Notes |
|---|---|---|---|---|
| 1 | `GET .../managedPrivateEndpoints` | **Viewer** or higher | `200` + `{ value: [...], continuationToken?, continuationUri? }` | Paginated. Supports `?continuationToken=` |
| 2 | `POST .../managedPrivateEndpoints` | **Admin** | `201` + the created object + `Location` header | Returns immediately with `provisioningState: "Provisioning"` |
| 3 | `DELETE .../managedPrivateEndpoints/{mpeId}` | **Admin** | `200`, empty body | Accepted, not completed — see §5.3 |
| 4 | `GET .../managedPrivateEndpoints/{mpeId}` | **Viewer** or higher | `200` + one object | Only useful for a single-row refresh |

All four support **service principal** identities. That is the fact the whole design rests on.

### 2.1 The object

```json
{
  "id": "59a92b06-6e5a-468c-b748-e28c8ff28da3",
  "name": "SqlPE",
  "targetPrivateLinkResourceId": "/subscriptions/.../providers/Microsoft.Sql/servers/testsql1",
  "targetSubresourceType": "sqlServer",
  "provisioningState": "Succeeded",
  "connectionState": {
    "status": "Approved",
    "description": "Endpoint approved",
    "actionsRequired": ""
  }
}
```

**Two independent status fields, and the UI shows both.** Conflating them is the most likely design mistake here.

| Field | Values | Owned by | Means |
|---|---|---|---|
| `provisioningState` | `Provisioning`, `Succeeded`, `Updating`, `Deleting`, `Failed` | **Fabric** | Did Fabric manage to create the endpoint object |
| `connectionState.status` | `Pending`, `Approved`, `Rejected`, `Disconnected` | **The data source admin, in the Azure portal** | Has the far end accepted the connection request |

`provisioningState: Succeeded` + `connectionState.status: Pending` is the **normal steady state** for minutes to days after creation. It is not an error and the app must not present it as one. The endpoint is unusable until the status reaches `Approved`.

`connectionState` is documented as the state "of provisioned endpoints" — expect it to be **absent** on a freshly created row (the `201` sample has no `connectionState` at all). Every read of it must be null-safe.

### 2.2 The create body

| Field | Required | Constraint |
|---|---|---|
| `name` | yes | ≤ 64 characters |
| `targetPrivateLinkResourceId` | yes | Full Azure resource ID |
| `targetSubresourceType` | no, but in practice yes | The private-link sub-resource, e.g. `sqlServer`, `blob`, `dfs` |
| `requestMessage` | no | ≤ 140 characters — this is the text the data source admin sees in the Azure portal |
| `targetFQDNs` | no | ≤ 20 entries. Only for Private Link Service / API Management style targets |

`targetSubresourceType` is optional in the schema and effectively mandatory in use. A storage account needs a **separate endpoint per sub-resource** — `blob` and `dfs` are two endpoints, not one. The picker must make that explicit or owners will create one endpoint and wonder why half their notebook fails.

---

## 3. Identity — why no delegated call and no connector work

The app has needed delegated calls twice, and both times for the same structural reason: the data or the right was **per-user** and the broker could not stand in.

| Existing delegated use | Why delegation was unavoidable |
|---|---|
| `ListMyConnections` | A connection list is per-user data. SPN-A's list is not the caller's list |
| `AddConnectionRoleAssignment` | An SPN cannot grant itself a role on someone else's connection. Only the connection Owner can |

**Managed private endpoints are neither.** They are workspace-scoped objects, there is no per-user view of them, and the write requires workspace **Admin** — which the owners explicitly do not have and will not be granted (ARCHITECTURE §1). A delegated create would fail with `403` for every single user of this app.

So delegation is not merely unnecessary here, it is **impossible for the write path** and pointless for the read path. Brokering through SPN-A is the only design that works, and it is the same shape as `GetOutboundRules` / `SetOutboundRules`.

Concretely, this means **no** change to `gateway_lst_app_con`:

- no new operations to add
- no new scope (`Workspace.Read.All` / `Workspace.ReadWrite.All` are **delegated** scopes; they are irrelevant to a client-credentials token)
- no re-consent, and no risk of the connection-recreation problem in [OPEN-ISSUES.md](docs/OPEN-ISSUES.md) §9
- no new connection reference to rebind after import ([OPEN-ISSUES.md](docs/OPEN-ISSUES.md) §8.1)

Each new flow's `connectionReferences` will be `{}`, matching `GetOAPSetting`, `GetOutboundRules` and `GetGatewayRules`.

### 3.1 Permissions — plane 1, Fabric

What SPN-A needs to make the three calls at all.

| Requirement | Where | Already satisfied? |
|---|---|---|
| SPN in `fabric_power_app_grp` + tenant setting *"Service principals can call Fabric public APIs"* | Fabric admin portal | ✅ PREREQUISITES A3 / B1 |
| SPN-A workspace **Admin** on the target workspace | Fabric workspace role | ✅ Already granted across the managed estate (OPEN-ISSUES §3.2) |
| Entra **application** permissions on `sp_fabric_powerapp` | App registration | ➖ None needed. Fabric access is not granted by app roles — ARCHITECTURE §2 |
| Delegated scopes | Custom connector | ➖ Not applicable, no delegated call |
| Tenant setting for managed private endpoints | Fabric admin portal | ➖ **There isn't one** — §6.1 |

Nothing to request, nothing to consent to. `403` on any of these three calls means SPN-A lost its Admin role on that workspace; `401` means A3/B1 broke.

### 3.2 Permissions — plane 2, Azure

**We need nothing in Azure. Not SPN-A, not the workspace owner, not the app.**

This is the part that looks like it should require an Azure grant and doesn't. The private endpoint is **not** created in the customer's subscription — Fabric provisions it inside a Microsoft-managed virtual network that Fabric owns. What lands on the customer's resource is a *private endpoint connection request*, in state `Pending`. Issuing that request is not a privileged operation on the target resource, which is exactly why the approval step exists: the request is inert until the resource owner accepts it.

So the Azure rights are all on the **approver's** side, and none of them are ours to hold or to grant:

| Azure requirement | Scope | Who holds it | When it's needed |
|---|---|---|---|
| `Microsoft.Network/register/action` — register the `Microsoft.Network` resource provider | Subscription containing the target resource | Subscription Owner or Contributor | Once per subscription, before the first endpoint |
| `Microsoft.<Provider>/<type>/privateEndpointConnectionsApproval/action` — e.g. `Microsoft.Sql/servers/privateEndpointConnectionsApproval/action`, `Microsoft.Storage/storageAccounts/privateEndpointConnectionsApproval/action` | The target resource | The data source admin — typically Owner or Contributor on that resource | At approval time, per endpoint |
| Anything at all, to **request** an endpoint | — | **Nobody** | Never |

The practical consequence is the useful one: **there is no Azure onboarding work for the 4000 workspaces.** No subscription needs to be enumerated, no service principal needs a Reader role anywhere, and nothing in this feature requires the Azure and Fabric estates to be reconciled in advance. The Azure dependency is per-target-resource, borne by that resource's owner, at the moment they approve.

The flip side is §5.1: because requesting costs no permission, the resource-ID field is, from Azure's point of view, unauthenticated free text. Approval is the control, not us.

### 3.3 Permissions — plane 3, Power Platform

What a workspace owner needs to press the button. Nothing new in kind — the same four steps as every other flow (ARCHITECTURE §6):

| Requirement | Note |
|---|---|
| Security role **`Fabric Workspace Owner`** | Already exists. No new table privileges unless P3 adds a Dataverse table |
| Canvas app shared with the group | Already done |
| **Run-only users** set on each of the three new flows | New work, per flow, per environment. All three use *Use this connection* for the HTTP actions — no run-only user connection to bind, since there is no connector |
| Connector sharing | ➖ Not applicable — these flows touch no connector |

> Run-only settings **do not survive solution import** (OPEN-ISSUES §8.2). Three new flows means three more entries on the post-import checklist that does not exist yet (§8.4).

---

## 4. Flows to build

Same skeleton as every existing networking flow: `Run_a_Child_Flow` → `GetFabricToken` → `Initialize_variable` (`accessToken`) → `HTTP` → `Respond to a Power App or flow`. No connector, no inline token block.

Full build instructions live in one file per flow:

- [flows/nocustomcon/ListPrivateEndpoints.md](docs/flows/nocustomcon/ListPrivateEndpoints.md)
- [flows/nocustomcon/CreatePrivateEndpoint.md](docs/flows/nocustomcon/CreatePrivateEndpoint.md)
- [flows/nocustomcon/DeletePrivateEndpoint.md](docs/flows/nocustomcon/DeletePrivateEndpoint.md)

The summaries below are the design intent; the per-flow files are the build specification and win on any detail.

### 4.1 `ListPrivateEndpoints` — read

| | |
|---|---|
| Trigger | Power Apps (V2), one required text input `workspaceId` (key `text`) |
| Calls | `GET /v1/workspaces/{id}/managedPrivateEndpoints` |
| Returns | `endpointsjson` (string) |

**Must page.** The response carries `continuationToken`, so this needs the `Do_until` pattern from `ListMyConnections` / `AddConnectionRoleAssignment`, not a bare GET. Use `PT1M` as the `Until` timeout, not `PT5M` — this responds to a PowerApp and the app's budget is 120 seconds.

In practice a workspace holds a handful of endpoints, so page 2 will be rare. Build the loop anyway; the pattern is copy-paste and a truncated list is indistinguishable from a complete one (OPEN-ISSUES FN.3).

Return the merged array as **one JSON string** and `ParseJSON` it app-side. That is what `GetOutboundRules` does with `rulesjson`, and it sidesteps the trap that cost flows 3 and 4 a field each: **every Respond output must be typed string** (FLOWS §4).

This flow also feeds the create panel's duplicate validation (§5.5).

### 4.2 `CreatePrivateEndpoint` — write

| | |
|---|---|
| Trigger | Power Apps (V2) — `workspaceId`, `name`, `targetPrivateLinkResourceId`, `targetSubresourceType`, `requestMessage` |
| Calls | `POST /v1/workspaces/{id}/managedPrivateEndpoints` |
| Returns | `outcome`, `endpointid`, `provisioningstate`, `message` |

Five trigger inputs means five positional keys — `text`, `text_1` … `text_4`. Name them deliberately before wiring anything; they bind positionally and are trivial to cross-wire (FLOWS §2).

`requestMessage` should be **composed by the flow, not typed by the user** — or at minimum prefixed. The data source admin approving this in the Azure portal needs to know who asked and why, and the caller's identity is the one thing the app knows and the Azure portal does not. Something like `"<workspace name> (<owner email>) — <user text>"`, truncated to 140.

The response must be reachable on **failure** as well as success — `runAfter` covering *is successful* and *has failed*. This is the exact defect fixed three times already in this solution (flows 5 and 7): a failed HTTP action skips the Respond and the app gets a dead run with no message at all.

Expected named failures worth mapping to a readable `outcome`:

| Condition | `outcome` | What the owner should be told |
|---|---|---|
| Duplicate name | `Failed` | Fabric's own message — *"Private Endpoint with the specified name already exists."* ✅ confirmed |
| Workspace not on an F64+/Trial capacity | `Failed` | Not available on this workspace's capacity |
| Recreating an endpoint to a resource deleted < 15 min ago | `Failed` | Wait 15 minutes — see §6 |
| Malformed / unsupported `targetPrivateLinkResourceId` | `Failed` | Bad resource ID, with the expected format |

`outcome` has exactly two values, `Created` and `Failed`. Every error is a 4xx carrying readable text, so naming individual failure modes in the contract buys nothing the `message` does not already give.

### 4.3 `DeletePrivateEndpoint` — write

| | |
|---|---|
| Trigger | Power Apps (V2) — `workspaceId`, `managedPrivateEndpointId` |
| Calls | `DELETE /v1/workspaces/{id}/managedPrivateEndpoints/{mpeId}` |
| Returns | `outcome`, `message` |

Destructive and **not undoable within 15 minutes** (§6). Requires a typed-name confirmation in the UI, not a plain "Are you sure?".

### 4.4 `GetPrivateEndpoint` — probably skip

A single-row `GET` only saves bandwidth. The list call already returns full status for every row, the lists are small, and a second flow is a second thing to build, share, document and re-bind on import. **Recommendation: don't build it.** Refresh by re-running `ListPrivateEndpoints`.

Revisit only if a per-row auto-refresh timer is added and re-listing proves too heavy.

---

## 5. What the app can and cannot do

### 5.1 Approval is out of scope, and that is the whole security model

Creating the endpoint sends a request to the data source. **Approval happens in the Azure portal, by the data source admin, outside Fabric.** There is no Fabric API to approve, and this app must not attempt it.

That is also the answer to the obvious objection — *can an owner point a private endpoint at any Azure resource in the world?* Structurally yes: the resource ID is a free-text field and Fabric will happily create a `Pending` request against a subscription nobody here controls. It does nothing until the far-side admin approves, so the blast radius is a stray pending request, not access. Still worth an allow-list if the customer wants one (§8).

The app should therefore include a short **"what happens next"** panel after creation: *the request is now pending with the owner of the target resource; nothing works until they approve it in the Azure portal*. Without that, every `Pending` row becomes a support ticket.

### 5.2 Create is not a long-running operation

`POST` returns `201` immediately with `provisioningState: "Provisioning"`. There is no `x-ms-operation-id`, no `202`, and `/v1/operations/{id}` has nothing to say about it. **`GetGitOperationStatus` is not involved.** Progress is observed by re-listing, nothing else.

> **A `201` is acceptance, not success — confirmed 2026-09-02.** Fabric does **not** validate `targetSubresourceType` against the target resource type at create time. A wrong sub-resource is accepted with `201`, the endpoint is created, and provisioning then fails — the Fabric UI shows its **Activation status as `Failed`**.
>
> Two consequences:
>
> 1. `outcome: Created` means *the request was accepted*, not that anything works. The app must re-list after creating and render `provisioningState`.
> 2. **`Failed` needs no diagnosis.** Failed means failed: the owner deletes the row and creates a new one with the right sub-resource. Not worth building explanation machinery for a state the combination list in §5.6 largely prevents.
>
> Prevention over explanation is the whole reason §5.6 constrains the picker — the API will not catch a mismatch, so the app must not offer one.

### 5.3 Delete returns 200 before it is done

`DELETE` answers `200` with an empty body, but the endpoint then moves through `provisioningState: "Deleting"` and lingers in the list. The gallery must not treat "still listed after delete" as a failed delete. Refresh and let `Deleting` render as its own state.

### 5.4 There is no update API

Four operations exist and none of them is `PATCH`. Changing a name, sub-resource or target is **delete + recreate**, and the 15-minute cooldown in §6 makes that a genuinely slow round trip. Same shape as the Git connection settings problem (FLOWS §6) — the UI must say so rather than letting an owner discover it.

### 5.5 Duplicates — name and resource identifier

The Fabric UI refuses to create an endpoint when **either** the *Managed private endpoint name* **or** the *Resource identifier* matches one that already exists in the workspace.

**Decision 2026-09-02: reproduce this in the app only. The flow carries no duplicate logic.**

The create panel validates against the collection `ListPrivateEndpoints` already loaded — Create stays disabled and the error appears next to the offending field. Re-run the list when the panel opens, not just when the tab loads, and the collection is current enough.

The arguments for *also* checking inside `CreatePrivateEndpoint` were examined and rejected:

| Argument | Verdict |
|---|---|
| "The trigger is a URL and can be called without the app" | **Not a reason.** A forged call that creates a *duplicate* is not an attack worth defending against. The forged call that matters creates an endpoint in a workspace the caller doesn't own — that is P1, and a duplicate check does nothing about it |
| "The app's collection goes stale" | **Real but narrow.** One or two owners per workspace, and the window is between opening the panel and pressing Create |
| "`AddConnectionRoleAssignment` checks before writing" | **Misread precedent.** That flow's pre-check made its `409` branch unreachable and hid a broken response for a week (FLOWS §7). A pre-check that shadows a server rule stops you finding out what the server does |

> **Fabric enforces both rules — confirmed by testing 2026-09-02.**
>
> | Attempt | Result |
> |---|---|
> | Same **name** | `400` · `DuplicatePrivateEndpointName` — *"Private Endpoint with the specified name already exists."* |
> | Same **resource ID + same sub-resource**, different name | `400` · `DuplicateTargetPrivateLinkResourceId` |
> | Same **resource ID + different sub-resource**, different name | **Accepted** — `201` |
>
> **The server's uniqueness key is the pair (`targetPrivateLinkResourceId`, `targetSubresourceType`)** — exactly the key this document argued for, and for the same reason: a storage account needs `blob` and `dfs` as two separate endpoints (§2.2). Fabric gets this right.
>
> **The flow needs no duplicate logic.** Both violations are a `400`, which the ordinary status-code test already reports as `Failed`, with Fabric's own message in `message`. No pre-flight `GET`, no `errorCode` mapping.
>
> **The app's check is a convenience, not a guard.** Since the server enforces both rules, the inline check exists only to put the error next to the field before the owner submits. If the app's collection is stale and a duplicate slips through, Fabric rejects it and the owner sees a readable message — a worse experience, not a wrong outcome.

> **A blanket "resource ID must be unique" rule is wrong, and Fabric agrees.** The third row above is the proof: the *same* `targetPrivateLinkResourceId` with a different sub-resource is accepted, because that is the documented storage-account case. Key the app's check on the pair, or it blocks a configuration Fabric explicitly supports.

Match case-insensitively on both fields. Azure resource IDs are case-insensitive in practice and arrive pasted from the portal, so `.../resourceGroups/RG1/...` and `.../resourcegroups/rg1/...` are the same resource.

### 5.6 Deriving `targetSubresourceType` from the resource ID

The Fabric UI infers the sub-resource from the resource identifier. We can do the same for **most** types, but the field cannot be removed — and the reason is visible in Fabric's own supported-sources table.

The sub-resource is Azure's **private-link group ID**, and it is a property of the *resource type*, not of the resource. So it is derivable by parsing the `/providers/{namespace}/{type}/` segment out of the ID — whenever that type has only one group ID.

#### 1:1 — the app fills it in and never asks

```
/subscriptions/2374e587-d28b-4898-a39c-6070e078ae31/resourceGroups/rg-data/providers/Microsoft.Sql/servers/sql-prod-01
                                                                                     └──────── type ────────┘
```

Type is `Microsoft.Sql/servers`, which has exactly one group ID: `sqlServer`. There is no second option, so there is no question to ask.

| Resource type in the ID | `targetSubresourceType` |
|---|---|
| `Microsoft.Sql/servers` | `sqlServer` |
| `Microsoft.Sql/managedInstances` | `managedInstance` |
| `Microsoft.KeyVault/vaults` | `vault` |
| `Microsoft.Kusto/clusters` | `cluster` |
| `Microsoft.EventHub/namespaces` | `namespace` |
| `Microsoft.Devices/IotHubs` | `iotHub` |
| `Microsoft.Search/searchServices` | `searchService` |
| `Microsoft.CognitiveServices/accounts` | `account` |
| `Microsoft.MachineLearningServices/workspaces` | `amlworkspace` |
| `Microsoft.DBforMySQL/flexibleServers` | `mysqlServer` |
| `Microsoft.DBforPostgreSQL/flexibleServers` | `postgresqlServer` |
| `Microsoft.Insights/privatelinkscopes` | `azuremonitor` |
| `Microsoft.ApiManagement/service` | `gateway` |
| `Microsoft.Web/sites` | `sites` |
| `Microsoft.Network/privateLinkServices` | *(empty)* |

#### 1:many — the ID is genuinely not enough

**Storage.** One account, at least two endpoints:

```
/subscriptions/2374e587-.../resourceGroups/rg-data/providers/Microsoft.Storage/storageAccounts/stdatalake01
```

| The owner wants to reach | Sub-resource |
|---|---|
| `stdatalake01.dfs.core.windows.net` — Parquet/Delta via ADLS Gen2, the Spark path | `dfs` |
| `stdatalake01.blob.core.windows.net` — a blob container | `blob` |

Same ID, same account, two different endpoints — **and a notebook using both needs both**, each approved separately. Also valid: `file`, `queue`, `table`, `web`. Nothing in the ID says which.

This is why Fabric's supported-sources table lists *Azure Blob Storage*, *Azure Data Lake Storage Gen2*, *Azure File Storage*, *Azure Queue Storage* and *Azure Table Storage* as five separate data sources **with one identical resource ID format**.

**Cosmos DB.** The account's API is not in its ID:

```
/subscriptions/2374e587-.../resourceGroups/rg-app/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-orders
```

→ `Sql` for the NoSQL API, `MongoDB` for the MongoDB API. Also `Cassandra`, `Gremlin`, `Table`, `Analytical`. Same reason Fabric lists *Cosmos DB for MongoDB* and *Cosmos DB for NoSQL* separately against one ID format.

**Synapse.** Three things behind one workspace:

```
/subscriptions/2374e587-.../resourceGroups/rg-analytics/providers/Microsoft.Synapse/workspaces/syn-analytics
```

→ `Sql` for a dedicated SQL pool, `SqlOnDemand` for serverless, `Dev` for Studio and pipelines.

**Purview** → `account` or `portal`. **Databricks** → `databricks_ui_api` or `browser_authentication`.

#### Is there an API that returns the valid combinations?

**Not one we can use.**

| Source | Verdict |
|---|---|
| Fabric REST | **Nothing.** No endpoint lists supported types or their sub-resources. The supported-source table is documentation only |
| Azure ARM — `GET .../{resourceId}/privateLinkResources?api-version=...` | **Exists and is authoritative**, returning the exact `groupId` values for a *specific* resource. **Rejected:** it requires Azure RBAC (Reader) on the target resource |

The second one is worth being explicit about, because it looks attractive. Calling it would mean SPN-A holding a role in every subscription any owner might ever target — which destroys the single best property of this feature: that it needs **no Azure permissions at all** and therefore no Azure onboarding across 4000 workspaces (§3.2). Trading that away to save a maintained list would be a bad bargain.

So the list is **maintained by us, and lives in the app** — which also means the picker keeps working for owners who cannot see the target subscription at all.

#### The combination list

Seed data, from Fabric's supported-sources table crossed with Azure's private-link group IDs. The lookup key is the **resource type**, lowercased.

**1:many — five types, dropdown with no default:**

| Resource type | Sub-resources to offer |
|---|---|
| `microsoft.storage/storageaccounts` | `blob`, `dfs`, `file`, `queue`, `table` |
| `microsoft.documentdb/databaseaccounts` | `Sql`, `MongoDB` |
| `microsoft.synapse/workspaces` | `Sql`, `SqlOnDemand`, `Dev` |
| `microsoft.purview/accounts` | `account`, `portal` |
| `microsoft.databricks/workspaces` | `databricks_ui_api`, `browser_authentication` |

**1:1 — auto-select, show read-only:**

| Resource type | Sub-resource |
|---|---|
| `microsoft.sql/servers` | `sqlServer` |
| `microsoft.sql/managedinstances` | `managedInstance` |
| `microsoft.keyvault/vaults` | `vault` |
| `microsoft.kusto/clusters` | `cluster` |
| `microsoft.eventhub/namespaces` | `namespace` |
| `microsoft.devices/iothubs` | `iotHub` |
| `microsoft.search/searchservices` | `searchService` |
| `microsoft.cognitiveservices/accounts` | `account` |
| `microsoft.machinelearningservices/workspaces` | `amlworkspace` |
| `microsoft.dbformysql/flexibleservers` | `mysqlServer` |
| `microsoft.dbforpostgresql/flexibleservers` | `postgresqlServer` |
| `microsoft.insights/privatelinkscopes` | `azuremonitor` |
| `microsoft.apimanagement/service` | `gateway` |
| `microsoft.web/sites` | `sites` |

> **`microsoft.network/privatelinkservices` is deliberately absent.** Azure defines its sub-resource as *empty*, and Fabric additionally requires `targetFQDNs` for it — which the app does not send in v1 (§6). Listing it would offer owners a choice that cannot succeed, and it would be the only row with a blank `crbab_subresource`, forcing the flow to build its request body conditionally instead of from a literal. Excluded on both counts. Add it if and when `targetFQDNs` is implemented.

> **Two caveats on this data.** Azure defines more values than Fabric documents — storage also has `web` and a `_secondary` variant of every entry, and Cosmos DB also has `Cassandra`, `Gremlin`, `Table`, `Analytical` and `SqlDedicated`. They are omitted above because Fabric does not list them as supported sources. Second, `microsoft.openenergyplatform/energyservices` (Azure Data Manager for Energy) is in Fabric's supported list but **not** in Azure's published group-ID table — its sub-resource is unverified. Both are reasons to keep the free-text fallback for unrecognised types rather than hard-failing.

#### Where it lives

A flat Dataverse table, **`crbab_PrivateLinkTarget`**, one row per **(resource type, sub-resource)** pair — this resolves P3. Seed data is in [data/PrivateLinkTargets.csv](data/PrivateLinkTargets.csv), 28 rows, matching the tables above.

| Column | Type | Purpose |
|---|---|---|
| `crbab_resourcetype` | Text (100) | Lookup key, lowercased — `microsoft.storage/storageaccounts` |
| `crbab_subresource` | Text (100) | The value sent as `targetSubresourceType`. **Case-sensitive** — `sqlServer`, `SqlOnDemand`, `MongoDB`. Never blank |
| `crbab_displayname` | Text (100) | Primary name column. What the owner reads — *"Data Lake Storage Gen2 (dfs)"* rather than `dfs` |
| `crbab_sortorder` | Whole number | So the common choice sits at the top of a dropdown |

**`crbab_subresource` is never blank**, and that is load-bearing: it means the app always sends a non-empty `targetSubresourceType`, so `CreatePrivateEndpoint` can use a literal JSON body rather than composing one conditionally. A row with an empty sub-resource would send `"targetSubresourceType": ""`, which is not the same as omitting the property.

Create it in the maker portal, **never by editing `customizations.xml`** (ARCHITECTURE §4), then import the CSV. It follows the existing seed-data convention alongside `data/AllowedConnectionType.xlsx`; CSV rather than XLSX because it diffs in review.

Add it to the `Fabric Workspace Owner` security role with **Read**, alongside `crbab_Workspaces` and `crbab_AllowedConnectionType` (ARCHITECTURE §6). Owners only ever read it.

App behaviour, given the type parsed out of the resource ID:

```
Filter(PrivateLinkTargets, crbab_resourcetype = parsedType)
```

- **1 row** → auto-select it, show read-only. No decision to make.
- **2+ rows** → dropdown on `crbab_displayname`, **no default**, Create disabled until chosen.
- **0 rows** → free text, and let Fabric have it.

Flat beats parent/child here: the dropdown is a filter on one table, and adding a newly supported source is one row, addable by anyone with Dataverse access and no app republish. That matters because Fabric's supported-source list grows — and because the two gaps noted above (`web`/`_secondary` variants, and Azure Data Manager for Energy) get closed by adding rows rather than by shipping a new app version.

#### Why guessing is worse than asking

There are **two** distinct failure modes, and neither is caught at create time.

**A sub-resource that is invalid for the resource type** — say `dfs` against a `Microsoft.Sql/servers` ID. Fabric accepts the `POST` with `201`, creates the row, and provisioning then fails: the endpoint shows **Activation = `Failed`** (§5.2). Visible, and the owner deletes it and creates a correct one.

**A sub-resource that is valid but not the one the owner needed** — `blob` where the work requires `dfs`. This is the dangerous one. Nothing complains at any stage: the endpoint provisions to `Succeeded`, the storage admin approves it, `connectionState.status` reads `Approved` — and the notebook still fails, because its traffic goes to a hostname this endpoint does not cover. Every signal the app can see says success.

The combination list kills the first outright and makes the second much less likely, which is why it is worth more than any amount of error-message polish on the `Failed` state.

Keep `targetSubresourceType` as a trigger input either way. The app decides the value; the flow just passes it.

> **Could the flow do the lookup instead?** No. It is a ~20-row table with five one-to-many rows, and expressing that as nested `if()` in a Logic Apps expression would be unreadable. The app needs the mapping anyway to render the dropdown, so a second copy in the flow is just something to drift.

> **Could we omit the field and let Fabric infer?** It is optional in the API, so possibly — for 1:1 types. Untested, and it cannot work for storage. Worth establishing (test 3 in [flows/nocustomcon/CreatePrivateEndpoint.md](docs/flows/nocustomcon/CreatePrivateEndpoint.md)) because it would let the app omit the field rather than guess when it meets a type it does not recognise.

This makes P3 more pressing: the mapping is no longer just a picker's contents, it is validation logic. A Dataverse table keyed on `provider/type` with the valid sub-resources per type can be maintained without republishing the app, which matters because Fabric's supported-source list grows.

Parsing the type out of the ID, app-side:

```
With(
    { m: Match(Trim(txtResourceId.Text), "/providers/(?<ns>[^/]+)/(?<type>[^/]+)/") },
    Lower(m.ns & "/" & m.type)
)
```

---

## 6. Constraints that are not ours to fix

| Constraint | Consequence for the app |
|---|---|
| **Capacity ≥ 64 CU** — Trial, F64 or larger | Creation is blocked on smaller capacities. Unknown how much of the 4000-workspace estate qualifies — **open question, §8** |
| **`Microsoft.Network` resource provider registered** in the target Azure subscription | Owned by the target subscription's admin. A create can fail for a reason nobody in Fabric can act on |
| **Region** — requires Fabric Data Engineering support in both the tenant home region and the capacity region | Creation is blocked outright where unavailable |
| **15-minute cooldown** — after requesting deletion, wait 15 min before creating a new endpoint to the same resource | The app must warn on delete, and explain the failure on a too-fast recreate |
| **FQDN-based endpoints are REST-only** | A capability the app *could* expose that the Fabric UI cannot. Out of scope for v1 — and the reason `Microsoft.Network/privateLinkServices` is excluded from the sub-resource picker (§5.6) |
| Approval is an Azure portal action | §5.1, §3.2 |

### 6.1 There is no tenant setting for this

Verified against the [tenant settings index](https://learn.microsoft.com/en-us/fabric/admin/tenant-settings-index) on 2026-09-02. **Advanced networking** contains five settings and none of them governs managed private endpoints:

| Setting | Governs |
|---|---|
| Tenant-level Private Link | Inbound private link *to the Fabric tenant* — a different feature |
| Block Public Internet Access | Inbound, same feature as above |
| Configure workspace-level inbound network rules | Inbound workspace rules |
| **Configure workspace-level outbound network rules** | **OAP — what the app's existing Outbound tab depends on** |
| Configure workspace-level IP firewall rules and trusted resource instances | Inbound firewall |

Two things follow.

First, **the private endpoints element has no tenant-level kill switch**, unlike the Outbound tab, which stops working entirely if an admin turns off *Configure workspace-level outbound network rules*. One less environment-specific prerequisite, one less thing to re-do per tenant.

Second, **do not be misled by the overview page**, which ends *"take them into account before enabling the Azure Private Link tenant setting for your tenant."* That sentence points at **Tenant-level Private Link** — inbound access to Fabric — which is unrelated to managed private endpoints and is not a prerequisite for them. The two features share the words "private link" and nothing else.

---

## 7. Where it goes in the app

Its **own tab**, on the tab bar beside Git and Outbound — decided 2026-09-02. Build guide: [APP-PRIVATE-ENDPOINTS-TAB.md](docs/APP-PRIVATE-ENDPOINTS-TAB.md).

> **Do not gate it on `gblFlowResult.oapenabled`.** Managed private endpoints are independent of Outbound Access Protection — they are inbound-to-datasource plumbing, not an outbound rule. The Fabric UI puts both under *Network security*, which makes the two easy to confuse. Every control in `RulesContainer` and `GatewaysContainer` lives under `networking/communicationPolicy/outbound/*`; nothing here does. Gating on OAP would hide a working feature on every workspace with OAP off.

Minimum UI:

- **Gallery** — name, target resource (last segment of the resource ID is enough; full ID on hover), sub-resource, `provisioningState`, `connectionState.status`, and the approver's `description` when present
- **`provisioningState: Failed`** — show it plainly and offer delete from the row. No diagnosis; the owner deletes and recreates with the right sub-resource (§5.2)
- **Refresh** — re-runs `ListPrivateEndpoints`. `Pending` and `Provisioning` are states users will sit and watch
- **Create panel** — name, resource ID, sub-resource, justification, with the supported-data-source table driving the sub-resource choice
- **Create validation, before the button enables** — name ≤ 64 chars and not already used; justification ≤ 140 chars; resource ID well-formed and not already paired with the same sub-resource (§5.5). Show the error on the field, not in a banner after submitting
- **Delete** — typed-name confirmation
- **Empty and error states** — "none yet" reads very differently from "the call failed"

Apply the load-flash lesson from [APP-OUTBOUND-TAB.md](docs/APP-OUTBOUND-TAB.md): a blank collection is falsy, so an unguarded "no private endpoints" label will flash on every workspace that has some. Gate on a `gblMpeLoaded` flag.

---

## 8. Open questions

| # | Question | Why it matters |
|---|---|---|
| P1 | **Authorization.** These are writes, and the app still has no `crbab_Workspaces` ownership check (OPEN-ISSUES §10.3, F5.9). A forged `workspaceId` on `DeletePrivateEndpoint` deletes a real endpoint in someone else's workspace | The Git flows deferred this on the argument that the app is limited to the build team. Deleting a private endpoint breaks a live data path — **this feature should not ship without F5.9** |
| P2 | Do we **allow-list** target resource IDs (subscription prefix, or a `crbab_AllowedPrivateEndpointTarget` table mirroring `crbab_AllowedConnectionType`)? | §5.1 — approval already gates real access, so this is governance, not security. Customer's call |
| P3 | ~~Where does the sub-resource list live?~~ | ✅ **Decided 2026-09-02.** A flat Dataverse table, one row per (resource type, sub-resource) pair, seeded from §5.6. No Fabric API exists; the Azure ARM one needs RBAC we deliberately do not hold |
| P4 | Is **delete** exposed at all in v1, or is the app read + create only? | Halves the risk surface and drops one flow. Deleting is rare and the Fabric UI can do it |
| P5 | How much of the estate is on **F64+/Trial**? | If most workspaces don't qualify, the tab is mostly a "not available on this capacity" message |
| P6 | Do we surface **`targetFQDNs`** (Private Link Service / API Management)? | REST-only capability — the app could beat the Fabric UI here, but it adds a repeating field and validation for a rare case |
| P7 | Audit rows for create/delete | Same gap as F5.10. If `crbab_GitAuditLog` is generalised, these belong in it |
| P8 | ~~Does Fabric reject duplicates itself?~~ | ✅ **Answered 2026-09-02.** Yes, both: `DuplicatePrivateEndpointName` for the name, `DuplicateTargetPrivateLinkResourceId` for the (resource ID + sub-resource) pair. Flow carries no duplicate logic. §5.5 |
| P9 | ~~Is a mismatched-sub-resource failure visible?~~ | ✅ **Answered 2026-09-02.** The row is created and shows **Activation = `Failed`**. No further handling — delete and recreate. The combination list in §5.6 is the real fix · §5.2 |

**Recommended order:** P1 first (it blocks shipping), then P4 (it changes what gets built), then P8 and P3 (both are cheap tests that change the create panel).

---

## 9. Test list

Things that must be established by running them, not by reading docs:

| # | Test | Establishes |
|---|---|---|
| T1 | Create an endpoint as SPN-A against a resource in a subscription where **SPN-A has no Azure role at all** | §3.2 — that no Azure RBAC is needed to request |
| ~~T2~~ | ~~Create the same name twice~~ | ✅ **Done 2026-09-02.** `400 DuplicatePrivateEndpointName` · §5.5 |
| ~~T2b~~ | ~~Same resource ID and sub-resource under a different name~~ | ✅ **Done 2026-09-02.** Permitted — no server-side rule. App blocks it · §5.5 |
| T3 | Create `blob` and `dfs` endpoints against **one** storage account | §5.6 — that both are accepted, i.e. the case the app's duplicate check must *not* block |
| T3b | Create without `targetSubresourceType` on a 1:1 type | §5.6 — whether Fabric infers it, and whether the app can ever omit the field |
| T4 | Create, then read the list before approval | §2.1 — that `connectionState` may be absent, and the field is null-safe |
| T5 | Delete, then list immediately | §5.3 — the `Deleting` state renders correctly |
| T6 | Delete, then recreate to the same resource inside 15 minutes | §6 — the failure is caught and explained, not surfaced raw |
| T7 | Run against a workspace on a sub-F64 capacity | §6 — the capacity failure is readable |
