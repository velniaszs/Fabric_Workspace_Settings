# Flow — `GetWorkspaceGitState`

Build instructions for the read-only flow the wizard calls first: it reports whether a Fabric workspace is connected to Git, and to what. Called by the canvas app; changes nothing.

Verified against `Workflows/GetWorkspaceGitState-39F29F3D-CF8F-F111-8076-7CED8D76CBFD.json` on 2026-08-17.

Related: [../FLOWS.md](../FLOWS.md) §4 (design rationale), [../PREREQUISITES.md](../PREREQUISITES.md) (A3, B1, E3, E4), [../OPEN-ISSUES.md](../OPEN-ISSUES.md) §3.1.

---

## 0. Before you start

- Create the flow **inside the solution**, so it binds to connection references rather than raw connections.
- **No connector connection is needed.** The flow uses only built-in actions: `Run a Child Flow`, `Initialize variable`, `HTTP`, `Condition`, `Respond to a Power App or flow`.
- The child flow **`GetFabricToken`** must already exist. It is referenced by GUID: `50895fca-088f-f111-8076-7ced8d76bf1b` → `Workflows/GetFabricToken-50895FCA-088F-F111-8076-7CED8D76BF1B.json`.
- Authentication is **service principal**, not delegated. The token comes from `GetFabricToken`, which runs the client-credentials grant as the broker SPN and returns `access_token`. Every Fabric call in this flow carries that bearer token.
- Environment variables are **not referenced directly by this flow**. They are consumed by the child flow:

  | Variable | Default in the solution | Used by |
  |---|---|---|
  | `ab_TenantId` | `9e929790-272d-4977-a2ab-301443c11ece` | `GetFabricToken` (token endpoint) |
  | `ab_BrokerClientId` | `a385fde9-1d6a-4e7f-8336-dc7feba5a4bc` | `GetFabricToken` (client id) |
  | `ab_BrokerObjectId` | `6f70a764-908f-435b-a930-ffcb375577f3` | *not used by this flow* |

  The broker **client secret** is not an environment variable — it is an `Initialize variable` inside `GetFabricToken`, scrubbed on export and re-entered per environment (PREREQUISITES E4). Never commit it.
- The broker SPN must be a member of the Fabric API security group and the tenant setting must be on, or every call here returns a bare `401`.

Actions are listed in execution order. Build them in that order — inserting an action later re-parents its successor and silently creates a parallel branch.

---

## 1. Trigger — Power Apps (V2)

| Field | Value |
|---|---|
| Type | `Request` |
| Kind | `PowerAppV2` |
| Action name | `manual` |

One input:

| Input title | Schema key | Type | Content hint | Required |
|---|---|---|---|---|
| `workspaceId` | `text` | string | `TEXT` | Yes |

Referenced downstream as `@triggerBody()['text']` — the schema key stays `text` regardless of the title. The description is the designer default, `Please enter your input`.

The input is already **required** in the export, and must stay that way. An optional PowerApp V2 input is dropped from the payload entirely when blank — the property is absent, `triggerBody()['text']` throws `InvalidTemplate`, and nothing in the run history shows the value was never sent.

---

## 2. `Initialize_workspaceid` — Initialize variable

| Field | Value |
|---|---|
| Name | `workspaceId` |
| Type | String |
| Value | `@triggerBody()['text']` |

The only flow of the four that copies the trigger key into a named variable up front. Everything downstream reads `variables('workspaceId')`.

---

## 3. `Run_a_Child_Flow` — Workflow

Runs after `Initialize_workspaceid` on **Succeeded**.

| Field | Value |
|---|---|
| Type | `Workflow` |
| `host.workflowReferenceName` | `50895fca-088f-f111-8076-7ced8d76bf1b` |
| Inputs | none |

That GUID is `GetFabricToken`. It takes no parameters and returns `access_token`.

---

## 4. `Initialize_access_token` — Initialize variable

Runs after `Run_a_Child_Flow` on **Succeeded**.

| Field | Value |
|---|---|
| Name | `accessToken` |
| Type | String |
| Value | `@body('Run_a_Child_Flow')?['access_token']` |

Holds a bearer token with tenant-wide Fabric rights. It is deliberately never a trigger input and never returned to the app.

---

## 5. Response variables

Four more **Initialize variable** actions, each chained on **Succeeded** from the previous one, in this exact order:

| Order | Name | Type | Initial value |
|---|---|---|---|
| 1 | `gitConnectionState` | String | `Unknown` |
| 2 | `providerJson` | String | `{}` |
| 3 | `credentialsJson` | String | `{}` |
| 4 | `errorMessage` | String | *(no value — action name `Initialize_errorMessage`, `inputs.variables[0]` has no `value` key)* |

Action names in the export: `Initialize_gitConnectionState`, `Initialize_providerJson`, `Initialize_credentialsJson`, `Initialize_errorMessage`.

Seeding the three JSON-bearing variables as **strings** — not objects — is what lets the Respond stay all-string. The nested Fabric payloads are stringified before they leave the flow.

---

## 6. `Get_git_connection` — HTTP

Runs after `Initialize_errorMessage` on **Succeeded**.

| Field | Value |
|---|---|
| Method | `GET` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{variables('workspaceId')}/git/connection` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Header `Accept` | `application/json` |
| Body | none |
| Authentication block | none — no `authentication` property; the bearer token is supplied by hand in the header |

There is **no** `Retry Policy` override and **no** `operationOptions` on this action.

A disconnected workspace returns **200 with `gitConnectionState: NotConnected`**, not a 404. The three documented values are `NotConnected`, `Connected` and `ConnectedAndInitialized`.

---

## 7. `Condition` — If

Runs after `Get_git_connection` on **Succeeded or Failed**. The `Failed` branch is what keeps a Fabric error from ending the run with no response.

Expression:

```
@outputs('Get_git_connection')['statusCode']
```

compared with **is equal to** the number `200`. In the raw definition:

```json
"expression": {
  "equals": [
    "@outputs('Get_git_connection')['statusCode']",
    200
  ]
}
```

The right-hand side is the JSON number `200`, not the string `"200"`.

> `outputs('Get_git_connection')['statusCode']` is unguarded — no `?[...]`, no `coalesce`. If the HTTP action fails before it produces outputs at all, the `If` itself fails, `Respond_to_a_Power_App_or_flow` is skipped, and the app sees a hard error rather than a message. An HTTP status of 4xx/5xx is fine — the action reports `Failed` but still carries `statusCode`.

### 7.1 True branch — the call returned 200

Three **Set variable** actions, chained on **Succeeded**:

**`Set_variable_gitConnectionState`**

| Field | Value |
|---|---|
| Name | `gitConnectionState` |
| Value | `@{coalesce(body('Get_git_connection')?['gitConnectionState'], 'Unknown')}` |

**`Set_variable_providerJson`**

| Field | Value |
|---|---|
| Name | `providerJson` |
| Value | `@{string(coalesce(body('Get_git_connection')?['gitProviderDetails'], json('{}')))}` |

**`Set_variable_credentialsJson`**

| Field | Value |
|---|---|
| Name | `credentialsJson` |
| Value | `@{string(coalesce(body('Get_git_connection')?['gitCredentials'], json('{}')))}` |

`coalesce(..., json('{}'))` guards the `NotConnected` case, where neither nested object is present. Logic Apps evaluates function arguments eagerly, so an unguarded `string(body(...)?['gitProviderDetails'])` throws rather than returning empty.

### 7.2 False branch — anything other than 200

Two **Set variable** actions, chained on **Succeeded**:

**`Set_variable_gitConnectionState_err`**

| Field | Value |
|---|---|
| Name | `gitConnectionState` |
| Value | `Error` |

**`Set_variable_errorMessage`**

| Field | Value |
|---|---|
| Name | `errorMessage` |

```
@{concat('HTTP ', string(outputs('Get_git_connection')['statusCode']), ': ', string(coalesce(body('Get_git_connection')?['message'], body('Get_git_connection')?['errorCode'], 'Unknown error')))}
```

`Error` is a value this flow invents; it is not one Fabric returns.

---

## 8. Response contract

`Respond_to_a_Power_App_or_flow` — type `Response`, kind `PowerApp`, `statusCode` 200. Runs after `Condition` on **Succeeded** only.

| Output name (as exported) | Title | Declared type | Value |
|---|---|---|---|
| `gitconnectionstate` | `gitConnectionState` | string | `@variables('gitConnectionState')` |
| `isconnected` | `isConnected` | **boolean** | `@{not(or(equals(variables('gitConnectionState'),'NotConnected'), equals(variables('gitConnectionState'),'Error')))}` |
| `gitproviderdetails` | `gitProviderDetails` | string | `@variables('providerJson')` |
| `gitcredentials` | `gitCredentials` | string | `@variables('credentialsJson')` |
| `errormessage` | `errorMessage` | string | `@variables('errorMessage')` |

Keep every Respond field typed **string**. The designer wraps a single expression in `@{ }`, which stringifies it, so a field declared boolean or number returns `"true"` / `"7"` and fails schema validation — and one bad field makes every output of the flow unreadable in the app, not just the bad one.

`isconnected` above is exactly that defect, still present in the export: declared `boolean`, emitted as `@{...}`. See §9.

Output names come back **lowercased** in Power Fx. The `title` is cosmetic; bind to `gitconnectionstate`, `gitproviderdetails`, `gitcredentials`, `errormessage`.

`gitproviderdetails` and `gitcredentials` arrive as JSON **text**. Parse them in Power Fx with `ParseJSON`; do not expect a record.

---

## 9. After building

- Add the flow to the canvas app (left rail → Power Automate → **+ Add flow**). Watch for a suffixed duplicate such as `GetWorkspaceGitState_1` from adding it twice.
- If you change the trigger input later, **remove and re-add the flow in the app** — Power Apps caches the signature at bind time.
- Renaming the flow does not change the name Power Fx binds to. Trust formula-bar autocomplete over the portal display name.
- Pass the trigger input positionally: `GetWorkspaceGitState.Run(workspaceId)`.
- The flow answers a PowerApp, so it must respond within **120 seconds**. One token call and one GET; there is no loop and no retry override, so the budget is not at risk.

---

## 10. Known drift from the exported definition

- **`isConnected` is still in the export, and still typed `boolean`.** `FLOWS.md` §4 states: "**`isConnected` removed 2026-08-12 — non-string Respond fields are a trap.** … Both affected fields were derived values, so both were deleted rather than retyped: `isConnected` here and `count` in flow 3." The exported `Respond_to_a_Power_App_or_flow` still declares

  ```json
  "isconnected": {
    "title": "isConnected",
    "x-ms-dynamically-added": true,
    "type": "boolean"
  }
  ```

  with the body value `"@{not(or(equals(variables('gitConnectionState'),'NotConnected'), equals(variables('gitConnectionState'),'Error')))}"`. That is a boolean-typed field carrying a `@{ }` string, which is the exact condition `FLOWS.md` says was removed. Until it is deleted, Power Apps fails the whole response with *JSON parsing error, expected 'boolean' but got 'string'* and **no** field of this flow is readable.
- `FLOWS.md` §4 lists the return set as "`gitConnectionState`, `gitProviderDetails`, `gitCredentials`, `errorMessage`" — four fields. The export returns **five**, the extra one being `isconnected`. Same root cause as above.
