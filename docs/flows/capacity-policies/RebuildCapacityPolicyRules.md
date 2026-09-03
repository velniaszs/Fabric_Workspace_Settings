# Flow — `RebuildCapacityPolicyRules`

Child flow. **The only flow that writes policy rules.** Reads the desired state from Dataverse and replaces every `ItemCreation` rule on one capacity's policy set in a single call.

> **Not built yet.** Specification, not a description of something that exists.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §2 and §3, [GetPolicyToken.md](docs/flows/capacity-policies/GetPolicyToken.md), [InitializeCapacityPolicySet.md](docs/flows/capacity-policies/InitializeCapacityPolicySet.md), [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md), [RemoveWorkspaceFromPolicy.md](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md).

---

## 0. Before you start

- Build [GetPolicyToken.md](docs/flows/capacity-policies/GetPolicyToken.md) first.
- The three tables from [CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §3 must exist and be seeded.
- **This flow needs a Dataverse connection**, unlike the Fabric-only flows elsewhere in this repo. It will have a `connectionReferences` entry. That is expected here.
- Logical names below use the `crbab_` prefix. **Substitute your publisher prefix.** Pick tables and columns from the designer dropdowns rather than typing them.

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

## Step 3 — Find the policy set

**+ New step** → Dataverse **List rows**. Rename it `Get_policy_row`.

| Field | Value |
|---|---|
| Table name | `Capacity Policies` |
| Filter rows | `crbab_capacityid eq '@{triggerBody()['text']}'` |
| Row count | `1` |

**+ New step** → **Condition**, renamed `Condition_policy_exists`:

| Left (expression) | Operator | Right |
|---|---|---|
| `empty(body('Get_policy_row')?['value'])` | is equal to | `true` |

**Yes** branch → a **Respond to a Power App or flow** returning `Outcome` = `Failed`, `Message` = `No policy set is registered for this capacity. Run InitializeCapacityPolicySet first.` Then **Terminate** with status `Succeeded` — the caller gets an answer, and this is a caller error rather than a flow fault.

Everything from Step 4 on goes in the **No** branch.

---

## Step 4 — Variables

Five `Initialize variable` actions, in order.

| Rename to | Name | Type | Value |
|---|---|---|---|
| `Initialize_policySetId` | `policySetId` | String | `first(body('Get_policy_row')?['value'])?['crbab_policysetid']` |
| `Initialize_maxPerRule` | `maxPerRule` | Integer | `int(parameters('PolicyMaxWorkspacesPerRule (ab_PolicyMaxWorkspacesPerRule)'))` |
| `Initialize_workspaces` | `workspaces` | Array | *(leave empty)* |
| `Initialize_itemTypes` | `itemTypes` | Array | *(leave empty)* |
| `Initialize_chunkCount` | `chunkCount` | Integer | `0` |

---

## Step 5 — Read the desired state

### 5a. `List_workspace_rows` — Dataverse **List rows**

| Field | Value |
|---|---|
| Table name | `Capacity Workspaces` |
| Filter rows | `crbab_capacityid eq '@{triggerBody()['text']}'` |
| Select columns | `crbab_workspaceid` |
| Row count | `5000` |

⋯ → **Settings** → **Pagination On**, Threshold `5000`. Without it you silently get the first page only, and a capacity over the page size loses workspaces on every rebuild — a data-loss bug that looks like a Fabric problem.

### 5b. `Select_workspace_ids` — **Select**

| Field | Value |
|---|---|
| From | `body('List_workspace_rows')?['value']` |
| Map | switch to **text mode** (the `T` icon) and enter `item()?['crbab_workspaceid']` |

Text mode is what makes this produce an array of plain strings rather than an array of objects. An array of objects sent as `predicate.values` is rejected.

### 5c. `Set_workspaces` — **Set variable**

| Field | Value |
|---|---|
| Name | `workspaces` |
| Value | `union(body('Select_workspace_ids'), body('Select_workspace_ids'))` |

`union` of a list with itself is the idiomatic **dedupe**. A uniqueness key on the table should prevent duplicates, but a duplicated GUID inside one `values` array is the kind of thing Fabric may reject, and this costs nothing.

### 5d. `List_item_type_rows` — Dataverse **List rows**

| Field | Value |
|---|---|
| Table name | `Policy Item Types` |
| Filter rows | `crbab_active eq true` |
| Select columns | `crbab_itemtype` |
| Row count | `5000` |

### 5e. `Select_item_types` — **Select**

| Field | Value |
|---|---|
| From | `body('List_item_type_rows')?['value']` |
| Map (text mode) | `item()?['crbab_itemtype']` |

### 5f. `Set_itemTypes` — **Set variable**

| Field | Value |
|---|---|
| Name | `itemTypes` |
| Value | `union(body('Select_item_types'), body('Select_item_types'))` |

---

## Step 6 — Work out how many rules are needed

**+ New step** → **Set variable**, renamed `Set_chunkCount`:

| Field | Value |
|---|---|
| Name | `chunkCount` |
| Value | `if(equals(length(variables('workspaces')), 0), 0, add(div(sub(length(variables('workspaces')), 1), variables('maxPerRule')), 1))` |

That is integer ceiling division: zero workspaces gives zero rules, 1–49 gives one, 50 gives two.

### The ceiling guard

**+ New step** → **Condition**, renamed `Condition_too_many_rules`:

| Left | Operator | Right |
|---|---|---|
| `add(variables('chunkCount'), 1)` | is greater than | `int(parameters('PolicyMaxRulesPerPolicy (ab_PolicyMaxRulesPerPolicy)'))` |

**Yes** → Respond with `Outcome` = `Failed` and a message naming the limit, then **Terminate** with `Succeeded`.

The ceiling is **49 whitelist rules × 49 workspaces = 2401 workspaces per capacity**. Fail here, before calling Fabric — a rejected `replaceByPolicy` would leave the live rules untouched but the caller with no idea why.

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

Writing the row on both paths is the point — a failed rebuild that leaves `last_error` blank is indistinguishable from a healthy one, and this table is what the app shows.

### 10b. Respond

**+ New step** → **Respond to a Power App or flow**, ⋯ → **Configure run after** on `Update_policy_row` with **is successful** and **has failed** ticked. Four **Text** outputs:

| Output | Value |
|---|---|
| `Outcome` | `if(less(coalesce(outputs('Replace_rules')?['statusCode'], 0), 300), 'Rebuilt', 'Failed')` |
| `RuleCount` | `string(add(variables('chunkCount'), 1))` |
| `WorkspaceCount` | `string(length(variables('workspaces')))` |
| `Message` | `if(less(coalesce(outputs('Replace_rules')?['statusCode'], 0), 300), 'Rules rebuilt.', coalesce(body('Replace_rules')?['message'], body('Replace_rules')?['errorCode'], string(body('Replace_rules'))))` |

Status code lives on `outputs('Replace_rules')`, the payload on `body('Replace_rules')`. They are not interchangeable — `body(...)?['statusCode']` is always blank, which would report every rebuild as `Failed`.

**Every output must be Text.** A field typed Number or Boolean fails schema validation at runtime and makes *every* output of the flow unreadable to the caller, not just the bad one. That is why `RuleCount` is `string(...)` rather than an integer.

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | Capacity with **zero** rows in `Capacity Workspaces` | Exactly **one** rule in the portal — the deny-all. **Run this first**; it is the path that unlocks a capacity if it is wrong |
| 2 | Capacity with 3 workspaces | Two rules: deny-all, plus one whitelist rule named without a `(1/1)` suffix |
| 3 | Capacity with 50 workspaces | Three rules: deny-all, plus `(1/2)` and `(2/2)`, split 49 + 1 |
| 4 | Run twice with no data change | Identical rule set, no duplicates. `replaceByPolicy` makes this idempotent |
| 5 | Remove a workspace row, rerun | The workspace is gone from the rules and no empty rule is left behind |
| 6 | Unregistered capacity ID | `Failed` with the "run InitializeCapacityPolicySet first" message, and no Fabric call |
| 7 | Peek code on `Select_whitelist_rules` | `values` is a JSON **array**, not a quoted string |

Test 7 is worth doing once by hand. It is the difference between a rule that works and a rule that looks right in the designer and matches nothing.

> Testing from the designer reports **`ActionResponseSkipped`** on the Respond action — expected, because nothing is waiting for the response. The rules are still written. Check the outcome by reading the Respond action's **inputs** in the run history, or by looking at the rules in the portal.
