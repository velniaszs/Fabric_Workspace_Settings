# The `?beta=true` switch — surviving PuPr and GA without editing flows

**Status: the environment variable exists** — `PolicyApiSuffix` / `ubsppcoe_PolicyApiSuffix`, created 2026-09-22 with an **empty** value. **No flow has been edited yet**; §5.1.1 is the work. The six questions this plan depended on were **answered 2026-09-22** — see §6. All six confirm the plan: **the route is the only thing that changes.**

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

**Two values, ever — confirmed 2026-09-22.** `?beta=true` and empty; there is no third form of the parameter (§6 Q3). Anyone tempted to add a per-environment variant should read §6 first.

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
| `GET /v1/capacities` | [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md) Step 4, [DeleteCapacityPolicySet](../bau/DeleteCapacityPolicySet.md) §3a, [MIG_RegisterAllCapacityPolicySets](../migration/MIG_RegisterAllCapacityPolicySets.md) §3a | Unrelated to policy sets. **Confirmed unaffected 2026-09-22** — §6 Q1 |
| `GET /v1/operations/{id}` and `/result` | [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md) Step 7, [MIG_InitializeCapacityPolicySet](../migration/MIG_InitializeCapacityPolicySet.md) Step 7 | The generic long-running-operation endpoint. The operation is *created* by a beta call but does not inherit the beta route — **confirmed unaffected 2026-09-22**, §6 Q2 |
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

| Design | What a call site looks like | Why not |
|---|---|---|
| **Full suffix, chosen** | `…/policySets@{parameters('PolicyApiSuffix (ubsppcoe_PolicyApiSuffix)')}` | — Empty resolves to nothing and the URL is unchanged. No conditional at any call site |
| Parameter only (`beta=true`) | `…/policySets@{if(empty(parameters(…)), '', concat('?', parameters(…)))}` | Identical result, six times the expression, six chances to mistype it |
| Two-option choice / boolean | `…/policySets@{if(equals(parameters(…), 'Yes'), '?beta=true', '')}` | **Puts the literal `?beta=true` back into six flows** — the exact thing this exercise removes — in exchange for nothing |

**The chosen form is the only one where a call site contains no logic at all.** `@{parameters(…)}` appended to a URL is the smallest change that can be made to six actions, and the smallest thing to get wrong. Q3 confirms the value will only ever be `?beta=true` or empty, so the conditional forms buy no flexibility that is ever used.

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
| 1 | ~~**Create** `ubsppcoe_PolicyApiSuffix`, Text, **Current Value empty**~~ — **done 2026-09-22** | The policy solution |
| 2 | Append the suffix to the **six** actions in §2, from the picker — **step by step in §5.1.1** | Four flows, in the customer environment |
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

#### 5.1.1. The six edits, one by one

**The variable is empty, so every edit below is inert.** Nothing changes behaviour today — which is exactly why this can be done in working hours, in one sitting, and verified before public preview forces the issue.

**Do edit 1 first and verify it (§5.4 step 2) before doing the other five.** It is the same edit six times; proving it once on the flow that matters most is cheaper than discovering the picker problem on the sixth.

##### The procedure — identical for all six

1. **Solutions** → the policy solution → the flow → **Edit**. **Never from *My flows*** — a flow opened there cannot see the solution's environment variables, and the picker in step 4 will not offer one.
2. Expand the action named below, and click into **URL of the request**.
3. Put the cursor at the **very end** of the existing URL. No space, no slash, nothing after it.
4. **Dynamic content** → scroll to the **Environment variable** section → click **PolicyApiSuffix**.
5. Check the token reads exactly `parameters('PolicyApiSuffix (ubsppcoe_PolicyApiSuffix)')`, and that it is the last thing in the box.
6. **Save.** Then reopen the flow and look at the URL again — if the suffix is not there, the save did not take.
7. **Touch nothing else.** Method, headers, body, **Asynchronous Pattern**, **Retry Policy** and **Configure run after** all stay exactly as they are.

> **Step 4 is the whole procedure.** Typing `@{parameters('PolicyApiSuffix (ubsppcoe_PolicyApiSuffix)')}` by hand produces an expression that looks right, saves without complaint, and fails at runtime with *The workflow parameter … is not found* — because the designer only writes the declaration into `definition.parameters` when it resolves the reference **from the picker, against a variable that existed when the flow was opened**. See [CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md) §8.11.
>
> **The variable was created today, so every flow open before that is stale.** Close any flow you already had open and reopen it, or the picker will not list `PolicyApiSuffix` at all.

##### Edit 1 — [RebuildCapacityPolicyRules](../bau/RebuildCapacityPolicyRules.md), Step 9, action `Replace_rules`

**Before:**
```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{variables('policySetId')}/policyRules/replaceByPolicy
```
**After:**
```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{variables('policySetId')}/policyRules/replaceByPolicy@{parameters('PolicyApiSuffix (ubsppcoe_PolicyApiSuffix)')}
```

**This is the one that matters.** It is the only writer of rules, and [AddWorkspaceToPolicy](../bau/AddWorkspaceToPolicy.md), [RemoveWorkspaceFromPolicy](../bau/RemoveWorkspaceFromPolicy.md), [RebuildOnExceptionChange](../bau/RebuildOnExceptionChange.md), [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md) 8b and [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md) all reach Fabric through it. **Five callers, one edit** — and none of the five needs touching.

##### Edit 2 — [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md), Step 6, action `Create_policy_set`

**Before:**
```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets
```
**After:**
```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets@{parameters('PolicyApiSuffix (ubsppcoe_PolicyApiSuffix)')}
```

**Leave Asynchronous Pattern *Off*.** It is off deliberately — Step 6's note explains why turning it on loses the policy set ID. It is in the same ⋯ → **Settings** panel people open while poking at an action they are editing.

##### Edit 3 — [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md), Step 8c, action `Activate`

**Before:**
```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{variables('policySetId')}/activate
```
**After:**
```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{variables('policySetId')}/activate@{parameters('PolicyApiSuffix (ubsppcoe_PolicyApiSuffix)')}
```

**Two edits in this one flow — do not stop at the first.** `Activate` is nested inside Step 8, below `Run_rebuild`, so it is easy to miss when the branch is collapsed.

**Leave `Configure run after` on `Run_rebuild` → *is successful* only**, and leave the body's three properties alone — `capacityId` is undocumented and required (Step 8c).

##### Edit 4 — [DeleteCapacityPolicySet](../bau/DeleteCapacityPolicySet.md), §3c, action `Delete_policy_set`

**Before:**
```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{first(body('Get_policy_row')?['value'])?['ubsppcoe_policysetid']}
```
**After:**
```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{first(body('Get_policy_row')?['value'])?['ubsppcoe_policysetid']}@{parameters('PolicyApiSuffix (ubsppcoe_PolicyApiSuffix)')}
```

**Read the URL off the flow before changing it.** This is the one action whose URL is described in prose rather than given as a table in its own document, so the form above is reconstructed from §3c — confirm it matches what is actually in the designer, and correct the document if not.

**Do not test this one by running it.** It deletes a policy set. It is exercised in §5.4 step 5, against the test capacity created in step 3, and nowhere else.

##### Edit 5 — [MIG_InitializeCapacityPolicySet](../migration/MIG_InitializeCapacityPolicySet.md), Step 6, action `Create_policy_set`

Identical string to **edit 2**.

##### Edit 6 — [MIG_ActivateAllCapacityPolicySets](../migration/MIG_ActivateAllCapacityPolicySets.md), §4b, action `Activate`

**Before:**
```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{items('For_each_policy')?['ubsppcoe_policysetid']}/activate
```
**After:**
```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{items('For_each_policy')?['ubsppcoe_policysetid']}/activate@{parameters('PolicyApiSuffix (ubsppcoe_PolicyApiSuffix)')}
```

> ### Edits 5 and 6 may not exist any more, and that is fine
>
> Both flows are **deleted after cutover** by their own documents, along with `MIG_RegisterAllCapacityPolicySets`. If they are already gone, there are **four** edits, not six, and nothing is missed: [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md) is the one `MIG_` flow that is kept, and it reaches Fabric only through edit 1.
>
> **If they still exist, edit them.** A migration flow that is still in the solution will be run by somebody eventually — that is the reason its own document gives for deleting it — and one that silently calls a dead route during public preview fails halfway through an estate-wide activation.

##### When all of them are done

| Check | How |
|---|---|
| Every edit saved | Reopen each flow and read the URL. Six URLs, six suffixes |
| The declaration is real, not just the expression | Export the solution, open each flow's JSON, confirm a `"PolicyApiSuffix (ubsppcoe_PolicyApiSuffix)"` key in `definition.parameters` — **this is the check that catches a typed expression**, and it is §5.1 step 3 |
| Behaviour is unchanged | §5.4, with the value still empty |
| The flow documents match the flows | §5.1 step 5 — the URL row in each of the six action tables |

### 5.2. At public preview — the switch

**Assume the old route dies the moment the new one goes live** (§6 Q5). Between the service flipping and somebody setting the value, every call in §2 fails.

| # | Change |
|---|---|
| 1 | **Get the flip date from the product team** and hold the day. The value change is two minutes; knowing when to make it is the hard part |
| 2 | Set `ubsppcoe_PolicyApiSuffix` **Current Value** to `?beta=true`, in **every** environment, on that day |
| 3 | Run the §5.4 verification |
| 4 | **Clean up the window** — §5.2.1 |

**No flow is opened. No solution is exported or imported.** That is the whole return on this exercise.

> **Do it in every environment at once.** A dev environment left empty fails silently until the next person tests there and concludes their own change broke it.

#### 5.2.1. Nothing that failed in the window fixes itself

The three event flows trigger on Dataverse row changes, get one attempt, write `ubsppcoe_lasterror` and stop. **There is no scheduled rebuild and no drift scan** ([README](../README.md)), so a failure during the window persists until a human acts. Check all three, in this order:

| What may have been missed | How to find it | How to fix it |
|---|---|---|
| A **rules** change — a workspace enabled or disabled, an exception granted or revoked | Run history of [AddWorkspaceToPolicy](../bau/AddWorkspaceToPolicy.md), [RemoveWorkspaceFromPolicy](../bau/RemoveWorkspaceFromPolicy.md), [RebuildOnExceptionChange](../bau/RebuildOnExceptionChange.md); `ubsppcoe_lasterror` on `Capacity Policies` | [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md) over the estate |
| A **new capacity** — [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md) failed at create or activate | A `ubsppcoe_Node` row with no `Capacity Policies` row, or one whose `ubsppcoe_status` is not `Active` | Re-run `InitializeCapacityPolicySet` for that capacity |
| A **retired capacity** — [DeleteCapacityPolicySet](../bau/DeleteCapacityPolicySet.md) failed | A soft-deleted Node row whose policy row is still `Active` | Re-run that flow, or delete the set by hand |

> ### The estate-wide rebuild is not enough on its own
>
> It republishes **rules**. It does not create a policy set that was never created, and it does not activate one that was never activated — so a capacity provisioned during the window comes out of it **ungoverned while looking registered**, which is the same failure mode the handover register already names for a reversed soft-delete.
>
> **A capacity created in that window is open, not closed.** It is the one outcome of this transition that fails in the unsafe direction, and it is invisible unless somebody looks at the two columns above.

### 5.3. At GA — the switch back

Set the value to empty. **Do not delete the variable** — a fourth phase is not impossible, and an empty variable costs nothing. Deleting it costs six flow edits and a run of *The workflow parameter … is not found*.

### 5.4. Verification, all three times

Same sequence each time. It exercises four of the six call sites.

1. **`GET /v1/capacities`** from a throwaway manual flow — confirms the connection and identity before anything writes. [CAPACITY-POLICY-FLOWS.md](CAPACITY-POLICY-FLOWS.md) §8 step 3 describes it.
2. **`RebuildCapacityPolicyRules` against one non-production capacity** — call 1. A `200` and the expected rule count.
3. **`InitializeCapacityPolicySet` against a test capacity** — calls 2 and 3, plus the `202` polling path, which §6 Q2 confirms is unaffected.
4. **Read the rules back in the portal.** A rebuild that returns `200` having written nothing is the failure mode this subsystem cannot otherwise see.
5. **`DeleteCapacityPolicySet`** on that test capacity — call 4, and it cleans up after step 3.

> **Step 4 is not optional on the PuPr switch.** The whole risk of this change is a URL that resolves to something that answers politely and governs nothing.

---

## 6. Questions — all answered 2026-09-22

**Every open question is closed, and none of the answers changes the plan.** Recorded rather than deleted, because *"we checked, and it is only the route"* is the assumption the whole design rests on, and the next person will want to know it was asked rather than assumed.

| # | Question | Answer |
|---|---|---|
| **Q1** | Does `?beta=true` apply to **`GET /v1/capacities`**? | **No.** The capacity list is untouched. The inventory in §2 stands at six actions |
| **Q2** | Does a long-running operation started by a beta call need the suffix on **`/v1/operations/{id}`** and **`/result`**? | **No.** The `202` path in [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md) Step 7 keeps working unchanged |
| **Q3** | Is the parameter exactly **`beta=true`**? | **Yes — it is either nothing or `beta=true`.** Two values, exactly as §1 assumes |
| **Q4** | Does the **request body or response shape** change at beta? | **No. The API is static; the route is the only difference.** This is what makes a variable sufficient |
| **Q5** | Is there a **grace period** where both routes answer? | **Not confirmed, and probably not.** Plan for none — see below |
| **Q6** | Do the **PowerShell scripts** in `C:\GIT\ubs-policies` need the same switch? | **No — out of scope for this change** |

> ### Q4 is the answer that makes this worth doing
>
> A static API where only the route moves is the one case a query-suffix variable fully solves. Both transitions become a value change, and **no flow is ever reopened for public preview or GA**. Had the body changed, the six actions would need editing anyway and the variable would have saved only half the work.

> ### Q5 is the answer that shapes the day
>
> **Assume the old route stops answering the moment the new one starts.** There is then a window — from the service flipping to somebody setting the value — in which every call in §2 fails. §5.2 is written for that.

> **Q6 noted, with one consequence.** The scripts call the same routes, so one run by hand during public preview will fail the same way. If anyone does run `activate_policy_set.ps1` or its siblings in that period, the parameter goes on by hand. They remain the authority for **payloads**, which Q4 confirms are not changing.

---

## 7. What this does not solve

**Variable *values* do not travel reliably with a solution export.** Same caveat as the other five — [DEPLOYMENT-ALM.md](DEPLOYMENT-ALM.md) §2, [HANDOVER-REGISTER.md](HANDOVER-REGISTER.md) E1. An import during public preview that skips the prompt lands an **empty** suffix, which is a working GA configuration applied to a beta service: every policy call fails, and the import reports success.

**Nothing detects a wrong value.** There is no drift scan and no scheduled rebuild ([README.md](../README.md)), so a stale suffix surfaces when somebody provisions or retires a capacity — which may be days later. The detection is the §5.4 run, performed by a human, on the day the value changes.

**An empty variable and a missing variable fail differently.** Empty builds a valid GA URL and fails at the service. Missing fails at expression evaluation with *The workflow parameter … is not found*, before any call. The second is the better failure and neither is announced.
