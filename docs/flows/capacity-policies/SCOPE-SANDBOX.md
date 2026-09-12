# Sandbox — Scopes, try/catch and `result()`

A throwaway flow for learning how Scope actions and `result()` behave, before wiring them into [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) Step 7.

> **Disposable.** Name it `ZZ_ScopeSandbox`, build it in a **non-production** solution or outside a solution entirely, and delete it when the questions below are answered. It touches no Dataverse table and calls nothing real.

**Time budget:** the build is about ten minutes. The experiments are the point.

---

## Why this exists

Four things about Scopes are load-bearing in the real flow and none of them are reliably documented:

| # | Question | Why it matters |
|---|---|---|
| 1 | What exactly does `result()` return? | The Catch writes its output to a Dataverse column. Wrong shape, wrong column contents |
| 2 | Does a Scope report **Failed** when an action inside it failed but a later action handled it with *run after → has failed*? | **This decides whether the Catch is reachable at all.** It is the entire basis of the Case A / Case B split in the real flow |
| 3 | Does `Terminate` inside the Try let the Catch run? | The real flow puts a Terminate in the Catch and claims one in the Try would be wrong |
| 4 | Can `Initialize variable` live inside a Scope? | Five of them sit above the Try on the strength of this |
| 5 | Does a Catch that runs and succeeds make the **run** report green? | Decides whether the Catch needs a `Terminate` — and a Terminate there stops `Compose_result` running |

**Answered so far:** 2 (E3 — the Scope reports Succeeded, the Catch is skipped), 3 (E4 — the Catch never runs, and the scope goes Aborted) and 5 (E7 — **yes, the run goes green**, so the Catch's Terminate is essential). Questions 1 and 4 are confirmation only; run E1 and E5 when convenient.

---

## Build

**New** → **Instant cloud flow** → **Manually trigger a flow** → name `ZZ_ScopeSandbox`. No inputs.

### 1. Variables — at the top level

| Rename to | Name | Type | Value |
|---|---|---|---|
| `Initialize_shouldFail` | `shouldFail` | **Boolean** | `true` |
| `Initialize_handleIt` | `handleIt` | **Boolean** | `false` |
| `Initialize_note` | `note` | String | *(empty)* |

These two booleans are the experiment switches. You will flip them and re-run rather than rebuilding anything.

### 2. `Scope_try` — **Control** → **Scope**

Inside it, in order:

| # | Action | Configuration |
|---|---|---|
| 1 | `Compose_first` — **Compose** | `'step one ok'` |
| 2 | `Condition_should_fail` — **Condition** | `variables('shouldFail')` is equal to `true` |
| 3 | └ **Yes** → `Compose_boom` — **Compose** | `div(1, 0)` |
| 4 | └ **Yes** → `Compose_after_boom` — **Compose** | `'handled'` |
| 5 | `Compose_last` — **Compose** | `'step last ok'` |

**`div(1, 0)` is the deliberate failure.** It fails at expression evaluation, so it needs no connector, no network and no permissions, and it fails the same way every time. Type it into the expression box — the designer will accept it without complaint and fail at runtime.

**`Compose_after_boom` is the switch for question 2.** Select it → ⋯ → **Configure run after** → `Compose_boom`:

- For the **unhandled** case: leave *is successful* ticked only. It will be skipped when the boom fires.
- For the **handled** case: untick *is successful*, tick **has failed**. It now runs *because* the boom failed — a hand-rolled catch, exactly like `Condition_rebuild_ok` in the real flow.

Flip this with the `handleIt` variable in your notes, not in the flow — the variable is just a label so the run history tells you which configuration produced which result.

### 3. `Scope_catch` — **Control** → **Scope**

⋯ → **Configure run after** on `Scope_try`: tick **has failed**, **is skipped**, **has timed out**. Untick *is successful*.

Inside it:

| # | Action | Configuration |
|---|---|---|
| 1 | `Compose_raw_result` — **Compose** | `result('Scope_try')` |
| 2 | `Filter_failed` — **Filter array** | From: `result('Scope_try')` · Condition: `item()?['status']` **is equal to** `Failed` |
| 3 | `Compose_failed_name` — **Compose** | `first(body('Filter_failed'))?['name']` |
| 4 | `Compose_failed_message` — **Compose** | `first(body('Filter_failed'))?['error']?['message']` |
| 5 | `Compose_failed_code` — **Compose** | `first(body('Filter_failed'))?['error']?['code']` |

> ### `filter()` is not an expression in this language
>
> There is no `filter(array, item => ...)`. The Workflow Definition Language has `first`, `last`, `take`, `skip`, `union`, `intersection` and `join`, and **no lambda syntax at all**. Filtering an array is the **Filter array** *action*, which is why step 2 above is an action and not a one-liner.
>
> This is worth internalising before writing the real Catch, because the wrong version looks plausible and the designer rejects it only when you save.

### 4. `Compose_summary` — top level, after both scopes

⋯ → **Configure run after**: tick **all four** statuses on **both** `Scope_try` and `Scope_catch`.

```
try=@{result('Scope_try')} | note=@{variables('note')}
```

**All four statuses, or this never runs.** `Scope_catch` is skipped on a healthy run, and an action that runs after it on *is successful* alone is skipped too. This is the same trap as `Compose_result` in the real flow.

---

## Experiments

Run each with **Test** → **Manually** → **Run flow**, then open the run and read the actions.

### E1 — Happy path

`shouldFail` = `false`.

> **Answered 2026-09-12, and the headline result was not the expected one.**

| Observe | Result |
|---|---|
| `Scope_try` status | Succeeded |
| `Scope_catch` status | **Skipped** |
| `Compose_summary` | **Ran** — confirms the four-status configuration |
| `result('Scope_try')` entry count | **3, not 5** |

### `result()` does not recurse — the single most important finding here

The scope holds five actions. `result('Scope_try')` returned **three**: `Compose`, `Condition` and `Compose_last`. The two actions inside the Condition's Yes branch — `Compose_boom` and `Compose_after_boom` — **are absent entirely**, not even present as skipped entries.

> **`result('X')` returns the *immediate children* of `X` and nothing deeper.** A nested container appears as one entry; whatever happened inside it does not appear at all.

This is what the real Catch has to be written around, because in [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) the action most likely to fail — `Run_rebuild` — sits **three Conditions deep** inside `Scope_try`. `result('Scope_try')` will never name it. See E8.

### The entry shape, from a real run

```json
{
  "name": "Compose",
  "inputs": "'step one ok'",
  "outputs": "'step one ok'",
  "startTime": "2026-09-12T19:38:26.4617007Z",
  "endTime": "2026-09-12T19:38:26.4620149Z",
  "trackingId": "…",
  "clientTrackingId": "…",
  "clientKeywords": ["testFlow,…"],
  "code": "OK",
  "status": "Succeeded"
}
```

Three things to take from it:

**`inputs` and `outputs` are included verbatim.** For a `Compose` of a short string that is harmless. For `Get_workspace_row` it is the Dataverse query **and every row it returned**. This is why the real Catch extracts fields rather than writing `result()` whole — see the cookbook.

**The shape varies by action type.** The `Condition` entry carried `"inputs": {"expressionResult": false}` and **no `code` field at all**, where the `Compose` entries had `"code": "OK"`. Any expression reading these must use `?[]` throughout and coalesce anything it displays.

**`name` is the internal action name.** The first Compose reported as `"Compose"` because it had not been renamed — the display name is not what appears here, and internal names keep their underscores. Rename actions *before* writing anything that filters on `name`.

### E6 — `result()` from outside, on a healthy scope

**Confirmed 2026-09-12.** `Compose_summary` ran on the happy path with `Scope_catch` skipped, and `result('Scope_try')` resolved normally. `result()` works from **any** action outside the scope, not only from a catch block — it is a general "tell me about that container" function.

### E2 — Unhandled failure

`shouldFail` = `true`, and `Compose_after_boom` set to run after **is successful** only.

| Observe | Expect |
|---|---|
| `Scope_try` status | **Failed** |
| `Scope_catch` | Runs |
| `Compose_failed_name` | **`Condition`, not `Compose_boom`** — see E1 and E8 |
| `Compose_failed_message` | **Probably blank.** The divide-by-zero text belongs to a nested action |
| Overall run | **Succeeded — green.** See E7; this surprised the author of this document |

**The middle two rows were originally predicted as `Compose_boom` and the divide-by-zero text, and E1 disproved that** before this experiment was re-run. `Compose_boom` is inside a Condition, and `result()` does not recurse. **E8 is the experiment that pins down what actually appears.**

**The last row is the one to stare at.** A red scope, a caught error, and a run the portal reports as *"Your flow ran successfully."* The `Terminate` in the real Catch is what turns that red, and it is not optional — E7 covers the consequences.

### E3 — Handled failure ← **the important one**

`shouldFail` = `true`, and `Compose_after_boom` set to run after **has failed**.

> **Answered 2026-09-12. `Scope_try` reported Succeeded and `Scope_catch` was skipped.**

| Observe | Result |
|---|---|
| `Compose_boom` status | Failed |
| `Compose_after_boom` status | Succeeded |
| **`Scope_try` status** | **Succeeded** |
| **`Scope_catch`** | **Skipped** |

**A failure handled inside a Scope is invisible to the Catch.** The scope's status reflects whether anything was left unhandled, not whether anything went wrong — one action configured to run after *has failed* is enough to make the whole scope report clean.

So the rule this establishes, and it is the one to carry back into every flow that uses this pattern:

> **No action inside a Try scope may be configured to run after *has failed*.** Each one silently disables the Catch for whatever path it covers. The two mechanisms do not layer — the inner one wins, and it wins quietly.

For [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) this settles Step 5: unticking **has failed** on `Condition_rebuild_ok` is **essential, not optional**. Left ticked, a hard failure of the child flow would be absorbed by the Condition, `Scope_try` would report Succeeded, and the Catch would never fire — dead code for the single case it was built to handle, and a run history that looks healthy while the error reaches no table at all.

**Also worth noting:** this is why E2 and E3 must both be run. They differ by one checkbox and produce opposite outcomes, and neither on its own tells you that the checkbox is what did it.

### E4 — Terminate inside the Try

Temporarily add a `Terminate` (status **Failed**) as the last action inside `Scope_try`.

> **Answered 2026-09-12.**

| Observe | Result |
|---|---|
| Actions before the Terminate | Green, including the red `Compose_boom` and whatever handled it |
| `Terminate` itself | Ran |
| **`Scope_try` status** | **Grey ✕ — Aborted.** Not Failed, not Succeeded |
| **`Scope_catch`** | **Never evaluated** |
| Overall run | **Failed** — taken from the Terminate's *status* parameter |

**Terminate ends the run, it does not end the scope.** Nothing downstream is evaluated — no `runAfter` is even considered — so the Catch cannot fire no matter how it is configured.

There is a second reason it could never work, worth knowing because it applies to any container: **Aborted is not one of the four `runAfter` statuses.** The options are Succeeded, Failed, Skipped and TimedOut. Even if the run had continued, nothing can be configured to catch an aborted scope.

**The run's colour comes from the Terminate, not from the failure.** Set that Terminate to status *Succeeded* and the run reports Succeeded with a red `Compose_boom` sitting inside it. That is the trap: a flow that swallowed a genuine error and reports green.

**Delete the Terminate afterwards** or every later experiment ends early.

### E7 — Does a successful Catch turn the run green?

`shouldFail` = `true`, `Compose_after_boom` back on *is successful* only (the E2 configuration), **and no Terminate anywhere**.

> **Answered 2026-09-12. The run reported Succeeded — *"Your flow ran successfully."***

| Observe | Result |
|---|---|
| `Scope_try` status | **Failed** (red) |
| `Scope_catch` status | Succeeded |
| **Overall run status** | **Succeeded — green** |

**The Terminate in the real Catch is essential.** Without it, a caught error produces a run the portal calls successful, no owner notification, and nothing in the failure list.

### The rule E3 and E7 together establish

> **A handled failure reports clean, at every level.** Handle it inside a Scope and the Scope reports Succeeded (E3). Handle a Scope's failure with a Catch and the *run* reports Succeeded (E7). It is the same rule applied recursively, and each application hides the error one level further up.

The consequence is worth stating bluntly, because it inverts the reason people reach for try/catch in the first place:

> **A try/catch without a Terminate is worse than no try/catch at all.** With no scopes, an unhandled failure fails the run loudly and someone finds out. Add a Catch that only logs, and the identical failure produces a green run. You have not added error handling — you have converted a visible failure into an invisible one, and paid two actions for the privilege.

So whatever a Catch does, **it must end by making the failure visible**: `Terminate` with status Failed, or something equivalent that a human actually reads. Writing to a Dataverse error column is not that, on its own — nobody watches a column.

### E5 — `Initialize variable` inside a Scope

Drag any `Initialize variable` into `Scope_try` and press **Save**.

> **Confirmed 2026-09-12. Save fails validation.** This is why the five variables in the real flow stay above `Scope_try`.

### E8 — How does a *nested* failure appear?

`shouldFail` = `true`, `Compose_after_boom` on *is successful* only, no Terminate.

> **Answered 2026-09-12. The container reports Failed and carries an error — and that error says nothing.**

| Observe | Result |
|---|---|
| Entries in `result('Scope_try')` | **3** — `Compose`, `Condition`, `Compose_last` |
| An entry named `Compose_boom`? | **No.** Confirms E1 |
| The `Condition` entry's `status` | **Failed**, `code: ActionFailed` |
| Its `error.message` | **`"An action failed. No dependent actions succeeded."`** |
| `Compose_failed_name` | `Condition` |
| `Compose_failed_message` | the boilerplate above |

### The container's error is generic, and that is worse than blank

```json
{
  "name": "Condition",
  "code": "ActionFailed",
  "status": "Failed",
  "error": {
    "code": "ActionFailed",
    "message": "An action failed. No dependent actions succeeded."
  }
}
```

No action name. No divide-by-zero. Nothing that distinguishes this failure from any other failure anywhere inside that container.

**A blank message would have been safer.** Blank is obviously broken and someone investigates the expression. *"An action failed. No dependent actions succeeded."* looks like a real diagnostic, reads like the system told you something, and will be copied into tickets for months before anyone notices it is the same sentence every time.

> **The expression works and the output is useless.** Those are different things, and only a test like this one separates them. Anything built on `result()` should be judged on whether a human could act on the string, not on whether the expression resolved.

### Skipped actions also carry an `error`

`Compose_last` was skipped and still has one — and unlike the Condition's, **it is genuinely informative**:

```json
{
  "name": "Compose_last",
  "code": "ActionSkipped",
  "status": "Skipped",
  "error": {
    "code": "ActionConditionFailed",
    "message": "The execution of template action 'Compose_last' is skipped: the 'runAfter' condition for action 'Condition' is not satisfied. Expected status values 'Succeeded' and actual value 'Failed'."
  }
}
```

Two consequences:

**Filter on `status` equals `Failed`, never on the presence of `error`.** Half the entries in a failed run carry one. A filter written the obvious way would return skipped actions alongside the real failure, and `first()` might well pick a skipped one.

**A skipped entry has no `inputs` or `outputs`** — `Compose_last` has neither, where the succeeded `Compose` has both. One more reason every read uses `?[]`.

### E6 — `result()` on a healthy scope, from the Catch

Not directly observable — the Catch does not run when the Try succeeds. `Compose_summary` covers it instead, which is why that action calls `result('Scope_try')` too. **Confirmed under E1.**

---

## Round two — testing the expressions that will actually ship

E1–E8 characterised the platform. These three test the **specific expressions written into [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) Step 7b**, which have never been run. Build the Catch in the sandbox exactly as that document specifies, then run the three scenarios below.

The Catch is the worst place in a flow to discover a bad expression: it executes only when something else has already gone wrong, so a defect there stays invisible until the day it matters, and then it destroys the evidence for the original failure.

### E9 — The real message expression, end to end

Set `Compose_failed_message` to the string the real flow will use:

```
concat(coalesce(first(body('Filter_failed'))?['name'], 'unknown'), ': ', coalesce(first(body('Filter_failed'))?['error']?['message'], 'no message'), ' | run ', workflow()?['run']?['name'])
```

Run the E8 configuration.

> **Answered 2026-09-12. Every expression resolved. The output is exactly as predicted — a pointer, not a diagnosis.**

| Observe | Result |
|---|---|
| **Filter array** with `item()?['status']` *is equal to* `Failed` | **Works.** 3 entries in, 1 out |
| Did it exclude the **Skipped** entry? | **Yes** — `Compose_last` filtered out despite carrying an `error` |
| `length(body('Filter_failed'))` | 1 |
| `workflow()?['run']?['name']` | **`08584123630290374015221423576CU18`** — a usable run ID |
| Final composed string | `Condition: An action failed. No dependent actions succeeded. \| run 08584123630290374015221423576CU18` |

**The filter result confirms the advice empirically.** `Compose_last` was Skipped and carried an `ActionConditionFailed` error, and filtering on `status` correctly dropped it. A filter written on the presence of `error` would have returned two entries.

### Three properties worth keeping

**The run ID is real and usable.** It is the same value that appears as `clientTrackingId` on every entry, and it is the identifier in the portal's run URL. Pasting it into the run history finds the run.

**`workflow()` does not depend on the filter.** It resolves regardless of whether anything matched — so even on a path where `Filter_failed` is empty, the message still carries a usable pointer. Given E11 is still open, that is the one part of the string guaranteed to survive.

> **A third property was claimed here and is false — see E10.** This section originally asserted that `result()` returns entries in execution order, so `first()` would land on the root cause. **It does not.** E10's output shows the array ordered `Condition, Compose_last, Compose_boom, Compose` while the `startTime` values run `Compose_boom, Compose, Condition, Compose_last`. The claim survived a passing test because there was only one failed entry to choose from, which is exactly how an ordering assumption gets embedded without being noticed.

**Length is not a problem.** The string is about 100 characters, against a 2000-character `ubsppcoe_lasterror` column. E10's real error message is closer to 200, still comfortable.

### E10 — Does flattening actually help?

Move `Compose_boom` **out** of the Condition so it is an immediate child of `Scope_try`. Change nothing else. Re-run.

> **Answered 2026-09-12. Yes — emphatically. Flattening turns the signpost into a diagnosis.**

| Observe | Result |
|---|---|
| `Compose_failed_name` | **`Compose_boom`** — the actual culprit |
| `Compose_failed_message` | **The real error**, quoted below |
| `Scope_try` | Failed |
| Overall run | Succeeded — green again, confirming E7 |

```
Compose_boom: Unable to process template language expressions in action 'Compose_boom'
inputs at line '0' and column '0': 'Attempt to divide an integral or decimal value by
zero in function 'div'.'. | run 08584123627027593468229893810CU25
```

Compare with the nested version from E8:

```
Condition: An action failed. No dependent actions succeeded. | run 08584…
```

**Same flow, same failure, same expressions. The only difference is one level of nesting**, and it is the difference between a column somebody can act on and a column nobody can.

So the flattening option in [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) Step 7b is now **evidence-backed rather than inferred**. It does not make it the right call — restructuring a working flow still has to be justified on its own.

> **Decided 2026-09-12: `Scope_try` is not being flattened.** The result above stands as evidence of what flattening buys, not as a recommendation. Do not read this experiment as an argument for restructuring the real flow — that was considered, on exactly this evidence, and declined. See Step 7b.

### `result()` order is not execution order — do not rely on it

This run is the counter-example. The array came back in this order:

| Array position | Action | `startTime` |
|---|---|---|
| 1 | `Condition` | `…:22.9158744` |
| 2 | `Compose_last` | `…:22.9173047` |
| 3 | `Compose_boom` | `…:22.9096041` ← **earliest** |
| 4 | `Compose` | `…:22.9117513` |

Execution order was `Compose_boom → Compose → Condition → Compose_last`. The array is in none of: execution order, reverse execution order, or alphabetical order.

**Consequence: `first(body('Filter_failed'))` picks an arbitrary failed entry, not the first one to fail.** It is safe here only because a sequential flow produces exactly **one** `Failed` entry — whatever broke first — and everything after it is `Skipped`, which the filter excludes. With one match, order cannot matter.

**Where it would bite:** parallel branches, or anything that lets two actions fail in the same scope. Neither exists in [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md), so the expression is safe **as long as the flow stays sequential**. If a parallel branch is ever added inside `Scope_try`, revisit this — the Catch will start reporting a random one of the failures with no indication it is choosing.

### Two smaller details from this run

**`code` and `error.code` are different values.** `Compose_boom` reported `"code": "BadRequest"` at the top level and `"error": {"code": "InvalidTemplate"}` inside. Anything falling back from one to the other should expect two different vocabularies.

**The error message already names the action**, so the `name:` prefix in the composed string is redundant for expression failures. Harmless, and worth keeping — connector failures do not all name themselves.

### E11 — What happens when nothing matched

The Catch fires on **Failed, Skipped and TimedOut**, but `Filter_failed` only ever matches `Failed`. On the other two paths it returns an empty array, and every expression above then runs against `first([])`.

Force it: put a `Compose` with `div(1,0)` at the **top level, above `Scope_try`**, so the scope is *skipped* rather than failed. (An `Initialize variable` cannot fail, so it has to be a Compose.)

> **Answered 2026-09-12. Nothing throws — the guards are sufficient. But the message is worthless.**

| Observe | Result |
|---|---|
| Does `result('Scope_try')` resolve for a **skipped** scope? | **Yes** — all four children returned, every one `Skipped` |
| `first()` on an empty array | **Returns null. Does not throw** |
| Did the Catch complete? | **Yes**, cleanly |
| Composed message | `unknown: no message \| run 08584123620389337454695046314CU20` |

**No extra Condition is needed in the real Catch.** The `coalesce` wrappers cover this path, which is what they were written for.

### The message is safe and useless, which is a different bug

`unknown: no message` says nothing about what happened. The actual failure — the Compose *above* the scope — is invisible to `result('Scope_try')`, because it is not inside the scope, and no expression in the Catch can reach it.

**The run ID is the only thing carrying information on this path**, which is the clearest possible demonstration of why it belongs in the string. Without it the column would say `unknown: no message` and nothing else.

So improve the fallbacks to describe the path rather than admit defeat:

```
concat(coalesce(first(body('Filter_failed'))?['name'], 'no failed action in Scope_try'), ': ', coalesce(first(body('Filter_failed'))?['error']?['message'], 'scope was skipped or timed out'), ' | run ', workflow()?['run']?['name'])
```

That turns `unknown: no message` into a string that tells the reader the scope never ran — a genuinely different situation from an action inside it failing, and one they would otherwise have to open the run to distinguish.

**Retested 2026-09-12 with the new fallbacks, on the same skipped-scope path:**

```
no failed action in Scope_try: scope was skipped or timed out | run 08584123618164522272360067699CU30
```

Same path, same guards, nothing throws — and the column now explains itself. **This is the version in [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) Step 7b.**

**When this path actually occurs in the real flow:** a **TimedOut** scope, most likely, since a timed-out action does not carry `status: Failed`. `Skipped` needs something above `Scope_try` to fail, and the only things there are `Initialize variable` actions, which cannot.

### One more detail worth noting

`Compose_boom` was skipped with `error.code: ActionDependencyFailed` and the message *"dependant action 'Scope_try' completed with status 'Skipped'"* — an action inside the scope citing **the scope itself** as its failed dependency. That is how the platform expresses "the container never ran", and it is worth recognising in a run history rather than reading as a circular reference.

---

## What to write down

Copy this into the PR or the ticket when you are done:

```
E1 result() entry count on a 5-action scope:              3  [verified 2026-09-12]
E1 result() recurses into nested containers:             NO [verified 2026-09-12]
E1 entry carries inputs + outputs verbatim:              YES, do not write it raw to a column
E1 shape varies by action type (Condition has no code):  YES
E3 Scope_try status when the failure was handled inside:  Succeeded   [verified 2026-09-12]
E3 Scope_catch ran:                                       No          [verified 2026-09-12]
E4 Scope_try status with a Terminate inside:              Aborted     [verified 2026-09-12]
E4 Catch ran after Terminate in Try:                      No          [verified 2026-09-12]
E4 run status source:                        the Terminate's status parameter  [verified 2026-09-12]
E5 Initialize variable inside a Scope saved:              No          [verified 2026-09-12]
E6 result() readable from outside the scope:              Yes         [verified 2026-09-12]
E7 run status when the Catch ran and succeeded, no Terminate:  Succeeded  [verified 2026-09-12]
E8 nested failure appears as:      the CONTAINER, status Failed, code ActionFailed  [verified]
E8 container's error.message:      "An action failed. No dependent actions succeeded."  [verified]
E8 skipped actions also carry an error object:           Yes         [verified 2026-09-12]
E9  Filter array + first() + workflow() run ID work end to end:  Yes  [verified 2026-09-12]
E9  Filter array excluded the Skipped entry:                     Yes  [verified 2026-09-12]
E9  sample output:  "Condition: An action failed. No dependent actions succeeded. | run 08584..."
E10 flattening surfaces the real action name and error:          YES  [verified 2026-09-12]
E10 result() array order is execution order:                     NO   [verified 2026-09-12]
E10 safe only because a sequential scope yields ONE Failed entry
E11 result() resolves for a Skipped scope:                       Yes  [verified 2026-09-12]
E11 first([]) returns null rather than throwing:                 Yes  [verified 2026-09-12]
E11 Catch completed cleanly on the empty-filter path:            Yes  [verified 2026-09-12]
E11 message on that path is useless without the run ID:          confirmed
E11 rewritten fallbacks retested on the same path:               Pass [verified 2026-09-12]
```

**All eleven are answered.** The Catch as specified in [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) Step 7b is safe to build: nothing throws, the `coalesce` guards are sufficient, and no extra Condition is required.

Two results changed the design rather than confirming it. **E10** proved flattening `Scope_try` recovers the real error text, and disproved the ordering assumption recorded under E9. **E11** showed the fallback text was safe but uninformative, and it has been rewritten.

---

## Expression cookbook

Working notes for the real Catch, assuming the filter action is named `Filter_failed`:

| Want | Expression |
|---|---|
| The scope's **immediate children** | `result('Scope_try')` — **not** everything inside it |
| The failed entries | `body('Filter_failed')` — after a **Filter array** on `item()?['status']` equals `Failed` |
| First failed action's name | `first(body('Filter_failed'))?['name']` |
| First failed action's message | `first(body('Filter_failed'))?['error']?['message']` |
| First failed action's code | `first(body('Filter_failed'))?['error']?['code']` |
| **The run ID**, so the history is findable | `workflow()?['run']?['name']` |
| Did anything fail at all | `greater(length(body('Filter_failed')), 0)` |
| Drill into a nested container | `result('Condition_name')` — one level at a time, name hard-coded |

The one-line string for a text column, which cannot live in the table above because it contains a `|`:

```
concat(coalesce(first(body('Filter_failed'))?['name'], 'no failed action in Scope_try'), ': ', coalesce(first(body('Filter_failed'))?['error']?['message'], 'scope was skipped or timed out'), ' | run ', workflow()?['run']?['name'])
```

**Copy expressions from code blocks, never from table cells.** A `|` inside a markdown table has to be written `\|`, and a `\|` pasted into the designer produces an expression that saves cleanly and fails at runtime — the worst of both.

**Include the run ID.** E8 established that a nested failure yields only *"An action failed. No dependent actions succeeded."* — so the message alone cannot be acted on. The run ID is one cheap expression, it resolves independently of the filter, and it is what makes the run history reachable.

**Filter on `status`, never on the presence of `error`.** Skipped actions carry an `error` object too (E8), and E9 confirmed the status filter correctly excludes them.

**Do not depend on array order.** E10 showed `result()` is not in execution order, so `first()` returns an arbitrary failed entry. Safe only while the scope is sequential and yields exactly one.

**Never write raw `result()` to a Dataverse column.** Every succeeded entry carries `inputs` and `outputs` verbatim (E1), so on a real flow that means the query you sent and every row that came back — into a 2000-character text column, and possibly into an audit log that should not hold it. Extract `name`, `code` and `error.message`, nothing else.

**Always `coalesce` anything you display.** Entry shape varies by action type and by status: Conditions have no `code` on success, skipped actions have no `inputs` or `outputs`, succeeded actions have no `error`, and `code` and `error.code` use different vocabularies (E10).

**Remember `result()` does not recurse.** A failure inside a Condition, an Apply to each or a nested Scope is represented by its *container*, with a generic message. Flatten the scope (E10) or accept a signpost.

**`result()` is not in the expression picker.** Type it by hand; the designer accepts it and resolves it at runtime.

**Rename actions before filtering on `name`.** It returns the internal name — an unrenamed Compose reports as `Compose` (E1), and the display name never appears.

---

## Cleanup

Delete `ZZ_ScopeSandbox`. Then fold the answers into [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) Step 7 — particularly E2's field list, which determines the `Compose_error` expression, and E3, which determines whether the Step 5 note is describing a safety margin or a requirement.
