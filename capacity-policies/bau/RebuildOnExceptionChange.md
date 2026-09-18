# Flow — `RebuildOnExceptionChange`

Fires when a `Policy Exceptions` row is created or edited, derives which capacity that workspace sits on, and rebuilds that capacity's rules. **Writes nothing to Dataverse except an error, and only when one occurs.**

> **Built in the customer environment.** This document is the specification it was built from.

> ## Why it exists
>
> `Policy Exceptions` is the only table in this design that **nothing triggers on**. Rule 3 is rebuilt from it only when somebody runs [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md), so approving an exception — or revoking one — is not live in Fabric until then. This flow closes that gap.
>
> It answers **Q16** and **Q33** in [ADR.md](../docs/ADR.md), both of which ask whether the table needs a modified-row trigger of its own. Update them when this is built.

Related: [CAPACITY-POLICY-FLOWS.md](../docs/CAPACITY-POLICY-FLOWS.md) §3, [RebuildCapacityPolicyRules.md](RebuildCapacityPolicyRules.md), [RemoveWorkspaceFromPolicy.md](RemoveWorkspaceFromPolicy.md) — build that one first, then copy it.

---

## 0. Before you start

- Build [RebuildCapacityPolicyRules.md](RebuildCapacityPolicyRules.md) first, and confirm the placeholder column names in its §0.
- Needs a **Dataverse connection** for reads only, and **not** the Entra ID HTTP connector. No Fabric calls of its own.
- Build [RemoveWorkspaceFromPolicy.md](RemoveWorkspaceFromPolicy.md) first and copy it. Steps 2c onward are nearly identical; Step 2b is the one genuinely new action in this flow.

> ## This is the smallest flow in the set, and it has no guards
>
> It does not decide whether an exception is valid, it does not check who approved it, and it never refuses. **Every path reaches the rebuild.** Both directions of the `ubsppcoe_active` flag need exactly the same action — activating puts the workspace into rule 3, deactivating takes it out, and `RebuildCapacityPolicyRules` regenerates the whole rule either way.
>
> That is why there is no complementary pair here. [AddWorkspaceToPolicy](AddWorkspaceToPolicy.md) and [RemoveWorkspaceFromPolicy](RemoveWorkspaceFromPolicy.md) are two flows because they report different things to different people. This one reports to nobody, so one flow covers both transitions.

> ### It never writes the exception table
>
> `Policy Exceptions` is filled in **by hand in the maker portal, or by the app through the Dataverse connector — no flow** (**Q32**, closed 2026-09-03). This flow reads it, derives a capacity, and calls the child. Nothing here creates, edits or deactivates a row, and nothing should be added that does.

> ### Revocation is `ubsppcoe_active` = No, not a delete
>
> The table has **no soft-delete column** — `ubsppcoe_active` is the revoke mechanism, and [CAPACITY-POLICY-TABLES.md](../docs/CAPACITY-POLICY-TABLES.md) §4 is explicit that it exists to revoke *without deleting history*. So a normal removal is `true` → `false`: a **Modified** event on a row that is still fully readable, with `ubsppcoe_workspaceid` intact and the capacity still derivable.
>
> **A hard delete is the one case this flow cannot handle.** The row is gone, the workspace GUID with it, and there is no way to work out which capacity to rebuild — the same reasoning as [RemoveWorkspaceFromPolicy](RemoveWorkspaceFromPolicy.md)'s *Why `Deleted` is not in the trigger*. Leave `Deleted` off the Change type; the workspace then keeps unrestricted creation until somebody runs an estate-wide rebuild. It is not the documented procedure, so it should be rare — but **deactivate, do not delete** is now operational procedure rather than a preference, and belongs wherever the exception process is written down.

> ### The blast radius is wider than one workspace
>
> Rule 3 is rebuilt whole, so a change to one exception row republishes **every** exception on that capacity, along with the entire whitelist. That is correct and it is what makes the rebuild idempotent — but it means a broken table anywhere on that capacity surfaces here, attributed to whoever last touched an exception.

---

## Step 1 — The trigger

**Solutions** → **New** → **Automation** → **Cloud flow** → **Automated** → name `RebuildOnExceptionChange` → trigger **Microsoft Dataverse — When a row is added, modified or deleted**.

| Field | Value |
|---|---|
| Change type | **Added or Modified** |
| Table name | `Policy Exceptions` |
| Scope | **Organization** |
| Select columns | `ubsppcoe_active` |
| Filter rows | *(leave empty)* |

**`Added` is required, and this is the opposite of [AddWorkspaceToPolicy](AddWorkspaceToPolicy.md)'s reasoning — deliberately.** That flow is `Added or Modified` because a workspace row is *never* created already enabled; a separate process sets `ubsppcoe_oapenabled` later, so the enable is always a Modified event. **Exception rows have no such second process.** The person creating the row is the person approving it, and filling in the form — workspace, reason, approved by, Active to Yes — and pressing Save is a **single create**. That produces one `Added` event and no `Modified` event ever follows, so a `Modified`-only trigger would sit silent and the exception would not publish until somebody ran an estate-wide rebuild.

`ubsppcoe_active` defaults to **No**, so a row created and *then* activated fires twice and rebuilds twice. That is a wasted rebuild, not a wrong one, and it is the correct price for not missing the single-save case.

**No `Filter rows`, and not `ubsppcoe_active eq true`.** Both directions of the flag need a rebuild. Filtering on `true` would publish every approval and no revocation — the failure with the security dimension, and the one **Q33** is about.

**Scope must be Organization.** The default is `User`, which fires only for rows the flow's owner changed. Exceptions are approved by whoever is on the rota, so on the default this flow silently does nothing for everybody else's rows.

⋯ → **Settings** → **Concurrency Control On, Degree of Parallelism 1**.

> **Bulk edits queue rather than collide.** Deactivating twenty rows in one sitting fires this flow twenty times, and Degree of Parallelism 1 serialises them into twenty rebuilds of the same capacity. Every one is idempotent — `replaceByPolicy` — and every one publishes the complete, correct rule 3, so the end state is right; the intermediate ones are transient partial states nobody sees. At exception volumes that is fine. **If bulk edits ever become routine, do them with the flow turned off and run [MIG_RebuildAllCapacityPolicies](../migration/MIG_RebuildAllCapacityPolicies.md) afterwards** rather than trying to debounce this, which the platform has no mechanism for.

---

## Step 2 — Variables

| Rename to | Name | Type | Value |
|---|---|---|---|
| `Initialize_outcome` | `outcome` | String | `Failed` |
| `Initialize_message` | `message` | String | *(empty)* |
| `Initialize_workspaceId` | `workspaceId` | String | `triggerOutputs()?['body/ubsppcoe_workspaceid']` |
| `Initialize_nodeRowId` | `nodeRowId` | String | *(empty)* |
| `Initialize_capacityId` | `capacityId` | String | *(empty)* |
| `Initialize_policyRowId` | `policyRowId` | String | *(empty)* |

All six at the **top level and outside `Scope_try`**. `Initialize variable` cannot go inside a Condition, a Scope or an Apply to each.

`ubsppcoe_workspaceid` on `Policy Exceptions` is **Text (50)**, not a lookup — the Fabric workspace GUID as typed. It is the only business key the table has ([CAPACITY-POLICY-TABLES.md](../docs/CAPACITY-POLICY-TABLES.md) §4).

---

## Step 2b — Find the workspace, and with it the Node

**This is the one action that does not exist in any sibling flow.** The other two get their Node straight off the trigger row; here the trigger row is an exception, which carries no Node and no capacity.

`Get_workspace_row` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Workspaces` (`ubsppcoe_Workspace`) |
| Filter rows | `ubsppcoe_workspaceid eq '@{variables('workspaceId')}' and ubsppcoe_statecode eq 1` |
| Select columns | `ubsppcoe_workspaceid,_ubsppcoe_nodeid_value` |
| Row count | `50` |

`Set_nodeRowId` — **Set variable**:

| Variable | Value |
|---|---|
| `nodeRowId` | `coalesce(first(body('Get_workspace_row')?['value'])?['_ubsppcoe_nodeid_value'], '00000000-0000-0000-0000-000000000000')` |

> **The zero GUID is load-bearing, not decoration.** Step 2c's filter interpolates this value directly, and an **empty** string produces `_ubsppcoe_node_value eq ` — malformed OData that fails the action and sends the run to the Catch. A zero GUID is well-formed, matches nothing, and lets the flow reach Step 5 and report properly. Same idiom as [RemoveWorkspaceFromPolicy](RemoveWorkspaceFromPolicy.md) Step 2b, for the same reason: a Condition here would push everything after it into a branch and cost the flat diagnosis in Step 6.

> ### `ubsppcoe_statecode eq 1` — this must match the rebuild
>
> [RebuildCapacityPolicyRules](RebuildCapacityPolicyRules.md) Step 5l excludes soft-deleted workspaces from rule 3, so an exception naming a deleted workspace publishes nothing. Without the same clause here the flow would derive a Node from a deleted row and report a rebuild that included the workspace — a **correct rebuild described wrongly**, which is the failure mode this document set keeps returning to.
>
> Choice column, `1` = Active, `2` = Deleted on `ubsppcoe_Workspace`, unquoted integer, and **not** Dataverse's system `statecode` ([CAPACITY-POLICY-TABLES.md](../docs/CAPACITY-POLICY-TABLES.md) §1).

> ### A typo in `ubsppcoe_workspaceid` lands here, and that is the flow's best day
>
> The column is free text that somebody typed. A mistyped GUID matches no workspace, so the rebuild's 5l join finds nothing and the exception **silently grants nothing** — today that goes unnoticed until the person it was raised for complains that they still cannot create anything.
>
> This action turns that into a `NoWorkspace` outcome within a minute of the row being saved. **It is the strongest argument for building this flow at all**, and it is worth more than the same-day publishing that motivated it.

> ### `first()`, and the case where that is not enough
>
> If the same workspace GUID appears on **two live rows pointing at different Nodes**, the exception applies to both capacities — 5l would pick it up on each — and this flow rebuilds only the first. The second is not published until somebody runs an estate-wide rebuild.
>
> Fixing it properly means an `Apply to each` around `Run_rebuild`, which nests the child call and forfeits the real error message Step 6 depends on ([SCOPE-SANDBOX.md](../discarded/SCOPE-SANDBOX.md) E1, E10). **Not worth it for a state that should not exist.** The right fix is upstream: an alternate key on `ubsppcoe_workspaceid`, as already recommended in [CAPACITY-POLICY-TABLES.md](../docs/CAPACITY-POLICY-TABLES.md) §2 for the other tables. Recorded so it is not rediscovered as a defect.

---

## Step 2c — Derive the capacity

A copy of [RemoveWorkspaceFromPolicy](RemoveWorkspaceFromPolicy.md) Step 2b, reading `nodeRowId` instead of the trigger body.

`Get_policy_row` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Capacity Policies` |
| Filter rows | `_ubsppcoe_node_value eq @{variables('nodeRowId')}` |
| Select columns | `ubsppcoe_capacityid,ubsppcoe_capacitypolicyid` |
| Row count | `2` |

The GUID is **unquoted**, as always for a lookup filter.

`Set_capacityId` and `Set_policyRowId` — two **Set variable** actions:

| Variable | Value |
|---|---|
| `capacityId` | `coalesce(first(body('Get_policy_row')?['value'])?['ubsppcoe_capacityid'], '00000000-0000-0000-0000-000000000000')` |
| `policyRowId` | `coalesce(first(body('Get_policy_row')?['value'])?['ubsppcoe_capacitypolicyid'], '')` |

**`_ubsppcoe_node_value` is not selected here**, unlike in the sibling flow. Nothing in this flow compares Nodes — Step 2b already established which one, and there is no caller-supplied capacity to check it against.

> **Two lookups on two different tables, both holding a Node row GUID.** `_ubsppcoe_nodeid_value` in Step 2b is the `Node` lookup on a `ubsppcoe_Workspace` row; `_ubsppcoe_node_value` here is our own lookup on `ubsppcoe_CapacityPolicy`. The names differ by three characters and that is not a typo — see [CAPACITY-POLICY-TABLES.md](../docs/CAPACITY-POLICY-TABLES.md) §0. Neither is a capacity id.

---

> ### The shape of this flow
>
> ```
> trigger
> Step 2   Initialize_outcome / message / workspaceId / nodeRowId / capacityId / policyRowId
> Step 2b  Get_workspace_row / Set_nodeRowId
> Step 2c  Get_policy_row / Set_capacityId / Set_policyRowId
> Step 3   Run_rebuild
>          Condition_rebuild_ok        ├─ Yes: Rebuilt │ No: Failed
> Step 4   Condition_workspace_missing ├─ Yes: NoWorkspace │ No: empty
> Step 5   Compose_result
> Scope_catch   runAfter Scope_try = Failed, Skipped, TimedOut
> ```
>
> **Every action inside `Scope_try` is an immediate child of it**, and the two Conditions contain nothing but `Set variable`. That is what makes `result('Scope_try')` name the action that actually failed instead of a container ([SCOPE-SANDBOX.md](../discarded/SCOPE-SANDBOX.md) E10) — the same property [RemoveWorkspaceFromPolicy](RemoveWorkspaceFromPolicy.md) has and [AddWorkspaceToPolicy](AddWorkspaceToPolicy.md) does not.
>
> **Keep it flat.** A `List rows`, an `Apply to each` or a `Run a Child Flow` inside either Condition costs this flow its diagnosis, and there is nothing else here to diagnose with.

---

## Step 3 — Rebuild

`Run_rebuild` — **Run a Child Flow** → `RebuildCapacityPolicyRules`, passing `variables('capacityId')`.

`Condition_rebuild_ok` — **Condition**, run after `Run_rebuild` on **is successful** only:

| Left | Operator | Right |
|---|---|---|
| `body('Run_rebuild')?['outcome']` | is equal to | `Rebuilt` |

**Yes** → `outcome` = `Rebuilt`, and `message` = 

```
concat('Policy rules republished. ', body('Run_rebuild')?['ExceptionCount'], ' exception workspace(s) and ', body('Run_rebuild')?['WorkspaceCount'], ' whitelisted workspace(s) on this capacity.')
```

**No** → `outcome` = `Failed`, and `message` =

```
concat('The rules could not be republished: ', coalesce(body('Run_rebuild')?['Message'], 'the rebuild flow failed.'), ' Nothing will retry this — rebuild this capacity by hand.')
```

**Tick *is successful* only.** An action inside a Try scope that runs after *has failed* makes `Scope_try` report Succeeded and skips the Catch entirely ([SCOPE-SANDBOX.md](../discarded/SCOPE-SANDBOX.md) E3).

> **An ungoverned capacity arrives here as the zero GUID** and the child answers with its own *capacity is not registered* message, which this branch surfaces unchanged. Do not add a second check for it — one flow should own that message, and it is the child.

---

## Step 4 — The workspace override

`Condition_workspace_missing` — **Condition**, **at the top level immediately after `Condition_rebuild_ok`**, not inside either of its branches:

| Left | Operator | Right |
|---|---|---|
| `empty(body('Get_workspace_row')?['value'])` | is equal to | `true` |

**Yes** → overwrite `outcome` with `NoWorkspace` and set `message` to: `No live workspace matches the ID on this exception row, so the exception grants nothing. Check ubsppcoe_workspaceid against the workspace in Fabric — a mistyped GUID produces an exception that looks approved and does nothing.`

**No** → **leave the branch completely empty.** Step 3 has already set both variables; this branch's job is to not touch them.

> **It runs *after* the rebuild and overwrites it, which looks backwards until you follow the values.** With no workspace row, `nodeRowId` is the zero GUID, so `capacityId` is too, so the child fails and Step 3 has already written `Failed` with the child's *capacity is not registered* text. That message is true and useless — the capacity is not the problem, the GUID on the exception row is.
>
> Overwriting last is what puts the more specific diagnosis on top. Same override pattern as [RemoveWorkspaceFromPolicy](RemoveWorkspaceFromPolicy.md) Step 4b, and for the same reason: a sibling Condition can correct either branch, where a nested one corrects half.

---

## Step 5 — Record the outcome

`Compose_result` — **Compose**, run after **both** `Scope_try` and `Scope_catch` on **all four** statuses:

```
@{variables('outcome')} — @{variables('message')}
```

| `outcome` | Meaning | Run ends |
|---|---|---|
| `Rebuilt` | The capacity's rules now reflect the exception table | Succeeded |
| `NoWorkspace` | The exception row's workspace GUID matches no live workspace. **It grants nothing** | Succeeded |
| `Failed` | The child reported an error. **Nothing will retry it** | Succeeded |
| `Caught` | An action failed outright. Set by `Scope_catch` | **Failed** |

There is no `NotEnabled` and no `WrongCapacity`. An exception grants regardless of `ubsppcoe_oapenabled` ([RebuildCapacityPolicyRules](RebuildCapacityPolicyRules.md) 5l), and there is no caller-supplied capacity to be wrong about.

> **`NoWorkspace` goes into a `Compose` that nobody opens**, which is the same complaint [RemoveWorkspaceFromPolicy](RemoveWorkspaceFromPolicy.md) Step 7 makes about `StillExcepted`. Here it is more actionable and cheaper to route: the row was saved seconds ago by a person who is still at their desk. **Consider a `Terminate` with status Failed on that branch**, which puts a mistyped exception in the failure list instead of a green run. Left undecided on purpose — it is a judgement about who watches what — but decide it before launch rather than after the first exception that quietly did nothing.

---

## Step 6 — Try and Catch

Build **last**, and copy it wholesale from [RemoveWorkspaceFromPolicy.md](RemoveWorkspaceFromPolicy.md) Step 8. Only the action names in Step 6a differ.

### 6a. `Scope_try`

**Control** → **Scope**, renamed `Scope_try`. Drag Steps 2b, 2c, 3 and 4 into it. The six `Initialize variable` actions stay above it.

**Then check every action inside for *has failed*.** There should be none once `Condition_rebuild_ok` is set to *is successful* only.

### 6b. `Scope_catch`

**Control** → **Scope**, renamed `Scope_catch`. **Configure run after** `Scope_try`: **has failed**, **is skipped**, **has timed out**.

| # | Action | Detail |
|---|---|---|
| 1 | `Compose_error` — **Compose** | `result('Scope_try')` |
| 2 | `Filter_failed` — **Filter array** | From `result('Scope_try')`, `item()?['status']` **is equal to** `Failed` |
| 3 | `Set variable` | `outcome` = `Caught` |
| 4 | `Set_message` — **Set variable** | `message` = the expression below |
| 5 | `Condition_row_known` — **Condition** | `empty(variables('policyRowId'))` is equal to `false` |
| 6 | └ **Yes** → `Update_policy_error` | `Capacity Policies`, Row ID `variables('policyRowId')`, `ubsppcoe_lasterror` = **`variables('message')`** — that column and no other |
| 7 | `Add_log_row` — Dataverse **Add a new row** | Table `Logging`, **outside the Condition** — `Log Category` = `Error`, `Log Source Name` = `workflow()?['tags']?['flowDisplayName']`, `Log Source URL` = the run URL |
| 8 | `Terminate` | Status **Failed**, message `concat(variables('outcome'), ' — ', variables('message'))` |

```
concat(coalesce(first(body('Filter_failed'))?['name'], 'no failed action in Scope_try'), ': ', coalesce(first(body('Filter_failed'))?['error']?['message'], 'scope was skipped or timed out'), ' | run ', workflow()?['run']?['name'])
```

Copy from the code block, not from a table cell — the `|` would need escaping, and a `\|` pasted into the designer fails at runtime rather than at save.

> **The `Terminate` is not optional.** Without it a caught error produces a **green run** — measured in [SCOPE-SANDBOX.md](../discarded/SCOPE-SANDBOX.md) E7. A try/catch that only logs converts a visible failure into an invisible one.

> **`ubsppcoe_lasterror` takes `variables('message')`, never `outputs('Compose_error')`.** The raw `result()` array carries every action's `inputs` and `outputs` verbatim — including the workspace GUIDs `Get_workspace_row` returned — exceeds the column's 2000 characters, and is not text.

> **`policyRowId` is empty more often in this flow than in its siblings.** A mistyped GUID, a workspace on an ungoverned capacity and a failure inside `Get_workspace_row` all reach the Catch with nowhere to write, so row 7's `Logging` insert is the only record on those paths. Keep it outside the Condition and above the `Terminate`.

> **The `Logging` columns' logical names are not confirmed — Q48.** Only the UI display names are known and the table belongs to the platform team. See [CAPACITY-POLICY-TABLES.md](../docs/CAPACITY-POLICY-TABLES.md) §5a.

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | Create an exception row with `Active` = Yes **in one save**, for a workspace on a governed capacity | Flow fires on `Added`; `Rebuilt`; rule 3 appears in the portal with that workspace and **no `item.type` condition** |
| 2 | Create a row with `Active` unset, then set it to Yes | Fires **twice**. Both `Rebuilt`. The first is the wasted rebuild the trigger note accepts |
| 3 | Set `Active` to **No** on a live exception | `Rebuilt`, and the workspace is gone from rule 3. **This is Q33** — verify it in the portal, not just the run history |
| 4 | Set `Active` to No on the capacity's **only** exception | Rule 3 disappears entirely rather than being published empty |
| 5 | A second exception on the same capacity, one row edited | **Both** workspaces present in rule 3. The rebuild regenerates the whole rule |
| 6 | Create a row with a **mistyped** workspace GUID | `NoWorkspace`. Nothing published. **The test this flow is worth building for** |
| 7 | Create a row for a workspace whose capacity has no `Capacity Policies` row | `Failed`, with the child's *capacity is not registered* message |
| 8 | Create a row for a **soft-deleted** workspace (`ubsppcoe_statecode` = 2) | `NoWorkspace`, not `Rebuilt`. Proves the `eq 1` clause in Step 2b matches the rebuild's 5l |
| 9 | Exception for a workspace that is **also** OAP-enabled | Present in **both** rule 2 and rule 3. Not an error, not deduplicated |
| 10 | **Delete** an exception row outright | Flow does **not** fire. Confirm the gap exists rather than discovering it later — §0 |
| 11 | Edit only `ubsppcoe_reason` on a live row | Does **not** fire. `Select columns` is `ubsppcoe_active` alone |
| 12 | Deactivate five rows on one capacity in quick succession | Five serialised runs, all `Rebuilt`, final rule set correct. No overlap — Degree of Parallelism 1 |
| 13 | Break `Get_policy_row` with a bad column name | `Caught`, run ends **Failed**, and `ubsppcoe_lasterror` names `Get_policy_row` and its real error — not a container |
| 14 | Inspect any run's action list | **No write action against `Policy Exceptions`, `ubsppcoe_Workspace` or `ubsppcoe_Node`** |

**Test 6 is the one to build the flow around.** Same-day publishing was the motivation, but a mistyped GUID is the failure that has no detection at all — an estate-wide rebuild does nothing about it and never will.

**Test 11 is the cheap mistake.** Adding more columns to `Select columns` makes every edit to a reason or an approver rebuild a capacity.

**Test 10 verifies a deliberate gap.** It should fail to fire, and somebody should know that.

**Test 1 is the one that breaks if the trigger is `Modified` only** — the most likely way to build this flow wrong, because the equivalent reasoning in [AddWorkspaceToPolicy](AddWorkspaceToPolicy.md) points the other way.
