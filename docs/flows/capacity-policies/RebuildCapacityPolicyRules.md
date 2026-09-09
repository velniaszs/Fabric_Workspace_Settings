# Flow — `RebuildCapacityPolicyRules`

Child flow. **The only flow that writes policy rules.** Reads the desired state from Dataverse — the OAP-enabled workspaces under a capacity's Node row, plus this project's own exception list — and replaces every `ItemCreation` rule on that capacity's policy set in a single call.

> **Not built yet.** Specification, not a description of something that exists.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §2 and §3, [InitializeCapacityPolicySet.md](docs/flows/capacity-policies/InitializeCapacityPolicySet.md), [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md), [RemoveWorkspaceFromPolicy.md](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md).

---

## 0. Before you start

- **There is no token flow.** Fabric is called through the *HTTP with Microsoft Entra ID (preauthorized)* connector, which attaches the bearer token itself — see the box below. [GetPolicyToken.md](docs/flows/capacity-policies/GetPolicyToken.md) is retired.
- The new tables from [CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §3 must exist, and `Policy Item Types` must be seeded. `Policy Exceptions` may legitimately be empty.
- **This flow needs two connections** — Dataverse, and the Entra ID HTTP connector. Both appear in `connectionReferences` on export. That is expected here.
- Logical names below use the **`ubsppcoe_`** prefix — for the four tables this project creates **and** for the platform team's two. Since 2026-09-07 they share it, so **the prefix no longer tells you which table you are pointed at.** Pick tables and columns from the designer dropdowns rather than typing them, and see [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §0 for the two logical names that now exist on more than one table.

### How every Fabric call in this folder is made

**This is the pattern. It is written out once here; the other flow docs refer back to it.**

1. **+ New step** → search **HTTP with Microsoft Entra ID (preauthorized)**.
2. Choose the action **Invoke an HTTP request**.
3. First time only, create the connection: **Base Resource URL** and **Microsoft Entra ID Resource URI (Application ID URI)** are both `https://api.fabric.microsoft.com`.
4. Fill in **Method**, **URL of the request**, and where needed **Headers** and **Body of the request**.

| Do | Do not |
|---|---|
| Set `Content-Type: application/json` on POST and PATCH | **Add an `Authorization` header.** The connector adds it. A hand-written one is either ignored or breaks the call |
| Leave **Retry Policy** at Default — it covers `429` | Reference `variables('accessToken')`. There is no such variable any more |

**Headers, in full:** a `GET` needs none — `Accept: application/json` is optional and harmless, and the flow docs include it only so every `GET` looks alike. A `POST` or `PATCH` carrying a body needs `Content-Type: application/json`. Nothing in this design needs any other header.

> **The connection's identity is what Fabric sees**, not the flow and not whoever ran it. Every role in [CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §5 must be held by that identity. Which identity it should be is **Q45**, still open.

> **Verify the output shape on your first build.** This document keeps using `outputs('X')?['statusCode']` and `outputs('X')?['headers']` — the same expressions the plain `HTTP` action supports — because API-connection actions expose them too. Confirm it once in a real run before relying on the `202` branch in [InitializeCapacityPolicySet.md](docs/flows/capacity-policies/InitializeCapacityPolicySet.md) Step 7, which reads `x-ms-operation-id` out of the response headers. If the shape differs, that branch is the only thing that needs rewriting.

### The two tables this flow does not own

The workspace whitelist lives in the platform team's existing tables. This flow **reads** them and writes nothing back.

| Purpose | Name used below | Status |
|---|---|---|
| Capacity table | `ubsppcoe_Node` | Confirmed |
| Node row key — **and the Fabric capacity GUID** | `ubsppcoe_nodeuniqueid` | Confirmed 2026-09-07 |
| Workspace table | `ubsppcoe_Workspace` | Confirmed |
| Workspace row key | `ubsppcoe_workspaceuniqueid` | Confirmed 2026-09-07 |
| **Fabric workspace GUID** on the workspace row | `ubsppcoe_workspaceid` | Confirmed 2026-09-07 |
| `Node` lookup on the workspace row | `ubsppcoe_nodeid` — filtered as `_ubsppcoe_nodeid_value` | Confirmed 2026-09-07 |
| The whitelist flag — boolean | `ubsppcoe_oapenabled` | Confirmed 2026-09-07 |

> **Confirm every placeholder in the maker portal before you build Step 5.** Settings → Tables → the table → Columns, and read the **Logical name** column. A wrong name in a `Filter rows` expression does not fail loudly — Dataverse returns a `400` for an unknown column, but an expression that resolves to blank returns **every row**, which would whitelist every workspace in the tenant on one capacity.

> **The two tables treat their Fabric GUID in opposite ways. Read this twice.** On `ubsppcoe_Node` the row key **is** the Fabric capacity GUID, so `nodeRowId` below is also a capacity id. On `ubsppcoe_Workspace` they are separate and named the wrong way round: `ubsppcoe_workspaceid` looks like a row key and **is not** — it is the **Fabric workspace GUID**, and it is the column Step 5 filters and selects. The row key `ubsppcoe_workspaceuniqueid` never leaves Dataverse. Publishing row keys into `predicate.values` would be accepted by Fabric as well-formed GUIDs and then match nothing, denying a whole capacity with no error anywhere.

> **The capacity id is never filtered against a Node row here.** `Capacity Policies` carries a `node` lookup, so Step 4 reads the policy set id and the Node row GUID in one call. Confirming the Node row exists happens once, in [InitializeCapacityPolicySet.md](docs/flows/capacity-policies/InitializeCapacityPolicySet.md), when that row is created.

> **`ubsppcoe_oapenabled` = `true` is the whitelist, and this flow only reads it.** `false`, null, or no Node lookup means the workspace is in **no** rule — it is never added explicitly anywhere, and rule 1's deny-all is what applies to it. The flag is owned by another team — nothing in this design writes it, or any other column on either table. See [CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §3.

| Environment variable | Value |
|---|---|
| `ubsppcoe_PolicyHolderWorkspaceId` | The workspace holding the PolicySet items |
| `ubsppcoe_PolicySentinelWorkspaceId` | `00000000-0000-0000-0000-000000000000` |
| `ubsppcoe_PolicyMaxWorkspacesPerRule` | `49` |
| `ubsppcoe_PolicyMaxRulesPerPolicy` | `50` |

**Create these before building — they do not exist by default**, and a missing one fails at runtime with `The workflow parameter … is not found`. Steps in [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §8.11.

> ### The one thing that must not go wrong
>
> `replaceByPolicy` **overwrites every rule of the policy, including rule 1**. A capacity with no whitelisted workspaces must still receive rule 1 on its own.
>
> A policy with **zero** rules is not an empty allow-list — it is an unenforced policy, and the capacity silently unlocks. Rule 1 is therefore built as a hard-coded array element in Step 8, never as the output of a loop that happens to run at least once.

> ### Three kinds of rule, and rule 3 is the odd one
>
> | | Conditions | Effect |
> |---|---|---|
> | Rule 1 — deny-all baseline | `workspace.id AnyOf [sentinel]` | Allow, never matches |
> | Rule 2..n — whitelist | `workspace.id AnyOf [chunk]` **and** `item.type AnyOf [types]` | Allow |
> | Rule 3 — exceptions | `workspace.id AnyOf [chunk]` — **and nothing else** | Allow |
>
> **Rule 3's missing second condition is the entire feature, not an omission.** With no `item.type` condition the rule matches every item type, so a workspace listed there can create anything the policy governs. If you copy Step 7a to build Step 7d and leave the `item.type` block in, the exception silently degrades into an ordinary whitelist entry and nobody notices until someone tries to create the item type they were excepted for.
>
> **All three are scoped to this capacity by the same `Node` lookup.** Rule 3's workspaces come from a tenant-wide table, so the join in Step 5l is what keeps them here — and what makes a workspace that has moved capacity disappear from this capacity's rules without anyone deleting anything.

---

## Step 1 — Create the flow

**Solutions** → your solution → **New** → **Automation** → **Cloud flow** → **Instant** → name it `RebuildCapacityPolicyRules` → trigger **Manually trigger a flow**.

Add one input: **+ Add an input** → **Text**, titled `capacityId`. Referenced as `triggerBody()['text']`.

> Trigger must be **Manually trigger a flow** so the other flows can call it with `Run a Child Flow`.

> ### Do **not** set Concurrency Control on this trigger
>
> Power Automate rejects it:
>
> > *Concurrency control is not supported when the workflow contains actions of type 'Response' without the operationOptions flag set to 'Asynchronous'.*
>
> A request-response flow — a **Manually trigger a flow** trigger plus a `Respond to a Power App or flow` action — cannot have trigger concurrency at all. Making the Response asynchronous would satisfy the platform and defeat the point, since every caller needs the answer.
>
> **The consequence: two rebuilds of the same capacity can overlap, and the later write wins.** That is tolerable, because both runs read the same Dataverse state and `replaceByPolicy` publishes the whole rule set from it — so the two agree unless the data changed in the seconds between their reads. If it did, the loser's view is at most seconds stale and the next rebuild, or the nightly run, converges it.
>
> **Serialisation happens where the volume is**, not here: [RebuildAllCapacityPolicies](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) is Recurrence-triggered with no `Respond`, so it *can* set Degree of Parallelism 1 — both on its trigger and on its loop. The nightly batch therefore never overlaps itself, which is the only case that would have produced concurrent rebuilds at scale.

> ### The shape of this flow — three guards, and you do **not** nest them
>
> Steps 4, 5a and 6 are early exits with an identical shape:
>
> **Condition → *Yes*: Respond, then Terminate. *No*: leave empty.**
>
> Because every one of those *Yes* branches ends in **Terminate**, which stops the entire run immediately, **everything that follows a guard sits at the top level as a sibling.** Do not put the rest of the flow inside the *No* branch.
>
> Nesting would work, but it compounds: three guards inside one another puts Step 10 four levels deep, and the designer becomes very hard to work in. Flat, the flow reads as a straight line with three ejector seats.
>
> | Condition | Ends in Terminate? | So the rest of the flow is… |
> |---|---|---|
> | Step 4 `Condition_policy_exists` | Yes | a sibling after it |
> | Step 5a `Condition_node_linked` | Yes | a sibling after it |
> | Step 6 `Condition_too_many_rules` | Yes | a sibling after it |
> | Step 5k `Condition_has_candidates` | **No** | **genuinely nested** — 5l, 5m and 5n live in its *No* branch |
>
> **5k is the only Condition whose branch holds anything.** It has no Terminate, so its contents must be inside it.
>
> Two `Apply to each` loops also nest their contents, for the ordinary reason that loops do — Steps 7 and 7c. Everything else in the flow is a sibling at the top level:
>
> ```
> trigger
> Step 3   12 × Initialize variable
> Step 4   Get_policy_row
>          Condition_policy_exists          ── Yes: Respond + Terminate │ No: empty
>          Set_policySetId / Set_nodeRowId / Set_policyRowId
> Step 5   Condition_node_linked            ── Yes: Respond + Terminate │ No: empty
>          5b … 5j
>          Condition_has_candidates         ── No: 5l, 5m, 5n
> Step 6   Set_chunkCount / Set_exceptionChunkCount
>          Condition_too_many_rules         ── Yes: Respond + Terminate │ No: empty
> Step 7   For_each_whitelist_chunk         ── Compose + Append
> Step 7c  For_each_exception_chunk         ── Compose + Append
> Step 8   Compose_rule1 / Compose_body
> Step 9   Replace_rules
> Step 10  Update_policy_row / Respond_rebuilt
> ```
>
> **Steps 8–10 must sit after the loops, not inside them.** `Compose_body` reads `whitelistRules` and `exceptionRules`, which are only complete once both loops have finished. Dropped inside a loop it would run once per chunk against a half-filled array, and publish a policy set missing its later rules.
>
> **The Terminate actions are load-bearing.** The flat structure is safe *only* because they are there. Delete one while tidying up and the flow carries straight on past a failed guard — rebuilding a capacity from data it has just declared unusable, which is exactly what the guards exist to prevent.

> ### Building a guard exit — the same two actions every time
>
> **1. Respond to a Power App or flow**, carrying all six Text outputs from Step 10b. **2. Control → Terminate**, Status **`Succeeded`**. In that order.
>
> **Name both actions after the guard** — `Respond_no_node` / `Terminate_no_node`, and so on. Left at their defaults you get `Terminate`, `Terminate 2` and `Terminate 3`, and a run history that cannot tell you which guard fired without opening each one.
>
> **Respond must come first.** `Terminate` ends the run immediately, so a Respond placed after it never executes and the caller receives nothing at all.
>
> **Status is `Succeeded`, not `Failed`, and that is deliberate.** These flows are called with `Run a Child Flow`. Terminating as `Failed` makes that call fail in the parent, which then cannot read the Respond payload — the caller gets a flow fault instead of `Outcome = Failed` and a sentence explaining why. The flow did its job: it detected a bad state and reported it. Reserve a genuine failure for when the flow itself breaks.
>
> **Fill in every one of the six outputs, even the ones that are zero or blank.** Step 10b explains why: a caller reading a field the taken branch never declared gets a blank rather than an error, so a parent flow silently treats a missing `RuleCount` as nothing at all.

---

## Step 2 — The Fabric connection

**Nothing is built in this step** — it replaces what used to be the token step, and the numbering below is unchanged so existing references still resolve.

The first time you add an **Invoke an HTTP request** action (Step 9), Power Automate asks you to create the connection. Create it once, as described in §0, and every later flow reuses it from the dropdown.

> **There is no `accessToken` variable in this flow, and no `Run a Child Flow` at the top.** If you are copying an older draft, delete both.

---

## Step 3 — Variables

Twelve `Initialize variable` actions, in order.

| Rename to | Name | Type | Value |
|---|---|---|---|
| `Initialize_policySetId` | `policySetId` | String | *(leave empty)* |
| `Initialize_nodeRowId` | `nodeRowId` | String | *(leave empty)* |
| `Initialize_policyRowId` | `policyRowId` | String | *(leave empty)* |
| `Initialize_maxPerRule` | `maxPerRule` | Integer | `int(parameters('PolicyMaxWorkspacesPerRule (ubsppcoe_PolicyMaxWorkspacesPerRule)'))` |
| `Initialize_workspaces` | `workspaces` | Array | *(leave empty)* |
| `Initialize_itemTypes` | `itemTypes` | Array | *(leave empty)* |
| `Initialize_exceptionCandidates` | `exceptionCandidates` | Array | *(leave empty)* |
| `Initialize_exceptions` | `exceptions` | Array | *(leave empty)* |
| `Initialize_whitelistRules` | `whitelistRules` | Array | *(leave empty)* |
| `Initialize_exceptionRules` | `exceptionRules` | Array | *(leave empty)* |
| `Initialize_chunkCount` | `chunkCount` | Integer | `0` |
| `Initialize_exceptionChunkCount` | `exceptionChunkCount` | Integer | `0` |

> **All of these must sit at the top level of the flow, before the first Condition.** `Initialize variable` is the one action Power Automate refuses to place inside a Condition, Scope or Apply to each — the designer offers it and then fails validation on save, which is a confusing way to find out. Everything below sets these with **Set variable**, or with **Append to array variable** in Steps 7 and 7c.

> **`whitelistRules` and `exceptionRules` exist because the rules are built in a loop** (Step 7). Appending to an array variable is the only way to accumulate across `Apply to each` iterations — which is also why they cannot be declared next to the loop that fills them.

That is why `policySetId`, `nodeRowId` and `policyRowId` start empty and are assigned later, rather than being initialised from a lookup that has not run yet.

---

## Step 4 — Find the policy set

**+ New step** → Dataverse **List rows**. Rename it `Get_policy_row`.

| Field | Value |
|---|---|
| Table name | `Capacity Policies` |
| Filter rows | `ubsppcoe_capacityid eq '@{triggerBody()['text']}'` |
| Select columns | `ubsppcoe_capacitypolicyid,ubsppcoe_policysetid,_ubsppcoe_node_value` |
| Row count | `1` |

**+ New step** → **Condition**, renamed `Condition_policy_exists`:

| Left (expression) | Operator | Right |
|---|---|---|
| `empty(body('Get_policy_row')?['value'])` | is equal to | `true` |

**Yes** branch — two actions, in this order:

**1. `Respond_no_policy_row`** — **Respond to a Power App or flow**. **All six Text outputs, not two:**

| Output | Type | Value |
|---|---|---|
| `Outcome` | **Text** | `Failed` |
| `PolicySetId` | **Text** | `variables('policySetId')` |
| `RuleCount` | **Text** | `0` |
| `WorkspaceCount` | **Text** | `0` |
| `ExceptionCount` | **Text** | `0` |
| `Message` | **Text** | `No policy set is registered for this capacity. Run InitializeCapacityPolicySet first.` |

**Every output box is required — none can be left blank.** `PolicySetId` uses the same expression as the other three Responds even though there is no policy set here: `policySetId` was initialised to an empty string in Step 3 and nothing has set it, so it evaluates to empty on its own. That keeps one expression across all four exits instead of a special case.

**The three counts are Text, not Number — type `0` into a Text field.** Picking Number because the name looks numeric is the mistake; see the typing rule at Step 10b.

**2. `Terminate_no_policy_row`** — **Control** → **Terminate**, **Status = `Succeeded`**. The caller gets an answer, and this is a caller error rather than a flow fault.

> **Declaring only `Outcome` and `Message` here would be a bug**, and a quiet one. Every `Respond` in this flow must declare the same six outputs — see Step 10b. A caller reading `RuleCount` from a response that never declared it gets a **blank, not an error**, which a parent flow then treats as zero.

**Leave the *No* branch empty.** Then, back at the **top level** after the Condition, three **Set variable** actions:

| Rename to | Name | Value |
|---|---|---|
| `Set_policySetId` | `policySetId` | `first(body('Get_policy_row')?['value'])?['ubsppcoe_policysetid']` |
| `Set_nodeRowId` | `nodeRowId` | `first(body('Get_policy_row')?['value'])?['_ubsppcoe_node_value']` |
| `Set_policyRowId` | `policyRowId` | `first(body('Get_policy_row')?['value'])?['ubsppcoe_capacitypolicyid']` |

> **One read, three values.** `Capacity Policies` carries a `node` lookup to `ubsppcoe_Node` ([CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §3), so this row already holds the Node row GUID. There is no second query against the Node table — confirming the Node exists happens once, in flow 1, when the row is created.
>
> **`nodeRowId` will equal `triggerBody()['text']`**, because the Node row key is the Fabric capacity GUID. Use the variable anyway rather than the trigger input: it is the value that proves a Node row was linked, and if the platform team ever stops keying Nodes on the capacity id, this flow keeps working and only flow 1 needs changing.
>
> `policyRowId` is this row's own key, and Step 10a updates the row with it — reading it here saves repeating the `first(...)` expression at the far end of the flow.
>
> Read the Node value from the **`_ubsppcoe_node_value`** form, with the leading underscore and the `_value` suffix. `ubsppcoe_node` on a `List rows` result is not the GUID; it is either absent or an expanded object, depending on what was selected.
>
> **This is `Capacity Policies`.`_ubsppcoe_node_value` — note the missing `id`.** The workspace table's lookup is `ubsppcoe_nodeid`, read as `_ubsppcoe_nodeid_value`, and Step 5 uses that one. Two different columns four characters apart, both resolving to the same capacity GUID; see [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §0.

**Leave the *No* branch empty and continue at the top level.** Step 5 onwards are siblings of this Condition, not children of it — the *Yes* branch terminates, so nothing after it runs on that path. See the shape box in Step 1.

> **The three `Set variable` actions above are siblings too**, not children of the Condition. Power Automate variables are scoped to the **run**, not to the branch they were set in, so Step 5 reads them perfectly well from the top level. Putting them inside the *No* branch would also work — it is just the one place where doing so buys nothing and breaks the "every guard's *No* branch is empty" rule.

---

## Step 5 — Read the desired state

Three lists come out of Dataverse here: the whitelist (`ubsppcoe_Workspace` rows whose `Node` is this capacity **and** whose `ubsppcoe_oapenabled` is `true`), the governed item types, and the exception workspaces — which are approved centrally and then narrowed to this capacity by the same `Node` lookup. `nodeRowId` and `policyRowId` are already in hand from Step 4.

**Fourteen actions, of which exactly three are nested:**

```
5a  Condition_node_linked        ── guard: Yes = Respond + Terminate, No = empty
5b  List_workspace_rows          ─┐
5c  Select_workspace_ids          │ the whitelist
5d  Set_workspaces               ─┘
5e  List_item_type_rows          ─┐
5f  Select_item_types             │ the governed item types
5g  Set_itemTypes                ─┘
5h  List_exception_rows          ─┐
5i  Select_exception_ids          │ exception candidates, tenant-wide
5j  Set_exceptionCandidates      ─┘
5k  Condition_has_candidates      ── Yes: empty
        └─ No:  5l  List_exception_workspace_rows   ─┐
                5m  Select_exception_workspace_ids   │ narrowed to this capacity
                5n  Set_exceptions                  ─┘
Step 6 …                          ── back at the top level
```

Everything except 5l, 5m and 5n sits at the top level.

### 5a. `Condition_node_linked` — **Condition**

| Left (expression) | Operator | Right |
|---|---|---|
| `empty(variables('nodeRowId'))` | is equal to | `true` |

**Yes** branch — two actions, in this order:

**1. `Respond_no_node`** — **Respond to a Power App or flow**, with the same six **Text** outputs as Step 10b:

| Output | Type | Value |
|---|---|---|
| `Outcome` | **Text** | `Failed` |
| `PolicySetId` | **Text** | `variables('policySetId')` — known, Step 4 set it |
| `RuleCount` | **Text** | `0` |
| `WorkspaceCount` | **Text** | `0` |
| `ExceptionCount` | **Text** | `0` |
| `Message` | **Text** | `This capacity's policy row has no Node link, so its workspaces cannot be determined.` |

**2. `Terminate_no_node`** — **Control** → **Terminate**, **Status = `Succeeded`**.

**Leave the *No* branch empty** — 5b onwards are siblings of this Condition, not children of it.

> ### Failing here is the whole safety argument
>
> A blank Node link and a capacity whose workspaces are all disabled produce the **same empty workspace list**, and one of them means "rebuild with rule 1 alone" while the other means "we cannot see this capacity's workspaces at all".
>
> Continuing past a blank link would strip a live whitelist off a working capacity, report `Rebuilt`, and leave rule 1 sitting there looking exactly like the intended default. **Zero enabled workspaces under a Node that resolves is fine. A Node that does not resolve is not.**
>
> The link can be blank two ways: flow 1 never set it, or the Node row was deleted and Dataverse nulled the lookup. Both mean the same thing here.

### 5b. `List_workspace_rows` — Dataverse **List rows**

| Field | Value |
|---|---|
| Table name | `Workspaces` (`ubsppcoe_Workspace`) |
| Filter rows | `_ubsppcoe_nodeid_value eq @{variables('nodeRowId')} and ubsppcoe_oapenabled eq true` |
| Select columns | `ubsppcoe_workspaceid` |
| Row count | `5000` |

⋯ → **Settings** → **Pagination On**, Threshold `5000`. Without it you silently get the first page only, and a capacity over the page size loses workspaces on every rebuild — a data-loss bug that looks like a Fabric problem.

Three things about that filter are easy to get wrong.

**The lookup is `_ubsppcoe_nodeid_value`, with the leading underscore and the `_value` suffix.** `ubsppcoe_nodeid eq '…'` is not a queryable column and returns a `400`. It is **not** `_ubsppcoe_node_value` either — that is our own `Capacity Policies` lookup from Step 4, and against this table it is simply an unknown column.

**The GUID is not quoted.** Lookup and unique-identifier columns compare against a bare GUID — `_ubsppcoe_nodeid_value eq 6f9a…`, no apostrophes. Quoting it is the one that produces a confusing error rather than a clear one.

**`eq true`, not `eq 'Yes'`.** `ubsppcoe_oapenabled` is a boolean. It is also nullable: rows where nobody has ever set it are `null`, and `eq true` correctly excludes them alongside the explicit `false` rows — which is exactly the intended behaviour. **`false` and null are the same thing here: not whitelisted, and not added to any rule explicitly.** Do not add `and ubsppcoe_oapenabled ne null`; it changes nothing and reads as though null were a third case.

> **Filter in the query, not afterwards.** It is tempting to fetch every workspace on the Node and filter with a condition or an array expression later. Do not: pagination interacts badly with it, and a capacity with thousands of workspaces pulls thousands of rows to discard most of them. More importantly, if the `ubsppcoe_oapenabled` name is wrong, a server-side filter fails with a `400` and this flow stops — whereas a client-side filter on a misspelled property silently evaluates to false for every row and rebuilds the capacity down to rule 1 alone.

### 5c. `Select_workspace_ids` — **Select**

| Field | Value |
|---|---|
| From | `body('List_workspace_rows')?['value']` |
| Map | switch to **text mode** (the `T` icon) and enter `item()?['ubsppcoe_workspaceid']` |

Text mode is what makes this produce an array of plain strings rather than an array of objects. An array of objects sent as `predicate.values` is rejected.

### 5d. `Set_workspaces` — **Set variable**

| Field | Value |
|---|---|
| Name | `workspaces` |
| Value | `union(body('Select_workspace_ids'), body('Select_workspace_ids'))` |

`union` of a list with itself is the idiomatic **dedupe**. One row per workspace should make duplicates impossible, but this table is not ours — the same workspace GUID on two rows is exactly the kind of thing that turns up in an inventory table — and a duplicated GUID inside one `values` array may be rejected by Fabric. This costs nothing.

> A blank workspace GUID on an enabled row becomes an empty string in this array, and Fabric rejects the whole `replaceByPolicy` call for a malformed value — taking the capacity's rebuild down with it. If that turns out to happen in practice, add ` and ubsppcoe_workspaceid ne null` to the 5d filter rather than handling it here.

### 5e. `List_item_type_rows` — Dataverse **List rows**

| Field | Value |
|---|---|
| Table name | `Policy Item Types` |
| Filter rows | `ubsppcoe_active eq true` |
| Select columns | `ubsppcoe_itemtype` |
| Row count | `5000` |

### 5f. `Select_item_types` — **Select**

| Field | Value |
|---|---|
| From | `body('List_item_type_rows')?['value']` |
| Map (text mode) | `item()?['ubsppcoe_itemtype']` |

### 5g. `Set_itemTypes` — **Set variable**

| Field | Value |
|---|---|
| Name | `itemTypes` |
| Value | `union(body('Select_item_types'), body('Select_item_types'))` |

### 5h. `List_exception_rows` — Dataverse **List rows**

| Field | Value |
|---|---|
| Table name | `Policy Exceptions` |
| Filter rows | `ubsppcoe_active eq true` |
| Select columns | `ubsppcoe_workspaceid` |
| Row count | `5000` |

Pagination on, threshold `5000`. **This query is tenant-wide, not per capacity** — `Policy Exceptions` has no capacity column, because which capacity an exception applies to is read from the workspace's `Node` in 5k ([CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §3). A few hundred rows across the estate is a cheap read; if it ever stops being one, filter it down in 5k rather than adding a capacity column here.

> **Filter on `ubsppcoe_active eq true`, and remember it is nullable.** A row created by hand with the Yes/No column left untouched is `null`, and `eq true` excludes it — so a new exception that appears to do nothing is almost always an unset `active` flag. That is the right default (grant nothing), but say it on the screen that creates these rows.
>
> **`ubsppcoe_workspaceid` on this table is the Fabric workspace GUID**, the same meaning as the identically-named column on `ubsppcoe_Workspace` — which is precisely why 5l can join the two directly.
>
> **An empty result is normal.** Unlike the workspace query in 5b, there is no fail-closed argument here: most capacities have no exceptions, so zero rows means zero rows and rule 3 is simply not emitted.

### 5i. `Select_exception_ids` — **Select**

| Field | Value |
|---|---|
| From | `body('List_exception_rows')?['value']` |
| Map (text mode) | `item()?['ubsppcoe_workspaceid']` |

### 5j. `Set_exceptionCandidates` — **Set variable**

| Field | Value |
|---|---|
| Name | `exceptionCandidates` |
| Value | `union(body('Select_exception_ids'), body('Select_exception_ids'))` |

Deduped the same way as 5d. Here the duplicate is likelier — this table has no uniqueness constraint and two people can approve the same workspace twice.

**Candidates, not exceptions.** These are every workspace anyone has excepted anywhere. 5k narrows them to the ones on this capacity.

### 5k. `Condition_has_candidates` — **Condition**

| Left (expression) | Operator | Right |
|---|---|---|
| `empty(variables('exceptionCandidates'))` | is equal to | `true` |

**Yes** → leave it **empty**; `exceptions` stays empty and rule 3 is not emitted. **The *No* branch really does hold 5l, 5m and 5n** — this is the one Condition in the flow that nests its contents, because it has no Terminate to fall through from. The guard exists because the filter built in 5l is malformed when the array is empty.

Step 6 onwards resume at the top level, outside this Condition.

### 5l. `List_exception_workspace_rows` — Dataverse **List rows**

| Field | Value |
|---|---|
| Table name | `Workspaces` (`ubsppcoe_Workspace`) |
| Filter rows | `_ubsppcoe_nodeid_value eq @{variables('nodeRowId')} and (ubsppcoe_workspaceid eq '@{join(variables('exceptionCandidates'), ''' or ubsppcoe_workspaceid eq ''')}')` |
| Select columns | `ubsppcoe_workspaceid` |
| Row count | `5000` |

**This is the join that decides which capacity an exception applies to.** An excepted workspace whose `Node` is another capacity — or whose row was deleted — matches nothing here and is absent from this capacity's rule 3. That is what makes a capacity move need no cleanup: the old capacity's next rebuild drops it, the new capacity's next rebuild picks it up.

> ### The parentheses around the `or` chain are load-bearing
>
> Without them the filter reads `A and B or C or D`, which OData groups as **`(A and B) or C or D`**. The Node condition would then constrain only the first candidate, and **every other excepted workspace in the tenant would match regardless of which capacity it is on** — publishing other capacities' workspaces into this capacity's rule 3.
>
> It fails silently and the filter still looks plausible. This is the single most dangerous expression in the flow.

The `join` builds `g1' or ubsppcoe_workspaceid eq 'g2`, which the surrounding literal apostrophes close into a valid chain. Quoting is the whole difficulty: **`''` inside an expression string is one literal apostrophe**, so the separator `''' or ubsppcoe_workspaceid eq '''` produces `' or ubsppcoe_workspaceid eq '`.

**Check the built string on the first run** — open 5l → **Inputs → Filter rows**. With two candidates you want exactly:

```
_ubsppcoe_nodeid_value eq 6f9a… and (ubsppcoe_workspaceid eq 'g1' or ubsppcoe_workspaceid eq 'g2')
```

Doubled or missing apostrophes mean the `'''` quoting is off. Read this from the run history, never from the expression in the designer.

**Settings on this action** — ⋯ → **Settings**. These are not the defaults, and unlike every other action here the defaults are wrong:

| Setting | Value |
|---|---|
| **Timeout** | `PT2M` |
| **Retry Policy** | **Fixed Interval**, Count `2`, Interval `PT10S` |

A bad filter now fails in well under half a minute instead of hanging.

> ### Why this one action overrides the retry defaults
>
> `in` is a documented Dataverse `$filter` operator and reads far better than the chain above, but **it is rejected in this environment — confirmed 2026-09-09.** The connector answers **`501 NotImplemented`**.
>
> The symptom is nastier than a plain failure. `501` is a `5xx`, so the **default** retry policy treats it as transient and keeps retrying something that can never succeed — presenting as a `List rows` stuck at *0 seconds duration* with a climbing retry count for **thirty minutes**, rather than as an error.
>
> **That is not survivable for a child flow.** `Run a Child Flow` gives this flow roughly 120 seconds to answer ([RebuildAllCapacityPolicies.md](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) §5). An action that can burn thirty minutes takes the caller down with it, and in the nightly batch it would stall the whole queue behind one bad capacity.
>
> Two retries still cover a genuine Dataverse `429`, which is the only transient failure worth waiting for here.
>
> If a future environment does accept `in`, the equivalent is `ubsppcoe_workspaceid in (@{concat('''', join(variables('exceptionCandidates'), ''','''), '''')})` — shorter, and it needs no parentheses because `in` is a single operand.

> **`ubsppcoe_oapenabled` is deliberately not in this filter.** An exception grants regardless of the flag; only the `Node` is required. Adding `and ubsppcoe_oapenabled eq true` here would silently reduce rule 3 to a subset of rule 2 and make the whole feature a no-op.

### 5m. `Select_exception_workspace_ids` — **Select**, inside the **No** branch

| Field | Value |
|---|---|
| From | `body('List_exception_workspace_rows')?['value']` |
| Map | **text mode** (the `T` icon) — `item()?['ubsppcoe_workspaceid']` |

Same shape as 5c, on the exception list instead of the whitelist. Text mode for the same reason: an array of objects is rejected as `predicate.values`.

### 5n. `Set_exceptions` — **Set variable**, inside the **No** branch

| Field | Value |
|---|---|
| Name | `exceptions` |
| Value | `union(body('Select_exception_workspace_ids'), body('Select_exception_workspace_ids'))` |

`union` with itself dedupes, exactly as 5d does for the whitelist.

> **The exception list is deliberately not cross-checked against the whitelist.** A workspace may be in both, and that is neither an error nor a duplicate: rules are all `Allow` and are ORed, so the workspace is simply unrestricted and the narrower rule 2 match adds nothing. `migrate_policy_sets.ps1` does not reconcile the two lists either — do not add a `Filter array` that tries to.

---

## Step 6 — Work out how many rules are needed

**A capacity with more than 49 enabled workspaces gets more than one whitelist rule**, split exactly as `migrate_policy_sets.ps1` splits it. This is normal operation, not an edge case: 120 workspaces is three rules, and the naming carries `(1/3)`, `(2/3)`, `(3/3)`.

**+ New step** → **Set variable**, renamed `Set_chunkCount`:

| Field | Value |
|---|---|
| Name | `chunkCount` |
| Value | `if(equals(length(variables('workspaces')), 0), 0, add(div(sub(length(variables('workspaces')), 1), variables('maxPerRule')), 1))` |

That is integer ceiling division: zero workspaces gives zero rules, 1–49 gives one, 50 gives two, 120 gives three.

**+ New step** → **Set variable**, renamed `Set_exceptionChunkCount`, the same expression over the other array:

| Field | Value |
|---|---|
| Name | `exceptionChunkCount` |
| Value | `if(equals(length(variables('exceptions')), 0), 0, add(div(sub(length(variables('exceptions')), 1), variables('maxPerRule')), 1))` |

Exceptions chunk at 49 exactly as the whitelist does, with their own `(i/n)` numbering. In practice this is 0 or 1 for almost every capacity.

### The 50-rule service limit

Separate concern, and not to be confused with the chunking above. Chunking is how a large capacity is **handled**; this is the point past which Fabric itself refuses.

**+ New step** → **Condition**, renamed `Condition_too_many_rules`:

| Left | Operator | Right |
|---|---|---|
| `add(add(variables('chunkCount'), variables('exceptionChunkCount')), 1)` | is greater than | `int(parameters('PolicyMaxRulesPerPolicy (ubsppcoe_PolicyMaxRulesPerPolicy)'))` |

**Yes** branch — two actions, in this order:

**1. `Respond_too_many_rules`** — **Respond to a Power App or flow**, all six Text outputs. **Unlike the earlier two guards, almost everything is known by now, so fill it in:**

| Output | Type | Value |
|---|---|---|
| `Outcome` | **Text** | `Failed` |
| `PolicySetId` | **Text** | `variables('policySetId')` |
| `RuleCount` | **Text** | `string(add(add(variables('chunkCount'), variables('exceptionChunkCount')), 1))` |
| `WorkspaceCount` | **Text** | `string(length(variables('workspaces')))` |
| `ExceptionCount` | **Text** | `string(length(variables('exceptions')))` |
| `Message` | **Text** | `concat('This capacity needs ', string(add(add(variables('chunkCount'), variables('exceptionChunkCount')), 1)), ' rules, which exceeds the service limit of ', parameters('PolicyMaxRulesPerPolicy (ubsppcoe_PolicyMaxRulesPerPolicy)'), '. No rules were published.')` |

**2. `Terminate_too_many_rules`** — **Control** → **Terminate**, **Status = `Succeeded`**.

**Blanking the counts here would waste the only useful diagnostic.** The whole point of failing at this step rather than at Fabric is that the caller learns *how far over* the limit the capacity is.

The `add(..., 1)` is rule 1, which is always emitted and always counts against the 50. **Exception chunks count too** — leaving them out of this sum moves the failure from a readable message here to an opaque rejection at Fabric, which is the whole reason the check exists.

This flow does not manage capacity size — it splits into as many rules as the workspaces require, and only fails when the service will not accept the result. Failing here rather than at Fabric means the caller gets a sentence instead of an opaque rejection. Nothing forecasts or warns as a capacity grows.

**Leave the *No* branch empty.** Steps 7–10 are siblings of this Condition — the *Yes* branch terminates, so they cannot run on that path.

---

## Step 7 — Build the whitelist rules

> **Do not try to do this with a `Select`.** An earlier draft of this document put the rule object into a **Select** action's Map in text mode. **That does not work** — text mode expects a single *expression*, so a pasted JSON literal fails with *"the expression is invalid"* on the leading `{`. `Compose` is the action that accepts raw JSON with embedded expressions, so the rules are built one per loop iteration and appended.

**+ New step** → **Apply to each**, renamed `For_each_whitelist_chunk`.

| Field | Value |
|---|---|
| Select an output from previous steps | `range(0, variables('chunkCount'))` |

⋯ → **Settings** → **Concurrency Control On, Degree of Parallelism 1**. The chunks must be appended in order, or `(1/3)` may not be the first 49 workspaces. Nothing breaks if they are out of order — each rule carries its own index in its name — but a rebuilt policy set then cannot be diffed against a migrated one.

**`range(0, 0)` is an empty array**, so a capacity with no whitelisted workspaces runs this loop zero times and `whitelistRules` stays `[]`. That is the zero case handled without a special branch.

### 7a. `Compose_whitelist_rule` — **Compose**, inside the loop

> **Paste the block below straight into the `Inputs` box as plain text.** Do **not** open the expression editor (`fx`) and do not build it from dynamic content — the expression editor takes one expression, so a pasted JSON literal fails there for the same reason it failed in a `Select` map. Compose's `Inputs` accepts raw JSON, and the runtime evaluates the `@` tokens inside it.
>
> **Then check it with Peek code**, because the designer sometimes escapes a typed `@` as `@@`, which turns a live expression into literal text. In the peeked JSON you want to see `"values": "@take(...)"` — one `@`, and the expression *inside* the quotes. Two `@` means it will publish the word `@take(...)` to Fabric.
>
> The same applies to `Compose_exception_rule` and to both Composes in Step 8.

```json
{
  "displayName": "@{if(greater(variables('chunkCount'), 1), concat('Approved item types for whitelisted workspaces (', string(add(items('For_each_whitelist_chunk'), 1)), '/', string(variables('chunkCount')), ')'), 'Approved item types for whitelisted workspaces')}",
  "description": "@{concat('Allow ', string(length(variables('itemTypes'))), ' item type(s) in ', string(length(take(skip(variables('workspaces'), mul(items('For_each_whitelist_chunk'), variables('maxPerRule'))), variables('maxPerRule')))), ' whitelisted workspace(s).')}",
  "conditions": [
    {
      "type": "Dynamic",
      "targetProperty": "workspace.id",
      "predicate": {
        "operator": "AnyOf",
        "values": "@take(skip(variables('workspaces'), mul(items('For_each_whitelist_chunk'), variables('maxPerRule'))), variables('maxPerRule'))"
      }
    },
    {
      "type": "Dynamic",
      "targetProperty": "item.type",
      "predicate": {
        "operator": "AnyOf",
        "values": "@variables('itemTypes')"
      }
    }
  ],
  "effects": [ { "type": "Allow" } ]
}
```

### 7b. `Append_whitelist_rule` — **Append to array variable**, inside the loop

| Field | Value |
|---|---|
| Name | `whitelistRules` |
| Value | `outputs('Compose_whitelist_rule')` |

Four things about this block matter.

**`items('For_each_whitelist_chunk')`, not `item()`.** Inside an `Apply to each` the bare `item()` is ambiguous and the designer will often reject it outright. The named form is the chunk index — 0, 1, 2.

**`take(skip(…))` is the chunking.** `skip` drops the earlier chunks, `take` keeps 49.

**`"@expr"` versus `"@{expr}"` is not cosmetic.** The two `values` properties use the bare `"@…"` form, which yields a real **array**. The `displayName` and `description` use `"@{…}"`, which yields a **string**. Get this backwards on `values` and Fabric receives `"[\"guid\",\"guid\"]"` — a string that looks right in the run history and is rejected, or worse, accepted as a single nonsense value.

**The display name is kept short deliberately.** Rule names are capped at **60 characters** by the service. `Approved item types for whitelisted workspaces` is 46, leaving room for ` (10/12)` and beyond. The PowerShell uses a longer base name and truncates it; this avoids needing the truncation expression at all. Rule names are cosmetic — rules are identified by ID — so the first rebuild of a migrated capacity renaming its rules is harmless.

---

## Step 7c — Build the exception rules

Same shape as Step 7: a loop, a `Compose`, an append.

**+ New step** → **Apply to each**, renamed `For_each_exception_chunk`, over `range(0, variables('exceptionChunkCount'))`. Concurrency 1, for the same reason.

### 7d. `Compose_exception_rule` — **Compose**, inside the loop

```json
{
  "displayName": "@{if(greater(variables('exceptionChunkCount'), 1), concat('Unrestricted item creation for exception workspaces (', string(add(items('For_each_exception_chunk'), 1)), '/', string(variables('exceptionChunkCount')), ')'), 'Unrestricted item creation for exception workspaces')}",
  "description": "@{concat('Allow any item type in ', string(length(take(skip(variables('exceptions'), mul(items('For_each_exception_chunk'), variables('maxPerRule'))), variables('maxPerRule')))), ' exception workspace(s); the item type whitelist does not apply to them.')}",
  "conditions": [
    {
      "type": "Dynamic",
      "targetProperty": "workspace.id",
      "predicate": {
        "operator": "AnyOf",
        "values": "@take(skip(variables('exceptions'), mul(items('For_each_exception_chunk'), variables('maxPerRule'))), variables('maxPerRule'))"
      }
    }
  ],
  "effects": [ { "type": "Allow" } ]
}
```

### 7e. `Append_exception_rule` — **Append to array variable**, inside the loop

| Field | Value |
|---|---|
| Name | `exceptionRules` |
| Value | `outputs('Compose_exception_rule')` |

> **One condition. Do not add a second.** This block is Step 7a with the `item.type` condition deleted, and that deletion *is* the feature — a rule with no `item.type` condition matches every item type, which is what an exception means. Pasting Step 7a and editing the strings, while leaving the second condition behind, produces a rule that looks plausible in the portal and grants exactly nothing extra.

**The base name is 50 characters**, against the service's 60-character cap. That leaves room for ` (1/2)` but not for ` (10/12)` — which would need 58 and still fits, while a three-digit chunk count would not. A capacity with 450+ exception workspaces is not a scenario this design expects; if one appears, shorten the base name rather than truncating at runtime.

**`exceptionChunkCount` = 0 means the loop never runs,** `exceptionRules` stays `[]`, and Step 8b's `union` appends nothing. No exceptions, no rule 3, no special case.

---

## Step 8 — Build rule 1 and the request body

Both actions here are **Compose**, and both take pasted JSON in `Inputs` — same method and same `@@` check as Step 7a.

### 8a. `Compose_rule1` — **Compose**

```json
{
  "displayName": "Deny all item creation (PBI items not tracked)",
  "description": "Baseline - grants nothing, so only the rules below can allow creation",
  "conditions": [
    {
      "type": "Dynamic",
      "targetProperty": "workspace.id",
      "predicate": {
        "operator": "AnyOf",
        "values": [ "@{parameters('PolicySentinelWorkspaceId (ubsppcoe_PolicySentinelWorkspaceId)')}" ]
      }
    }
  ],
  "effects": [ { "type": "Allow" } ]
}
```

There is no `Deny` effect in the API. This is an `Allow` rule whose condition can never match, because the sentinel is not a real workspace. It grants nothing; its job is to keep the policy in force so that anything not allowed by a later rule is refused.

The sentinel here is a **single value inside a literal array**, so `"@{…}"` interpolation is correct — unlike Step 7's `values`.

### 8b. `Compose_body` — **Compose**

```json
{
  "policy": "ItemCreation",
  "policyRules": "@union(union(createArray(outputs('Compose_rule1')), variables('whitelistRules')), variables('exceptionRules'))"
}
```

`createArray` wraps rule 1 into a one-element array; the inner `union` appends the whitelist rules after it, the outer one appends the exception rules last. When both loops ran zero times the result is **rule 1 alone** — the safe default from §0, reached without a special case.

**The order matches `migrate_policy_sets.ps1`:** baseline, whitelist, exceptions. Rules are all `Allow` and are evaluated as an OR, so order carries no meaning to the service — but keeping it identical means a migrated policy set and a rebuilt one can be compared rule by rule during cutover.

> **`union` deduplicates, and here that is harmless but worth knowing.** It compares whole objects, and two rules are only identical if their names, descriptions, conditions and effects all match — which the `(i/n)` naming and the differing descriptions prevent. Do not rely on it to tidy anything up; it is being used as a concatenation that happens to be the only array-joining function available.

---

## Step 9 — Write the rules

**+ New step** → **HTTP with Microsoft Entra ID (preauthorized)** → **Invoke an HTTP request**, renamed `Replace_rules`.

| Field | Value |
|---|---|
| Method | `POST` |
| URL of the request | `https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{variables('policySetId')}/policyRules/replaceByPolicy` |
| Header `Content-Type` | `application/json` |
| Body of the request | `@outputs('Compose_body')` |

**No `Authorization` header** — the connector supplies it (§0).

The body is the bare `@outputs(...)` form. Wrapping it in `@{ }` would send the whole document as a quoted string.

**Leave Retry Policy at Default.** It already retries `408`, `429` and `5xx` — 4 attempts, exponential backoff — which covers ordinary throttling without any configuration. Just do not set it to **None**: that would turn a routine `429` into a failed capacity.

If throttling ever turns out to be routine rather than rare, tune it then. `migrate_policy_sets.ps1` settled on 5 retries with a 30-second floor, which is the obvious next step — but there is no reason to pay for it up front.

> A `429` that survives the retries fails this flow, which stamps `last_error` and reports `Failed`. The nightly job picks the capacity up next run, and its stale `last_rebuild` puts it near the front of the queue. **`Run a Child Flow` is not retried by callers**, which is deliberate — see [RebuildAllCapacityPolicies.md](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) §5.

Retries do not show as failures. To see whether they are happening, open a run, select `Replace_rules`, and check the attempt count.

---

## Step 10 — Stamp the row and respond

### 10a. `Update_policy_row` — Dataverse **Update a row**

Runs after `Replace_rules` on **is successful** and **has failed**.

| Field | Value |
|---|---|
| Table name | `Capacity Policies` |
| Row ID | `variables('policyRowId')` |
| `ubsppcoe_lastrebuild` | `utcNow()` |
| `ubsppcoe_lasterror` | `if(less(coalesce(outputs('Replace_rules')?['statusCode'], 0), 300), '', coalesce(body('Replace_rules')?['message'], body('Replace_rules')?['errorCode'], string(body('Replace_rules'))))` |
| `ubsppcoe_workspacecount` | `length(variables('workspaces'))` |
| `ubsppcoe_exceptioncount` | `length(variables('exceptions'))` |
| `ubsppcoe_rulecount` | `add(add(variables('chunkCount'), variables('exceptionChunkCount')), 1)` |

Writing the row on both paths is the point — a failed rebuild that leaves `last_error` blank is indistinguishable from a healthy one, and this table is what the app shows.

> **The three counts are written for [ListCapacityPolicySets](docs/flows/capacity-policies/ListCapacityPolicySets.md), which cannot afford to compute them.** Counting enabled workspaces per capacity at read time is one Dataverse query per capacity, 200–300 of them inside a 120-second budget. This flow has all three numbers already.
>
> They are stamped **on the failure path too, and that is deliberate**: they describe what Dataverse said at the time of the attempt, not what Fabric ended up holding. Paired with a non-blank `last_error` they read correctly — *"this is what we tried to publish, and it did not land"*. Writing them only on success would leave the previous run's numbers sitting next to a fresh failure, which is the more misleading of the two options.
>
> Store them as **whole numbers**, not text. The typing rule that forces every *Respond* output to Text does not apply to Dataverse columns, and flow 2 needs to sort on them.

### 10b. `Respond_rebuilt`

**+ New step** → **Respond to a Power App or flow**, renamed `Respond_rebuilt`. ⋯ → **Configure run after** on `Update_policy_row` with **is successful** and **has failed** ticked. Six **Text** outputs:

| Output | Type | Value |
|---|---|---|
| `Outcome` | **Text** | `if(less(coalesce(outputs('Replace_rules')?['statusCode'], 0), 300), 'Rebuilt', 'Failed')` |
| `PolicySetId` | **Text** | `variables('policySetId')` |
| `RuleCount` | **Text** | `string(add(add(variables('chunkCount'), variables('exceptionChunkCount')), 1))` |
| `WorkspaceCount` | **Text** | `string(length(variables('workspaces')))` |
| `ExceptionCount` | **Text** | `string(length(variables('exceptions')))` |
| `Message` | **Text** | `if(less(coalesce(outputs('Replace_rules')?['statusCode'], 0), 300), 'Rules rebuilt.', coalesce(body('Replace_rules')?['message'], body('Replace_rules')?['errorCode'], string(body('Replace_rules'))))` |

Status code lives on `outputs('Replace_rules')`, the payload on `body('Replace_rules')`. They are not interchangeable — `body(...)?['statusCode']` is always blank, which would report every rebuild as `Failed`.

**Every output must be Text.** A field typed Number or Boolean fails schema validation at runtime and makes *every* output of the flow unreadable to the caller, not just the bad one. That is why `RuleCount` is `string(...)` rather than an integer.

### `PolicySetId` costs nothing and answers the support question

It is already in a variable, so returning it is free. What it buys is a run history where **the policy set that was written is on the record next to the outcome**, rather than something you re-derive from `Capacity Policies` as it stands today — which is the wrong day to be reading it, because by then it may have been repointed. The nightly batch in [RebuildAllCapacityPolicies.md](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) is where this pays: 250 child-flow runs in one parent, and the id is what ties a failure to a capacity without a second query.

> **Do not return the rule IDs.** `replaceByPolicy` responds with the rules it created, and it is tempting to keep them. They are regenerated with new IDs on every rebuild, so anything that stored them would be stale within a day, and nothing in this design addresses a rule by ID — that is the entire point of rebuilding wholesale.

### Every Respond in this flow declares the same six fields

There are **four** `Respond to a Power App or flow` actions here — three early exits and the real one:

| Action | Step | `Outcome` | `PolicySetId` | `RuleCount` | `WorkspaceCount` | `ExceptionCount` |
|---|---|---|---|---|---|---|
| `Respond_no_policy_row` | 4 | `Failed` | `variables('policySetId')` — empty here | `0` | `0` | `0` |
| `Respond_no_node` | 5a | `Failed` | `variables('policySetId')` | `0` | `0` | `0` |
| `Respond_too_many_rules` | 6 | `Failed` | `variables('policySetId')` | computed total | actual | actual |
| `Respond_rebuilt` | 10b | `Rebuilt` / `Failed` | `variables('policySetId')` | computed total | actual | actual |

**The field list is identical everywhere, and so is the type — all six are Text on all four.** `PolicySetId` even uses the same expression on all four; it simply evaluates to empty at Step 4, because nothing has set it yet.

**No output box may be left blank.** The designer requires a value in each one, so "blank" always means *an expression that evaluates to empty*, never an empty field.

A caller reading a field that the branch it happened to take never declared gets a **blank, not an error**. So a mismatch does not fail; it produces early-exit responses whose `RuleCount` is empty and a parent flow that quietly treats it as zero. Identical schemas everywhere is the only version of this that stays debuggable.

> **`Message` is omitted from the table above only because every one differs.** It is still required on all four.

---

## To verify after building

### What has to exist before the first run

**This flow never creates a policy set.** It rewrites the rules of one that already exists, addressed by `policySetId`. With nothing seeded, the very first thing you hit is the Step 4 guard — which is test 6, not test 1.

The build order deliberately puts this flow **before** [InitializeCapacityPolicySet](docs/flows/capacity-policies/InitializeCapacityPolicySet.md), the flow that would normally create and register the set. So for now, seed it by hand:

| # | What | How |
|---|---|---|
| 1 | A **throwaway capacity that already has a `ubsppcoe_Node` row** | Pick an existing one — see below for how to tell. **Do not create the Node row** — that table belongs to the platform team and nothing in this project writes it (§0). If no spare capacity has one, that is a request to them, not a workaround |
| 2 | A **policy set** in the holder workspace, scoped to that capacity | `POST /v1/workspaces/{holderWs}/policySets` by hand, or the Fabric portal. **Leave it deactivated** |
| 3 | A row in **`Capacity Policies`**, created **by hand** | Tables → Capacity Policies → Data → **+ New row**. `ubsppcoe_capacityid` = the capacity GUID · `ubsppcoe_policysetid` = the set's GUID from 2 · `ubsppcoe_node` = the Node row from 1 · `ubsppcoe_status` = `Inactive`. Leave `lastrebuild`, `lasterror` and the three counts **empty** — Step 10a fills them, and watching that happen is part of the test |
| 4 | At least one active row in **`Policy Item Types`** | Import [input/PolicyItemTypes.csv](docs/flows/capacity-policies/input/PolicyItemTypes.csv). Only needed once a workspace is whitelisted — see the warning below |

**Rules: none needed.** A freshly created policy set has no rules at all, and that is the right starting point — `replaceByPolicy` overwrites whatever is there, including nothing. Test 1 then proves the flow puts the deny-all baseline in.

> **The `Node` lookup is picked by name, not by GUID.** The row selector shows `ubsppcoe_nodename`, so you need the node's name rather than the capacity id you started from. The Web API check below returns exactly that — `?$select=ubsppcoe_nodename`.

> **This hand-made row will make flow 1 skip this capacity later.** [InitializeCapacityPolicySet](docs/flows/capacity-policies/InitializeCapacityPolicySet.md) returns `AlreadyExists` and stops when a `Capacity Policies` row already carries a `policy_set_id` — correct behaviour, but it means your test row masks the path you will want to test next. Delete it before building flow 1, or test flow 1 against a different capacity.

**Names: irrelevant to this flow.** It addresses the policy set by GUID and never reads or writes its display name. `pol_<capacity>` is a convention that flow 1 applies at creation, and `ubsppcoe_policysetname` on the row is only read by the drift scan and the app. Call your test set anything.

> ### Checking whether a capacity has a Node row
>
> **It is a lookup by row key, not a filter.** `ubsppcoe_nodeuniqueid` *is* the Fabric capacity GUID, so there is no "capacity id" column to search on — which is the first thing that confuses people looking for one.
>
> In a browser signed into the environment:
>
> ```
> https://<org>.crm<n>.dynamics.com/api/data/v9.2/ubsppcoe_nodes(<capacity-guid>)?$select=ubsppcoe_nodename
> ```
>
> `200` means the row exists; `404` means it does not.
>
> **Finding the instance URL:** make.powerapps.com → gear → **Session details** → *Instance url*, or admin.powerplatform.microsoft.com → **Environments** → your environment → *Environment URL*. **Do not guess the `crm<n>` part** — it is regional (`crm` North America, `crm4` EMEA, `crm5`/`crm6` APAC, and others). The `make.powerapps.com/environments/<guid>/…` address is the **environment ID**, a different identifier, and will not work against the Web API.
>
> If the call 404s complaining about the *segment* rather than the row, the entity set is pluralised differently — check `/api/data/v9.2/$metadata`.
>
> In the maker portal instead: **Tables → Node → Data**, then **Edit columns** and add *Node Unique Id*. It is hidden by default, which is why the grid appears to have no capacity id at all.

> **Leave the policy set deactivated while testing.** Rule 1 is a deny-all baseline, so an *activated* set with the rules this flow publishes will genuinely stop item creation on that capacity. Deactivated, every rule is written and visible in the portal and nothing is enforced — which is all you need to verify tests 1–18. Activation is flow 1's job, on a capacity you have decided to govern.

> **Seed `Policy Item Types` before testing anything with a whitelisted workspace.** With no active item types, rule 2 is emitted with an empty `item.type` array and Fabric rejects the whole call — taking the rebuild down for a reason that looks like a bug in the rule builder. Test 1 has zero whitelisted workspaces so it passes regardless; test 2 is where an unseeded table bites.

| # | Test | Expect |
|---|---|---|
| 1 | Capacity whose Node row exists but has **no** OAP-enabled workspaces | Exactly **one** rule in the portal — the deny-all. **Run this first**; it is the path that unlocks a capacity if it is wrong |
| 2 | Capacity with 3 enabled workspaces | Two rules: deny-all, plus one whitelist rule named without a `(1/1)` suffix |
| 3 | Capacity with 50 enabled workspaces | Three rules: deny-all, plus `(1/2)` and `(2/2)`, split 49 + 1 |
| 4 | Run twice with no data change | Identical rule set, no duplicates. `replaceByPolicy` makes this idempotent |
| 5 | Set one workspace's `ubsppcoe_oapenabled` to `false`, rerun | The workspace is gone from the rules and no empty rule is left behind |
| 6 | Unregistered capacity ID (no `Capacity Policies` row) | `Failed` with the "run InitializeCapacityPolicySet first" message, and no Fabric call |
| 7 | **Policy row whose `node` lookup is blank** | `Failed`, and **no Fabric call**. Not rule 1 alone — see the box in Step 5a |
| 8 | A workspace on the Node with `ubsppcoe_oapenabled` **null** (never set) | Absent from the rules, identical to an explicit `false`. **The case the `eq true` filter has to get right** |
| 9 | Move a workspace's `Node` to another capacity, rebuild **both** | It appears on the new capacity and disappears from the old |
| 10 | Peek code on `Compose_whitelist_rule` | `values` is a JSON **array**, not a quoted string |
| 11 | **One active `Policy Exceptions` row**, for a workspace on this capacity's Node | A third rule appears, with **one** condition and no `item.type`. Check this in the portal, not just in the run history |
| 12 | Set that row's `active` to No and rerun | The rule is gone entirely — not left behind as an empty or orphaned rule |
| 13 | A `Policy Exceptions` row created with `active` never set | Absent from the rules. Blank is not Yes |
| 14 | An exception row for a workspace that is **also** OAP-enabled | Present in **both** rule 2 and rule 3. Not an error, not deduplicated |
| 15 | An exception row for a workspace on a **different** Node | Absent from this capacity's rules, present on the other capacity's after **its** rebuild. This is the join in Step 5l |
| 16 | **Move an excepted workspace's `Node`, rebuild both capacities** | Gone from the old capacity's rule 3, present in the new one's. **No row was edited** — the whole point of §3's "no capacity column" |
| 17 | An exception row whose `workspace_id` is a GUID with no workspace row | Absent everywhere, and no error. Nothing is published for it |
| 18 | Delete every `Policy Exceptions` row, rerun | Two rules, or one. Rule 3 disappears rather than being emitted empty |

Test 11 is the one to do by hand in the portal. A rule 3 that arrived with an `item.type` condition attached still looks like a rule 3 in the run history and grants nothing extra.

Test 16 is the one that justifies the design. If it fails, the old capacity is left granting unrestricted creation to a workspace that is no longer on it.

Test 7 is the one this design added and the one worth writing down: it is the difference between "a capacity has no whitelist" and "we cannot see the whitelist", and only one of those should reach Fabric.

Test 10 is worth doing once by hand. It is the difference between a rule that works and a rule that looks right in the designer and matches nothing.

> Testing from the designer reports **`ActionResponseSkipped`** on the Respond action — expected, because nothing is waiting for the response. The rules are still written. Check the outcome by reading the Respond action's **inputs** in the run history, or by looking at the rules in the portal.
