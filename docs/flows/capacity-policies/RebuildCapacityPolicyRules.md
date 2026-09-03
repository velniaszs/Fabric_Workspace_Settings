# Flow — `RebuildCapacityPolicyRules`

Child flow. **The only flow that writes policy rules.** Reads the desired state from Dataverse — the `FabricEnabled` workspaces under a capacity's Node row — and replaces every `ItemCreation` rule on that capacity's policy set in a single call.

> **Not built yet.** Specification, not a description of something that exists.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §2 and §3, [GetPolicyToken.md](docs/flows/capacity-policies/GetPolicyToken.md), [InitializeCapacityPolicySet.md](docs/flows/capacity-policies/InitializeCapacityPolicySet.md), [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md), [RemoveWorkspaceFromPolicy.md](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md).

---

## 0. Before you start

- Build [GetPolicyToken.md](docs/flows/capacity-policies/GetPolicyToken.md) first.
- The new tables from [CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §3 must exist, and `Policy Item Types` must be seeded.
- **This flow needs a Dataverse connection**, unlike the Fabric-only flows elsewhere in this repo. It will have a `connectionReferences` entry. That is expected here.
- Logical names below use the `crbab_` prefix for the tables this project creates. **Substitute your publisher prefix.** Pick tables and columns from the designer dropdowns rather than typing them.

### The two tables this flow does not own

The workspace whitelist lives in the platform team's existing tables. This flow **reads** them and writes nothing back.

| Purpose | Name used below | Status |
|---|---|---|
| Capacity table | `ubsppcoe_Node` | Confirmed |
| Node row key | `ubsppcoe_nodeid` | By Dataverse convention |
| Capacity GUID on the Node row | `ubsppcoe_fabriccapacityid` | **Placeholder — confirm** |
| Workspace table | `ubsppcoe_Workspace` | Confirmed |
| Workspace row key | `ubsppcoe_workspaceid` | By Dataverse convention |
| Workspace GUID on the workspace row | `ubsppcoe_fabricworkspaceid` | **Placeholder — confirm** |
| `Node` lookup on the workspace row | `_ubsppcoe_node_value` | **Placeholder — confirm** |
| `FabricEnabled` — Yes/No | `ubsppcoe_fabricenabled` | **Placeholder — confirm** |

> **Confirm every placeholder in the maker portal before you build Step 5.** Settings → Tables → the table → Columns, and read the **Logical name** column. A wrong name in a `Filter rows` expression does not fail loudly — Dataverse returns a `400` for an unknown column, but an expression that resolves to blank returns **every row**, which would whitelist every workspace in the tenant on one capacity.

> **Neither GUID is the row key, and the names look alike.** Both tables key on a name column, so `ubsppcoe_workspaceid` is almost certainly the Dataverse **row key** — not the Fabric workspace id, which lives in a differently-named column beside it. Read both out of the portal and do not infer either from the other. Confusing them gives a `404` on `Update a row`, or a filter that matches nothing.

> **The capacity id is never filtered against a Node row here.** `Capacity Policies` carries a `node` lookup, so Step 4 reads the policy set id and the Node row GUID in one call. Resolving a capacity GUID against `ubsppcoe_Node` happens once, in [InitializeCapacityPolicySet.md](docs/flows/capacity-policies/InitializeCapacityPolicySet.md), when that row is created.

> **`FabricEnabled` = Yes is the whitelist, and this flow only reads it.** No, blank, or no Node lookup means the workspace is in **no** rule. The flag is owned by another team — nothing in this design writes it, or any other column on either table. See [CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §3.

| Environment variable | Value |
|---|---|
| `ab_PolicyHolderWorkspaceId` | The workspace holding the PolicySet items |
| `ab_PolicySentinelWorkspaceId` | `00000000-0000-0000-0000-000000000000` |
| `ab_PolicyMaxWorkspacesPerRule` | `49` |
| `ab_PolicyMaxRulesPerPolicy` | `50` |

> ### The one thing that must not go wrong
>
> `replaceByPolicy` **overwrites every rule of the policy, including rule 1**. A capacity with no whitelisted workspaces must still receive rule 1 on its own.
>
> A policy with **zero** rules is not an empty allow-list — it is an unenforced policy, and the capacity silently unlocks. Rule 1 is therefore built as a hard-coded array element in Step 8, never as the output of a loop that happens to run at least once.

---

## Step 1 — Create the flow

**Solutions** → your solution → **New** → **Automation** → **Cloud flow** → **Instant** → name it `RebuildCapacityPolicyRules` → trigger **Manually trigger a flow**.

Add one input: **+ Add an input** → **Text**, titled `capacityId`. Referenced as `triggerBody()['text']`.

> Trigger must be **Manually trigger a flow** so the other flows can call it with `Run a Child Flow`.

Then ⋯ on the flow → **Settings** → **Concurrency Control** → **On**, **Degree of Parallelism = 1**. Two rebuilds of the same capacity overlapping would be last-writer-wins against Fabric even though Dataverse stayed consistent.

---

## Step 2 — Token

1. **+ New step** → **Run a Child Flow** → **GetPolicyToken**. Leave the action name `Run_a_Child_Flow`.
2. **+ New step** → **Initialize variable**, named `Initialize_variable`:

| Field | Value |
|---|---|
| Name | `accessToken` |
| Type | String |
| Value | `body('Run_a_Child_Flow')?['access_token']` |

---

## Step 3 — Variables

Six `Initialize variable` actions, in order.

| Rename to | Name | Type | Value |
|---|---|---|---|
| `Initialize_policySetId` | `policySetId` | String | *(leave empty)* |
| `Initialize_nodeRowId` | `nodeRowId` | String | *(leave empty)* |
| `Initialize_maxPerRule` | `maxPerRule` | Integer | `int(parameters('PolicyMaxWorkspacesPerRule (ab_PolicyMaxWorkspacesPerRule)'))` |
| `Initialize_workspaces` | `workspaces` | Array | *(leave empty)* |
| `Initialize_itemTypes` | `itemTypes` | Array | *(leave empty)* |
| `Initialize_chunkCount` | `chunkCount` | Integer | `0` |

> **All of these must sit at the top level of the flow, before the first Condition.** `Initialize variable` is the one action Power Automate refuses to place inside a Condition, Scope or Apply to each — the designer offers it and then fails validation on save, which is a confusing way to find out. Everything below sets these with **Set variable** instead.

That is why `policySetId` and `nodeRowId` start empty and are assigned later, rather than being initialised from a lookup that has not run yet.

---

## Step 4 — Find the policy set

**+ New step** → Dataverse **List rows**. Rename it `Get_policy_row`.

| Field | Value |
|---|---|
| Table name | `Capacity Policies` |
| Filter rows | `crbab_capacityid eq '@{triggerBody()['text']}'` |
| Select columns | `crbab_policysetid,_crbab_node_value` |
| Row count | `1` |

**+ New step** → **Condition**, renamed `Condition_policy_exists`:

| Left (expression) | Operator | Right |
|---|---|---|
| `empty(body('Get_policy_row')?['value'])` | is equal to | `true` |

**Yes** branch → a **Respond to a Power App or flow** returning `Outcome` = `Failed`, `Message` = `No policy set is registered for this capacity. Run InitializeCapacityPolicySet first.`, and the other three fields blank or zero — see Step 10b on keeping the schemas identical. Then **Terminate** with status `Succeeded` — the caller gets an answer, and this is a caller error rather than a flow fault.

In the **No** branch, two **Set variable** actions:

| Rename to | Name | Value |
|---|---|---|
| `Set_policySetId` | `policySetId` | `first(body('Get_policy_row')?['value'])?['crbab_policysetid']` |
| `Set_nodeRowId` | `nodeRowId` | `first(body('Get_policy_row')?['value'])?['_crbab_node_value']` |

> **One read, both values.** `Capacity Policies` carries a `node` lookup to `ubsppcoe_Node` ([CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §3), so this row already holds the Node row GUID. There is no second query to resolve the capacity id against the Node table's capacity GUID column — that lookup happens once, in flow 1, when the row is created.
>
> Read it from the **`_crbab_node_value`** form, with the leading underscore and the `_value` suffix. `crbab_node` on a `List rows` result is not the GUID; it is either absent or an expanded object, depending on what was selected.

Everything from Step 5 on goes in the same **No** branch.

---

## Step 5 — Read the desired state

The whitelist is `ubsppcoe_Workspace` rows whose `Node` is this capacity **and** whose `FabricEnabled` is Yes. `nodeRowId` is already in hand from Step 4.

### 5a. `Condition_node_linked` — **Condition**

| Left (expression) | Operator | Right |
|---|---|---|
| `empty(variables('nodeRowId'))` | is equal to | `true` |

**Yes** branch → Respond with `Outcome` = `Failed` and the message `This capacity's policy row has no Node link, so its workspaces cannot be determined.` Then **Terminate** with `Succeeded`. Everything from 5b on goes in the **No** branch.

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
| Filter rows | `_ubsppcoe_node_value eq @{variables('nodeRowId')} and ubsppcoe_fabricenabled eq true` |
| Select columns | `ubsppcoe_fabricworkspaceid` |
| Row count | `5000` |

⋯ → **Settings** → **Pagination On**, Threshold `5000`. Without it you silently get the first page only, and a capacity over the page size loses workspaces on every rebuild — a data-loss bug that looks like a Fabric problem.

Three things about that filter are easy to get wrong.

**The lookup is `_ubsppcoe_node_value`, with the leading underscore and the `_value` suffix.** `ubsppcoe_node eq '…'` is not a queryable column and returns a `400`.

**The GUID is not quoted.** Lookup and unique-identifier columns compare against a bare GUID — `_ubsppcoe_node_value eq 6f9a…`, no apostrophes. Quoting it is the one that produces a confusing error rather than a clear one.

**`eq true`, not `eq 'Yes'`.** `FabricEnabled` is a Yes/No column, which is a boolean in OData. And it is nullable: rows where nobody has ever set it are `null`, and `eq true` correctly excludes them, which is the intended behaviour — blank means not whitelisted.

> **Filter in the query, not afterwards.** It is tempting to fetch every workspace on the Node and filter with a condition or an array expression later. Do not: pagination interacts badly with it, and a capacity with thousands of workspaces pulls thousands of rows to discard most of them. More importantly, if the `FabricEnabled` name is wrong, a server-side filter fails with a `400` and this flow stops — whereas a client-side filter on a misspelled property silently evaluates to false for every row and rebuilds the capacity down to rule 1 alone.

### 5c. `Select_workspace_ids` — **Select**

| Field | Value |
|---|---|
| From | `body('List_workspace_rows')?['value']` |
| Map | switch to **text mode** (the `T` icon) and enter `item()?['ubsppcoe_fabricworkspaceid']` |

Text mode is what makes this produce an array of plain strings rather than an array of objects. An array of objects sent as `predicate.values` is rejected.

### 5d. `Set_workspaces` — **Set variable**

| Field | Value |
|---|---|
| Name | `workspaces` |
| Value | `union(body('Select_workspace_ids'), body('Select_workspace_ids'))` |

`union` of a list with itself is the idiomatic **dedupe**. One row per workspace should make duplicates impossible, but this table is not ours — the same workspace GUID on two rows is exactly the kind of thing that turns up in an inventory table — and a duplicated GUID inside one `values` array may be rejected by Fabric. This costs nothing.

> A blank workspace GUID on an enabled row becomes an empty string in this array, and Fabric rejects the whole `replaceByPolicy` call for a malformed value — taking the capacity's rebuild down with it. If that turns out to happen in practice, add ` and ubsppcoe_fabricworkspaceid ne null` to the 5d filter rather than handling it here.

### 5e. `List_item_type_rows` — Dataverse **List rows**

| Field | Value |
|---|---|
| Table name | `Policy Item Types` |
| Filter rows | `crbab_active eq true` |
| Select columns | `crbab_itemtype` |
| Row count | `5000` |

### 5f. `Select_item_types` — **Select**

| Field | Value |
|---|---|
| From | `body('List_item_type_rows')?['value']` |
| Map (text mode) | `item()?['crbab_itemtype']` |

### 5g. `Set_itemTypes` — **Set variable**

| Field | Value |
|---|---|
| Name | `itemTypes` |
| Value | `union(body('Select_item_types'), body('Select_item_types'))` |

---

## Step 6 — Work out how many rules are needed

**A capacity with more than 49 enabled workspaces gets more than one whitelist rule**, split exactly as `migrate_policy_sets.ps1` splits it. This is normal operation, not an edge case: 120 workspaces is three rules, and the naming carries `(1/3)`, `(2/3)`, `(3/3)`.

**+ New step** → **Set variable**, renamed `Set_chunkCount`:

| Field | Value |
|---|---|
| Name | `chunkCount` |
| Value | `if(equals(length(variables('workspaces')), 0), 0, add(div(sub(length(variables('workspaces')), 1), variables('maxPerRule')), 1))` |

That is integer ceiling division: zero workspaces gives zero rules, 1–49 gives one, 50 gives two, 120 gives three.

### The 50-rule service limit

Separate concern, and not to be confused with the chunking above. Chunking is how a large capacity is **handled**; this is the point past which Fabric itself refuses.

**+ New step** → **Condition**, renamed `Condition_too_many_rules`:

| Left | Operator | Right |
|---|---|---|
| `add(variables('chunkCount'), 1)` | is greater than | `int(parameters('PolicyMaxRulesPerPolicy (ab_PolicyMaxRulesPerPolicy)'))` |

**Yes** → Respond with `Outcome` = `Failed`, a message naming the limit, and the same five fields as Step 10b — `PolicySetId` and `WorkspaceCount` are both known here, so fill them in rather than blanking them. Then **Terminate** with `Succeeded`.

The `add(..., 1)` is rule 1, which is always emitted and always counts against the 50.

This flow does not manage capacity size — it splits into as many rules as the workspaces require, and only fails when the service will not accept the result. Failing here rather than at Fabric means the caller gets a sentence instead of an opaque rejection. Nothing forecasts or warns as a capacity grows.

Steps 7–10 go in the **No** branch.

Steps 7–10 go in the **No** branch.

---

## Step 7 — Build the whitelist rules

**+ New step** → **Select**, renamed `Select_whitelist_rules`.

| Field | Value |
|---|---|
| From | `range(0, variables('chunkCount'))` |

Switch the **Map** to **text mode** and paste this whole object:

```json
{
  "displayName": "@{if(greater(variables('chunkCount'), 1), concat('Approved item types for whitelisted workspaces (', string(add(item(), 1)), '/', string(variables('chunkCount')), ')'), 'Approved item types for whitelisted workspaces')}",
  "description": "@{concat('Allow ', string(length(variables('itemTypes'))), ' item type(s) in ', string(length(take(skip(variables('workspaces'), mul(item(), variables('maxPerRule'))), variables('maxPerRule')))), ' whitelisted workspace(s).')}",
  "conditions": [
    {
      "type": "Dynamic",
      "targetProperty": "workspace.id",
      "predicate": {
        "operator": "AnyOf",
        "values": "@take(skip(variables('workspaces'), mul(item(), variables('maxPerRule'))), variables('maxPerRule'))"
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

Three things about this block matter.

**`take(skip(…))` is the chunking.** `From` is `range(0, chunkCount)`, so `item()` is the chunk index — 0, 1, 2. `skip` drops the earlier chunks, `take` keeps 49. No loop, no append, and the order is guaranteed because `Select` preserves it.

**`"@expr"` versus `"@{expr}"` is not cosmetic.** The two `values` properties use the bare `"@…"` form, which yields a real **array**. The `displayName` and `description` use `"@{…}"`, which yields a **string**. Get this backwards on `values` and Fabric receives `"[\"guid\",\"guid\"]"` — a string that looks right in the run history and is rejected, or worse, accepted as a single nonsense value.

**The display name is kept short deliberately.** Rule names are capped at **60 characters** by the service. `Approved item types for whitelisted workspaces` is 46, leaving room for ` (10/12)` and beyond. The PowerShell uses a longer base name and truncates it; this avoids needing the truncation expression at all. Rule names are cosmetic — rules are identified by ID — so the first rebuild of a migrated capacity renaming its rules is harmless.

---

## Step 8 — Build rule 1 and the request body

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
        "values": [ "@{parameters('PolicySentinelWorkspaceId (ab_PolicySentinelWorkspaceId)')}" ]
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
  "policyRules": "@union(createArray(outputs('Compose_rule1')), body('Select_whitelist_rules'))"
}
```

`createArray` wraps rule 1 into a one-element array; `union` appends the whitelist rules after it. When `chunkCount` is 0, `Select` returns `[]` and the result is **rule 1 alone** — the safe default from §0, reached without a special case.

---

## Step 9 — Write the rules

**+ New step** → **HTTP**, renamed `Replace_rules`.

| Field | Value |
|---|---|
| Method | `POST` |
| URI | `https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ab_PolicyHolderWorkspaceId)')}/policySets/@{variables('policySetId')}/policyRules/replaceByPolicy` |
| Header `Authorization` | `Bearer @{variables('accessToken')}` |
| Header `Content-Type` | `application/json` |
| Body | `@outputs('Compose_body')` |

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
| Row ID | `first(body('Get_policy_row')?['value'])?['crbab_capacitypolicyid']` |
| `crbab_lastrebuild` | `utcNow()` |
| `crbab_lasterror` | `if(less(coalesce(outputs('Replace_rules')?['statusCode'], 0), 300), '', coalesce(body('Replace_rules')?['message'], body('Replace_rules')?['errorCode'], string(body('Replace_rules'))))` |
| `crbab_workspacecount` | `length(variables('workspaces'))` |
| `crbab_rulecount` | `add(variables('chunkCount'), 1)` |

Writing the row on both paths is the point — a failed rebuild that leaves `last_error` blank is indistinguishable from a healthy one, and this table is what the app shows.

> **The two counts are written for [ListCapacityPolicySets](docs/flows/capacity-policies/ListCapacityPolicySets.md), which cannot afford to compute them.** Counting enabled workspaces per capacity at read time is one Dataverse query per capacity, 200–300 of them inside a 120-second budget. This flow has both numbers already.
>
> They are stamped **on the failure path too, and that is deliberate**: they describe what Dataverse said at the time of the attempt, not what Fabric ended up holding. Paired with a non-blank `last_error` they read correctly — *"this is what we tried to publish, and it did not land"*. Writing them only on success would leave the previous run's numbers sitting next to a fresh failure, which is the more misleading of the two options.
>
> Store them as **whole numbers**, not text. The typing rule that forces every *Respond* output to Text does not apply to Dataverse columns, and flow 2 needs to sort on them.

### 10b. Respond

**+ New step** → **Respond to a Power App or flow**, ⋯ → **Configure run after** on `Update_policy_row` with **is successful** and **has failed** ticked. Five **Text** outputs:

| Output | Value |
|---|---|
| `Outcome` | `if(less(coalesce(outputs('Replace_rules')?['statusCode'], 0), 300), 'Rebuilt', 'Failed')` |
| `PolicySetId` | `variables('policySetId')` |
| `RuleCount` | `string(add(variables('chunkCount'), 1))` |
| `WorkspaceCount` | `string(length(variables('workspaces')))` |
| `Message` | `if(less(coalesce(outputs('Replace_rules')?['statusCode'], 0), 300), 'Rules rebuilt.', coalesce(body('Replace_rules')?['message'], body('Replace_rules')?['errorCode'], string(body('Replace_rules'))))` |

Status code lives on `outputs('Replace_rules')`, the payload on `body('Replace_rules')`. They are not interchangeable — `body(...)?['statusCode']` is always blank, which would report every rebuild as `Failed`.

**Every output must be Text.** A field typed Number or Boolean fails schema validation at runtime and makes *every* output of the flow unreadable to the caller, not just the bad one. That is why `RuleCount` is `string(...)` rather than an integer.

### `PolicySetId` costs nothing and answers the support question

It is already in a variable, so returning it is free. What it buys is a run history where **the policy set that was written is on the record next to the outcome**, rather than something you re-derive from `Capacity Policies` as it stands today — which is the wrong day to be reading it, because by then it may have been repointed. The nightly batch in [RebuildAllCapacityPolicies.md](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) is where this pays: 250 child-flow runs in one parent, and the id is what ties a failure to a capacity without a second query.

> **Do not return the rule IDs.** `replaceByPolicy` responds with the rules it created, and it is tempting to keep them. They are regenerated with new IDs on every rebuild, so anything that stored them would be stale within a day, and nothing in this design addresses a rule by ID — that is the entire point of rebuilding wholesale.

### Keep every Respond in this flow to the same five fields

There are three `Respond to a Power App or flow` actions here — the two early exits in Steps 4 and 6, and this one. **Give all of them the same five outputs**, with `PolicySetId`, `RuleCount` and `WorkspaceCount` set to `''`, `'0'` and `'0'` on the early exits.

A caller reading a field that the branch it happened to take never declared gets a **blank, not an error**. So a mismatch does not fail; it produces early-exit responses whose `RuleCount` is empty and a parent flow that quietly treats it as zero. Identical schemas everywhere is the only version of this that stays debuggable.

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | Capacity whose Node row exists but has **no** `FabricEnabled` workspaces | Exactly **one** rule in the portal — the deny-all. **Run this first**; it is the path that unlocks a capacity if it is wrong |
| 2 | Capacity with 3 enabled workspaces | Two rules: deny-all, plus one whitelist rule named without a `(1/1)` suffix |
| 3 | Capacity with 50 enabled workspaces | Three rules: deny-all, plus `(1/2)` and `(2/2)`, split 49 + 1 |
| 4 | Run twice with no data change | Identical rule set, no duplicates. `replaceByPolicy` makes this idempotent |
| 5 | Set one workspace's `FabricEnabled` to No, rerun | The workspace is gone from the rules and no empty rule is left behind |
| 6 | Unregistered capacity ID (no `Capacity Policies` row) | `Failed` with the "run InitializeCapacityPolicySet first" message, and no Fabric call |
| 7 | **Policy row whose `node` lookup is blank** | `Failed`, and **no Fabric call**. Not rule 1 alone — see the box in Step 5a |
| 8 | A workspace on the Node with `FabricEnabled` blank (never set) | Absent from the rules, same as an explicit No |
| 9 | Move a workspace's `Node` to another capacity, rebuild **both** | It appears on the new capacity and disappears from the old |
| 10 | Peek code on `Select_whitelist_rules` | `values` is a JSON **array**, not a quoted string |

Test 7 is the one this design added and the one worth writing down: it is the difference between "a capacity has no whitelist" and "we cannot see the whitelist", and only one of those should reach Fabric.

Test 10 is worth doing once by hand. It is the difference between a rule that works and a rule that looks right in the designer and matches nothing.

> Testing from the designer reports **`ActionResponseSkipped`** on the Respond action — expected, because nothing is waiting for the response. The rules are still written. Check the outcome by reading the Respond action's **inputs** in the run history, or by looking at the rules in the portal.
