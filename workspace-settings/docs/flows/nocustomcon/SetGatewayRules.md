# Flow — `SetGatewayRules`

Build instructions for the write that replaces a workspace's outbound **gateway** communication policy — the gateways block on the canvas app's Outbound tab. The matching read is `GetGatewayRules`. One of the eight pre-existing networking flows, not part of the Git-integration build order.

Verified against `app/Workflows/SetGatewayRules-F82666CB-4D8A-F111-AB0F-7C1E528D41FB.json` on 2026-08-17.

Related: [../../FLOWS.md](../../FLOWS.md) (Networking flows table), [../../PREREQUISITES.md](../../PREREQUISITES.md) (A1), [../../OPEN-ISSUES.md](../../OPEN-ISSUES.md) §1.6, §10.3, [../../APP-OUTBOUND-TAB.md](../../APP-OUTBOUND-TAB.md) (how the app calls it), [GetGatewayRules.md](GetGatewayRules.md) (the matching read), [../ListGateways.md](../ListGateways.md) (the delegated flow that names the gateways), [SetGitPolicy.md](SetGitPolicy.md) (the same shape on the Git endpoint).

---

## 0. Before you start

- Create the flow **inside the solution**, so it binds to connection references rather than raw connections.
- **Needs the *HTTP with Microsoft Entra ID (preauthorized)* connection**, signed in as the `workspace provisioning` service account. Create it once with **Base Resource URL** and **Microsoft Entra ID Resource URI** both set to `https://api.fabric.microsoft.com`. It appears in `connectionReferences` on export.
- **There is no token flow and no secret.** The connector attaches the bearer token itself, so there is no `GetFabricToken` child call, no `accessToken` variable and **no `Authorization` header**. Never add one — the connector supplies it, and a hand-written header is either ignored or breaks the call.
- This is a **write**, and the `workspace provisioning` account needs a role on the target workspace to make it. A `403` means the broker lost that role; a `401` means the *HTTP with Microsoft Entra ID (preauthorized)* connection has lapsed — and it then fails on every workspace at once, not just this one.

Actions are listed in execution order. Build them in that order — inserting an action later re-parents its successor and silently creates a parallel branch.

---

## 1. Trigger — Power Apps (V2)

| Field | Value |
|---|---|
| Type | `Request` |
| Kind | `PowerAppV2` |
| Action name | `manual` |

Two text inputs, both `x-ms-content-hint: TEXT`, both with the designer default description `Please enter your input`, and **both required**:

| # | Input title | Schema key | Type | Required | Raw reference |
|---|---|---|---|---|---|
| 1 | `workspaceId` | `text` | string | Yes | `@triggerBody()['text']` |
| 2 | `RulesJson` | `text_1` | string | Yes | `@triggerBody()['text_1']` |

The titles are display only; the schema keys `text` and `text_1` are what the definition reads, and they bind **positionally**. Getting them the wrong way round sends a workspace ID as the policy document and a policy document as the workspace ID — the URI is then nonsense and nothing indicates a swap.

Both are required and must stay required. An optional PowerApp V2 input is **dropped from the payload entirely** when blank — the property is absent rather than empty — and both references here use the unsafe `triggerBody()['…']` form, which then throws `InvalidTemplate: property 'text_1' doesn't exist`. That is why neither reference needs a `?[...]` guard or a `coalesce`.

`RulesJson` is the **whole policy document**, serialized app-side. Round-trip it from `GetGatewayRules` rather than composing it by hand.

> The flow takes `workspaceId` at face value. There is no ownership check, so it will overwrite the gateway policy of any workspace the broker administers for any caller who can run it. Deferred by decision — OPEN-ISSUES §10.3.

---

## 2. `HTTP_2` — Invoke an HTTP request

First action; `runAfter` is empty.

| Field | Value |
|---|---|
| Method | `PUT` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}/networking/communicationPolicy/outbound/gateways` |
| Header `Content-Type` | `application/json` |
| `retryPolicy` | *(absent — default exponential, 4 retries)* |
| Authentication | **None to configure.** The connector attaches the bearer token |

Body — the trigger input passed straight through, as a bare expression, **not** wrapped in `@{ }` and not rebuilt:

```
@triggerBody()['text_1']
```

The bare `@expr` form matters. `@{triggerBody()['text_1']}` would interpolate the document into a string and Fabric would receive a quoted blob instead of an object. Nothing here validates the payload — whatever the app sends is what Fabric gets.

`PUT`, not `PATCH`: the whole policy document is replaced. The same URI as `GetGatewayRules`, and there is **no `ETag`** on either side, so a concurrent edit is last-writer-wins. Read immediately before writing; the app does this from the same button.

**Headers are not copied when you duplicate an action.** A missing `Authorization` comes back as `401` with the same generic `RequestFailed` body Fabric uses for semantic rejections — read the status code first.

The action keeps its designer-generated name `HTTP_2` from before the FN.1 rewrite, when `HTTP` was the token call. Renaming it now would mean rewiring both Respond actions; it is left alone deliberately.

---

## 3. `RespondSuccess` — Response

Runs after `HTTP_2` on **Succeeded**. Parallel sibling of §6.

| Output name (as exported) | Title | Type | Value (verbatim from the export) |
|---|---|---|---|
| `status` | `Status` | string | `"\"OK\""` |
| `errormessage` | `ErrorMessage` | string | `"\"\""` |

Both values are **literals**, not derived. Nothing is read from `HTTP_2`.

**The quotes are part of the string.** The exported JSON is `"status": "\"OK\""`, so the app receives the four characters `"OK"` — including the double quotes — not `OK`. `errormessage` is the two characters `""`, not an empty string. Any Power Fx comparison must account for that, or match on which branch answered rather than on the value.

---

## 4. `RespondError` — Response

Runs after `HTTP_2` on **Failed**. Parallel sibling of §5.

| Output name (as exported) | Title | Type | Value (verbatim from the export) |
|---|---|---|---|
| `status` | `Status` | string | `"\"Error\""` |
| `errormessage` | `ErrorMessage` | string | `@{coalesce(body('HTTP_2')?['message'], body('HTTP_2')?['errorCode'], string(body('HTTP_2')))}` |

`status` is again a quoted literal — the app receives `"Error"` with the quotes.

`errormessage` walks the three shapes a Fabric rejection can take, in order: a human-readable `message`, an `errorCode` such as `InsufficientPrivileges`, and finally the raw body stringified. The third argument is the catch-all that makes an unrecognised payload readable rather than blank. All three arguments are evaluated eagerly — the `?[...]` accessors are what keep that safe on a body that has neither key.

This branch is what makes the flow different from the other seven networking flows: it uses two Respond actions on **Succeeded** / **Failed** rather than one on Succeeded only, so a rejected `PUT` reaches the app as a readable message instead of a dead run. `SetGitPolicy`, on the identical shape of endpoint, has no error branch.

Because the two branches are mutually exclusive, exactly one Respond ever fires.

---

## Response contract

Both Respond actions declare **identical** output names and types — they must, or the app sees a different signature depending on which branch ran.

| Name | Type |
|---|---|
| `status` | string |
| `errormessage` | string |

Keep every Respond field typed **string**. The designer wraps a single expression in `@{ }`, which stringifies it, so a field declared boolean or number returns `"true"` / `"7"` and fails schema validation — and one bad field makes every output of the flow unreadable in the app, not just the bad one. Both fields here are correctly string.

Output names come back **lowercased** in Power Fx — bind to `status` and `errormessage`, not `Status` and `ErrorMessage`.

---

## After building

- Add the flow to the canvas app (left rail → Power Automate → **+ Add flow**). Watch for a suffixed duplicate such as `SetGatewayRules_1` from adding it twice.
- If you change the trigger inputs later, **remove and re-add the flow in the app** — Power Apps caches the signature at bind time. With two positional inputs this matters more here than on the single-input flows.
- Renaming the flow does not change the name Power Fx binds to. Trust formula-bar autocomplete over the portal display name.
- Pass the inputs **positionally**, in trigger order: `SetGatewayRules.Run(workspaceId, rulesJson)`. Do not use a trailing options record.
- The flow answers a PowerApp, so it must respond within **120 seconds**. One child call and one PUT; the budget is not at risk.
- The app calls this from `BtnSaveGateways.OnSelect`, alongside `GetGatewayRules`. That control is hidden when OAP is off, which is what keeps the write path from firing on a workspace where the policy does not apply — see `APP-OUTBOUND-TAB.md`.