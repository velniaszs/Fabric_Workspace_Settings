# Flow — `GetMyEmail`

Build instructions for the delegated read that returns the signed-in user's mail address, UPN and display name from Office 365. It is the smallest flow in the solution and **currently unused** — retained from a dropped experiment on the Git tab.

Verified against `Workflows/GetMyEmail-C32A020E-8894-F111-8075-7CED8D76CBFD.json` on 2026-08-17.

Related: [../../FLOWS.md](../../FLOWS.md) (flow inventory — this flow is not listed there), [../../PREREQUISITES.md](../../PREREQUISITES.md) (E2 connection references, E5 run-only users), [../../OPEN-ISSUES.md](../../OPEN-ISSUES.md) §1.7, §10.3 (the authorization boundary this flow does **not** implement), [../../APP-GIT-TAB.md](../../APP-GIT-TAB.md) (the decision to drop it), [../ListMyConnections.md](../ListMyConnections.md) and [../AddConnectionRoleAssignment.md](../AddConnectionRoleAssignment.md) (the other delegated flows).

> **Not used.** `APP-GIT-TAB.md` records the decision of 2026-08-11: the `GitContent` stub controls `git text`, `getEmailButton` and `Label1` are left over from a dropped `GetMyEmail` experiment and are to be deleted. Nothing in the app calls this flow. Do not build it as part of the Git-integration build order. This document exists so the export is accounted for and so the flow can be rebuilt if the identity is ever needed.

---

## 0. Before you start

- Create the flow **inside the solution**, so it binds to a connection reference rather than a raw connection.
- **One connector connection is needed**, and it is not the custom connector. This flow is the only one in the solution that uses **Office 365 Users**:

  | | |
  |---|---|
  | Connector | `shared_office365users` |
  | API id | `/providers/Microsoft.PowerApps/apis/shared_office365users` |
  | Connection reference logical name | `ab_sharedoffice365users_a9929` |
  | `runtimeSource` | `invoker` |

  That reference is present in `customizations.xml`. It arrives unbound on import and must be bound per environment — PREREQUISITES E2.

- The connection is **delegated**, not service principal. `runtimeSource: invoker` means the action executes as the signed-in caller, which is the entire point: the flow returns *your* profile, not the broker's. Sharing must be *Provided by run-only user* (PREREQUISITES E5).
- **No environment variables are used.** `ab_TenantId`, `ab_BrokerClientId` and `ab_BrokerObjectId` are all irrelevant here — there is no token acquisition, no `GetFabricToken` child call and no Fabric endpoint. Defaults, for reference only: `9e929790-272d-4977-a2ab-301443c11ece`, `a385fde9-1d6a-4e7f-8336-dc7feba5a4bc`, `6f70a764-908f-435b-a930-ffcb375577f3`.
- **This flow is not an authorization check.** It reports who the caller claims to be to the *app*, which is not a boundary — the app is the thing being trusted. The real check is the Dataverse lookup described in ARCHITECTURE §3 and tracked in OPEN-ISSUES §1.7 / §10.3, and it is not implemented anywhere. Do not build ownership logic on this flow's output.

Actions are listed in execution order. Build them in that order — inserting an action later re-parents its successor and silently creates a parallel branch.

---

## 1. Trigger — Power Apps (V2)

| Field | Value |
|---|---|
| Type | `Request` |
| Kind | `PowerAppV2` |
| Action name | `manual` |

**No inputs.** The trigger schema is empty:

```json
{
  "type": "object",
  "properties": {},
  "required": []
}
```

Nothing is read from `triggerBody()`. The caller's identity comes from the connection, not from a parameter — which is why there is nothing to pass and nothing to get in the wrong order.

The optional-input hazard does not apply here, there being no inputs. If one is ever added, make it **required**: an optional PowerApp V2 input is dropped from the payload entirely when blank, the property is absent rather than empty, and it is invisible in run history.

---

## 2. `Get_my_profile_(V2)` — OpenApiConnection

First action; `runAfter` is empty.

| Field | Value |
|---|---|
| Type | `OpenApiConnection` |
| `host.connectionName` | `shared_office365users` |
| `host.operationId` | `MyProfile_V2` |
| `host.apiId` | `/providers/Microsoft.PowerApps/apis/shared_office365users` |
| `parameters` | `{}` — none |
| `authentication` | `@parameters('$authentication')` |

`MyProfile_V2` takes no parameters; the profile it returns is determined entirely by the identity behind the connection. The `authentication` value is the standard `$authentication` secure-object parameter the designer emits on every connector action — it carries no secret of its own and must never be replaced with a literal.

The action name contains parentheses, which is unusual and worth keeping intact: the Respond references it as `outputs('Get_my_profile_(V2)')`. Renaming the action breaks all three output expressions at once.

---

## Response contract

`Respond_to_a_Power_App_or_flow` — type `Response`, kind `PowerApp`, `statusCode` 200. Runs after `Get_my_profile_(V2)` on **Succeeded**.

| Output name (as exported) | Title | Type | Value (verbatim) |
|---|---|---|---|
| `email` | `email` | string | `@outputs('Get_my_profile_(V2)')?['body/mail']` |
| `upn` | `upn` | string | `@outputs('Get_my_profile_(V2)')?['body/userPrincipalName']` |
| `displayname` | `displayName` | string | `@outputs('Get_my_profile_(V2)')?['body/displayName']` |

All three use the bare `@expr` form and the `outputs(...)?['body/…']` accessor — a single `?[...]` hop against a slash-joined key, which is how connector outputs are addressed. A user with no `mail` attribute set yields an empty value rather than a run failure; `userPrincipalName` is the field to trust when `email` comes back blank.

Keep every Respond field typed **string**. The designer wraps a single expression in `@{ }`, which stringifies it, so a field declared boolean or number returns `"true"` / `"7"` and fails schema validation — and one bad field makes every output of the flow unreadable in the app, not just the bad one. All three fields here are correctly string.

Output names come back **lowercased** in Power Fx — bind to `displayname`, not `displayName`. Note that this is the only flow in the solution where an output *title* differs in case from its schema key (`displayName` vs `displayname`); Power Fx sees the key, lowercased, either way.

`Respond` runs on **Succeeded** only. A connector failure — most likely an unbound or revoked connection reference — fails the run with no response, and the app sees a hard error rather than a readable message.

---

## After building

- Add the flow to the canvas app (left rail → Power Automate → **+ Add flow**). Watch for a suffixed duplicate such as `GetMyEmail_1` from adding it twice. *Only do this if the flow is actually being reintroduced* — the current decision is to delete the stub controls instead.
- If you change the trigger inputs later, **remove and re-add the flow in the app** — Power Apps caches the signature at bind time. That includes going from zero inputs to one.
- Renaming the flow does not change the name Power Fx binds to. Trust formula-bar autocomplete over the portal display name.
- There are no inputs to pass: `GetMyEmail.Run()`.
- The flow answers a PowerApp, so it must respond within **120 seconds**. One connector call; the budget is not at risk.
