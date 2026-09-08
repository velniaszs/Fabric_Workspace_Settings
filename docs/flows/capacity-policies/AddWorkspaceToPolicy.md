# Flow — `AddWorkspaceToPolicy`

Confirms that a workspace really is whitelisted on a capacity, then rebuilds that capacity's rules. **Writes nothing to Dataverse.**

> **Not built yet.** Specification, not a description of something that exists.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md), [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md), [RemoveWorkspaceFromPolicy.md](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md).

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

## Step 1 — Create the flow

**Solutions** → **New** → **Automation** → **Cloud flow** → **Instant** → name `AddWorkspaceToPolicy` → trigger **Power Apps (V2)**.

Two **Text** inputs, in this order:

| Order | Title | Key | Reference |
|---|---|---|---|
| 1 | `capacityId` | `text` | `triggerBody()['text']` |
| 2 | `workspaceId` | `text_1` | `triggerBody()['text_1']` |

Both required, and both are GUIDs. Getting them the wrong way round is caught — Step 3 returns `NotFound` — but add them in the order above anyway, and check the first run in the history. `AddWorkspaceToPolicy` and `RemoveWorkspaceFromPolicy` take the same two inputs in the same order, so the app calls both the same way.

---

## Step 2 — Variables

| Rename to | Name | Type | Value |
|---|---|---|---|
| `Initialize_outcome` | `outcome` | String | `Failed` |
| `Initialize_message` | `message` | String | *(empty)* |

---

## Step 3 — Find the workspace row

`Get_workspace_row` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Workspaces` (`ubsppcoe_Workspace`) |
| Filter rows | `ubsppcoe_workspaceid eq '@{triggerBody()['text_1']}'` |
| Select columns | `ubsppcoe_workspaceuniqueid,ubsppcoe_workspaceid,ubsppcoe_oapenabled,_ubsppcoe_nodeid_value` |
| Row count | `2` |

> **`ubsppcoe_workspaceid` is the Fabric workspace GUID, not the Dataverse row key.** These tables invert the usual convention — the row key is `ubsppcoe_workspaceuniqueid`. Filtering on the row key here matches nothing and returns `NotFound` for every caller.

`Condition_workspace_found` — **Condition**:

| Left | Operator | Right |
|---|---|---|
| `length(body('Get_workspace_row')?['value'])` | is equal to | `1` |

**No** → `outcome` = `NotFound`, `message` = `No workspace record exists for this ID, or more than one does. It must be registered before it can be whitelisted.` Stop — no rebuild.

Everything below goes in the **Yes** branch.

---

## Step 4 — Is it on the right capacity, and is it enabled?

### 4a. `Condition_node_matches` — **Condition**

| Left (expression) | Operator | Right |
|---|---|---|
| `first(body('Get_workspace_row')?['value'])?['_ubsppcoe_nodeid_value']` | is equal to | `triggerBody()['text']` |

**No** → `outcome` = `WrongCapacity`, `message` = `This workspace is not assigned to that capacity, so it will not appear in that capacity's rules.` Stop.

> **There is no query against `ubsppcoe_Node` here, and there does not need to be.** The Node row key **is** the Fabric capacity GUID ([CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §1), so the workspace's `Node` lookup value is already a capacity id and compares straight against the trigger input.
>
> What this drops is the old check that the capacity had a Node row at all. That is no loss: a capacity with no Node row has no workspaces pointing at it, so every call for it returns `WrongCapacity` — and if it also has no `Capacity Policies` row, Step 5's rebuild says so plainly.

> **This check is the reason the two GUIDs cannot be swapped by accident.** Both inputs are GUIDs, so passing them the wrong way round would otherwise produce a syntactically valid pair, a successful rebuild of the **wrong capacity**, and a confident success message. Rebuilding a policy the caller never asked about is the worst outcome available here, and it is a one-line mistake to make.

### 4b. `Condition_enabled` — **Condition**

| Left | Operator | Right |
|---|---|---|
| `first(body('Get_workspace_row')?['value'])?['ubsppcoe_oapenabled']` | is equal to | `true` |

**No** → `outcome` = `NotEnabled`, `message` = `This workspace is registered on the capacity but does not have OAP enabled, so it cannot be whitelisted. That flag is set by the platform team's process, not by this app.` Stop — **no rebuild**.

> **`false` and null both take the No branch, and that is correct.** `ubsppcoe_oapenabled` is nullable, so a row nobody has ever touched compares unequal to `true` exactly as an explicit `false` does. Neither is whitelisted, neither is added to any rule explicitly, and the message does not distinguish them — there is nothing the caller could do differently.

> **Refusing here rather than rebuilding is a judgement call, and this is the reasoning.** Rebuilding would be harmless: the workspace is not enabled, so the rules come out the same. But the caller asked to add a workspace, and returning a success outcome after a no-op rebuild is how an app ends up telling a user they have access they do not have.
>
> The cost is that a genuinely stale rule set on that capacity does not get republished by this call. The nightly run covers it, and "we refused and told you why" beats "we succeeded at something you did not ask for".

> **`NotEnabled` does not mean the workspace can create nothing.** An active `PolicyException` row puts it in rule 3, which never consults `ubsppcoe_oapenabled` ([CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §3) — so a workspace can be refused here and still be able to create anything on that capacity.
>
> This flow does not check for that, deliberately: it is about whitelisting, the answer is still "no, and here is why", and adding a query for a case that changes nothing about the outcome buys a second sentence and a second failure mode. The place that needs to know is [RemoveWorkspaceFromPolicy.md](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md), where the same fact turns a removal into a false confirmation.

Everything below goes in the **Yes** branch.

---

## Step 5 — Rebuild

`Run_rebuild` — **Run a Child Flow** → `RebuildCapacityPolicyRules`, passing `triggerBody()['text']`.

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

## Step 6 — Respond

**Respond to a Power App or flow**, run after the Condition on **is successful** and **has failed**. Two **Text** outputs:

| Output | Value |
|---|---|
| `Outcome` | `variables('outcome')` |
| `Message` | `variables('message')` |

| `outcome` | Meaning | Rebuild ran? |
|---|---|---|
| `Added` | Confirmed whitelisted, rules republished | Yes |
| `NotFound` | No workspace record for that ID, or more than one | No |
| `WrongCapacity` | The row exists but its `Node` is another capacity | No |
| `NotEnabled` | On the right capacity, but `ubsppcoe_oapenabled` is `false` or null. **The common one** | No |
| `Failed` | Dataverse is right, Fabric is stale. The nightly run will converge it | Yes, and it failed |

Both outputs **Text**. A non-Text field fails schema validation at runtime and makes *every* output of the flow unreadable to the app.

> **`Added` is not a promise that this call changed anything.** It means the rules now match Dataverse and the workspace is in them. Calling it twice returns `Added` twice; that is correct, and `replaceByPolicy` makes it harmless.

---

## What the app must do

### Handle `NotEnabled` as a normal outcome, not an error

It is what happens whenever provisioning runs ahead of whatever sets `ubsppcoe_oapenabled` — which, since the two are different systems, will be routine rather than exceptional. The message needs to tell the user **who** sets the flag and that the workspace will be picked up once it is set. An app that shows this as a red failure will generate tickets for something working as designed.

### Do not claim more than the outcome supports

`Added` is safe to phrase as *"workspace whitelisted"*. Nothing else is. In particular `Failed` means the whitelist is correct and the **rules** are stale, which is almost the opposite of what a user reads into the word.

### A `Node` move is a Remove then an Add

Moving a workspace between capacities changes **two** whitelists. Call [RemoveWorkspaceFromPolicy](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md) against the old capacity and this flow against the new one. The old-capacity call is the one that gets forgotten, and it fails silently — the workspace stays in rules it no longer belongs in until the nightly run.

### The inventory is not Fabric

**The `Node` lookup is the CMDB's opinion.** Fabric accepts any well-formed GUID in a `workspace.id` condition — a stale row, a deleted workspace, or one already moved elsewhere is stored happily and simply never matches. Nothing fails, and the owner is left with a policy that looks correct and denies them.

If the app can afford the call, confirm with `GET /v1/workspaces/{id}` that the workspace exists and that its `capacityId` agrees with the Node lookup. Where they disagree the inventory is stale, and the fix belongs in `ubsppcoe_Workspace` — which is a request to its owners, not something any flow here can do.

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | An enabled workspace on a capacity with no others | `Added`; rules go from 1 to 2 |
| 2 | The same call again | `Added` again, identical rule set, no duplicates |
| 3 | The 50th enabled workspace | `Added`; rules go from 2 to 3, split 49 + 1 |
| 4 | A row whose `ubsppcoe_oapenabled` is `false`, and again with it **null** | `NotEnabled` both times, and **no Fabric call** in the child flow's history |
| 5 | Break the child flow deliberately | `Failed`, with the "nightly rebuild will apply it" message |
| 6 | A workspace GUID with no row in `ubsppcoe_Workspace` | `NotFound` |
| 7 | A workspace whose `Node` is a different capacity | `WrongCapacity`; **no rebuild**, and the other capacity's rules untouched |
| 8 | Swap the two inputs — pass the capacity id as `workspaceId` | `NotFound`, not a silent no-op |
| 9 | Capacity with no `Capacity Policies` row | `Failed`, carrying the child flow's "run InitializeCapacityPolicySet first" message |
| 10 | Inspect any run's action list | **No write action against `ubsppcoe_Workspace` or `ubsppcoe_Node`** |
| 11 | Two calls for the same capacity at once | Both succeed. The child flow's concurrency limit of 1 serialises the rebuilds |

Test 4 is the one worth writing first — it is both the most common real outcome and the one a plain refresh flow could not report at all.

Test 10 is the standing invariant for this whole design.

> Testing from the designer reports **`ActionResponseSkipped`** on the Respond action — expected, since nothing is waiting for the response. The rebuild still happens.
