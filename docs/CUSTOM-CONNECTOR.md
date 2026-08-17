# Custom connector — build instructions

How to recreate `gateway_lst_app_con` from scratch in the maker portal. Values verified against the exported artifacts in `Connector/` on 2026-08-17.

Related: `ARCHITECTURE.md` §5 (what the connector is), `PREREQUISITES.md` (the backing app registration), `OPEN-ISSUES.md` §9 (consent and connection-recreation problems), `FLOWS.md` (which flow calls which operation).

---

## 1. Connector-level settings

Schema name `ab_gateway-5flst-5fapp-5fcon`. Create it **inside the solution** so it becomes a Dataverse row rather than a classic connector.

### General tab

| Field | Value |
|---|---|
| Scheme | `HTTPS` |
| Host | `api.fabric.microsoft.com` |
| Base URL | `/v1` |

Base URL stays `/v1`. If it already contains the operation path, the path resolves to empty and validation fails with `paths/ : The path is not valid`.

### Security tab

| Field | Value |
|---|---|
| Authentication type | Azure Active Directory |
| Client ID | `1c221a2d-9a70-48cc-81b8-e68dfba7afbd` |
| Client secret | from the `gateway_lister_app` registration |
| Login URL | `https://login.microsoftonline.com` |
| Tenant ID | `9e929790-272d-4977-a2ab-301443c11ece` |
| Resource URL | `https://api.fabric.microsoft.com` |
| Scope | `Gateway.Read.All Connection.ReadWrite.All offline_access` |
| Enable on-behalf-of login | `false` |

The single space-delimited scope key is the connector UI's own encoding, not a malformed value. With the *Azure Active Directory* type the connector prepends the Resource URL, so short scope names are correct; under **Generic OAuth 2** they must be fully qualified or consent closes silently.

`security` and `securityDefinitions` are regenerated from this tab — edits made in the Swagger Editor are discarded.

After the first save the portal issues a redirect URL. Paste it into the app registration. Current value:

```
https://global.consent.azure-apim.net/redirect/gateway-5flst-5fapp-5fcon-5fe4e6bd1abcd77fac-5f0c1c5dd7f4e428ac
```

---

## 2. Actions

Five operations. For each: Definition tab → **New action** → fill Summary / Description / Operation ID → set the **operation** Visibility to `none` → **Import from sample** → paste Verb, URL, headers and body → **Add default response** → paste the sample payload so dynamic outputs appear in the flow designer.

Paste the *full* URL into Import from sample. The portal strips the host and base path automatically.

### 2.1 `ListGateways`

Summary `list gateways`. Description `Returns a list of all gateways the user has permission for, with pagination.`

```
GET  https://api.fabric.microsoft.com/v1/gateways?continuationToken=
```

Response:

```json
{"value":[{"id":"","type":"","displayName":"","capacityId":"","inactivityMinutesBeforeSleep":0,"numberOfMemberGateways":0}],"continuationToken":"","continuationUri":""}
```

### 2.2 `ListConnections`

Summary `list my connections`. Description `Returns the connections the signed-in user has permission for.`

```
GET  https://api.fabric.microsoft.com/v1/connections?continuationToken=
```

Response:

```json
{"value":[{"id":"","displayName":"","gatewayId":"","connectivityType":"","privacyLevel":"","connectionDetails":{"type":"","path":""}}],"continuationToken":"","continuationUri":""}
```

### 2.3 `GetConnection`

```
GET  https://api.fabric.microsoft.com/v1/connections/{fabricConnectionId}
```

Response:

```json
{"id":"","displayName":"","gatewayId":"","connectivityType":"","connectionDetails":{"type":"","path":""}}
```

### 2.4 `ListConnectionRoleAssignments`

```
GET  https://api.fabric.microsoft.com/v1/connections/{fabricConnectionId}/roleAssignments?continuationToken=
```

Response:

```json
{"value":[{"id":"","principal":{"id":"","displayName":"","type":""},"role":""}],"continuationToken":""}
```

### 2.5 `AddConnectionRoleAssignment`

```
POST https://api.fabric.microsoft.com/v1/connections/{fabricConnectionId}/roleAssignments

Content-Type: application/json
```

Request body:

```json
{"principal":{"id":"00000000-0000-0000-0000-000000000000","type":"User"},"role":"Owner"}
```

Response:

```json
{"id":"","principal":{"id":"","type":""},"role":""}
```

---

## 3. Parameter summary

| Operation | Verb | Path | Parameters |
|---|---|---|---|
| `ListGateways` | GET | `/gateways` | `continuationToken` (query, optional) |
| `ListConnections` | GET | `/connections` | `continuationToken` (query, optional) |
| `GetConnection` | GET | `/connections/{fabricConnectionId}` | `fabricConnectionId` (path, required) |
| `ListConnectionRoleAssignments` | GET | `/connections/{fabricConnectionId}/roleAssignments` | `fabricConnectionId` (path, required), `continuationToken` (query, optional) |
| `AddConnectionRoleAssignment` | POST | `/connections/{fabricConnectionId}/roleAssignments` | `fabricConnectionId` (path, required), `Content-Type` (header), `body` |

---

## 4. Things that bite

- Typing `?continuationToken=` in the sample URL is what creates the query parameter. Leave **Required = No**.
- `{fabricConnectionId}` in braces creates the path parameter automatically — required, string.
- The Definition tab has a Visibility dropdown on the **operation** and another on each **parameter**, and they mean opposite things. An operation marked `internal` is invisible in the flow designer while still looking correct in the connector editor — operations want `none`.
- The `Content-Type` header parameter wants Visibility `internal` **plus** a default of `application/json`. Internal without a default means the header is never sent.
- The Test tab is inert until *Update connector* is clicked, and is unreliable for solution-aware connectors. Test from a flow instead.
- Recreating the connection mints a **new** connection reference. Re-export and confirm every flow moved across rather than assuming it.
- The connector is solution-aware, so access needs Dataverse **table privileges** on the `connector` table, not classic connector sharing. A missing role surfaces as `prvReadConnector`.
- `TenantId` is hardcoded in the connection parameters and travels with the solution export. Imported into another tenant it still points here and every sign-in fails.

---

## 5. Known drift from the exported definition

- The exported `AddConnectionRoleAssignment` `Content-Type` header is `{"name":"Content-Type","in":"header","required":false,"type":"string"}` — it carries **neither** `x-ms-visibility: internal` nor a default of `application/json`, contrary to §4. Re-check this after any connector edit.
- `securityDefinitions` in the exported OpenAPI shows `login.windows.net/common` / `login.microsoftonline.com/common` endpoints. That is export normalisation; the effective tenant comes from the `TenantId` connection parameter.
