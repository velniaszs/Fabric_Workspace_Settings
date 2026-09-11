# Flow — `AddWorkspaceToPolicy`

Confirms that a workspace really is whitelisted on a capacity, then rebuilds that capacity's rules. **Writes nothing to Dataverse.**

> **Built, and being converted.** The flow exists as an instant flow with a Power Apps (V2) trigger. The conversion below replaces the trigger and nothing else of substance.

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

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md), [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md), [RemoveWorkspaceFromPolicy.md](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md), [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §1–§2.

---

## 0. Before you start

- Build [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) first. This flow validates, then wraps it.
- Needs a **Dataverse connection** for reads only, and **not** the Entra ID HTTP connector. It makes **no Fabric calls of its own** — every Fabric interaction, and therefore the whole auth question, lives inside the child flow.

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
| Filter rows | `ubsppcoe_oapenabled eq true and _ubsppcoe_nodeid_value ne null` |

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

All four at the **top level**, before any Condition. `Initialize variable` is the one action Power Automate refuses to place inside a Condition — which is why `capacityId` starts empty here and is filled by Step 2b rather than being declared where it is derived.

> **The two new variables exist to avoid editing the body.** They hold what `triggerBody()['text']` and `triggerBody()['text_1']` used to hold, so converting Steps 3, 4a and 5 is a find-and-replace rather than a rethink. `workspaceId` reads `ubsppcoe_workspaceid` — the **Fabric** workspace GUID, not the row key `ubsppcoe_workspaceuniqueid` ([CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §1).

---

## Step 2b — Derive the capacity

The step the conversion turns on. **The trigger gives you the Node row GUID; it does not give you a capacity id**, and the capacity id is the only thing the child flow understands.

### `Get_policy_row` — Dataverse **List rows**

| Field | Value |
|---|---|
| Table name | `Capacity Policies` (`ubsppcoe_CapacityPolicy`) |
| Filter rows | `_ubsppcoe_node_value eq @{triggerOutputs()?['body/_ubsppcoe_nodeid_value']}` |
| Select columns | `ubsppcoe_capacityid` |
| Row count | `2` |

**The GUID is unquoted**, as always for a lookup filter. **Row count 2, not 1** — you are asserting one governed capacity per Node, and asking for one row would return the first of two and tell you nothing.

### `Set_capacityId` — **Set variable**

`capacityId` = `coalesce(first(body('Get_policy_row')?['value'])?['ubsppcoe_capacityid'], '00000000-0000-0000-0000-000000000000')`

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
> Step 2   Initialize_outcome / message / workspaceId / capacityId
> Step 2b  Get_policy_row → Set_capacityId
> Step 3   Get_workspace_row
>          Condition_workspace_found
>            ├─ No:  2 × Set variable            ← NotFound, no rebuild
>            └─ Yes: Step 4a  Get_node_row
>                          4b  Condition_node_matches
>                                ├─ No:  2 × Set variable   ← WrongCapacity
>                                └─ Yes: 4c  Condition_enabled
>                                            ├─ No:  2 × Set variable   ← NotEnabled
>                                            └─ Yes: Step 5  Run_rebuild
>                                                          Condition_rebuild_ok
> Step 6   Compose_result                     ← top level, reached by every path
> ```
>
> **So yes — 4c is inside 4b's Yes branch, and 4a/4b are inside Step 3's Yes branch.** Three levels by the time you reach Step 5. **The conversion adds two actions at the top and changes the last one; it moves nothing.**
>
> Terminate would now be *permissible* — there is no caller left to strand — and it would flatten this considerably. It is still not worth doing: the branches already work, and the only gain is readability of a flow nobody needs to re-read. **Leave the structure alone.**
>
> **Step 6 is the only action at the top level after Step 3.** Everything else lives on a branch.

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

Configure this Condition to run after `Run_rebuild` on **is successful** and **has failed**, so a hard failure of the child flow lands here rather than ending the run with no response.

### Yes

`outcome` = `Added`, `message` = `concat('Policy rules updated. ', body('Run_rebuild')?['workspacecount'], ' workspace(s) allowed on this capacity.')`

### No

`outcome` = `Failed`, `message` = `concat('The workspace is whitelisted in Dataverse but the rules could not be republished: ', coalesce(body('Run_rebuild')?['message'], 'the rebuild flow failed.'), ' The nightly rebuild will apply it.')`

> **There is nothing to roll back, and that is a real simplification.** Earlier drafts of this flow wrote a row (or a flag) and had to undo it when the rebuild failed — a compensating write that was itself not transactional. Since this flow writes nothing, a failed rebuild leaves the world exactly as it found it: Dataverse already said the workspace was whitelisted before the call, and the previously published rules are untouched.
>
> The only casualty is timing. The workspace is whitelisted according to Dataverse and not yet according to Fabric, and it stays that way until the next successful rebuild. Say so in the message rather than reporting a bare failure.

---

## Step 6 — Record the outcome

**Delete the `Respond to a Power App or flow` action** — it is invalid without a Power Apps or Request trigger and will block the save.

Replace it with `Compose_result` — **Compose**, run after the Condition on **is successful** and **has failed**:

```
@{variables('outcome')} — @{variables('message')}
```

| `outcome` | Meaning | Rebuild ran? |
|---|---|---|
| `Added` | Confirmed whitelisted, rules republished | Yes |
| `NotFound` | `ubsppcoe_workspaceid` is blank on the row, or duplicated. **An inventory defect** | No |
| `WrongCapacity` | The capacity is not governed, or our `ubsppcoe_capacityid` disagrees with the Node | No |
| `NotEnabled` | The flag was cleared between the trigger firing and the run starting. **Now rare** | No |
| `Failed` | Dataverse is right, Fabric is stale. The nightly run will converge it | Yes, and it failed |

> **Nothing reads this.** It exists so that "why did this run do nothing" is answerable from the run history without re-deriving it from four action outputs — which matters far more now that runs happen unattended and in bulk than it did when a user was waiting for the answer.
>
> **The frequency of each outcome inverts with the trigger change.** `NotEnabled` was the common one and is now nearly unreachable; `WrongCapacity` was a caller error and is now the ordinary way an ungoverned capacity exits. If the run history does not look like that after a week, something in Step 2b is not doing what this document claims.

> **`Added` is not a promise that this run changed anything.** It means the rules now match Dataverse and the workspace is in them. Two edits to the same row in quick succession produce `Added` twice; that is correct, and `replaceByPolicy` makes it harmless.

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

Tests 2, 3 and 5 are the ones to write first. They verify the trigger's filters, which are the only part of this flow that is genuinely new — and a filter that is too loose does not fail, it just quietly rebuilds the estate all day.

Test 12 is the standing reminder that this conversion is half finished.

Test 10 is the standing invariant for this whole design.
