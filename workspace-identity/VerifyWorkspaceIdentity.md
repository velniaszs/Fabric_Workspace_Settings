# Flow — `VerifyWorkspaceIdentity`

Child flow. For one workspace, reads the identity's **client ID** from Fabric, then asks **Entra ID** what that identity is called. The flow returns `clientid` and `name`, and it checks that Fabric and Entra agree on the identity.

> **Specification. Not built yet.** Read [README.md](README.md) first. The connections, the Fabric call pattern, the Catch block and the final `Respond` are all specified there once, and this document refers back to them.

APIs:

- [Workspaces — Get Workspace](https://learn.microsoft.com/en-us/rest/api/fabric/core/workspaces/get-workspace) returns `workspaceIdentity.applicationId`, which is the client ID.
- [Microsoft Graph — List servicePrincipals](https://learn.microsoft.com/en-us/graph/api/serviceprincipal-list) with `$filter=appId eq '…'` returns the `displayName` Entra holds for that client ID.

**This flow changes nothing. It only reads.** Run it as often as you like, including immediately before and after [ProvisionWorkspaceIdentity](ProvisionWorkspaceIdentity.md) or [DeprovisionWorkspaceIdentity](DeprovisionWorkspaceIdentity.md).

---

## 0. Before you start

- **This flow needs two connections** of *HTTP with Microsoft Entra ID (preauthorized)*: the Fabric one and the **Graph** one ([README.md](README.md) → *Solution and connections*). Both are signed in as the `workspace provisioning` service account.
- **The Graph read is delegated.** The connector is preauthorized for Microsoft Graph and acts as the signed-in account. It can read exactly what that account can read, and nothing more. Reading service principals works for an ordinary member user **unless the tenant restricts default user permissions**.

> ### Confirm the Graph read on the first build, before anything depends on it
>
> Run test 5 below first. If `Get_service_principal` returns **`403 Authorization_RequestDenied`**, the account cannot read service principals in this tenant. The options, in order of preference:
>
> 1. Ask the identity team to grant the `workspace provisioning` account the **Directory Readers** Entra role. That role is read-only and tenant-wide, and it is the smallest grant that covers this call.
> 2. Do without Entra. Fabric documents that the identity's name **follows the workspace name**, so `workspaceName` is the expected value. That is a statement of Fabric's intent, not a verification. If you take this route, rename the flow, because it no longer verifies anything.
>
> Do **not** work around it by adding a client secret or a service principal. Nothing else in these solutions uses one ([../capacity-policies/docs/SECURITY-AND-IDENTITY.md](../capacity-policies/docs/SECURITY-AND-IDENTITY.md)).

---

## Shape

The flow is **flat. It has no Condition at all.**

```
trigger   Manually trigger a flow — workspaceId
Step 2    7 × Initialize variable
Scope_try
  Step 3  Get_workspace                          (Fabric)
          Set_clientId, Set_servicePrincipalId, Set_workspaceName
  Step 4  Get_service_principal                  (Graph)
          Set_name, Set_entraObjectId
  Step 5  Set_outcome, Set_message
Scope_catch                                      ← README
Step 6    Respond_result
          Condition_outcome_failed               ← Yes: Terminate (Failed). Not reachable today; kept for symmetry
```

> **Why there is no "is it provisioned?" Condition.** The Graph call runs even when the workspace has no identity, and it asks for the zero GUID, which matches nothing ([Step 4](#step-4--ask-entra)). That keeps both HTTP calls as **immediate children of `Scope_try`**, so a Fabric `404` or a Graph `403` reaches the Catch with its **real** error text and not the Condition boilerplate ([README.md](README.md) → *Try / Catch*). For a read-only flow, one wasted Graph call is a better trade than an unreadable failure.

---

## Step 1 — Trigger

**Manually trigger a flow**, with one Text input `workspaceId` → `triggerBody()['text']`. See [README.md](README.md) → *Trigger*.

## Step 2 — Variables

All of these go at the top level, above `Scope_try`.

| Rename to | Name | Type | Value |
|---|---|---|---|
| `Initialize_outcome` | `outcome` | String | `Failed` |
| `Initialize_message` | `message` | String | *(empty)* |
| `Initialize_clientId` | `clientId` | String | *(empty)* |
| `Initialize_servicePrincipalId` | `servicePrincipalId` | String | *(empty)* |
| `Initialize_workspaceName` | `workspaceName` | String | *(empty)* |
| `Initialize_name` | `name` | String | *(empty)* |
| `Initialize_entraObjectId` | `entraObjectId` | String | *(empty)* |

---

## Step 3 — Ask Fabric for the client ID

**Control → Scope**, renamed `Scope_try`. Steps 3–5 go inside it, **in order, with no branches**.

### `Get_workspace` — Invoke an HTTP request (**Fabric** connection)

| Field | Value |
|---|---|
| Method | `GET` |
| URL of the request | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}` |
| Header `Accept` | `application/json` |

### Three Set variable actions

| Rename to | Name | Value |
|---|---|---|
| `Set_clientId` | `clientId` | `coalesce(body('Get_workspace')?['workspaceIdentity']?['applicationId'], '')` |
| `Set_servicePrincipalId` | `servicePrincipalId` | `coalesce(body('Get_workspace')?['workspaceIdentity']?['servicePrincipalId'], '')` |
| `Set_workspaceName` | `workspaceName` | `coalesce(body('Get_workspace')?['displayName'], '')` |

---

## Step 4 — Ask Entra

### `Get_service_principal` — Invoke an HTTP request (**Graph** connection)

| Field | Value |
|---|---|
| Method | `GET` |
| URL of the request | the expression below, entered as **one** expression (*fx*). Do not type any part of it as plain text |
| Header `Accept` | `application/json` |

```
concat('https://graph.microsoft.com/v1.0/servicePrincipals?$filter=appId eq ''', if(empty(variables('clientId')), '00000000-0000-0000-0000-000000000000', variables('clientId')), '''&$select=id,appId,displayName')
```

The URL it produces must read exactly like this, with no `=` after `eq`:

```
https://graph.microsoft.com/v1.0/servicePrincipals?$filter=appId eq '<guid>'&$select=id,appId,displayName
```

> **Build the whole URL in one expression.** When plain text and an expression are mixed in the URL field, the designer can rewrite the text around the token. One build produced `appId eq = '<guid>'`, which Graph rejects with **`400 BadRequest`**. A single `concat()` leaves the designer nothing to edit. Inside an expression, `''` is an escaped single quote. Use plain spaces, not `%20`, because the connector encodes the URL itself. If you still get a `400`, open the failed run, expand `Get_service_principal`, and compare the URL under **Raw inputs** with the body's `error.message`. The message names the part Graph could not parse.

**Pick the Graph connection on this action.** The designer offers the most recently used connection, which is the Fabric one. A Graph URL sent through the Fabric connection fails with an audience error that does not mention the connection.

> **Look up by `appId`, never by name.** Entra allows any number of app registrations with the same name, and Fabric creates exactly that situation when a workspace is deleted and recreated with the same name. Filtering on `displayName` would return several identities, and `first()` would pick one of them at random.

> **`$filter`, not the alternate-key form.** `servicePrincipals(appId='…')` reads more cleanly, but it answers **`404`** when nothing matches. That fails the action and sends a legitimate "not in Entra" result into the Catch as an error. `$filter` answers `200` with an empty `value` array, which Step 5 reads as data.

> **The zero GUID is a sentinel. It is not a real lookup.** When the workspace has no identity, `clientId` is empty, and `appId eq ''` is not something to rely on. The zero GUID is well-formed and matches nothing. This is the same technique the capacity-policies flows use for Dataverse filters ([PLATFORM-FINDINGS](../capacity-policies/docs/PLATFORM-FINDINGS.md) §4).

### Two Set variable actions

| Rename to | Name | Value |
|---|---|---|
| `Set_name` | `name` | `coalesce(first(body('Get_service_principal')?['value'])?['displayName'], '')` |
| `Set_entraObjectId` | `entraObjectId` | `coalesce(first(body('Get_service_principal')?['value'])?['id'], '')` |

`first([])` returns null and does not throw ([PLATFORM-FINDINGS](../capacity-policies/docs/PLATFORM-FINDINGS.md) §2), so the `coalesce` is all the guarding these actions need.

---

## Step 5 — Decide

Two **Set variable** actions. Neither one references its own variable, so neither needs a Compose ([PLATFORM-FINDINGS](../capacity-policies/docs/PLATFORM-FINDINGS.md) §3).

### `Set_outcome` → `outcome`

```
if(empty(variables('clientId')), 'NotProvisioned', if(empty(variables('entraObjectId')), 'NotFoundInEntra', if(equals(toLower(variables('entraObjectId')), toLower(variables('servicePrincipalId'))), 'Verified', 'Mismatch')))
```

### `Set_message` → `message`

```
if(empty(variables('clientId')), 'Workspace has no identity in Fabric.', if(empty(variables('entraObjectId')), concat('Fabric reports client ID ', variables('clientId'), ' but Entra has no service principal with that appId.'), if(equals(toLower(variables('entraObjectId')), toLower(variables('servicePrincipalId'))), concat('Entra name: ', variables('name')), concat('Entra object ID ', variables('entraObjectId'), ' does not match Fabric servicePrincipalId ', variables('servicePrincipalId'), '.'))))
```

| `outcome` | Means | Typical cause |
|---|---|---|
| `Verified` | Fabric's client ID resolves in Entra to the same service principal object Fabric reports | Normal |
| `NotProvisioned` | Fabric reports no identity. Graph returned nothing, which is expected for the sentinel | No identity yet, or it was deprovisioned |
| `NotFoundInEntra` | Fabric has a client ID, but Entra has no service principal with it | Usually replication lag in the seconds after provisioning, so rerun it. If it persists, someone deleted the enterprise application in Entra, and Fabric's identity is broken |
| `Mismatch` | Both sides have the identity, but they disagree on its object ID | Should not happen. Treat it as an incident and do not repair it automatically |

**None of these fail the run.** They are findings, not errors, and the caller decides what to do about each one. The run fails only when a call fails, through the Catch.

---

## Catch

`Scope_catch` exactly as specified in [README.md](README.md) → *Try / Catch*. `Respond_caught` returns the fields in Step 6 with `outcome` = `Failed`. The `clientid` field is **filled** when Fabric answered and Graph did not. That is the `403` case in §0, and the field tells the caller the failure was on the Entra side.

---

## Step 6 — Respond

`Respond_result` and `Condition_outcome_failed`, wired as in [README.md](README.md) → *The final `Respond`*. All the outputs are **Text**:

| Output | Value | Notes |
|---|---|---|
| `outcome` | `variables('outcome')` | |
| `message` | `variables('message')` | |
| `workspaceid` | `triggerBody()['text']` | |
| `clientid` | `variables('clientId')` | **The client ID** (`appId`), as Fabric reports it |
| `name` | `variables('name')` | **The Entra name** (`displayName`) of that service principal. It is empty unless `outcome` is `Verified` or `Mismatch` |
| `serviceprincipalid` | `variables('servicePrincipalId')` | The object ID, as Fabric reports it |
| `workspacename` | `variables('workspaceName')` | The workspace's current display name |
| `namematchesworkspace` | `if(empty(variables('name')), '', if(equals(variables('name'), variables('workspaceName')), 'Yes', 'No'))` | `Yes`/`No` as **text**, and empty when there is no name to compare |

> **`namematchesworkspace` = `No` is information, not a failure.** Fabric renames the identity when the workspace is renamed, but Entra may lag for a short while after a rename. A persistent `No` means the identity was renamed in Entra by hand. Report it and leave it alone. These flows never write to Entra.

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | Workspace with an identity | `Verified`. `clientid` and `name` match **Workspace settings → Workspace identity** in Fabric, and match **Entra → Enterprise applications** searched by that application ID. `namematchesworkspace` = `Yes` |
| 2 | Workspace without an identity | `NotProvisioned`. `clientid` and `name` are empty, and `Get_service_principal` ran with the zero GUID and returned an empty `value` |
| 3 | Rename the workspace in Fabric, wait a minute, run it again | `Verified`, `name` = the new workspace name, and the same `clientid` as before |
| 4 | Random GUID as `workspaceId` | `Failed`. The message names **`Get_workspace`** and carries Fabric's `404` text, and the run is red |
| 5 | **Run first, on any workspace with an identity** | `Get_service_principal` answers `200`. On `403`, stop and take §0. On `400`, check the URL encoding ([Step 4](#step-4--ask-entra)) |
| 6 | Run it immediately after [ProvisionWorkspaceIdentity](ProvisionWorkspaceIdentity.md) returns `Created` | `Verified`, or `NotFoundInEntra` followed by `Verified` on a rerun a few seconds later. Note which one you see. It tells the provisioning solution whether it needs a delay before relying on the identity |
| 7 | Inspect the `Get_service_principal` run inputs | The Graph connection is used, and the host is `graph.microsoft.com` |
