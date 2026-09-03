# Flow — `RemoveWorkspaceFromPolicy`

Removes a workspace from a capacity's whitelist. Deletes the Dataverse rows, then rebuilds that capacity's rules.

> **Not built yet.** Specification, not a description of something that exists.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md), [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md), [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md).

---

## 0. Before you start

- Build [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) first.
- Needs a **Dataverse connection**. No Fabric calls of its own.
- Near-identical to [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md). Build that one first and copy it; the differences are Steps 3, 4 and 6.

> ### The awkward cases do not exist here
>
> Editing rules incrementally, removing the **last** workspace from a rule is a special case: the API rejects an empty `values` list with `PropertyMinCount`, so the rule has to be deleted rather than patched. `remove_workspace_from_rule.ps1` refuses to guess and hands that back to the operator.
>
> Rebuilding sidesteps it entirely. Rules are not edited, they are regenerated — a chunk that would be empty is simply never emitted, and rule 1 is always present regardless. There is no last-workspace case, no empty-rule case, and no rule to delete.

---

## Step 1 — Create the flow

**Solutions** → **New** → **Automation** → **Cloud flow** → **Instant** → name `RemoveWorkspaceFromPolicy` → trigger **Power Apps (V2)**.

Two **Text** inputs:

| Order | Title | Key | Reference |
|---|---|---|---|
| 1 | `capacityId` | `text` | `triggerBody()['text']` |
| 2 | `workspaceId` | `text_1` | `triggerBody()['text_1']` |

Both required. Same order as `AddWorkspaceToPolicy`, so the app calls both the same way.

---

## Step 2 — Variables

| Rename to | Name | Type | Value |
|---|---|---|---|
| `Initialize_outcome` | `outcome` | String | `Failed` |
| `Initialize_message` | `message` | String | *(empty)* |

---

## Step 3 — Find the rows

`Get_links` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Capacity Workspaces` |
| Filter rows | `crbab_capacityid eq '@{triggerBody()['text']}' and crbab_workspaceid eq '@{triggerBody()['text_1']}'` |
| Row count | `50` |

**Rows, plural, deliberately.** A uniqueness key should make this at most one, but if duplicates ever got in, removing only the first would leave the workspace whitelisted and the user staring at a "removed" message that did nothing. Fetch them all and delete them all.

`Condition_present` — **Condition**:

| Left | Operator | Right |
|---|---|---|
| `empty(body('Get_links')?['value'])` | is equal to | `true` |

**Yes** → `outcome` = `NotPresent`, `message` = `This workspace is not whitelisted on this capacity.` **Do not rebuild** — nothing changed.

Everything below goes in the **No** branch.

---

## Step 4 — Delete the rows

**Apply to each** over `@body('Get_links')?['value']`, renamed `For_each_link`. Inside, one Dataverse **Delete a row**:

| Field | Value |
|---|---|
| Table name | `Capacity Workspaces` |
| Row ID | `items('For_each_link')?['crbab_capacityworkspaceid']` |

Leave concurrency at default. These are independent deletes against different rows.

---

## Step 5 — Rebuild

`Run_rebuild` — **Run a Child Flow** → `RebuildCapacityPolicyRules`, passing `triggerBody()['text']`.

`Condition_rebuild_ok` — **Condition**, run after `Run_rebuild` on **is successful** and **has failed**:

| Left | Operator | Right |
|---|---|---|
| `body('Run_rebuild')?['outcome']` | is equal to | `Rebuilt` |

### Yes

`outcome` = `Removed`, `message` = `Workspace removed from the whitelist.`

### No

`outcome` = `Failed`, `message` = `concat('The workspace was removed from the list but the rules could not be rebuilt: ', coalesce(body('Run_rebuild')?['message'], 'the rebuild flow failed.'), ' The nightly rebuild will apply it.')`

---

## Step 6 — Why there is no rollback here

`AddWorkspaceToPolicy` deletes its row if the rebuild fails. **This flow does not re-insert.** The asymmetry is deliberate.

| | Add fails | Remove fails |
|---|---|---|
| Dataverse says | whitelisted | not whitelisted |
| Fabric still says | not whitelisted | whitelisted |
| Consequence | The app promises access that does not exist. The user is told they can create items and cannot | Access that should have been withdrawn persists until the next rebuild |

Both are wrong, but they fail in opposite directions, and only one of them can be made safe by rolling back.

Re-inserting the row would restore access the operator has just asked to withdraw — turning a delayed removal into a **cancelled** one. If the removal was for a security reason, silently reinstating it is the worse outcome. Leaving the row deleted means the intent is recorded, the nightly rebuild in [RebuildAllCapacityPolicies.md](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) converges Fabric to it, and the message tells the operator exactly that.

**Say so in the message.** An operator who removes access for a leaver needs to know whether it took effect now or tonight — that is the difference between finishing the task and escalating it.

---

## Step 7 — Respond

**Respond to a Power App or flow**, run after the Condition on **is successful** and **has failed**. Two **Text** outputs:

| Output | Value |
|---|---|
| `Outcome` | `variables('outcome')` |
| `Message` | `variables('message')` |

| `outcome` | Meaning |
|---|---|
| `Removed` | Rows deleted and rules rebuilt |
| `NotPresent` | Nothing to do |
| `Failed` | Rows deleted, rules **not** yet rebuilt. The nightly job will apply it |

Both **Text**.

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | Remove one of three workspaces | `Removed`; the whitelist rule holds two values |
| 2 | Remove the **last** workspace on a capacity | `Removed`; **exactly one rule remains** — the deny-all. No empty rule, no `PropertyMinCount` error |
| 3 | Remove a workspace that is not whitelisted | `NotPresent`; no rebuild |
| 4 | Remove one of 50, crossing back under the chunk boundary | Rules go from 3 to 2; the `(1/2)`/`(2/2)` naming is regenerated, not left stale |
| 5 | Break the child flow, then remove | `Failed`, the row **stays deleted**, and the message says the nightly rebuild will apply it |
| 6 | Remove, then re-add the same workspace | `Removed` then `Added`; final rule set identical to before |

Test 2 is the one that would have been hard the other way. It is a single rule with a sentinel value that matches nothing, and it is what keeps the capacity governed after its last whitelist entry is gone.

> Testing from the designer reports **`ActionResponseSkipped`** on the Respond action — expected. The deletes and the rebuild still happen.
