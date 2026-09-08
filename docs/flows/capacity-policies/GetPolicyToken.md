# Flow — `GetPolicyToken` — **RETIRED, do not build**

**Decision 2026-09-08 (Q44): this flow is not being built.** Every Fabric call in this folder now goes through the **HTTP with Microsoft Entra ID (preauthorized)** connector, which attaches the bearer token itself. There is nothing left for a token flow to do.

> **It was never built, so nothing needs undoing.** This file is kept so existing links resolve and so the decision is recorded where someone would look for it. **The build steps that were here have been removed** rather than left to be followed by accident.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §5, [../nocustomcon/GetFabricToken.md](docs/flows/nocustomcon/GetFabricToken.md) — the workspace-settings equivalent, which **is** built and **is** unaffected by this decision.

---

## What replaced it

| Was | Now |
|---|---|
| `Run a Child Flow` → `GetPolicyToken`, then `Initialize variable` → `accessToken` | **Nothing.** Each flow starts at its first real step |
| `HTTP` action with `Authorization: Bearer @{variables('accessToken')}` | **Invoke an HTTP request** on the connector, no auth header |
| Client secret in an `Initialize variable`, scrubbed to a space on export | **No secret anywhere in the design** |
| `ab_PolicyTenantId`, `ab_PolicyClientId` environment variables | Not needed |
| Secure Inputs / Secure Outputs on the token actions | Not needed — no token ever reaches the run history |

The connector pattern is set out once in [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) §0, and every flow doc in this folder now uses it.

---

## What was gained, and what was given up

**Gained.** No secret to store, rotate, or leak into run history. No expiry to monitor. No token flow to build, test and keep in step with its callers. The `ActionResponseSkipped` confusion that the old test step had to explain goes with it.

**Given up — read this before treating it as a pure win.** The old design named its own service principal and granted Fabric roles to that. The connector authenticates as **whatever the connection is**, which may be a signed-in user. That moves every role in [CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §5 onto that account, makes the *Service principals can use Fabric APIs* tenant setting irrelevant, and introduces a failure mode the token flow did not have: **the connection breaking when its owner leaves, loses a role, or is asked to re-consent.** It fails as `401` on every capacity at once, with nothing in the run history naming the connection as the cause.

That is **Q45**, and it is open. It blocks granting any Fabric role, because until it is answered nobody knows which identity to grant them to.

