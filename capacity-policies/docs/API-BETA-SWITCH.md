# The `?beta=true` switch — surviving PuPr and GA without editing flows

**Status: planning only. Nothing in this repo has been changed. No flow has been edited, no environment variable exists yet.**

The capacity-policy endpoints are in **private preview** today. At **public preview** they are re-released as **beta**, and every call needs a query parameter:

```
POST /v1/workspaces/{workspaceId}/policySets/{policySetId}/policyRules/replaceByPolicy?beta=true
```

At **GA** the parameter is removed again and the URL returns to what it is today.

> **So the URL changes twice, in opposite directions, on dates nobody here controls.** Hard-coding it means opening six actions in four flows twice. This document specifies one environment variable instead, so both transitions are a **value change in the solution**, not a flow edit.

**Scope: the capacity-policy APIs only** — `/policySets`, `/policyRules`, `/activate`, `replaceByPolicy`, and the `DELETE` on a set. The workspace-settings app's calls (`/networking/communicationPolicy/*`, `/managedPrivateEndpoints`, `/git/*`, and [scripts/Get-FabricOutboundRules.ps1](../../scripts/Get-FabricOutboundRules.ps1)) are **out of scope by decision** and are not listed below. If that decision changes, the same pattern applies but the variable belongs in the `ab_` solution, not this one.

---

## 1. The timeline, and why there is nothing to switch on today

| Phase | When | Suffix on a policy URL | Variable value |
|---|---|---|---|
| **Private preview** — today | Now | *(none)* | *(empty)* |
| **Public preview — beta** | Expected next week | `?beta=true` | `?beta=true` |
| **GA** | Unannounced | *(none)* | *(empty)* |

> ### There is no "PrPr mode" to build, and that is the point
>
> Private preview and GA produce the **same URL**. The variable is empty in both. So the work here is **preparation, not a switch**: wire the variable in now with an empty value, and the flows behave exactly as they do today — the change is provably inert before it matters.
>
> **Which also means it can be done and tested this week, before public preview is turned on.** Doing it afterwards means doing it under a broken estate, because the moment the service flips, every call in §2 starts failing at once (§5).

**Two values, ever.** `?beta=true` and empty. Anyone tempted to add a third — a per-environment variant, a `preview=true` — should read §6 first.

---

## 2. Affected calls — the complete inventory

Six actions across four flow documents. Each needs the suffix appended to the **end** of its URL.

| # | Flow | Action | Method + path today |
|---|---|---|---|
| 1 | [RebuildCapacityPolicyRules](../bau/RebuildCapacityPolicyRules.md) Step 9 | `Replace_rules` | `POST /v1/workspaces/{holderWs}/policySets/{id}/policyRules/replaceByPolicy` |
| 2 | [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md) Step 6 | `Create_policy_set` | `POST /v1/workspaces/{holderWs}/policySets` |
| 3 | [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md) Step 8c | `Activate` | `POST /v1/workspaces/{holderWs}/policySets/{id}/activate` |
| 4 | [DeleteCapacityPolicySet](../bau/DeleteCapacityPolicySet.md) §3c | `Delete_policy_set` | `DELETE /v1/workspaces/{holderWs}/policySets/{id}` |
| 5 | [MIG_InitializeCapacityPolicySet](../migration/MIG_InitializeCapacityPolicySet.md) Step 6 | `Create_policy_set` | `POST /v1/workspaces/{holderWs}/policySets` |
| 6 | [MIG_ActivateAllCapacityPolicySets](../migration/MIG_ActivateAllCapacityPolicySets.md) §4b | `Activate` | `POST /v1/workspaces/{holderWs}/policySets/{id}/activate` |

**Call 1 is the one that matters most.** It is the only writer of rules, and every event flow reaches Fabric through it. If only one action were changed, it would be this one — and the estate would still be broken, because a capacity cannot be created or retired.

### Calls deliberately **not** changed

| Call | Where | Why |
|---|---|---|
| `GET /v1/capacities` | [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md) Step 4, [DeleteCapacityPolicySet](../bau/DeleteCapacityPolicySet.md) §3a, [MIG_RegisterAllCapacityPolicySets](../migration/MIG_RegisterAllCapacityPolicySets.md) §3a | GA endpoint, unrelated to policy sets. **Confirm, do not assume** — §6 Q1 |
| `GET /v1/operations/{id}` and `/result` | [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md) Step 7, [MIG_InitializeCapacityPolicySet](../migration/MIG_InitializeCapacityPolicySet.md) Step 7 | The generic long-running-operation endpoint. **The operation is created by a beta call**, so whether it inherits the beta route is the open question in §6 Q2 |
| Everything in [SyncCapacityPolicySets](../discarded/SyncCapacityPolicySets.md) | `discarded/` | Discarded 2026-09-18. **Not built, not to be changed.** It is the only design that put its own query string on a policy URL (`?recursive=true`) — see §4 |

### Flows with nothing to change

Listed so nobody goes looking for a call that is not there.

| Flow | Why it is unaffected |
|---|---|
| [AddWorkspaceToPolicy](../bau/AddWorkspaceToPolicy.md), [RemoveWorkspaceFromPolicy](../bau/RemoveWorkspaceFromPolicy.md), [RebuildOnExceptionChange](../bau/RebuildOnExceptionChange.md) | Validate in Dataverse, then call `RebuildCapacityPolicyRules`. **No Fabric call of their own** |
| [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md) | Loops and calls the same child |
| [MIG_RegisterAllCapacityPolicySets](../migration/MIG_RegisterAllCapacityPolicySets.md) | `GET /v1/capacities` only; the create happens in its child (call 5) |
| [ListCapacityPolicySets](../helper/ListCapacityPolicySets.md) | One Dataverse read. No Fabric calls by design |

> **The child-flow shape is what makes this cheap.** Three BAU flows and one migration flow write rules, and all four go through one action — call 1. Six edits, not sixteen.

---

## 3. The environment variable

| Property | Value |
|---|---|
| Display name | `PolicyApiSuffix` |
| Schema name | `ubsppcoe_PolicyApiSuffix` |
| Data type | **Text** |
| Current value — today | *(empty)* |
| Current value — public preview | `?beta=true` |
| Current value — GA | *(empty)* |
| Read by | The six actions in §2 |

**Created inside the policy solution**, so it inherits the `ubsppcoe_` prefix like the other five — see [CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md) §8.11 for the creation steps, the prefix decision, and the *"the variable exists but the flow cannot see it"* trap, which is the failure everyone hits once.

### It holds the whole suffix, `?` included

Not `beta=true`, and not a `Yes/No`. The reason is arithmetic in the expression language:

| Design | What a call site looks like | Empty-value behaviour |
|---|---|---|
| **Full suffix, chosen** | `…/policySets@{parameters('PolicyApiSuffix (ubsppcoe_PolicyApiSuffix)')}` | URL is unchanged. Nothing to strip |
| Parameter only (`beta=true`) | `…/policySets@{if(empty(parameters(…)), '', concat('?', parameters(…)))}` | Same result, six times the expression |
| Two-option choice / boolean | `…/policySets@{if(equals(parameters(…), 'Yes'), '?beta=true', '')}` | Encodes *today's* parameter name in six flows. A rename at PuPr and the whole exercise was pointless |

**A Text variable holding the literal suffix is the only version where the next change is a value, not an edit.** If the product team ships `?beta=1`, or `?api-version=beta`, or two parameters, the value absorbs it and no flow is touched.

**Text, and Text only** — consistent with the two numeric variables, which are Text deliberately ([CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md) §8.11).

---

## 4. How a call site changes

The suffix goes at the **very end** of the URL, after the last path segment, inside the same expression box.

**Before** — call 1, [RebuildCapacityPolicyRules](../bau/RebuildCapacityPolicyRules.md) Step 9:

```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{variables('policySetId')}/policyRules/replaceByPolicy
```

**After:**

```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{variables('policySetId')}/policyRules/replaceByPolicy@{parameters('PolicyApiSuffix (ubsppcoe_PolicyApiSuffix)')}
```

Nothing else about the action changes — **method, headers, body, Asynchronous Pattern and Retry Policy all stay exactly as documented**. The five other call sites take the identical treatment: append, nothing more.

> **Insert the variable from the dynamic-content picker, never by typing it.** A typed `parameters('…')` creates the reference without the declaration in the flow's `parameters` block, and the run fails with *The workflow parameter … is not found* — while the expression on screen looks perfectly correct. [CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md) §8.11 has the full diagnosis and the fix. **This will happen to somebody on this change**, because it happens on every change that adds a variable.

### The one rule that has to be stated

**The suffix must be last, and the URL it is appended to must have no query string of its own.** All six call sites in §2 satisfy that today. Two places could break it:

| Case | Wrong | Right |
|---|---|---|
| `activate` with `allowReplace` — see [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md) §8c and [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md) §6 | `…/activate?allowReplace=True@{parameters(…)}` → `…?allowReplace=True?beta=true` | `…/activate@{parameters(…)}@{if(empty(parameters(…)), '?', '&')}allowReplace=True` |
| A list call with `?recursive=true` — only in [discarded](../discarded/SyncCapacityPolicySets.md), not built | `…/policySets?recursive=true?beta=true` | Same conditional form |

**No built flow passes `allowReplace` today** — `InitializeCapacityPolicySet` §8c refuses it deliberately, and surfacing `PolicySetActivationConflict` to a human is the intended behaviour. So the conditional form is documented and **not used**. Whoever first passes `allowReplace` owns applying it.

> Two `?` in one URL is not a syntax error Fabric rejects politely. It is a path that does not match, and the failure reads as a `400` or `404` on a call that looks right.

---

## 5. The list of changes

### 5.1. Now, before public preview — the whole job, done inert

| # | Change | Where |
|---|---|---|
| 1 | **Create** `ubsppcoe_PolicyApiSuffix`, Text, **Current Value empty** | The policy solution |
| 2 | Append the suffix to the **six** actions in §2, from the picker | Four flows, in the customer environment |
| 3 | Save each flow, then **export the solution and confirm** each has the `PolicyApiSuffix (ubsppcoe_PolicyApiSuffix)` entry in `definition.parameters` | Six actions, four flows |
| 4 | Run the §5.4 verification with the value **empty** — behaviour must be identical to today | Customer environment |
| 5 | Update the **flow documents**: the URL row in each of the six action tables | `bau/`, `migration/` — the six files in §2 |
| 6 | Update **five → six environment variables** everywhere the count appears | See the table below |
| 7 | Add the variable to the config table | [CAPACITY-POLICY-FLOWS.md](CAPACITY-POLICY-FLOWS.md) §6 |
| 8 | Link this document from the docs index | [README.md](../README.md) *Where to start* |

**The count of five is asserted in eight places.** All of them become six:

| File | Where |
|---|---|
| [CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md) | §8.11 variable table, and the *"Five, not six"* note — which is about the discarded policy-name variable and must not be deleted, only corrected to *"Six, not seven"* |
| [CAPACITY-POLICY-FLOWS.md](CAPACITY-POLICY-FLOWS.md) | §6 configuration table |
| [DEPLOYMENT-ALM.md](DEPLOYMENT-ALM.md) | §1 component count, §3 table and *"All five are Text"* |
| [DEPLOYMENT-RUNBOOK.md](DEPLOYMENT-RUNBOOK.md) | §1 component count, §6 table, §7 step 4, and the §8 checklist line |
| [CAPACITY-POLICY-MIGRATION-RUNBOOK.md](CAPACITY-POLICY-MIGRATION-RUNBOOK.md) | §0.3 and the checklist line *"All five environment variables set"* |
| [HANDOVER-REGISTER.md](HANDOVER-REGISTER.md) | Obligation **E1** |
| [ADR.md](ADR.md) | A new row recording this decision and its date |

> **Step 6 is not tidying.** A deployment runbook that says *five* is a runbook that ships an environment with the sixth variable blank — which, during public preview, is an estate where nothing can be published and the runbook says the deployment succeeded.

### 5.2. At public preview — the switch

| # | Change |
|---|---|
| 1 | Set `ubsppcoe_PolicyApiSuffix` **Current Value** to `?beta=true`, in **every** environment |
| 2 | Run the §5.4 verification |
| 3 | Set it back to empty and re-run one call if you want proof the old route is really gone — optional, and only worth it on a non-production environment |

**No flow is opened. No solution is exported or imported.** That is the whole return on this exercise.

> **Do it in every environment on the same day.** A dev environment left empty fails silently until the next person tests there and concludes their change broke it.

### 5.3. At GA — the switch back

Set the value to empty. **Do not delete the variable** — a fourth phase is not impossible, and an empty variable costs nothing. Deleting it costs six flow edits and a run of *The workflow parameter … is not found*.

### 5.4. Verification, all three times

Same sequence each time. It exercises four of the six call sites.

1. **`GET /v1/capacities`** from a throwaway manual flow — confirms the connection and identity before anything writes. [CAPACITY-POLICY-FLOWS.md](CAPACITY-POLICY-FLOWS.md) §8 step 3 describes it.
2. **`RebuildCapacityPolicyRules` against one non-production capacity** — call 1. A `200` and the expected rule count.
3. **`InitializeCapacityPolicySet` against a test capacity** — calls 2 and 3, plus the operations polling that §6 Q2 asks about.
4. **Read the rules back in the portal.** A rebuild that returns `200` having written nothing is the failure mode this subsystem cannot otherwise see.
5. **`DeleteCapacityPolicySet`** on that test capacity — call 4, and it cleans up after step 3.

> **Step 4 is not optional on the PuPr switch.** The whole risk of this change is a URL that resolves to something that answers politely and governs nothing.

---

## 6. Open questions — confirm before public preview, not after

| # | Question | Why it matters | Who |
|---|---|---|---|
| **Q1** | Does `?beta=true` apply to **`GET /v1/capacities`**? | Three flows read it. If it does, this document's inventory is wrong by three actions | Product team |
| **Q2** | Does a long-running operation started by a beta call need the suffix on **`/v1/operations/{id}`** and **`/result`**? | `Create_policy_set` returns `202` on the slow path. If polling needs it and does not have it, capacity creation hangs and times out — **while the create itself succeeded** | Product team |
| **Q3** | Is the parameter exactly **`beta=true`**, lower case, and is `true` the only accepted value? | The variable absorbs any answer, but the value has to be right once | Product team |
| **Q4** | Does the **request body or response shape** change at beta, or only the route? | A changed body is not a variable, it is a flow edit — and this document would be the wrong plan | Product team |
| **Q5** | Is there a **grace period** where both routes answer? | Decides whether §5.2 can be done calmly or has to be same-hour | Product team |
| **Q6** | Does `?beta=true` apply to the **PowerShell scripts** in `C:\GIT\ubs-policies` — `activate_policy_set.ps1` and the rest? | Those scripts are the documented authority for these payloads. They need the same switch, via `$env:` or a parameter | This team |

> **Q4 is the one that invalidates the plan.** Everything here assumes *the route changes and nothing else does*. If the beta release also renames a body property, the six actions need opening anyway and the variable only saves the second transition.

> **Q2 is the one that will be found in production if it is not asked.** The `202` path only runs when Fabric is slow, so it passes every test on a quiet environment and fails on the provisioning burst.

---

## 7. What this does not solve

**Variable *values* do not travel reliably with a solution export.** Same caveat as the other five — [DEPLOYMENT-ALM.md](DEPLOYMENT-ALM.md) §2, [HANDOVER-REGISTER.md](HANDOVER-REGISTER.md) E1. An import during public preview that skips the prompt lands an **empty** suffix, which is a working GA configuration applied to a beta service: every policy call fails, and the import reports success.

**Nothing detects a wrong value.** There is no drift scan and no scheduled rebuild ([README.md](../README.md)), so a stale suffix surfaces when somebody provisions or retires a capacity — which may be days later. The detection is the §5.4 run, performed by a human, on the day the value changes.

**An empty variable and a missing variable fail differently.** Empty builds a valid GA URL and fails at the service. Missing fails at expression evaluation with *The workflow parameter … is not found*, before any call. The second is the better failure and neither is announced.
