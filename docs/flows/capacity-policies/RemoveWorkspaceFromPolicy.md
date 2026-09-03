# Flow — `RemoveWorkspaceFromPolicy`

Confirms that a workspace is no longer whitelisted on a capacity, then rebuilds that capacity's rules. **Writes nothing to Dataverse.**

> **Not built yet.** Specification, not a description of something that exists.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md), [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md), [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md).

---

## 0. Before you start

- Build [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) first, and confirm the placeholder column names in its §0.
- Needs a **Dataverse connection** for reads only. No Fabric calls of its own.
- Build [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) first and copy it. Steps 1–3 are nearly identical; Step 4 is where they diverge, and they diverge on purpose.

> ## This flow removes nothing
>
> It does not clear `FabricEnabled` and it does not delete a row. Both belong to the platform team ([CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §3). What it does is **check that the workspace really has stopped qualifying, and republish the rules so Fabric agrees**.
>
> Withdrawal happens when the owning system clears `FabricEnabled`, repoints the `Node`, or deletes the row. This flow is how that becomes visible in the policy without waiting for the nightly run.

> ### It fails in the opposite direction to `AddWorkspaceToPolicy`
>
> Add **refuses** when the state is not what the caller assumed — rebuilding and reporting success would tell a user they have access they do not have.
>
> Remove **proceeds anyway**. Republishing the current truth can only ever narrow or preserve access, never widen it, so there is no unsafe case to guard against. A missing row, a repointed `Node`, a cleared flag — all of them mean *rebuild and report*. The one case that needs a distinct answer is a workspace whose flag is **still set**, because then the removal has not actually happened and the rules will keep it.
>
> Getting this backwards — refusing to rebuild because the row looks odd — would leave access in place that somebody has asked to withdraw. For a leaver or a security incident that is the wrong way to be cautious.

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

## Step 3 — Find the workspace row

`Get_workspace_row` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Workspaces` (`ubsppcoe_Workspace`) |
| Filter rows | `ubsppcoe_fabricworkspaceid eq '@{triggerBody()['text_1']}'` |
| Select columns | `ubsppcoe_fabricworkspaceid,ubsppcoe_fabricenabled,_ubsppcoe_node_value` |
| Row count | `50` |

**Rows, plural, deliberately.** This table is not ours and has no uniqueness key we control. If the same workspace GUID appears on two rows and either of them is still enabled, the workspace stays in the rules — so the check below has to see all of them, not the first.

Note the asymmetry with [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md), which refuses outright on more than one row. Acting on an ambiguous record is a guess; *reporting* on all copies of it is not.

`Filter_enabled` — **Filter array**:

| Field | Value |
|---|---|
| From | `coalesce(body('Get_workspace_row')?['value'], createArray())` |
| Condition | `item()?['ubsppcoe_fabricenabled']` **is equal to** `true` |

A **Filter array** action, not an expression. There is no `filter()` function in Power Automate's expression language — the only ways to narrow an array are this action and `Select`.

> **The capacity id is not used to find the row.** A workspace belongs to one Node, so the workspace GUID alone identifies it. Requiring the `Node` to still match `capacityId` would turn an already-completed move into a refusal to withdraw access — exactly the wrong way to fail here. The rebuild runs against the `capacityId` the caller gave, which is the capacity they want cleaned up.

---

## Step 4 — Decide what to report, then rebuild either way

`Condition_still_enabled` — **Condition**:

| Left | Operator | Right |
|---|---|---|
| `empty(body('Filter_enabled'))` | is equal to | `false` |

### Yes — the flag is still set

`outcome` = `StillEnabled`, and a message that says plainly what will happen: `This workspace is still Fabric-enabled, so it remains whitelisted on this capacity. The rules were republished as they stand. FabricEnabled is cleared by the platform team's process, not by this app.`

**Then continue to the rebuild anyway.** This is not an error branch — it sets a different message and falls through.

### No — not enabled, or no row at all

`outcome` = `Removed`. Both sub-cases mean the workspace no longer qualifies:

| State | Why it counts as removed |
|---|---|
| Row exists, `FabricEnabled` No or blank | The withdrawal has happened upstream |
| Row deleted entirely | The workspace is gone from the inventory, so it cannot match the filter |
| Row exists but `Node` now points elsewhere | Already moved; it is no longer this capacity's business |

> **A missing row is a success here and a refusal in `AddWorkspaceToPolicy`.** That is deliberate, and it is the clearest expression of the asymmetry in §0: you cannot whitelist a workspace that does not exist, but a workspace that does not exist is certainly not whitelisted.

---

## Step 5 — Rebuild

`Run_rebuild` — **Run a Child Flow** → `RebuildCapacityPolicyRules`, passing `triggerBody()['text']`.

`Condition_rebuild_ok` — **Condition**, run after `Run_rebuild` on **is successful** and **has failed**:

| Left | Operator | Right |
|---|---|---|
| `body('Run_rebuild')?['outcome']` | is equal to | `Rebuilt` |

### Yes

Leave `outcome` as Step 4 set it — `Removed` or `StillEnabled` — and append the counts to the message: `concat(variables('message'), ' Policy rules updated: ', body('Run_rebuild')?['workspacecount'], ' workspace(s) allowed on this capacity.')`

**Do not overwrite `outcome` with `Removed` here.** The rebuild succeeding says nothing about whether the workspace actually came out; that was decided in Step 4, and flattening the two would turn `StillEnabled` into a false confirmation.

### No

`outcome` = `Failed`, `message` = `concat('The rules could not be republished: ', coalesce(body('Run_rebuild')?['message'], 'the rebuild flow failed.'), ' If the workspace has been withdrawn in Dataverse, the nightly rebuild will apply it.')`

---

## Step 6 — Why a failure here is not rolled back

There is nothing to roll back — this flow writes nothing. But the *reporting* still matters, because Dataverse and Fabric now disagree and the operator needs to know which way.

| | `AddWorkspaceToPolicy` fails | This flow fails |
|---|---|---|
| Dataverse says | whitelisted | not whitelisted |
| Fabric still says | not whitelisted | **whitelisted** |
| Consequence | The app promises access that does not exist | **Access that should have been withdrawn is still live** |

The second is the one with a security dimension. The withdrawal is recorded in Dataverse and the nightly rebuild in [RebuildAllCapacityPolicies.md](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) will converge Fabric to it — but not until tonight.

**Say so in the message.** An operator withdrawing access for a leaver needs to know whether it took effect now or tonight; that is the difference between finishing the task and escalating it. A bare "failed" tells them neither.

---

## Step 7 — Respond

**Respond to a Power App or flow**, run after the Condition on **is successful** and **has failed**. Two **Text** outputs:

| Output | Value |
|---|---|
| `Outcome` | `variables('outcome')` |
| `Message` | `variables('message')` |

| `outcome` | Meaning | Rebuild ran? |
|---|---|---|
| `Removed` | The workspace no longer qualifies, and the rules now say so | Yes |
| `StillEnabled` | `FabricEnabled` is still set, so it **remains whitelisted**. Rules republished as they stand | Yes |
| `Failed` | Rules not republished. Access may still be live until the nightly run | Yes, and it failed |

Both **Text**. There is no `NotFound` — a workspace with no row is not whitelisted, which is `Removed`.

> **`StillEnabled` is a success status carrying a warning, and the app must not render it as either extreme.** It is not an error: the flow did everything it could. It is not a confirmation: the workspace is still in the rules. If the app shows a green tick, someone will believe access was withdrawn when it was not.

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | Row whose `FabricEnabled` is No, one of three formerly enabled | `Removed`; the whitelist rule holds two values |
| 2 | The **last** enabled workspace on a capacity, flag cleared | `Removed`; **exactly one rule remains** — the deny-all. No empty rule, no `PropertyMinCount` error |
| 3 | A row whose `FabricEnabled` is still Yes | `StillEnabled`; the rebuild **runs** and the workspace is still in the rules |
| 4 | A workspace GUID with no row at all | `Removed`; the rebuild runs, and **no row is created or deleted** |
| 5 | A row whose `Node` now points at a different capacity | `Removed`; this capacity's rules drop it |
| 6 | Crossing back under the chunk boundary, from 50 to 49 | Rules go from 3 to 2; the `(1/2)`/`(2/2)` naming is regenerated, not left stale |
| 7 | Break the child flow | `Failed`, with the message saying access may still be live until the nightly run |
| 8 | Duplicate rows, one enabled and one not | `StillEnabled`, not `Removed` |
| 9 | Inspect any run's action list | **No write action against `ubsppcoe_Workspace` or `ubsppcoe_Node`** |

Test 3 is the one that distinguishes this flow from a bare refresh, and test 8 is why Step 3 fetches every row rather than the first.

Test 2 is the one that would have been hard the other way. It is a single rule with a sentinel value that matches nothing, and it is what keeps the capacity governed after its last whitelist entry is gone.

> Testing from the designer reports **`ActionResponseSkipped`** on the Respond action — expected. The rebuild still happens.
