# Flow — `AddWorkspaceToPolicy`

Confirms that a workspace really is whitelisted on a capacity, then rebuilds that capacity's rules. **Writes nothing to Dataverse except an error, and only when one occurs.**

> **Built, and being converted.** The flow exists as an instant flow with a Power Apps (V2) trigger. Two changes are in flight: the trigger swap immediately below, and the try/catch scopes in Step 7.

> ## Converting the built flow — 2026-09-11
>
> The app no longer calls this. It fires on a Dataverse row change instead, and **derives** the capacity rather than being told it.
>
> **The body does not change.** Steps 3, 4a, 4b, 4c and 5 stay exactly as built, including every guard and every message. What changes is what feeds them: two variables stand in for the two trigger inputs, so the existing expressions keep working after a find-and-replace.
>
> | # | Edit | Where |
> |---|---|---|
> | 1 | Delete the Power Apps (V2) trigger, add the Dataverse one | Step 1 |
> | 2 | Two new variables — `workspaceId`, `capacityId` | Step 2 |
> | 3 | Two new actions — `Get_policy_row`, `Set_capacityId` | Step 2b |
> | 4 | `triggerBody()['text_1']` → `variables('workspaceId')` | Step 3 |
> | 5 | `triggerBody()['text']` → `variables('capacityId')` | Steps 4a, 5 |
> | 6 | Replace `Respond` with a `Compose` | Step 6 |
> | 7 | Concurrency Control On, Degree of Parallelism 1 | Settings |
>
> Three new actions, three expression edits, one action swapped. **No branch moves, and the nesting is untouched.**
>
> **`RemoveWorkspaceFromPolicy` is not converted yet** and still expects a caller, so `ubsppcoe_oapenabled` going `true` → `false` still reaches Fabric only at the nightly run.

> ## Adding try/catch scopes — 2026-09-12
>
> A customer standard: the body goes in a `Try` scope, and a `Catch` scope reads `result()` and writes the error to a Dataverse column.
>
> **This solution has no try/catch to copy.** There is not one `Scope` action in any of the seventeen exported flows — error handling here is "configure run after" throughout. So this is the first, and if it is to become a house standard it belongs in [CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §4 before it is built a second time.
>
> | # | Edit | Where |
> |---|---|---|
> | 8 | Add `ubsppcoe_capacitypolicyid` to `Get_policy_row`'s Select columns | Step 2b |
> | 9 | New variable `policyRowId`, and a `Set_policyRowId` beside `Set_capacityId` | Steps 2, 2b |
> | 10 | Untick **has failed** on `Condition_rebuild_ok`'s Configure run after | Step 5 |
> | 11 | Wrap Steps 2b–5 in `Scope_try`; add `Scope_catch` | Step 7 |
> | 12 | Re-point `Compose_result` to run after both scopes | Step 6 |
>
> **The body still does not change.** Dragging actions into a Scope edits none of them — variables are global, so every `variables('capacityId')` reference survives the move untouched.
>
> **One thing is not settled: which table the Catch writes to.** This document assumes `Capacity Policies`, which is ours. If the answer turns out to be `ubsppcoe_Workspace`, that is not a flow change — see Step 7.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md), [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md), [RemoveWorkspaceFromPolicy.md](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md), [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §1–§2.

---

## 0. Before you start

- Build [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) first. This flow validates, then wraps it.
- Needs a **Dataverse connection**, and **not** the Entra ID HTTP connector. It makes **no Fabric calls of its own** — every Fabric interaction, and therefore the whole auth question, lives inside the child flow.
- **Reads only, apart from one column.** `Scope_catch` writes `ubsppcoe_lasterror` on a `Capacity Policies` row, and only when something has failed. Nothing else in the flow writes anything — see Step 7.

> ## This flow does not add anything
>
> The name is the app's vocabulary, not a description of a write. Whitelist membership is **derived** from two columns on `ubsppcoe_Workspace` — the `Node` lookup and `ubsppcoe_oapenabled` — and **this project never writes either** ([CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §3). `ubsppcoe_oapenabled` in particular is an internal flag meaning *this workspace has OAP enabled and receives the rest of the Fabric treatment*; capacity policy is one late consumer of it.
>
> So what this flow actually does is **check that the conditions for whitelisting are already true, and publish the consequences**. If they are not true, it says so and refuses — which is the entire reason it still exists as a separate flow rather than a bare "rebuild this capacity" call.
>
> There is also no `PATCH` of a policy rule, no "find a rule with space", no 49-chunking. The rebuild recomputes the whole layout. If you find yourself reading policy rules in this flow, the design has been misunderstood — see [CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §2.

> ### The failure this flow exists to prevent
>
> An app that calls a plain refresh and then tells the user *"workspace added to the policy"* is asserting something nothing checked. A workspace whose `ubsppcoe_oapenabled` is `false` or null produces exactly the same successful rebuild as one that is properly enabled — same outcome, same rule count moving, and the workspace silently absent from the rules.
>
> `NotEnabled` in Step 4b is that case made visible. It is the most likely thing to go wrong in normal operation, because it happens whenever the app's provisioning runs ahead of whatever sets `ubsppcoe_oapenabled`.

---

## Step 1 — The trigger

In the built flow, **delete the Power Apps (V2) trigger and add** **Microsoft Dataverse — When a row is added, modified or deleted**. The designer allows the swap in place; the actions below survive it, but every expression referencing `triggerBody()` goes red until Step 2b is in.

| Field | Value |
|---|---|
| Change type | **Added or Modified** |
| Table name | `Workspaces` (`ubsppcoe_Workspace`) |
| Scope | **Organization** |
| Select columns | `ubsppcoe_oapenabled,ubsppcoe_nodeid` |
| Filter rows | `ubsppcoe_oapenabled eq true and _ubsppcoe_nodeid_value ne null and ubsppcoe_isdeleted ne true` |

> **`ubsppcoe_isdeleted` is a PLACEHOLDER name — see [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §1 (Q46)**, which lists all six places it appears. The real name has not been supplied.
>
> It is in `Filter rows` but deliberately **not** in `Select columns`. A workspace being soft-deleted should not fire *this* flow — that is [RemoveWorkspaceFromPolicy](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md)'s event. Keeping it out of `Select columns` means a delete does not even wake this flow up; keeping it in `Filter rows` means that if some *other* watched column changes on an already-deleted row, nothing happens.

**`Added or Modified`, not `Added`.** A workspace row is almost never created already enabled — `ubsppcoe_oapenabled` is set later by a different process, which is exactly why `NotEnabled` was the most common outcome of the app-called version. On `Added` alone this flow would fire at creation, find the flag null, and never see the enable.

**Scope must be `Organization`.** The default is `User`, which fires only for rows the connection's own user changed — and the whole point is to catch changes made by other people's processes. A `User` scope works perfectly in testing and never once fires in production.

> ### The two filters replace two guards
>
> `Select columns` controls **whether the trigger fires**, not what the body contains. Without it, every edit to any column on a table another team bulk-syncs starts a run, and each run ends in a `replaceByPolicy` write against Fabric. The two listed are the only columns that can change what the rules should be.
>
> `Filter rows` is evaluated against the row **after** the change, so it carries the enabled check that Step 4c used to make, and the Node-present check the flow never had to make. The second half matters: a blank Node lookup would make Step 2b's filter malformed and fail the run, and a workspace can legitimately be enabled before it is assigned.
>
> **Keep Step 4c anyway.** It is now redundant against the trigger and costs nothing, and it closes the gap between trigger time and run time — see Step 4c.
>
> It also defines the seam with [RemoveWorkspaceFromPolicy](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md) when that is converted: the same trigger with `ubsppcoe_oapenabled ne true`. **Not `eq false`** — `false` and null are different values and null is the common one, so `eq false` would silently drop every never-set row.

⋯ → **Settings** → **Concurrency Control On, Degree of Parallelism 1**. Now permitted, because losing `Respond` stops this being a request-response flow. It serialises a bulk enable; it does not shrink one, and 500 enabled rows is still 500 runs against perhaps 20 capacities. Time that before trusting it in production.

---

## Step 2 — Variables

| Rename to | Name | Type | Value |
|---|---|---|---|
| `Initialize_outcome` | `outcome` | String | `Failed` |
| `Initialize_message` | `message` | String | *(empty)* |
| `Initialize_workspaceId` | `workspaceId` | String | `triggerOutputs()?['body/ubsppcoe_workspaceid']` |
| `Initialize_capacityId` | `capacityId` | String | *(empty)* |
| `Initialize_policyRowId` | `policyRowId` | String | *(empty)* |

All five at the **top level**, before any Condition **and outside `Scope_try`**. `Initialize variable` is the one action Power Automate refuses to place inside a Condition, a Scope or an Apply to each — which is why `capacityId` and `policyRowId` start empty here and are filled by Step 2b rather than being declared where they are derived.

> **This is the one part of the try/catch change the designer will not warn you about.** It offers `Initialize variable` inside a Scope quite happily and then fails validation on save, with an error that names the action rather than the rule. Leave all five above `Scope_try` and the problem never arises.

> **The two new variables exist to avoid editing the body.** They hold what `triggerBody()['text']` and `triggerBody()['text_1']` used to hold, so converting Steps 3, 4a and 5 is a find-and-replace rather than a rethink. `workspaceId` reads `ubsppcoe_workspaceid` — the **Fabric** workspace GUID, not the row key `ubsppcoe_workspaceuniqueid` ([CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §1).

---

## Step 2b — Derive the capacity

The step the conversion turns on. **The trigger gives you the Node row GUID; it does not give you a capacity id**, and the capacity id is the only thing the child flow understands.

### `Get_policy_row` — Dataverse **List rows**

| Field | Value |
|---|---|
| Table name | `Capacity Policies` (`ubsppcoe_CapacityPolicy`) |
| Filter rows | `_ubsppcoe_node_value eq @{triggerOutputs()?['body/_ubsppcoe_nodeid_value']}` |
| Select columns | `ubsppcoe_capacityid,ubsppcoe_capacitypolicyid` |
| Row count | `2` |

**The GUID is unquoted**, as always for a lookup filter. **Row count 2, not 1** — you are asserting one governed capacity per Node, and asking for one row would return the first of two and tell you nothing.

**`ubsppcoe_capacitypolicyid` is the row key**, and it is selected only so that Step 7's Catch has something to write to. Nothing else in the flow reads it.

### `Set_capacityId` and `Set_policyRowId` — **Set variable**

| Variable | Value |
|---|---|
| `capacityId` | `coalesce(first(body('Get_policy_row')?['value'])?['ubsppcoe_capacityid'], '00000000-0000-0000-0000-000000000000')` |
| `policyRowId` | `coalesce(first(body('Get_policy_row')?['value'])?['ubsppcoe_capacitypolicyid'], '')` |

**The two `coalesce` fallbacks differ deliberately.** An unresolved capacity must become the zero GUID, because Step 4a's filter has to stay well-formed. An unresolved row key must become the **empty string**, because Step 7's Catch tests it with `empty()` and a zero GUID would pass that test and then fail the update.

> ### The `coalesce` is what keeps this a two-action change
>
> A capacity with no `Capacity Policies` row is not an error — it is one of the 200–300 capacities that exist in inventory and are not under policy management. Handling it properly would mean a Condition, and putting Steps 3 onward inside its Yes branch, which is the restructuring this conversion is trying to avoid.
>
> So instead an unresolved capacity becomes the **zero GUID**. Step 4a then finds no Node row, Step 4b's comparison fails, and the run ends at `WrongCapacity` with no rebuild — which is the correct behaviour reached through an existing guard rather than a new one. The zero GUID is already this solution's sentinel ([CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §8), so it is not a new convention either.
>
> **The cost is an imprecise label.** "Not governed" is reported as `WrongCapacity`. Step 4b's message is widened to name both causes; if that turns out to be the common case in the run history, promote it to its own Condition and accept the nesting.

> ### Why via `Capacity Policies` rather than via `ubsppcoe_Node`
>
> Reading the Node row instead — `Get a row by ID` on `Nodes`, then `ubsppcoe_nodeuniqueid` — is also one action and also works. This route was chosen because it answers a second question in the same call: **is this capacity governed at all?** Via the Node you would get an id for every capacity, hand it to the child flow, and have it fail with *"run InitializeCapacityPolicySet first"* — a red run, an owner notification, for a capacity working exactly as intended. Tolerable when a human clicked a button; noise when a trigger generates it at the rate another team edits their table.
>
> **The cost is Q29.** `ubsppcoe_capacityid` is our copy of a GUID that also lives on the Node row, and nothing reconciles them. Via the Node the id would be authoritative.
>
> **Step 4b turns out to close exactly that gap, for free** — see below. It is the strongest argument for leaving the body alone.

> ### The shape of this flow — it nests, and there is no Terminate
>
> Every guard here is an early exit that **sets two variables and nothing else**. There is a single `Compose` at the end that every path must reach, so a guard cannot stop the run — it can only fail to contain the work.
>
> ```
> trigger   (Filter rows has already asserted oapenabled = true and Node present)
> Step 2   Initialize outcome / message / workspaceId / capacityId / policyRowId
> Scope_try
>   Step 2b  Get_policy_row → Set_capacityId, Set_policyRowId
>   Step 3   Get_workspace_row
>            Condition_workspace_found
>              ├─ No:  2 × Set variable            ← NotFound, no rebuild
>              └─ Yes: Step 4a  Get_node_row
>                            4b  Condition_node_matches
>                                  ├─ No:  2 × Set variable   ← WrongCapacity
>                                  └─ Yes: 4c  Condition_enabled
>                                              ├─ No:  2 × Set variable   ← NotEnabled
>                                              └─ Yes: Step 5  Run_rebuild
>                                                            Condition_rebuild_ok
> Scope_catch   runAfter Scope_try = Failed, Skipped, TimedOut
> Step 6   Compose_result                     ← top level, reached by every path
> ```
>
> **So yes — 4c is inside 4b's Yes branch, and 4a/4b are inside Step 3's Yes branch**, and all of it is now inside `Scope_try`. Four levels by the time you reach Step 5. **The scopes add a level of indentation and move nothing else.**
>
> Terminate is now permissible — there is no caller left to strand — and Step 7's Catch uses one. It is still wrong *inside* `Scope_try`, and this is **verified rather than assumed** ([SCOPE-SANDBOX.md](docs/flows/capacity-policies/SCOPE-SANDBOX.md) E4): a Terminate there ends the run without evaluating anything downstream, the scope goes **Aborted** rather than Failed, and the Catch is never reached. Aborted is not one of the four `runAfter` statuses either, so nothing could catch it even in principle. **The only Terminate in this flow is the last action of the Catch.**
>
> **Step 6 is the only action at the top level after the two scopes.** Everything else lives in one of them — and it runs on every path except the caught one, where the Catch's Terminate ends the run first.

---

## Step 3 — Find the workspace row

`Get_workspace_row` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Workspaces` (`ubsppcoe_Workspace`) |
| Filter rows | `ubsppcoe_workspaceid eq '@{variables('workspaceId')}'` |
| Select columns | `ubsppcoe_workspaceuniqueid,ubsppcoe_workspaceid,ubsppcoe_oapenabled,_ubsppcoe_nodeid_value` |
| Row count | `2` |

> **`ubsppcoe_workspaceid` is the Fabric workspace GUID, not the Dataverse row key.** These tables invert the usual convention — the row key is `ubsppcoe_workspaceuniqueid`. Filtering on the row key here matches nothing and returns `NotFound` for every caller.

> **This step now re-reads the row that raised the trigger, and is worth keeping anyway.** It cannot return `NotFound` for a missing row — a row that does not exist cannot raise a trigger. It *can* return it when `ubsppcoe_workspaceid` is blank, which is a workspace row with no Fabric GUID: enabled, assigned to a capacity, and impossible to publish. That is a real defect in the inventory and this is the only place that names it.

`Condition_workspace_found` — **Condition**:

| Left | Operator | Right |
|---|---|---|
| `length(body('Get_workspace_row')?['value'])` | is equal to | `1` |

**No** → `outcome` = `NotFound`, `message` = `No workspace record exists for this ID, or more than one does. It must be registered before it can be whitelisted.` Stop — no rebuild.

Everything below goes in the **Yes** branch.

---

## Step 4 — Is it on the right capacity, and is it enabled?

### 4a. `Get_node_row` — Dataverse **List rows**

| Field | Value |
|---|---|
| Table name | `Nodes` (`ubsppcoe_Node`) |
| Filter rows | `ubsppcoe_nodeuniqueid eq @{variables('capacityId')}` |
| Row count | `1` |

Resolves the derived capacity id to the Node row's **primary key**, `ubsppcoe_nodeid`. Leave **Select columns** empty, or include `ubsppcoe_nodeid` explicitly.

**The zero GUID from Step 2b lands here and matches nothing**, which is the intended path for an ungoverned capacity.

### 4b. `Condition_node_matches` — **Condition**

| Left (expression) | Operator | Right |
|---|---|---|
| `first(body('Get_workspace_row')?['value'])?['_ubsppcoe_nodeid_value']` | is equal to | `first(body('Get_node_row')?['value'])?['ubsppcoe_nodeid']` |

**No** → `outcome` = `WrongCapacity`, `message` = `The capacity derived from this workspace's Node is not under policy management, or the Capacity Policies row's capacity ID disagrees with the Node it points at.` Stop — two **Set variable** actions and nothing else on that branch.

**4c goes in the Yes branch.**

> ### This guard changed meaning, and got more useful
>
> It used to catch a caller passing two GUIDs the wrong way round. Nothing can pass anything now, so that job is gone — but the comparison is not idle. It runs **Node → capacity id → Node** and checks the round trip closes.
>
> That is precisely the **Q29** check. `ubsppcoe_capacityid` on our `Capacity Policies` row is a copy of the Node's `ubsppcoe_nodeuniqueid` and nothing reconciles them; if ours is stale, Step 4a resolves it to a *different* Node row, this comparison fails, and the run stops **before** rebuilding a capacity the workspace does not belong to.
>
> Deriving the capacity via `Capacity Policies` rather than via the Node row would otherwise have traded that safety away. Keeping a guard written for a threat that no longer exists is what buys it back, which is a good argument for converting rather than rewriting.

> **A Dataverse lookup stores the target's primary key, and on `ubsppcoe_Node` that key is *not* the capacity id.** `ubsppcoe_nodeuniqueid` holds the capacity id, but it is an ordinary column — so `_ubsppcoe_nodeid_value` is a Node row GUID and cannot be compared against the trigger input directly. Step 4a exists solely to translate one into the other.
>
> Corrected 2026-09-09. The earlier version compared the lookup straight against `triggerBody()['text']`, which never matches — **every** call returned `WrongCapacity`.
>
> A capacity with no Node row makes 4a return nothing, the comparison fails, and the caller gets `WrongCapacity`. That is the right answer: a capacity with no inventory record has no workspaces pointing at it either.

> **This check is the reason the two GUIDs cannot be swapped by accident.** Both inputs are GUIDs, so passing them the wrong way round would otherwise produce a syntactically valid pair, a successful rebuild of the **wrong capacity**, and a confident success message. Rebuilding a policy the caller never asked about is the worst outcome available here, and it is a one-line mistake to make.

### 4c. `Condition_enabled` — **Condition**

| Left | Operator | Right |
|---|---|---|
| `first(body('Get_workspace_row')?['value'])?['ubsppcoe_oapenabled']` | is equal to | `true` |

**No** → `outcome` = `NotEnabled`, `message` = `This workspace is registered on the capacity but does not have OAP enabled, so it cannot be whitelisted. That flag is set by the platform team's process, not by this app.` Stop — **no rebuild**, two **Set variable** actions and nothing else on that branch.

> **`false` and null both take the No branch, and that is correct.** `ubsppcoe_oapenabled` is nullable, so a row nobody has ever touched compares unequal to `true` exactly as an explicit `false` does. Neither is whitelisted, neither is added to any rule explicitly, and the message does not distinguish them — there is nothing the caller could do differently.

> **Refusing here rather than rebuilding was a judgement call made for a caller, and under a trigger it inverts.** There is no longer a user to mislead, and the trigger's `Filter rows` has already asserted the flag — so this guard only fires when the flag was cleared **between the trigger and the run**. That is the disable case, and a rebuild is exactly what it needs.
>
> **Keep the guard as built, for now.** Refusing means a rapid enable-then-disable is not published here and waits for the nightly run. That is the same latency `RemoveWorkspaceFromPolicy` already has, so the conversion does not make anything worse — and once that flow is converted it will own the disable direction outright. **Revisit this box then**, rather than leaving a flow that quietly declines to publish a revocation.

> **`NotEnabled` does not mean the workspace can create nothing.** An active `PolicyException` row puts it in rule 3, which never consults `ubsppcoe_oapenabled` ([CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §3) — so a workspace can be refused here and still be able to create anything on that capacity.
>
> This flow does not check for that, deliberately: it is about whitelisting, the answer is still "no, and here is why", and adding a query for a case that changes nothing about the outcome buys a second sentence and a second failure mode. The place that needs to know is [RemoveWorkspaceFromPolicy.md](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md), where the same fact turns a removal into a false confirmation.

Everything below goes in the **Yes** branch — Step 5, but **not** Step 6, which stays at the top level so every branch reaches it.

---

## Step 5 — Rebuild

`Run_rebuild` — **Run a Child Flow** → `RebuildCapacityPolicyRules`, passing `variables('capacityId')`.

`Condition_rebuild_ok` — **Condition**:

| Left | Operator | Right |
|---|---|---|
| `body('Run_rebuild')?['outcome']` | is equal to | `Rebuilt` |

Configure this Condition to run after `Run_rebuild` on **is successful** only. **Untick "has failed"** — it was ticked in the built version, and removing it is what makes Step 7's Catch reachable at all.

> ### Verified 2026-09-12, and it is not a preference
>
> A failure handled *inside* a Scope is invisible to the Catch. Measured in [SCOPE-SANDBOX.md](docs/flows/capacity-policies/SCOPE-SANDBOX.md) E3: an action failed, a later action ran after **has failed** and succeeded, and `Scope_try` reported **Succeeded** with `Scope_catch` **skipped**.
>
> A scope's status reflects what was left *unhandled*, not what went wrong. So leaving **has failed** ticked here would absorb a hard failure of the child flow, report the scope clean, and leave the Catch as dead code for the one case it exists to serve — with a green run history and the error written to no table at all.
>
> **The general rule, which applies to every action inside `Scope_try`:**
>
> > **No action inside a Try scope may be configured to run after *has failed*.** Each one silently disables the Catch for the path it covers. The two mechanisms do not layer; the inner one wins, and it wins quietly.
>
> Check this whenever an action is added inside the Try. It is a checkbox on a properties flyout, it has no visible effect on the canvas, and it disables error handling for an entire branch.

### Yes

`outcome` = `Added`, `message` = `concat('Policy rules updated. ', body('Run_rebuild')?['workspacecount'], ' workspace(s) allowed on this capacity.')`

### No

`outcome` = `Failed`, `message` = `concat('The workspace is whitelisted in Dataverse but the rules could not be republished: ', coalesce(body('Run_rebuild')?['message'], 'the rebuild flow failed.'), ' The nightly rebuild will apply it.')`

> ### "The rebuild failed" is two different events, and only one of them can reach a Catch
>
> This is the least obvious part of the whole change, and getting it wrong produces a Catch block that looks right and never fires.
>
> | | **Case A** — the child hard-fails | **Case B** — the child returns `Failed` |
> |---|---|---|
> | Cause | Child flow crashed, was turned off, timed out, connector error | Fabric returned 4xx/5xx and the child handled it cleanly |
> | `Run_rebuild` action status | **Failed** | **Succeeded** |
> | Which path here | The Condition is **skipped** | The **No** branch above |
> | Reaches `Scope_catch`? | **Yes** | **No — nothing failed** |
> | `ubsppcoe_lasterror` written? | **No** | **Yes, by the child itself** |
> | How often | Rare | **The common one** |
>
> **Case B already writes the error, and writes it better than a Catch could.** [RebuildCapacityPolicyRules](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) Step 10a stamps `ubsppcoe_lasterror` on the `Capacity Policies` row on **both** its paths, carrying Fabric's own message. `result()` would give you "the child flow returned a value" and nothing about why.
>
> So do not try to force Case B into the Catch. It would need an action rigged to fail on purpose, and a `Terminate` cannot do it — Terminate inside `Scope_try` ends the run before the Catch runs.
>
> **Case A is exactly what the Catch is for**, and it is the case that leaves no trace anywhere else. Unticking **has failed** is what lets it propagate out of the Try instead of being absorbed here — verified, not assumed; see the box above.

> **Rollback is still nothing, and a failed rebuild still leaves the world as it found it.** Dataverse already said the workspace was whitelisted before the run, and the previously published rules are untouched. The Catch's write to `ubsppcoe_lasterror` is a diagnostic, not state — nothing reads it back as truth, and the nightly rebuild overwrites it either way.
>
> The only casualty is timing. The workspace is whitelisted according to Dataverse and not yet according to Fabric, and it stays that way until the next successful rebuild. Say so in the message rather than reporting a bare failure.

---

## Step 6 — Record the outcome

**Delete the `Respond to a Power App or flow` action** — it is invalid without a Power Apps or Request trigger and will block the save.

Replace it with `Compose_result` — **Compose**, run after **both** `Scope_try` and `Scope_catch` on all four statuses — *is successful*, *has failed*, *is skipped*, *has timed out*:

```
@{variables('outcome')} — @{variables('message')}
```

**All four statuses on both scopes, or this action is unreachable.** `Scope_catch` is *skipped* on every healthy run, and an action that runs after it on "is successful" alone would be skipped too — producing a flow whose happy path silently records nothing.

> ### It is not reached on the caught path, and cannot be
>
> `Scope_catch` ends with a `Terminate`, and **Terminate ends the run without evaluating anything downstream** — verified in [SCOPE-SANDBOX.md](docs/flows/capacity-policies/SCOPE-SANDBOX.md) E4. So when the Catch fires, this action never runs.
>
> That is not data loss, because the Terminate carries the same string as its message (Step 7b) and it appears in the run history the same way. But it does mean **`Compose_result` records five of the six outcomes, not all six.** `Caught` is recorded by the Terminate.
>
> Keep the four-status configuration anyway. It costs nothing, and it is what keeps the five non-caught outcomes recorded — including the paths where `Scope_catch` is skipped, which is most of them.

| `outcome` | Meaning | Rebuild ran? | Run ends |
|---|---|---|---|
| `Added` | Confirmed whitelisted, rules republished | Yes | Succeeded |
| `NotFound` | `ubsppcoe_workspaceid` is blank on the row, or duplicated. **An inventory defect** | No | Succeeded |
| `WrongCapacity` | The capacity is not governed, or our `ubsppcoe_capacityid` disagrees with the Node | No | Succeeded |
| `NotEnabled` | The flag was cleared between the trigger firing and the run starting. **Now rare** | No | Succeeded |
| `Failed` | Case B — the child reported a Fabric error. The nightly run will converge it | Yes, and it failed | Succeeded |
| `Caught` | Case A — an action failed outright. Set by `Scope_catch` | Maybe | **Failed** |

> **Only `Caught` ends the run red**, and that is the point of the last column. The four middle outcomes are ordinary states of a system where another team owns the input data — marking them failed would bury the real failures in a run history that is mostly red, and this flow now runs unattended at whatever rate that team edits their table.
>
> `Failed` staying green is the debatable one. It is green because the error is already recorded on the `Capacity Policies` row by the child flow, and because the nightly rebuild is expected to fix it — not because nothing went wrong. If operations would rather be paged for it, the change is a `Terminate` on the **No** branch of `Condition_rebuild_ok`, not a change to the scopes.

> **Nothing reads this.** It exists so that "why did this run do nothing" is answerable from the run history without re-deriving it from four action outputs — which matters far more now that runs happen unattended and in bulk than it did when a user was waiting for the answer.
>
> **The frequency of each outcome inverts with the trigger change.** `NotEnabled` was the common one and is now nearly unreachable; `WrongCapacity` was a caller error and is now the ordinary way an ungoverned capacity exits. If the run history does not look like that after a week, something in Step 2b is not doing what this document claims.

> **`Added` is not a promise that this run changed anything.** It means the rules now match Dataverse and the workspace is in them. Two edits to the same row in quick succession produce `Added` twice; that is correct, and `replaceByPolicy` makes it harmless.

---

## Step 7 — Try and Catch

Build this **last**, once the flow works without it. Wrapping a flow that already behaves is a mechanical change; debugging a Catch and a broken body together is not.

### 7a. `Scope_try`

**+ New step** → **Control** → **Scope**, renamed `Scope_try`. Drag Steps 2b, 3, 4a–4c and 5 into it, in order.

**No action inside is edited.** Variables are global in Power Automate, so every `variables('capacityId')`, every `body('Get_policy_row')` and every `triggerOutputs()` reference resolves exactly as before. This is the whole reason the change is small.

The five `Initialize variable` actions stay **above** the scope — see Step 2.

> ### Then check every action inside for *has failed*
>
> There should be exactly none, once Step 5 is done. A single action configured to run after **has failed** makes `Scope_try` report **Succeeded** even though something inside it failed, and `Scope_catch` is then skipped — verified in [SCOPE-SANDBOX.md](docs/flows/capacity-policies/SCOPE-SANDBOX.md) E3.
>
> This is the failure mode to watch for over the life of the flow, because it is invisible on the canvas and arrives by accident: somebody adds an action, ticks *has failed* out of ordinary caution, and disables the error handling for that branch without touching the Catch or leaving any trace that they did.

### 7b. `Scope_catch`

**+ New step** → **Control** → **Scope**, renamed `Scope_catch`. ⋯ → **Configure run after** on `Scope_try`: tick **has failed**, **is skipped** and **has timed out**. Untick *is successful*.

Inside it, in order:

| # | Action | Detail |
|---|---|---|
| 1 | `Compose_error` — **Compose** | `result('Scope_try')` |
| 2 | `Filter_failed` — **Filter array** | From `result('Scope_try')`, condition `item()?['status']` **is equal to** `Failed` |
| 3 | `Set variable` | `outcome` = `Caught` |
| 4 | `Set_message` — **Set variable** | `message` = the expression below |
| 5 | `Condition_row_known` — **Condition** | `empty(variables('policyRowId'))` is equal to `false` |
| 6 | └ **Yes** → `Update_policy_error` | Dataverse **Update a row** — see below |
| 7 | `Terminate` | Status **Failed**, message `concat(variables('outcome'), ' — ', variables('message'))` |

### The `message` expression

```
concat(coalesce(first(body('Filter_failed'))?['name'], 'no failed action in Scope_try'), ': ', coalesce(first(body('Filter_failed'))?['error']?['message'], 'scope was skipped or timed out'), ' | run ', workflow()?['run']?['name'])
```

**Copy it from the code block, not from a table cell.** It contains a `|` in the literal `' | run '`, which has to be escaped as `\|` to survive a markdown table — and a `\|` pasted into the designer is a broken expression that fails at runtime rather than at save. The same applies anywhere else this string is reproduced.

> ### Both `coalesce` fallbacks are load-bearing, and both are verified
>
> `Scope_catch` fires on **Failed, Skipped and TimedOut**, but `Filter_failed` only matches `Failed`. On the other two paths it returns an empty array and every expression here runs against `first([])`.
>
> [SCOPE-SANDBOX.md](docs/flows/capacity-policies/SCOPE-SANDBOX.md) E11 ran exactly that: **`first([])` returns null and does not throw**, the Catch completed cleanly, and `result()` resolved normally even for a scope that never ran. **So no length check and no extra Condition is needed** — the two `coalesce` wrappers are sufficient on their own.
>
> The fallback *text* matters more than it looks. E11's first attempt produced `unknown: no message`, which is safe and tells the reader nothing. The wording above produces `no failed action in Scope_try: scope was skipped or timed out`, which distinguishes *the scope never ran* from *something inside it broke* — two situations with different causes that would otherwise need the run opened to tell apart.
>
> **In this flow the realistic trigger for that path is a TimedOut scope**, since a timed-out action does not carry `status: Failed`. `Skipped` would need something above `Scope_try` to fail, and the only actions there are `Initialize variable`, which cannot.
>
> On that path **the run ID is the only informative thing in the string**. That is the clearest argument for keeping it.

Verified end to end in [SCOPE-SANDBOX.md](docs/flows/capacity-policies/SCOPE-SANDBOX.md) E9, E10 and E11.

**The Terminate's message repeats `Compose_result`'s expression deliberately.** Step 6 never runs on this path — the Terminate ends the run first — so this is where the `Caught` outcome gets recorded. Keep the two strings identical or the run history formats the same information two ways.

> ### The Terminate is not optional — verified 2026-09-12
>
> Without it a caught error produces a **green run**. Measured in [SCOPE-SANDBOX.md](docs/flows/capacity-policies/SCOPE-SANDBOX.md) E7: `Scope_try` failed, `Scope_catch` ran and succeeded, and the portal reported *"Your flow ran successfully."*
>
> This is the same rule as Step 5's, one level up. **A handled failure reports clean at every level** — handle it inside a Scope and the Scope goes green (E3); handle a Scope's failure with a Catch and the *run* goes green (E7).
>
> The consequence inverts the usual reason for reaching for try/catch, so it is worth stating plainly:
>
> > **A try/catch without a Terminate is worse than no try/catch at all.** With no scopes, a failure fails the run loudly and somebody finds out. Add a Catch that only logs, and the identical failure produces a green run, no owner notification and nothing in the failure list. That is not error handling — it is a visible failure converted into an invisible one.
>
> Writing `ubsppcoe_lasterror` does **not** substitute for this. Nobody watches a column. The Terminate is what puts the run where a human looks.
>
> **This is also why `Compose_result` does not run on the caught path** — Step 6. Losing that action here is the price of the run being red, and it is the right trade: the Terminate's message carries the same string.

> ### The filter is an action, not an expression
>
> There is no `filter(array, item => ...)` in this language. The Workflow Definition Language has `first`, `last`, `take`, `skip`, `union`, `intersection` and `join`, and **no lambda syntax at all**. Narrowing `result()` to the failed entry is the **Filter array** *action*, which is why row 2 above is an action.
>
> The expression form looks plausible enough to be worth naming: the designer accepts it in the box and rejects it on save.

> ### `result()` returns immediate children only — and that matters here
>
> Verified in [SCOPE-SANDBOX.md](docs/flows/capacity-policies/SCOPE-SANDBOX.md) E1: a five-action scope returned **three** entries. **`result('Scope_try')` lists the scope's immediate children and does not recurse.** A nested container appears as one entry; what happened inside it does not appear at all.
>
> In this flow that is not an edge case. `Run_rebuild` — the action most likely to fail — sits **three Conditions deep**. When it hard-fails, `Filter_failed` will surface `Condition_workspace_found`, the outermost container, and **never the name `Run_rebuild`**.

> ### What the error column will actually contain — read this before promising anyone anything
>
> E8 settled it. A container whose child failed reports `status: Failed` and **does** carry an error, and the error is this, every time, for every cause:
>
> ```
> "An action failed. No dependent actions succeeded."
> ```
>
> No action name, no Fabric error, nothing that distinguishes a dead child flow from a malformed Dataverse filter. So `ubsppcoe_lasterror` will read — and this is a **real, measured** output, not an illustration ([SCOPE-SANDBOX.md](docs/flows/capacity-policies/SCOPE-SANDBOX.md) E9):
>
> ```
> Condition: An action failed. No dependent actions succeeded. | run 08584123630290374015221423576CU18
> ```
>
> **That is a signpost, not a diagnosis**, and it is worth being blunt about because the string does not look like one. A blank column would be obviously broken and someone would fix it; this sentence reads like the system told you something, and it will be pasted into tickets for months before anyone notices it is identical every time.
>
> **The run ID is the part that earns its place.** Verified in E9: `workflow()?['run']?['name']` returns the identifier used in the portal's run URL, so the history is findable and the real error is one click away. It also resolves **independently of the filter**, so it survives even on a path where nothing matched. Without it the column is worthless; with it the column is a pointer.
>
> ### Decided 2026-09-12 — `Scope_try` keeps its nesting
>
> Flattening would fix this, and that is measured rather than argued. E10 ran the identical flow with the failing action moved out of its Condition and produced a real diagnosis:
>
> ```
> Compose_boom: Unable to process template language expressions in action 'Compose_boom'
> inputs at line '0' and column '0': 'Attempt to divide an integral or decimal value by
> zero in function 'div'.'. | run 08584…
> ```
>
> Same flow, same failure, same expressions — the only difference is one level of nesting.
>
> **It is not being done.** The body stays as built: Steps 3, 4a–4c and 5 keep their Conditions, and `Run_rebuild` stays three levels deep. Restructuring a working, tested flow to improve the wording of a diagnostic column is not a good trade, and "the error column would read better" was never a strong enough reason on its own.
>
> **The accepted cost:** `ubsppcoe_lasterror` is a **signpost, permanently**. It will name a container, carry a boilerplate sentence, and point at a run. Diagnosis happens by opening that run, not by reading the column.
>
> **This raises the stakes on the run ID.** It is no longer a convenience — it is the only route from the column to the actual error. If it is ever dropped from the expression, the column stops being worth writing at all.
>
> **Recorded here so it is not rediscovered as a defect.** Somebody will eventually read E10, see that flattening produces a better message, and propose it as an obvious improvement. It was considered, it works, and it was declined.

> ### One assumption the expression rests on: the scope stays sequential
>
> `result()` does **not** return entries in execution order. E10 measured an array ordered `Condition, Compose_last, Compose_boom, Compose` against `startTime` values running `Compose_boom, Compose, Condition, Compose_last` — no relationship to execution, reverse execution or alphabetical.
>
> So `first(body('Filter_failed'))` picks an **arbitrary** failed entry, not the first one to fail. It is correct here only because a sequential scope produces exactly **one** `Failed` entry — whatever broke first — and everything after it is `Skipped`, which the filter excludes. With one match, order cannot matter.
>
> **If a parallel branch is ever added inside `Scope_try`, this breaks quietly.** Two failures become two matches, `first()` returns one of them with no indication it chose, and the error column starts reporting a coin flip. Nothing in the flow will look wrong.

> ### Never write raw `result()` to the column
>
> Every entry carries `inputs` and `outputs` **verbatim** (E1). On `Get_workspace_row` that is the Dataverse query and every row it returned; on `Get_policy_row` likewise. Writing the array whole would push that into a 2000-character text column — truncated at best, and at worst putting inventory data somewhere nobody intended it to be.
>
> Extract `name`, `code` and `error.message`. Nothing else, ever.
>
> The same reasoning applies to `Compose_error` in row 1 above: it holds the raw array for the run history, which is fine, but **it is not what row 4 writes**.

**`result()` is new to this solution.** Nothing else in the seventeen flows uses it, it is absent from the expression picker (type it by hand), and the entry shape varies by action type — a `Condition` entry carries no `code` field at all where a `Compose` does. Every read of it uses `?[]` and every displayed value is coalesced.

**Rename actions before relying on `name`.** `result()` reports the internal action name, not the display name; an unrenamed Compose reports as `Compose`.

### 7c. `Update_policy_error`

| Field | Value |
|---|---|
| Table name | `Capacity Policies` |
| Row ID | `variables('policyRowId')` |
| `ubsppcoe_lasterror` | the error text from `Compose_error` |

**That column and no other.** Do not stamp `ubsppcoe_lastrebuild` — no rebuild happened, and a fresh timestamp beside a fresh error reads as "we rebuilt and it broke" rather than "we never got there".

> ### Why the `empty(policyRowId)` guard exists
>
> The Catch has to survive the failure of the action that would have told it where to write. If `Get_policy_row` is what failed — a malformed filter returning `400` is the realistic case — then `policyRowId` is still empty, and an unguarded `Update a row` fails on a blank Row ID. **A Catch block that throws is worse than no Catch block**, because the run history then blames the error handler instead of the error.
>
> On that branch the `Compose` and the `Terminate` are the entire record. That is acceptable: a failure that early is a defect in this flow, not a fact about a capacity, and the run history is the right place for it.

> ### Open — which table the error is written to
>
> **Deferred deliberately, 2026-09-12.** Build 7c against `Capacity Policies` in the meantime.
>
> It is ours, it already carries `ubsppcoe_lasterror`, and the child flow writes the same column in the same convention ([RebuildCapacityPolicyRules](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) Step 10a). Nothing needs agreeing with anyone, and **it is the reversible choice** — moving a write later is one action's configuration.
>
> **If the answer comes back as `ubsppcoe_Workspace`, that is not a flow change.** Q23 in [CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §7 is an absolute rule that no flow in this design writes any column on `ubsppcoe_Workspace` or `ubsppcoe_Node`, and it is absolute because those tables are another team's and other systems act on them. It would mean their schema change, their sign-off, and reopening a decision this design rests on in several places. **Raise it rather than building it.**
>
> There is also a practical objection worth putting to whoever decides. The error being recorded is about a **capacity's rules**, not about a workspace — a single failed rebuild concerns every workspace on that capacity, so writing it to the one workspace row that happened to trigger the run files it in the wrong place and makes it look narrower than it is.

---

## What the app must do

**Nothing. Stop calling this flow.** Setting `ubsppcoe_oapenabled` is what publishes a whitelist change now, and whoever sets it — app, bulk import, or the platform team's provisioning — gets the rebuild for free. Remove the call rather than leaving it: a Power Apps call to a flow with a Dataverse trigger fails at the connector, not silently.

**What the app loses is the answer.** There is no `Respond`, so nothing comes back and nothing can be shown to a user. An app that wants to confirm the outcome has to read `ubsppcoe_lastrebuild` and `ubsppcoe_lasterror` on the `Capacity Policies` row, which is what [ListCapacityPolicySets](docs/flows/capacity-policies/ListCapacityPolicySets.md) already surfaces — and which lags the edit by however long the run takes.

### A `Node` move still only rebuilds the new capacity

The trigger fires with the row's **new** Node and nothing carries the old one, so the workspace stays in the old capacity's rules until the nightly run. This is **Q17**, and the trigger does not close it — it removes the risk of the app forgetting the remove call and replaces it with a structural inability to make it. Worth stating plainly, because "it is automatic now" reads as though the gap went away.

### The inventory is not Fabric

**The `Node` lookup is the CMDB's opinion.** Fabric accepts any well-formed GUID in a `workspace.id` condition — a stale row, a deleted workspace, or one already moved elsewhere is stored happily and simply never matches. Nothing fails, and the owner is left with a policy that looks correct and denies them.

Nothing in this flow can confirm the workspace against `GET /v1/workspaces/{id}`, and it should not try — it makes no Fabric calls at all. Where the inventory disagrees with Fabric the fix belongs in `ubsppcoe_Workspace`, which is a request to its owners.

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | Set `ubsppcoe_oapenabled` to **Yes** on a workspace whose capacity has no others | Flow fires; `Added`; rules go from 1 to 2 |
| 2 | Save the row again with no change | Trigger does **not** fire — `Select columns` is doing its job |
| 3 | Edit a column *not* in `Select columns` | Trigger does **not** fire |
| 4 | Enable the 50th workspace on a capacity | `Added`; rules go from 2 to 3, split 49 + 1 |
| 5 | Enable a workspace whose `Node` is blank | Trigger does **not** fire — the `ne null` half of `Filter rows` |
| 6 | Enable a workspace on a capacity with **no `Capacity Policies` row** | `WrongCapacity`, **no rebuild**, run succeeds. Not a failed run |
| 7 | Corrupt one `ubsppcoe_capacityid` to another capacity's GUID, then enable a workspace on it | `WrongCapacity` — the Q29 round-trip check in 4b |
| 8 | Break the child flow deliberately | `Failed`, with the "nightly rebuild will apply it" message |
| 9 | Blank `ubsppcoe_workspaceid` on an enabled, assigned row | `NotFound` |
| 10 | Inspect any run's action list | **No write action against `ubsppcoe_Workspace` or `ubsppcoe_Node`** |
| 11 | Bulk-enable 20 workspaces across 3 capacities | 20 runs, serialised by Degree of Parallelism 1. **Time it** — this is the storm question at small scale |
| 12 | Set `ubsppcoe_oapenabled` to **No** | Trigger does **not** fire. The rules still contain the workspace until the nightly run — the gap `RemoveWorkspaceFromPolicy` has to close |
| 13 | **Turn the child flow off**, then enable a workspace | Case A. `Scope_catch` fires, `ubsppcoe_lasterror` written by **this** flow, run ends **Failed** |
| 14 | Put a bad `ubsppcoe_policysetid` on a `Capacity Policies` row, then enable a workspace on it | Case B. `Scope_catch` **skipped**, `ubsppcoe_lasterror` written by the **child**, run ends green with `outcome` = `Failed` |
| 15 | Point `Get_policy_row` at a non-existent column | `Scope_catch` fires, takes the `empty(policyRowId)` branch, and **does not itself fail** |
| 16 | Happy path | `Scope_catch` skipped, `Compose_result` still runs, `ubsppcoe_lasterror` left blank as the child set it |
| 17 | Try to save with an `Initialize variable` inside `Scope_try` | Validation error on save. Confirms the restriction rather than discovering it later |

Tests 2, 3 and 5 are the ones to write first. They verify the trigger's filters, which are the only part of this flow that is genuinely new — and a filter that is too loose does not fail, it just quietly rebuilds the estate all day.

**Tests 13 and 14 are the pair that proves the try/catch is wired correctly**, and they must be run together. Either one alone looks like a pass: 13 passing shows the Catch works, 14 passing shows the normal path works, and only the two side by side show that the *right* failure reaches the Catch and the other one deliberately does not.

Test 15 is the one people skip. A Catch that fails is worse than no Catch — the run history then blames the error handler instead of the error.

Test 12 is the standing reminder that this conversion is half finished.

Test 10 is the standing invariant for this whole design.
