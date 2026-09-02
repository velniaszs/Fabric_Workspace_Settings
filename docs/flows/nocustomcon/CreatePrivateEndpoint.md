# Flow — `CreatePrivateEndpoint`

Build instructions for the write that creates a **managed private endpoint** in a workspace. One of three new networking flows; the matching read is `ListPrivateEndpoints` and the sibling write is `DeletePrivateEndpoint`.

> **Built and tested 2026-09-02 — not yet verified against an export.** Every other file in this folder is *verified against* an exported definition in `Workflows/`. This one was written as a specification and the flow was built from it. Re-export the solution and reconcile this document against the JSON before trusting the action names and `runAfter` details.

Related: [../../APP-PRIVATE-ENDPOINTS.md](../../APP-PRIVATE-ENDPOINTS.md) (design investigation — §2.2, §3.2 and §5.5 in particular), [../../FLOWS.md](../../FLOWS.md), [../../PREREQUISITES.md](../../PREREQUISITES.md) (A1, A3, B1, E4), [../../OPEN-ISSUES.md](../../OPEN-ISSUES.md) §10.3, F5.9, F5.10, [GetFabricToken.md](GetFabricToken.md), [ListPrivateEndpoints.md](ListPrivateEndpoints.md), [DeletePrivateEndpoint.md](DeletePrivateEndpoint.md), [ConnectWorkspaceToGit.md](ConnectWorkspaceToGit.md) (the outcome-variable pattern this deliberately does *not* copy — see Step 6), [DisconnectWorkspaceFromGit.md](DisconnectWorkspaceFromGit.md) (the status-code-derived response pattern it uses instead).

---

## 0. Before you start

- Create the flow **inside the solution**, so it binds to connection references rather than raw connections.
- **No connector connection is needed.** Built-in actions only: `Run a Child Flow`, `Initialize variable`, `HTTP`, `Respond to a Power App or flow`. `connectionReferences` must end up `{}`.
- The child flow **`GetFabricToken`** must already exist: `50895fca-088f-f111-8076-7ced8d76bf1b`.
- Authentication is **service principal** (`sp_fabric_powerapp`). The create API requires **workspace Admin**, which the owners running the app do not have and will not be granted — a delegated call here would `403` for every user. Brokering is not a preference, it is the only design that works. See [../../APP-PRIVATE-ENDPOINTS.md](../../APP-PRIVATE-ENDPOINTS.md) §3.
- Environment variables are **not referenced directly by this flow** — the child flow consumes `ab_TenantId` and `ab_BrokerClientId`. The broker **client secret** lives inside `GetFabricToken`, is scrubbed on export, and must be re-entered per environment (PREREQUISITES E4).
- **No Azure permission is required to run this**, by anyone. The endpoint is provisioned in a Microsoft-managed VNet and what reaches the customer's resource is an inert `Pending` request. The Azure rights sit entirely with the *approver* — [../../APP-PRIVATE-ENDPOINTS.md](../../APP-PRIVATE-ENDPOINTS.md) §3.2.

> ### This flow must not ship without an authorization check
>
> It takes `workspaceId` at face value. Anyone who can reach the trigger URL can create a private endpoint in **any** workspace the broker administers, naming any Azure resource they like, with a justification message that will be read by a stranger in another organisation's Azure portal.
>
> The Git flows deferred the `crbab_Workspaces` ownership check (OPEN-ISSUES §10.3, F5.9) on the argument that the app is limited to the build team. That argument does not survive first contact with 4000 owners here, because the side effect of this flow leaves Fabric entirely. **Land F5.9 before this flow is shared**, and add the audit row (F5.10) at the same time — an outbound connection request with no record of who asked for it is the kind of thing that gets found during an audit rather than before one.

---

## How to enter anything in this document

Four designer mechanics that every step below relies on. If you already know them, skip to Step 1.

**Renaming an action.** Click the action's title bar and type the new name, or ⋯ → **Rename**. **Do it immediately after adding the action, before writing any expression that mentions it.** Expressions reference actions by name, and renaming later does *not* rewrite them — you get `InvalidTemplate: the action 'X' does not exist` at runtime. The action names in this document are not cosmetic; `body('Create')` only resolves if the action is called `Create`.

**Entering an expression.** Click into the field, then pick the **fx / Expression** tab in the popup (older designer: the *Expression* tab of the dynamic-content panel). Paste the expression **without** the leading `@`, then confirm. The designer adds the `@` itself.

**`@{...}` versus bare `@expr`.** You never type either form. The designer decides:

- a field that holds a **string** gets `@{...}` — the expression is interpolated into text
- a field typed **boolean**, **array** or **object** keeps the bare `@expr` form

This matters and it bites. Where a table below says *bare `@expr`*, check it — see the next point.

**Checking what you actually built.** Action ⋯ → **Peek code** shows the raw JSON for that action. This is the only reliable way to confirm an expression landed in the form you intended. Use it on anything this document flags.

---

## Step 1 — Create the flow

1. Go to [make.powerapps.com](https://make.powerapps.com) → **Solutions** → open **WorkspaceSol**.
2. **New** → **Automation** → **Cloud flow** → **Instant**.
3. Name it `CreatePrivateEndpoint`.
4. For the trigger, search **Power Apps** and choose **Power Apps (V2)**.

> **It must be built inside the solution.** A flow created from *My flows* is not solution-aware: it cannot see `GetFabricToken` in the child-flow picker, and it will not travel with the export.

> **Choose Power Apps (V2), not the older *PowerApps* trigger.** Only V2 lets you declare named inputs. The old one takes whatever the app passes, positionally and untyped, and there is no way to add the five inputs this flow needs.

---

## Step 2 — Declare the five trigger inputs

On the trigger card, click **+ Add an input** → **Text**, five times. Type the title into the input's name box, in this order:

| Order | Type this title | Key the designer assigns | Referenced in expressions as |
|---|---|---|---|
| 1 | `workspaceId` | `text` | `triggerBody()['text']` |
| 2 | `name` | `text_1` | `triggerBody()['text_1']` |
| 3 | `targetPrivateLinkResourceId` | `text_2` | `triggerBody()['text_2']` |
| 4 | `targetSubresourceType` | `text_3` | `triggerBody()['text_3']` |
| 5 | `requestMessage` | `text_4` | `triggerBody()?['text_4']` |

**The order you add them in is the contract.** The title is a label; the key is assigned by position and is what the definition actually reads. Add them in a different order and every expression below silently addresses the wrong field — a resource ID arrives where a name is expected, and the resulting `400` names neither. `SetOutboundRules` documents the same hazard with only two inputs; this flow has five.

**Leave every input required.** If your designer shows an ⋯ menu on an input with an *Optional* toggle, do not enable it. An optional PowerApp V2 input is **omitted from the payload entirely** when blank — the property is absent rather than empty — and `triggerBody()['text_1']` then throws `InvalidTemplate` instead of returning `""`.

Note the one deliberate inconsistency: `requestMessage` is read with `?['text_4']` rather than `['text_4']`. It is the one field a user may legitimately leave blank, so it is read defensively even though it is declared required.

---


## Step 3 — Add the child-flow call

1. **+ New step** → search **Run a Child Flow** → choose it (it is a built-in action, under *Workflows* / *Flows* depending on designer version — there is only one result).
2. In the **Child Flow** dropdown, select **GetFabricToken**.
3. Rename the action to `Run_a_Child_Flow` if it is not already called that.

There are no parameters to fill. `GetFabricToken` takes no inputs and returns `access_token`.

**If `GetFabricToken` is not in the dropdown**, one of these is true:

| Cause | Fix |
|---|---|
| This flow was not created inside the solution | Recreate it in **WorkspaceSol**. Child flows are only visible to solution-aware parents |
| `GetFabricToken`'s trigger is not *Manually trigger a flow* | It must be. A flow with a *Power Apps (V2)* trigger **cannot** be called as a child flow — that constraint is why `GetGitOperationStatus` had to stop being one |
| `GetFabricToken` is turned off | Turn it on |

The parent's own trigger is irrelevant to this — a parent may have any trigger. Only the child is constrained.

> Why a child flow at all: it is the only place the broker's client secret lives. Every other flow in the solution calls it rather than repeating the client-credentials block. Do **not** add an inline token `HTTP` action here — that pattern was deliberately removed from all eight networking flows on 2026-08-07 (OPEN-ISSUES §1.6).

---

## Step 4 — Store the token

**+ New step** → search **Initialize variable** → add it. Rename it `Initialize_variable` (the designer's default name, kept to match the other networking flows).

| Field | What to enter |
|---|---|
| Name | `accessToken` |
| Type | `String` |
| Value | expression: `body('Run_a_Child_Flow')?['access_token']` |

Enter the Value through the **fx / Expression** tab, not by typing into the box.

`accessToken` holds a bearer token for the broker. It is deliberately never a trigger input and never returned to the app.

---

## Step 5 — The `Create` call

**+ New step** → search **HTTP** → choose the built-in **HTTP** action. Not *HTTP with Microsoft Entra ID*, not *HTTP Request* — the plain one. **Rename it `Create` immediately**; every expression in Step 6 says `body('Create')` or `outputs('Create')`.

| Field | What to enter |
|---|---|
| Method | `POST` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{triggerBody()['text']}/managedPrivateEndpoints` |
| Headers | two rows — see below |
| Body | the JSON below |

Headers are a key/value grid; add two rows:

| Key | Value |
|---|---|
| `Authorization` | `Bearer @{variables('accessToken')}` — note the space after `Bearer` |
| `Content-Type` | `application/json` |

**Leave the *Authentication* section of the action alone.** The bearer token is supplied by hand in the header. Filling in the action's own authentication block as well produces two competing credentials.

Body:

```json
{
  "name": "@{triggerBody()['text_1']}",
  "targetPrivateLinkResourceId": "@{triggerBody()['text_2']}",
  "targetSubresourceType": "@{triggerBody()['text_3']}",
  "requestMessage": "@{take(coalesce(triggerBody()?['text_4'], ''), 140)}"
}
```

Paste the JSON, then replace each `@{...}` by clicking that spot and inserting the expression through the **fx** tab. Pasting the text verbatim also works, but the designer sometimes escapes it — **Peek code** afterwards and confirm the expressions are live, not quoted strings.

**Retry policy:** action ⋯ → **Settings** → leave **Retry Policy** at *Default*. Do not set it to None.

> **No duplicate check here — Fabric enforces both rules.** Tested 2026-09-02:
>
> | Attempt | Result |
> |---|---|
> | Same **name** | `400` · `DuplicatePrivateEndpointName` |
> | Same **resource ID + sub-resource**, different name | `400` · `DuplicateTargetPrivateLinkResourceId` |
> | Same **resource ID + different sub-resource**, different name | `201` — accepted, and correctly so: this is the storage `blob` + `dfs` case |
>
> The server's uniqueness key is the **pair** (resource ID, sub-resource). Both violations are a `400`, which already lands on the `Failed` path carrying Fabric's own readable text — so the flow needs nothing, not even an `errorCode` mapping. The app's inline check exists only to show the error next to the field before submitting.

### Notes on the body

`take(…, 140)` enforces the API's limit on `requestMessage`. `substring(x, 0, 140)` throws when the string is shorter than 140; `take` does not, which is why it is used here. `name` is capped at 64 characters by the API — validate that in the app rather than truncating silently, because a truncated name is a name the owner did not choose.

> **`targetSubresourceType` is never blank**, so this literal body is always valid. Every row in `crbab_PrivateLinkTarget` carries a non-empty sub-resource, and the one type whose sub-resource is empty — `Microsoft.Network/privateLinkServices` — is deliberately excluded from the picker ([../../APP-PRIVATE-ENDPOINTS.md](../../APP-PRIVATE-ENDPOINTS.md) §5.6). If that ever changes, the body must be built in a `Compose` with an `if()` that drops the property when blank, because `"targetSubresourceType": ""` is not the same as omitting it.

On the retry policy: a `POST` retried after a response was lost in transit will attempt a second create. Whether that produces a **second endpoint** or a rejection depends on whether Fabric enforces uniqueness, which is what test 1 below settles. A flow-side duplicate check would not have helped either way — the retry re-runs the HTTP action, not the actions before it.

---

## Step 6 — Respond to the app

1. Below `Create`, **+ New step** → search **Respond to a Power App or flow** → add it.
2. ⋯ → **Configure run after** → tick **both** *is successful* and *has failed*.
3. Add four outputs with **+ Add an output** → **Text**, in this order:

| Output name to type | Value — all entered through the **fx** tab |
|---|---|
| `Outcome` | `if(less(coalesce(outputs('Create')?['statusCode'], 0), 300), 'Created', 'Failed')` |
| `EndpointId` | `coalesce(body('Create')?['id'], '')` |
| `ProvisioningState` | `coalesce(body('Create')?['provisioningState'], '')` |
| `Message` | `if(less(coalesce(outputs('Create')?['statusCode'], 0), 300), 'Endpoint created. The request is now pending approval by the owner of the target resource.', coalesce(body('Create')?['message'], body('Create')?['errorCode'], string(body('Create'))))` |

**The run-after setting above is the part that is easy to get wrong**, and it is the whole error-handling design. By default a Respond runs on success only, so a rejected `POST` never reaches it and the run ends with **no output at all** — the app gets a hard error and no reason. That defect has been fixed three times in this solution already (`ConnectWorkspaceToGit`, `AddConnectionRoleAssignment`, and by design in `DisconnectWorkspaceFromGit`). Do not make it the fourth.

**Note `outputs('Create')` versus `body('Create')`.** The status code lives on `outputs`; the parsed payload lives on `body`. Both appear above and they are not interchangeable — `body('Create')?['statusCode']` is always blank, which would make every response report `Failed`.

**Choose Text for every output.** The *Respond* action offers Text / Number / Boolean / Object. Anything other than Text fails schema validation at runtime, because the designer wraps single expressions in `@{ }` and hands back the string `"true"` where a boolean was promised. One bad field makes **every** output of the flow unreadable in the app, not just the bad one — that defect cost `GetWorkspaceGitState` its `isConnected` field and `ListMyConnections` its `count` (FLOWS §4).

### Why there are no variables and no branches

An earlier draft seeded `outcome` / `message` / `endpointId` variables and set them from a success branch and a parallel failure branch, copying `ConnectWorkspaceToGit`. That was over-built. `ConnectWorkspaceToGit` needs variables because it has five genuinely different outcomes reached through a `Condition`; this flow has two, distinguished by nothing more than a status code.

Worse, with no `Condition` to act as a container, the Respond would have had to **join** two parallel branches — a `runAfter` naming both branch tails on *is successful* **and** *is skipped*. That is fiddly to build, easy to get wrong, and invisible when it is wrong. Deriving both fields inline from `outputs('Create')?['statusCode']` removes the join, the branches and the three variables at once. It is the shape `DisconnectWorkspaceFromGit` already uses, and `DeletePrivateEndpoint` uses it too.

The failures worth expecting all arrive through `Message`:

| Condition | `errorCode` | Status |
|---|---|---|
| Duplicate **name** in the workspace | `DuplicatePrivateEndpointName` — *"Private Endpoint with the specified name already exists."* | ✅ Confirmed 2026-09-02. `400` → `Failed` |
| Duplicate **target** — same resource ID *and* sub-resource | `DuplicateTargetPrivateLinkResourceId` | ✅ Confirmed 2026-09-02. `400` → `Failed` |
| Sub-resource invalid for the resource type | — | ⚠️ **Not an error here.** Accepted with `201`; the row is created and provisioning fails with Activation = `Failed`. See below |
| Workspace not on an F64+/Trial capacity | unknown | A capacity or SKU error |
| Recreating an endpoint to a resource deleted < 15 minutes ago | unknown | A conflict — the cooldown documented in [../../APP-PRIVATE-ENDPOINTS.md](../../APP-PRIVATE-ENDPOINTS.md) §6 |
| Malformed or unsupported `targetPrivateLinkResourceId` | unknown | A validation error naming the resource ID |

**Errors are not mapped to named outcomes, deliberately.** Every one of these returns a 4xx, which the status-code test already reports as `Failed`, and Fabric's own `message` is readable — *"Private Endpoint with the specified name already exists."* needs no improvement. Adding a `DuplicateName` outcome would mean a nested `if()` in the expression, a value in the contract and a branch in the app, all to say something `Message` already says.

If the app ever needs to act on an error programmatically — focusing the name field, say — add `errorCode` as a fifth Respond output (`coalesce(body('Create')?['errorCode'], '')`) and let the app decide. A raw passthrough keeps the decision in one place; an outcome mapping splits it across the flow and the app.

`outcome` is one of:

| Value | Meaning | What the app does |
|---|---|---|
| `Created` | The request was **accepted**. `provisioningState` is `Provisioning` | Refresh the list; show the "what happens next" panel |
| `Failed` | `Create` errored; Fabric's own text in `message` | Show the message |

> **`Created` is not a promise that anything works.** Fabric does not validate `targetSubresourceType` against the target resource type at create time — a mismatched sub-resource is accepted with `201`, the row is created, and provisioning then fails with **Activation = `Failed`** in the Fabric UI (confirmed 2026-09-02). The app must re-list after creating and surface `provisioningState`, or a broken endpoint is indistinguishable from a pending one. See [../../APP-PRIVATE-ENDPOINTS.md](../../APP-PRIVATE-ENDPOINTS.md) §5.2.

Output names come back **lowercased** in Power Fx — you type `Outcome`, the app binds `outcome`.

---

## Step 7 — Save and check

1. **Save**.
2. **Peek code** on `Create` and on the Respond. Confirm the expressions are live, not quoted text — and that the Respond's `runAfter` on `Create` lists both `Succeeded` and `Failed`.
3. Test from the flow's own **Test** panel before touching the app, so a failure is a flow problem rather than a binding problem.

The finished flow is **four actions**: one child-flow call, one variable, one POST, one response.

---

## Design notes

### `requestMessage` is composed by the app, not by this flow

The data source admin approving the request in the Azure portal sees only this string, and needs to know who asked and why. The flow cannot supply that — it knows neither the workspace display name nor the caller's email. The **app** composes the final string, along the lines of:

```
<workspace name> (<owner email>) — <the owner's justification>
```

The flow's only responsibility is truncating it to the API's 140-character limit (Step 5). `GetMyEmail` already exists if the app needs the caller's address.

### There is nothing to poll

`POST` returns `201` immediately, with `provisioningState: "Provisioning"`. There is **no** `x-ms-operation-id`, no `202`, and `/v1/operations/{id}` knows nothing about it. `GetGitOperationStatus` is not involved and must not be called. Progress is observed by re-running `ListPrivateEndpoints`, and the state the owner actually cares about — `connectionState.status` reaching `Approved` — is set by a human in the Azure portal, not by Fabric.

Do not add a `Do until` that waits for `Succeeded`. It would burn the app's 120-second budget waiting for something that finishes in its own time and is visible on the next refresh anyway.

---

## After building

- Add the flow to the canvas app. Watch for a suffixed duplicate such as `CreatePrivateEndpoint_1`.
- Call it positionally, in trigger order: `CreatePrivateEndpoint.Run(gblWsId, txtName.Text, txtResourceId.Text, drpSubresource.Selected.Value, composedMessage)`. No trailing options record.
- If you change the trigger inputs later, **remove and re-add the flow in the app**. With five positional inputs, a cached signature is far more damaging than on a single-input flow.
- Set **Run-only users**: *Use this connection* for the HTTP actions. Does not survive solution import (OPEN-ISSUES §8.2).
- The flow answers a PowerApp, so it must respond within **120 seconds**. One child call and one POST — the budget is not at risk.
- **The duplicate rule belongs in the create panel.** Name ≤ 64 characters and not already used; `requestMessage` ≤ 140; resource ID well-formed and not already paired with the same sub-resource. Inline field errors, not a banner after submitting — this is where an owner should learn about a duplicate, not from a flow response.
- **Re-run `ListPrivateEndpoints` when the create panel opens**, not just when the tab loads. That keeps the app's check current for the cost of one call.

---

## To verify after the first run

| # | Test | Establishes |
|---|---|---|
| ~~1~~ | ~~Create the same **name** twice~~ | ✅ **Done 2026-09-02.** `400 DuplicatePrivateEndpointName` |
| ~~2~~ | ~~Same resource ID **and** sub-resource, different name~~ | ✅ **Done 2026-09-02.** `400 DuplicateTargetPrivateLinkResourceId` — the uniqueness key is the pair |
| 3 | Create `blob` **and** `dfs` endpoints against a **real storage account**, and let both provision | That the pair-key genuinely supports the documented storage case end to end — not just that the `POST` is accepted |
| 4 | Create **without** `targetSubresourceType` on a 1:1 type such as `Microsoft.Sql/servers` | Whether Fabric infers it. Decides whether the app can ever omit the field — see [../../APP-PRIVATE-ENDPOINTS.md](../../APP-PRIVATE-ENDPOINTS.md) §5.6 |
| 5 | Create as SPN-A against a resource in a subscription where SPN-A has **no Azure role at all** | Confirms §0 — that no Azure RBAC is needed to request |
| 6 | Create with `requestMessage` longer than 140 characters | That `take` truncates rather than the API rejecting |
| 7 | Create on a **sub-F64** workspace | That the capacity failure reaches the app as a readable message |
| 8 | Create with a resource ID for a supported type in a subscription with `Microsoft.Network` **unregistered** | Whether this fails at create time or silently sits in `Provisioning` — it changes what the app should tell the owner |

Tests 3 and 4 shape the create panel. Run them before wiring its validation.
