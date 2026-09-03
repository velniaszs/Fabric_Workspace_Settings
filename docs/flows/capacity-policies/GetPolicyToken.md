# Flow — `GetPolicyToken`

Child flow. Acquires an app-only bearer token for the **policy** service principal and hands it to its caller. Every other flow in this folder calls it.

> **Not built yet.** Specification, not a description of something that exists.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) (design), [../nocustomcon/GetFabricToken.md](docs/flows/nocustomcon/GetFabricToken.md) (the equivalent for the workspace-settings broker — same shape, different principal).

---

## 0. Before you start

- Create the flow **inside the solution**, so the environment variables resolve as `parameters('… (ab_…)')` rather than literals.
- **No connector connection is needed.** Built-in actions only: `Initialize variable`, `HTTP`, `Respond to a Power App or flow`.
- **This is a different service principal from `sp_fabric_powerapp`.** The workspace-settings broker holds workspace Admin across the managed estate; the policy principal needs Contributor on one holder workspace and Capacity Admin on the managed capacities. Do not reuse the broker's credentials here — a single principal holding both sets of rights is a much larger blast radius than either job needs.
- Two environment variables must exist:

  | Variable | Holds |
  |---|---|
  | `ab_PolicyTenantId` | Entra tenant ID |
  | `ab_PolicyClientId` | The policy SPN's **application (client)** ID |

- The tenant setting **Service principals can use Fabric APIs** must be enabled for a group containing this SPN. Without it every downstream call returns a bare `401` while this flow still returns a token happily.

---

## Step 1 — Create the flow

1. [make.powerapps.com](https://make.powerapps.com) → **Solutions** → open your solution → **New** → **Automation** → **Cloud flow** → **Instant**.
2. Name it `GetPolicyToken`.
3. Trigger: search **Manually trigger a flow** and choose it.

> **The trigger must be *Manually trigger a flow*.** A flow can only be called by `Run a Child Flow` if that is its trigger. A Power Apps (V2) trigger makes it ineligible — the mistake that forced `GetGitOperationStatus` out of the child-flow role in the other subsystem.

No trigger inputs. Callers pass nothing.

---

## Step 2 — Hold the secret

**+ New step** → **Initialize variable**. Rename it `Initialize_variable`.

| Field | Value |
|---|---|
| Name | `clientSecret` |
| Type | String |
| Value | the policy SPN's client secret |

**Solution export scrubs this to a single space**, so it must be re-entered by hand in every environment. Never commit it.

Migrating this to a Key Vault-backed secret environment variable is the better answer and is worth doing before this reaches production.

---

## Step 3 — The token call

**+ New step** → **HTTP**. Rename it `HTTP`.

| Field | Value |
|---|---|
| Method | `POST` |
| URI | `https://login.microsoftonline.com/@{parameters('PolicyTenantId (ab_PolicyTenantId)')}/oauth2/v2.0/token` |
| Header `Content-Type` | `application/x-www-form-urlencoded` |

Body — a form-encoded **string**, not JSON:

```
grant_type=client_credentials&client_id=@{parameters('PolicyClientId (ab_PolicyClientId)')}&client_secret=@{variables('clientSecret')}&scope=https://api.fabric.microsoft.com/.default
```

Then: action ⋯ → **Settings** → turn on **Secure Inputs** and **Secure Outputs**. Without them the secret and the bearer token are both readable in run history by anyone who can open the flow.

> A token for this SPN legitimately comes back with no `roles` claim. Fabric does not grant REST access through Entra application permissions — access comes from the tenant setting plus Fabric-side roles. Do not add application permissions expecting them to help.

---

## Step 4 — Parse and return

**+ New step** → **Parse JSON**. Rename it `Parse_JSON`.

| Field | Value |
|---|---|
| Content | `@body('HTTP')` |
| Schema | `{ "type": "object", "properties": { "access_token": { "type": "string" }, "expires_in": { "type": "integer" }, "token_type": { "type": "string" } } }` |

**+ New step** → **Respond to a Power App or flow**. Add one **Text** output:

| Output name | Value |
|---|---|
| `access_token` | `body('Parse_JSON')?['access_token']` |

Also set **Secure Inputs** and **Secure Outputs** on the Respond action.

---

## Step 5 — Check

**Save**, then run it from the **Test** panel.

> The run will report **`ActionResponseSkipped`** on the Respond action. That is expected — nothing is waiting for the response when a flow is started from the Test panel. The token call still happened. Confirm success by checking that `HTTP` returned `200`; the body is hidden by Secure Outputs, which is correct.

The real test is Step 3 of [SyncCapacityPolicySets.md](docs/flows/capacity-policies/SyncCapacityPolicySets.md), which is the first flow to use the token against Fabric.

---

## How callers use it

**+ New step** → **Run a Child Flow** → **GetPolicyToken**. Then an `Initialize variable`:

| Field | Value |
|---|---|
| Name | `accessToken` |
| Type | String |
| Value | `body('Run_a_Child_Flow')?['access_token']` |

Every flow in this folder starts with exactly those two actions. `accessToken` is never a trigger input and is never returned to a caller.
