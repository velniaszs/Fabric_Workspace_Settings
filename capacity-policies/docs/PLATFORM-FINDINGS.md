# Platform findings

Verified behaviours of Power Automate, Dataverse and the Fabric policy API that this solution is built around.

**Why this document exists:** most of the design decisions in the flows look arbitrary until you know the platform behaviour behind them. Change one without reading this and the flow keeps working — it just stops reporting failures.

`E1`–`E11` refer to experiments run in a disposable sandbox flow; the method is preserved in [discarded/SCOPE-SANDBOX.md](../discarded/SCOPE-SANDBOX.md).

---

## 1. Scopes and try/catch

**A handled failure reports clean at every level.** (E3, E7) If an action fails inside a Scope and a later action runs after *has failed*, the Scope reports **Succeeded** and a Catch on *has failed* is **skipped**. Handle a Scope's failure with a Catch and the whole **run** reports success — "Your flow ran successfully" — with a red action inside it.

> **Rule: no action inside a Try scope may use *configure run after → has failed*.** It silently disables the Catch for that path. The two mechanisms do not layer; the inner one wins.

**A try/catch without a `Terminate` is worse than no try/catch.** It converts a loud failure into a green run. Every Catch must end with `Terminate` status **Failed**, or something a human actually reads. Writing an error column is not enough — nobody watches a column.

**`Terminate` inside a Try ends the run before the Catch runs.** (E4) The scope shows **Aborted** (grey X), not Failed. Aborted is not one of the four `runAfter` statuses, so nothing can catch it. **The only `Terminate` belongs at the end of the Catch.**

**`Terminate`'s *status* parameter sets the whole run's status.** `Terminate(Succeeded)` reports a green run with a red action inside it.

**A `Terminate` at the end of the Catch suppresses any top-level action after the scopes** — put the final record in the Terminate's message too.

**An action after a Catch must run after all four statuses on both scopes**, or it is skipped on healthy runs — the Catch is *Skipped*, not *Succeeded*.

**`Initialize variable` cannot go inside a Scope, Condition or Apply to each.** The designer accepts it and fails on save.

---

## 2. `result()`

**Returns immediate children only — it does not recurse.** (E1) A nested container appears as one entry; what failed inside it does not appear at all. A deeply nested failure is reported as the outermost container's name, not the culprit's. Drill down with `result('<container name>')`, one level at a time, name hard-coded.

**A container whose child failed gives boilerplate.** `status: Failed`, `code: ActionFailed`, and `error.message` = *"An action failed. No dependent actions succeeded."* — identical for every cause. The expression resolves; the output is useless, and worse than blank because it looks like a real diagnostic.

> **Always append the run ID:** `workflow()?['run']?['name']`. That is what makes the run history findable, and the run history is where the real error is.

**Flattening fixes it.** (E10) Same flow, same failure, failing action moved out of its Condition to be an immediate child of the scope → `name` is the real action and `error.message` is the real error text.

**Array order is not execution order.** (E10) Not reverse, not alphabetical — treat as unspecified. So `first(filter on Failed)` picks an **arbitrary** failure. Safe only while the scope is sequential. **A parallel branch inside the scope breaks this silently.**

**Skipped actions also carry an `error` object** (`ActionConditionFailed`). Filter on `status` equals `Failed`, **never** on the presence of `error`.

**`first([])` returns null and does not throw.** (E11) `result()` also resolves for a *Skipped* scope. So `coalesce` wrappers alone are enough in a Catch — no length check needed.

**Never write raw `result()` output to a column or log.** Each entry carries the failed action's `inputs` and `outputs` **verbatim**. Extract `name`, `code`, `error.message` only.

Other traps:

- `code` and `error.code` are different vocabularies on the same entry — e.g. `code: BadRequest` with `error.code: InvalidTemplate`
- Entry shape varies by action type: a `Condition` entry has no `code` where a `Compose` has `"code":"OK"`. Use `?[]` everywhere
- `name` is the **internal** action name, not the display name. Rename actions before filtering on it
- `result()` is absent from the expression picker — type it by hand

---

## 3. Expression language

**There is no `filter()` with lambda syntax. No lambdas at all.** Available: `first`, `last`, `take`, `skip`, `union`, `intersection`, `join`. Narrowing an array is the **Filter array** *action*, not an expression.

**`@expr` and `@{expr}` are not interchangeable.** Wrapped, a boolean becomes the string `"true"`, never equals the boolean, and a `Do until` spins to its count limit — a slow flow rather than an error.

**`\n` is not a newline.** It emits a literal backslash-n. Use `decodeUriComponent('%0A')` in a Compose, or `<br>` in an HTML mail body.

**A variable may not reference itself in its own assignment.** Use a `Compose` and then set the variable from it.

**`union(x, x)` deduplicates** — comparing `length` before and after is how you detect duplicates without a group-by, which the platform does not have.

---

## 4. Dataverse triggers and filters

**`Select columns` decides *whether the flow fires*, not what the body contains.** It is **update-only**. On the *Added* half of *Added or Modified* it is ignored and every insert is evaluated — `Filter rows` is what constrains inserts.

**Scope defaults to `User`.** At that scope the trigger only fires for changes the connection's own account made. **Set `Organization`** or the flow never fires for anyone else's edits — with no error and an empty run history.

**"To use filtering attributes your trigger must include an update event"** means `Change type` has no *Modified* in it. The error points at the filters; the fault is the dropdown.

**Lookup filters use `_x_value eq <unquoted GUID>`.** Quoting gives a worse error.

**An empty string in an OData filter is malformed, not empty.** `_ubsppcoe_node_value eq ` fails the action. Use a zero GUID sentinel — well-formed, matches nothing, and lets the flow reach its reporting step.

**A Power Apps (V2) trigger cannot be called by `Run a Child Flow`.** Child flows need the manual trigger, and **a trigger cannot be swapped afterwards** — `Save As` keeps the original and the designer will not let you delete it. Build fresh.

**Trigger concurrency is rejected on request-response flows** — those with a `Respond` action.

---

## 5. Power Apps (V2) triggers

**Schema keys are `text`, `text_1`, `text_2`… and they are sticky.** Deleting an input does not renumber the others, and a re-added input takes the next free number. **Designer position does not predict the key** — read it from the trigger's ⋯ → *Peek code* before wiring anything.

**A reference to a key that does not exist resolves to `null`, not an error.** Wrapped in `coalesce(..., 'default')` it silently yields the default: wrong branch, flow reports success having done nothing, invisible in run history.

**Optional inputs are dropped from the payload entirely when blank.** The key never arrives, indistinguishable from an unwired input. **Make every input required** — a blank then arrives as `""` and is visible.

**Arguments are passed positionally** from the canvas app. Inserting an input shifts every argument after it.

**There is a 120-second response budget** on request-response flows. It does not apply to manual or trigger-driven flows.

---

## 6. Fabric policy API

**`PATCH policyRules/{id}` replaces the whole `conditions` array.** Rebuild every condition, not just the edited one.

**An empty `values` list is rejected** (`PropertyMinCount`). Delete the rule instead of emitting it empty.

**There is no `Deny` effect.** A deny-all baseline is expressed as an `Allow` rule that can never match — `workspace.id AnyOf [00000000-0000-0000-0000-000000000000]`.

> **A policy with no rules is not an empty allow-list — it is an unenforced policy.** The capacity silently unlocks. Rule 1 must always be emitted.

**Deactivating a policy set whose capacity is gone returns `404 Capacity not found`** (`isRetriable: false`). The 404 is on the **capacity**, not the set — the endpoint resolves the activation scope first. **`DELETE` on the policy set still works.** Cleanup after a deprovisioned capacity is delete-only.

**Workspace GUIDs in `predicate.values` are never validated.** Any well-formed GUID is accepted and simply never matches. No error, anywhere.

**Use `continuationUri`, not `continuationToken`.** The token comes back already percent-encoded, so rebuilding the URL yourself means choosing between passing it raw and double-encoding — and double-encoding silently returns page 1 forever.

**`properties.scope.id` is frequently absent from list responses.** Resolving it needs a per-item `GET`. Design around matching on `id` instead.

**Enum parameters are validated server-side:** a wrong value gives `400 Failed to convert value '<x>' to the requested type at line 1 position N`.

Service limits: **49 workspaces per rule**, **50 rules per policy**, rule display names capped at **60 characters**, and only **F SKU** capacities can host a policy set.

---

## 7. Designer traps

**The `Condition` card lost *Edit in advanced mode*.** A single `@not(equals(...))` expression cannot be pasted in. Compare two integers instead — it fits the basic editor natively and avoids the boolean-versus-text trap. **`Filter array` kept advanced mode**, which is why conditions there are still written as one expression.

**A `Select` action's Map box defaults to key/value.** Switch it to **text mode** (the `T` icon) or it produces an array of *objects*, and `contains()` tests against it never match — which reads as "no differences found", the most reassuring possible wrong answer.

**Comparing a boolean to the text `true` is the classic silent mismatch.** Compare strings to strings, or integers to integers.

**Leave Retry Policy at Default** on API calls — it covers `408`, `429` and `5xx` with exponential backoff. Setting it to **None** is the only mistake available here.
