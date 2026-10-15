# Flow — `GetGatewayRules`

Build instructions for the read that returns a workspace's outbound **gateway** communication policy — which gateways the workspace is permitted to reach. The canvas app's Outbound tab calls it to populate the gateways block. One of the eight pre-existing networking flows, not part of the Git-integration build order.

Verified against `app/Workflows/GetGatewayRules-5EC91B70-4C8A-F111-AB0F-7C1E528D41FB.json` on 2026-08-17.

Related: [../../FLOWS.md](../../FLOWS.md) (Networking flows table), [../../PREREQUISITES.md](../../PREREQUISITES.md) (A1), [../../OPEN-ISSUES.md](../../OPEN-ISSUES.md) §1.6, §10.3, [../../APP-OUTBOUND-TAB.md](../../APP-OUTBOUND-TAB.md) (how the app calls it), [SetGatewayRules.md](SetGatewayRules.md) (the matching write), [../ListGateways.md](../ListGateways.md) (the delegated flow that names the gateways).

---

## 0. Before you start

- Create the flow **inside the solution**, so it binds to connection references rather than raw connections.
- **Needs the *HTTP with Microsoft Entra ID (preauthorized)* connection**, signed in as the `workspace provisioning` service account. Create it once with **Base Resource URL** and **Microsoft Entra ID Resource URI** both set to `https://api.fabric.microsoft.com`. It appears in `connectionReferences` on export.
- **There is no token flow and no secret.** The connector attaches the bearer token itself, so there is no `GetFabricToken` child call, no `accessToken` variable and **no `Authorization` header**. Never add one — the connector supplies it, and a hand-written header is either ignored or breaks the call.
- A `403` here means the `workspace provisioning` account lacks a role on the workspace; a `401` means the *HTTP with Microsoft Entra ID (preauthorized)* connection has lapsed — and it then fails on every workspace at once, not just this one. Fabric's error body is generic for both — read the status code, not the message.

Actions are listed in execution order. Build them in that order — inserting an action later re-parents its successor and silently creates a parallel branch.

---

## 1. Trigger — Power Apps (V2)

| Field | Value |
|---|---|
| Type | `Request` |
| Kind | `PowerAppV2` |
| Action name | `manual` |

One text input, `x-ms-content-hint: TEXT`, with the designer default description `Please enter your input`, **required**:

| # | Input title | Schema key | Type | Required | Raw reference |
|---|---|---|---|---|---|
| 1 | `workspaceId` | `text` | string | Yes | `@triggerBody()['text']` |

The underlying key is `text`; `workspaceId` is only the display title. Keep it required — an optional PowerApp V2 input is **dropped from the payload entirely** when blank, the property is absent rather than empty, and the unsafe `triggerBody()['text']` form used here would then throw `InvalidTemplate: property 'text' doesn't exist`.

> The flow takes `workspaceId` at face value. There is no ownership check, so it will read the gateway policy of any workspace the broker administers for any caller who can run it. Same posture as the Git flows — OPEN-ISSUES §10.3.

---

## 2. `HTTP_2` — Invoke an HTTP request

First action; `runAfter` is empty.

| Field | Value |
|---|---|
| Method | `GET` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}/networking/communicationPolicy/outbound/gateways` |
| Header `Accept` | `application/json` |
| Body | none |
| `retryPolicy` | *(absent — default exponential, 4 retries)* |
| Authentication | **None to configure.** The connector attaches the bearer token |

The connector supplies the bearer token. Nothing in this action references a credential.

**Headers are not copied when you duplicate an action.** A missing `Authorization` comes back as `401` with the same generic `RequestFailed` body Fabric uses for semantic rejections — check the header on every new HTTP action before chasing anything else.

The action keeps its designer-generated name `HTTP_2` from before the FN.1 rewrite, when `HTTP` was the token call. Renaming it now would mean rewiring the Respond; it is left alone deliberately.

The whole response body is returned to the app untouched — this flow reads no field of it.

---

## Response contract

`Respond_to_a_Power_App_or_flow` — type `Response`, kind `PowerApp`, `statusCode` 200. Runs after `HTTP_2` on **Succeeded**.

| Output name (as exported) | Title | Type | Value (verbatim) |
|---|---|---|---|
| `rulesjson` | `RulesJson` | string | `@{string(body('HTTP_2'))}` |

Keep every Respond field typed **string**. The designer wraps a single expression in `@{ }`, which stringifies it, so a field declared boolean or number returns `"true"` / `"7"` and fails schema validation — and one bad field makes every output of the flow unreadable in the app, not just the bad one. The single field here is correctly string, and the explicit `string(...)` around the body is what makes it honest.

Output names come back **lowercased** in Power Fx — bind to `rulesjson`, not `RulesJson`. Parse it app-side with `ParseJSON`.

Unlike `GetOutboundRules`, this flow returns **no `ETag`**, so the matching write has no optimistic-concurrency token to echo. A concurrent edit to the gateway policy is last-writer-wins.

`Respond` runs on **Succeeded** only. A rejected `GET` therefore fails the run with no response, and the app sees a hard error rather than a readable message. That is the pre-existing shape of all eight networking flows; the Git-integration flows use **Succeeded or Failed** with a derived `outcome` and a `message` carrying the raw Fabric payload instead.

---

## After building

- Add the flow to the canvas app (left rail → Power Automate → **+ Add flow**). Watch for a suffixed duplicate such as `GetGatewayRules_1` from adding it twice.
- If you change the trigger inputs later, **remove and re-add the flow in the app** — Power Apps caches the signature at bind time.
- Renaming the flow does not change the name Power Fx binds to. Trust formula-bar autocomplete over the portal display name.
- Pass the single input positionally: `GetGatewayRules.Run(workspaceId)`. Do not use a trailing options record.
- The flow answers a PowerApp, so it must respond within **120 seconds**. One child call and one GET; the budget is not at risk.
- The app calls this from `Form Screen.OnVisible` guarded by `If(gblFlowResult.oapenabled, ...)`, and again from `BtnSaveGateways.OnSelect` alongside `SetGatewayRules` — see `APP-OUTBOUND-TAB.md`.