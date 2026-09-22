# The `?beta=true` switch — surviving PuPr and GA without editing flows

**Status: the variable is built and proven** — `PolicyApiBeta` / `ubsppcoe_PolicyApiBeta`, a **Two options** toggle, verified end-to-end against `Activate` on 2026-09-22: **No** produces today's URL, **Yes** produces `…?beta=true`. Three earlier designs failed against the live platform first — **§3.1**. **The flow edits are not done**; §5.1.1 is the work. The six questions this plan depended on were **answered 2026-09-22** — see §6. All six confirm the plan: **the route is the only thing that changes.**

The capacity-policy endpoints are in **private preview** today. At **public preview** they are re-released as **beta**, and every call needs a query parameter:

```
POST /v1/workspaces/{workspaceId}/policySets/{policySetId}/policyRules/replaceByPolicy?beta=true
```

At **GA** the parameter is removed again and the URL returns to what it is today.

> **So the URL changes twice, in opposite directions, on dates nobody here controls.** Hard-coding it means opening six actions in four flows twice. This document specifies one environment variable instead, so both transitions are a **Yes/No change in the solution**, not a flow edit.

**Scope: the capacity-policy APIs only** — `/policySets`, `/policyRules`, `/activate`, `replaceByPolicy`, and the `DELETE` on a set. The workspace-settings app's calls (`/networking/communicationPolicy/*`, `/managedPrivateEndpoints`, `/git/*`, and [scripts/Get-FabricOutboundRules.ps1](../../scripts/Get-FabricOutboundRules.ps1)) are **out of scope by decision** and are not listed below. If that decision changes, the same pattern applies but the variable belongs in the `ab_` solution, not this one.

---

## 1. The timeline, and why there is nothing to switch on today

| Phase | When | Suffix on a policy URL | `PolicyApiBeta` |
|---|---|---|---|
| **Private preview** — today | Now | *(none)* | **No** — §3.1 |
| **Public preview — beta** | Expected next week | `?beta=true` | **Yes** |
| **GA** | Unannounced | *(none)* | **No** — §3.1 |

> ### There is no "PrPr mode" to build, and that is the point
>
> Private preview and GA produce the **same URL**, so the toggle is **No** in both. The work here is **preparation, not a switch**: wire the expression in now with the toggle off, and the flows behave exactly as they do today — the change is provably inert before it matters, and that inertness has already been confirmed on `Activate` (§3.1).
>
> **Which also means it can be done and tested this week, before public preview is turned on.** Doing it afterwards means doing it under a broken estate, because the moment the service flips, every call in §2 starts failing at once (§5).

**Two states, ever — confirmed 2026-09-22.** The parameter is present or it is not; there is no third form (§6 Q3). That is exactly what a Yes/No variable expresses, and why §3 stopped trying to express it as a string.

---

## 2. Affected calls — the complete inventory

Six actions across four flow documents. Each needs the beta parameter appended to the **end** of its URL.

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
| Display name | `PolicyApiBeta` |
| Schema name | `ubsppcoe_PolicyApiBeta` |
| Data type | **Two options** — a Yes/No toggle, **not Text** |
| Default Value | **No** |
| Current value — today | **No** |
| Current value — public preview | **Yes** |
| Current value — GA | **No** |
| Read by | The six actions in §2 |

**Set the Default Value as well as the Current Value.** A variable with neither is the state that blocked flow publishing on 2026-09-22 (§3.1), and the default is also the one that **travels with a solution export**.

**Created inside the policy solution**, so it inherits the `ubsppcoe_` prefix like the other five — see [CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md) §8.11 for the creation steps, the prefix decision, and the *"the variable exists but the flow cannot see it"* trap, which is the failure everyone hits once.

> **`ubsppcoe_PolicyApiSuffix` is superseded.** The Text variable created earlier on 2026-09-22 was never referenced by a flow. **Delete it** — leaving both invites somebody to set the wrong one.

### The toggle says whether, the flow says what

The variable carries **a decision, not a string**. Each call site turns *Yes* into the literal `?beta=true` and *No* into nothing:

```
@{if(parameters('PolicyApiBeta (ubsppcoe_PolicyApiBeta)'), '?beta=true', '')}
```

**This is not the first design. It is the fourth, and the first that works** — three simpler ones were tried against the live platform and all three were rejected (§3.1):

| Design | Outcome |
|---|---|
| Text variable, value = empty string | **Not storable.** A blank box saves nothing, the run fails with *value was not found*, and flows referencing it **will not publish** |
| Text variable, value `a`, later cleared | **The clear is ignored.** The flow keeps sending `a` |
| Text variable, value `?`, URL ends `…/activate?` | **`400 Bad Request` from Fabric.** An empty query string is rejected |
| **Two options toggle, expression emits the parameter** | **Works — verified on `Activate` 2026-09-22** |

> ### Why a toggle beats a Text sentinel
>
> A Text variable could have carried the same conditional with a `none` sentinel. **The toggle wins because it has no invalid states**: no blank, no `None` with a capital, no trailing space, nothing to type. **Every failure in this exercise has been a value problem**, and a Yes/No control removes free-typed values from the design entirely.
>
> The trade is that the literal `?beta=true` now lives in six flows — which **Q3 confirms will never change**, and which a Text variable only avoided at the cost of a value somebody has to type correctly, twice, months apart.

> **The cost is one expression, written once into six URLs, and never touched again.** Both transitions stay what this document set out to make them: **a toggle, with no flow opened.**

### 3.1. Why it is a toggle and not a suffix — tested 2026-09-22

Four attempts, four platform behaviours, in order:

| # | Attempt | Result |
|---|---|---|
| 1 | Text variable saved with a **blank** value | *value was not found in `ubsppcoe_PolicyApiSuffix`* — **and flows referencing it cannot be published at all** |
| 2 | Set `a`, publish the flow, then **clear** the value | The flow **keeps using `a`**. The clear is silently ignored |
| 3 | Set `?`, so the URL ends `…/activate?` | **`400 Bad Request`** |
| 4 | **Two options toggle + `if(...)` on `Activate`** | **Works.** `No` → `…/activate`; `Yes` → `…/activate?beta=true`, both confirmed in the action's **Inputs** |

**Attempt 2 is the one to remember.** It means *"set it back to nothing at GA"* would have quietly left the estate on the beta route while the screen said otherwise — so **nothing in this design ever clears a value.** A toggle cannot be cleared at all, which is half the reason it was chosen.

**Attempt 3 killed the last design with no logic in the flows.** Fabric parses the query string strictly enough to reject an empty one, so *"no suffix"* cannot be expressed as any string. It has to be expressed as **absence**, and only an expression produces absence.

So:

| Phase | Toggle | URL it produces |
|---|---|---|
| Private preview — today | **No** | `…/replaceByPolicy` |
| Public preview | **Yes** | `…/replaceByPolicy?beta=true` |
| GA | **No** | `…/replaceByPolicy` |

> **If the connector ever hands the toggle over as text rather than a boolean**, the expression becomes `@{if(equals(string(parameters('PolicyApiBeta (ubsppcoe_PolicyApiBeta)')), 'True'), '?beta=true', '')}`. §3.2 is where that is discovered — in one Compose, not in six URLs.

### 3.2. Prove the expression resolves — two minutes, before editing six flows

A throwaway **instant** flow, created **inside the solution**, with a single **Compose**:

```
@{if(parameters('PolicyApiBeta (ubsppcoe_PolicyApiBeta)'), '?beta=true', '')}
```

That is the exact expression the six call sites use. Run it with the toggle **No**: **Succeeded, empty output**. Flip it to **Yes** and run again: output `?beta=true`. Set it back to **No**, and delete the flow.

> **The second run doubles as the stale-value check.** If flipping to Yes still returns empty, the value change did not reach the flow — which is the failure §5.2.1a is about, found before six flows depend on it.

> **Do this before edit 1, not after edit 6.** It is the same failure in one place instead of six, and it is the failure you have already met once.

### 3.3. How to change the toggle

The whole operation, at every phase. **This is the entire switch** — there is nothing else to do to move the estate between the GA and beta routes.

1. [make.powerapps.com](https://make.powerapps.com) → **Solutions** → the policy solution.
2. Open **`PolicyApiBeta`**.
3. Set **Current Value** — **not** Default Value — to **Yes** or **No**.
4. **Save**.
5. Repeat in **every** environment.
6. Verify with §3.2, then §5.4.

| When | Set it to |
|---|---|
| Today — private preview | **No** |
| The day the API enters **public preview** | **Yes** |
| The day the API reaches **GA** | **No** |

> **Leave the Default Value at No permanently.** It is the fallback a fresh environment inherits when an import skips the prompt, and *No* is the state that matches the API for all but the public-preview window.

> **Never clear the value, in either direction.** A cleared value was observed to be silently ignored — the flow keeps the previous one (§3.1). Setting `No` and clearing look identical on screen and are not.

> **No flow is opened, saved, exported or imported.** If a switch ever seems to need that, the value did not take effect — §5.2.1a, not a flow edit.

---

## 4. How a call site changes

The expression goes at the **very end** of the URL, after the last path segment, inside the same expression box.

**This is the snippet**, identical at all six call sites:

```
@{if(parameters('PolicyApiBeta (ubsppcoe_PolicyApiBeta)'), '?beta=true', '')}
```

It reads: *if the toggle is Yes, append `?beta=true`; otherwise append nothing.*

**Before** — call 1, [RebuildCapacityPolicyRules](../bau/RebuildCapacityPolicyRules.md) Step 9:

```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{variables('policySetId')}/policyRules/replaceByPolicy
```

**After:**

```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{variables('policySetId')}/policyRules/replaceByPolicy@{if(parameters('PolicyApiBeta (ubsppcoe_PolicyApiBeta)'), '?beta=true', '')}
```

Nothing else about the action changes — **method, headers, body, Asynchronous Pattern and Retry Policy all stay exactly as documented**. The five other call sites take the identical treatment: append the snippet, nothing more.

> **Build the expression with the variable inserted from the dynamic-content picker, never typed.** A typed `parameters('…')` creates the reference without the declaration in the flow's `parameters` block, and the run fails with *The workflow parameter … is not found* — while the expression on screen looks perfectly correct. [CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md) §8.11 has the full diagnosis and the fix.
>
> **Practical order in the expression editor:** type `if(`, pick **PolicyApiBeta** from the **Environment variable** section, then type `, '?beta=true', '')`.

### The one rule that has to be stated

**The snippet must be last, and the URL it is appended to must have no query string of its own.** All six call sites in §2 satisfy that today. Two places could break it:

| Case | Wrong | Right |
|---|---|---|
| `activate` with `allowReplace` — see [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md) §8c and [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md) §6 | `…/activate?allowReplace=True` + the snippet → `…?allowReplace=True?beta=true` | `…/activate?allowReplace=True@{if(parameters('PolicyApiBeta (ubsppcoe_PolicyApiBeta)'), '&beta=true', '')}` |
| A list call with `?recursive=true` — only in [discarded](../discarded/SyncCapacityPolicySets.md), not built | `…/policySets?recursive=true?beta=true` | Same form — `&beta=true` instead of `?beta=true` |

**No built flow passes `allowReplace` today** — `InitializeCapacityPolicySet` §8c refuses it deliberately, and surfacing `PolicySetActivationConflict` to a human is the intended behaviour. So that form is documented and **not used**. Whoever first passes `allowReplace` owns applying it.

> **The `&` variant is the one place the literal appears twice in a flow** — a second reason the value is a toggle rather than a string: a Text variable could not have produced both forms without more expression logic than either is worth.

> Two `?` in one URL is not a syntax error Fabric rejects politely — and **the service has already been shown to be strict about the query string**, rejecting `…/activate?` outright with a `400` (§3.1). Expect it to be equally unforgiving here.

---

## 5. The list of changes

### 5.1. Now, before public preview — the whole job, done inert

| # | Change | Where |
|---|---|---|
| 1 | ~~**Create the environment variable**~~ — **done 2026-09-22.** `ubsppcoe_PolicyApiBeta`, Two options, Default and Current both **No**, expression proven on `Activate` (§3.1). **Delete the superseded `ubsppcoe_PolicyApiSuffix`** | The policy solution |
| 2 | Append the snippet to the **six** actions in §2, building it from the picker — **step by step in §5.1.1** | Four flows, in the customer environment |
| 3 | Save each flow, then **export the solution and confirm** each has the `PolicyApiBeta (ubsppcoe_PolicyApiBeta)` entry in `definition.parameters` | Six actions, four flows |
| 4 | Run the §5.4 verification with the toggle at **No** — behaviour must be identical to today | Customer environment |
| 5 | ~~Update the **flow documents**~~ — **done 2026-09-22.** Six URL rows, plus the variable in each flow's prerequisites | `bau/`, `migration/` — the six files in §2 |
| 6 | ~~Update **five → six environment variables** everywhere the count appears~~ — **done 2026-09-22** | See the table below |
| 7 | ~~Add the variable to the config table~~ — **done 2026-09-22** | [CAPACITY-POLICY-FLOWS.md](CAPACITY-POLICY-FLOWS.md) §6 |
| 8 | ~~Link this document from the docs index~~ — **done 2026-09-22** | [README.md](../README.md) *Where to start* |

**Steps 2–4 are the only work left, and all of it is in the customer environment.** Every document in the repository now describes the toggle; no flow has been edited yet.

**The count of five was asserted in eight places.** All are now six:

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

**With the toggle at No, the snippet resolves to nothing and every URL below is byte-for-byte what it is today.** The edits are genuinely inert — as proven on `Activate` already (§3.1) — which is why they can be done in working hours and verified long before public preview forces the issue.

**Do §3.2 first.** If the variable does not resolve, all six edits fail at runtime the moment they are saved — that is the *value was not found* error from 2026-09-22, multiplied by six, and flows referencing it cannot be published at all.

**Then do edit 1 and verify it (§5.4 step 2) before doing the other five.** It is the same edit six times; proving it once on the flow that matters most is cheaper than discovering a mistyped expression on the sixth.

##### The procedure — identical for all six

1. **Solutions** → the policy solution → the flow → **Edit**. **Never from *My flows*** — a flow opened there cannot see the solution's environment variables, and the picker below will not offer one.
2. Expand the action named below, and click into **URL of the request**.
3. Put the cursor at the **very end** of the existing URL. No space, no slash, nothing after it.
4. Open the **expression** editor and build the snippet from §4: type `if(`, insert **PolicyApiBeta** from the **Environment variable** section of dynamic content, then type `, '?beta=true', '')`.
5. Check the result matches §4 exactly, and that it is the last thing in the box.
6. **Save.** Then reopen the flow and look at the URL again — if the snippet is not there, the save did not take.
7. **Touch nothing else.** Method, headers, body, **Asynchronous Pattern**, **Retry Policy** and **Configure run after** all stay exactly as they are.

> **Step 4 is the whole procedure.** Typing `parameters('PolicyApiBeta (ubsppcoe_PolicyApiBeta)')` by hand produces an expression that looks right, saves without complaint, and fails at runtime with *The workflow parameter … is not found* — because the designer only writes the declaration into `definition.parameters` when it resolves the reference **from the picker, against a variable that existed when the flow was opened**. See [CAPACITY-POLICY-TABLES.md](CAPACITY-POLICY-TABLES.md) §8.11.
>
> **The variable was created today, so every flow open before that is stale.** Close any flow you already had open and reopen it, or the picker will not list `PolicyApiBeta` at all.

##### Edit 1 — [RebuildCapacityPolicyRules](../bau/RebuildCapacityPolicyRules.md), Step 9, action `Replace_rules`

**Before:**
```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{variables('policySetId')}/policyRules/replaceByPolicy
```
**After:**
```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{variables('policySetId')}/policyRules/replaceByPolicy@{if(parameters('PolicyApiBeta (ubsppcoe_PolicyApiBeta)'), '?beta=true', '')}
```

**This is the one that matters.** It is the only writer of rules, and [AddWorkspaceToPolicy](../bau/AddWorkspaceToPolicy.md), [RemoveWorkspaceFromPolicy](../bau/RemoveWorkspaceFromPolicy.md), [RebuildOnExceptionChange](../bau/RebuildOnExceptionChange.md), [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md) 8b and [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md) all reach Fabric through it. **Five callers, one edit** — and none of the five needs touching.

##### Edit 2 — [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md), Step 6, action `Create_policy_set`

**Before:**
```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets
```
**After:**
```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets@{if(parameters('PolicyApiBeta (ubsppcoe_PolicyApiBeta)'), '?beta=true', '')}
```

**Leave Asynchronous Pattern *Off*.** It is off deliberately — Step 6's note explains why turning it on loses the policy set ID. It is in the same ⋯ → **Settings** panel people open while poking at an action they are editing.

##### Edit 3 — [InitializeCapacityPolicySet](../bau/InitializeCapacityPolicySet.md), Step 8c, action `Activate`

**Before:**
```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{variables('policySetId')}/activate
```
**After:**
```
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{variables('policySetId')}/activate@{if(parameters('PolicyApiBeta (ubsppcoe_PolicyApiBeta)'), '?beta=true', '')}
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
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{first(body('Get_policy_row')?['value'])?['ubsppcoe_policysetid']}@{if(parameters('PolicyApiBeta (ubsppcoe_PolicyApiBeta)'), '?beta=true', '')}
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
https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{items('For_each_policy')?['ubsppcoe_policysetid']}/activate@{if(parameters('PolicyApiBeta (ubsppcoe_PolicyApiBeta)'), '?beta=true', '')}
```

> ### Edits 5 and 6 may not exist any more, and that is fine
>
> Both flows are **deleted after cutover** by their own documents, along with `MIG_RegisterAllCapacityPolicySets`. If they are already gone, there are **four** edits, not six, and nothing is missed: [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md) is the one `MIG_` flow that is kept, and it reaches Fabric only through edit 1.
>
> **If they still exist, edit them.** A migration flow that is still in the solution will be run by somebody eventually — that is the reason its own document gives for deleting it — and one that silently calls a dead route during public preview fails halfway through an estate-wide activation.

##### When all of them are done

| Check | How |
|---|---|
| Every edit saved | Reopen each flow and read the URL. Six URLs, six snippets |
| The declaration is real, not just the expression | Export the solution, open each flow's JSON, confirm a `"PolicyApiBeta (ubsppcoe_PolicyApiBeta)"` key in `definition.parameters` — **this is the check that catches a typed expression**, and it is §5.1 step 3 |
| Behaviour is unchanged | §5.4, with the toggle still **No** |
| The flow documents match the flows | §5.1 step 5 — the URL row in each of the six action tables |

### 5.2. At public preview — the switch

**Assume the old route dies the moment the new one goes live** (§6 Q5). Between the service flipping and somebody setting the value, every call in §2 fails.

| # | Change |
|---|---|
| 1 | **Get the flip date from the product team** and hold the day. The value change is two minutes; knowing when to make it is the hard part |
| 2 | Set `ubsppcoe_PolicyApiBeta` to **Yes**, in **every** environment, on that day — click path in §3.3 |
| 3 | **Prove the change took effect** — §5.2.1a. Do not skip this one |
| 4 | Run the §5.4 verification |
| 5 | **Clean up the window** — §5.2.1 |

**No flow is opened. No solution is exported or imported.** That is the whole return on this exercise.

> **Do it in every environment at once.** A dev environment left on **No** fails silently until the next person tests there and concludes their own change broke it.

#### 5.2.1a. A changed value is not a value in use — check it

**Clearing a value was observed not to take effect at all** (§3.1), so a flipped toggle cannot be assumed either. Run the §3.2 Compose flow and read the output: **`?beta=true`, not blank**.

If it still comes back blank:

| Try | Detail |
|---|---|
| 1 | Reopen the variable in the solution and confirm the **Current Value**, not only the Default Value, reads **Yes** |
| 2 | Turn the affected flow **Off** and back **On** — that re-reads the parameter |
| 3 | Open the flow from the solution and **Save** it again |

> **This is the failure that would make switch day look fine and be wrong.** The toggle reads **Yes** on screen, the flows keep sending the GA URL, and every policy call fails against the beta service with nothing naming the cause.

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

**Set the toggle back to **No**** — §3.3, same three clicks. Then run §5.2.1a and §5.4, exactly as at public preview.

> **A toggle cannot be cleared, which is why it was chosen** — the 2026-09-22 finding that a cleared value is silently ignored (§3.1) would otherwise have applied to this step, and left the estate on the beta route while the screen said otherwise.

**Do not delete the variable.** A fourth phase is not impossible, and the variable costs nothing. Deleting it costs six flow edits and a run of *The workflow parameter … is not found*.

### 5.4. Verification, all three times

Same sequence each time. It exercises four of the six call sites.

1. **`GET /v1/capacities`** from a throwaway manual flow — confirms the connection and identity before anything writes. [CAPACITY-POLICY-FLOWS.md](CAPACITY-POLICY-FLOWS.md) §8 step 3 describes it.
2. **`RebuildCapacityPolicyRules` against one non-production capacity** — call 1. A `200` and the expected rule count. **On the first run this also proves the snippet resolves to nothing**, leaving the URL exactly as it was (§3.1).
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
> A static API where only the route moves is the one case a toggle fully solves. Both transitions become a Yes/No change, and **no flow is ever reopened for public preview or GA**. Had the body changed, the six actions would need editing anyway and the variable would have saved only half the work.

> ### Q5 is the answer that shapes the day
>
> **Assume the old route stops answering the moment the new one starts.** There is then a window — from the service flipping to somebody setting the value — in which every call in §2 fails. §5.2 is written for that.

> **Q6 noted, with one consequence.** The scripts call the same routes, so one run by hand during public preview will fail the same way. If anyone does run `activate_policy_set.ps1` or its siblings in that period, the parameter goes on by hand. They remain the authority for **payloads**, which Q4 confirms are not changing.

---

## 7. What this does not solve

**Current values do not travel reliably with a solution export — default values do.** Same caveat as the other five ([DEPLOYMENT-ALM.md](DEPLOYMENT-ALM.md) §2, [HANDOVER-REGISTER.md](HANDOVER-REGISTER.md) E1), mitigated here by the **Default Value of No**: an environment that imports without a prompt lands on today's behaviour rather than on no value at all — which, per §3.1, is the state that will not publish.

**The import that still bites** is one arriving **during public preview**: the default says No, nobody sets the toggle, and every policy call quietly goes to the dead GA route while the import reports success.

**Nothing detects a wrong setting.** There is no drift scan and no scheduled rebuild ([README.md](../README.md)), so a stale toggle surfaces when somebody provisions or retires a capacity — which may be days later. The detection is the §5.4 run, performed by a human, on the day the toggle changes.

**Three states, three different failures** — and only one of them is loud:

| State | What happens |
|---|---|
| **No value at all** — neither Default nor Current set | *value was not found*, and **flows referencing it cannot be published**. The loud one, met 2026-09-22 — which is why both are set |
| **No, during public preview** | A valid *GA* URL against a beta service. Fails at Fabric, per capacity, with nothing naming the cause |
| **Yes, at GA** | A valid *beta* URL against a GA service. Same shape of failure, in the other direction |

**The second and third are the reason §5.2 and §5.3 both end in a verification run.** Neither announces itself, and both look like the flow is broken rather than the setting.

> **What the toggle removed for good:** a mistyped value. Three of the four designs in §3.1 failed on *what was in the box*, and a Yes/No control has no box. The two failures left are both *which way it is pointing*, and both are caught by one run.
