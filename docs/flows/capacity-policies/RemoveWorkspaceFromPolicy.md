# Flow — `RemoveWorkspaceFromPolicy`

Confirms that a workspace is no longer whitelisted on a capacity, then rebuilds that capacity's rules. **Writes nothing to Dataverse.**

> **Not built yet.** Specification, not a description of something that exists.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md), [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md), [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md).

---

## 0. Before you start

- Build [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) first, and confirm the placeholder column names in its §0.
- Needs a **Dataverse connection** for reads only, and **not** the Entra ID HTTP connector. No Fabric calls of its own.
- Build [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) first and copy it. Steps 1–3 are nearly identical; Step 4 is where they diverge, and they diverge on purpose.

> ## This flow removes nothing
>
> It does not clear `ubsppcoe_oapenabled` and it does not delete a row. Both belong to the platform team ([CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §3). Nor does it touch `PolicyException`, which is ours — no flow writes that table either. What it does is **check that the workspace really has stopped qualifying, and republish the rules so Fabric agrees**.
>
> Access goes away when the owning system clears `ubsppcoe_oapenabled`, repoints the `Node`, or deletes the row. This flow is how that becomes visible in the policy without waiting for the nightly run.

> ### What it is normally called for
>
> **A workspace moving from one capacity to another, or a workspace being deleted.** In both, the `Node` lookup has already changed or gone — and rule 2 *and* rule 3 are both keyed on that lookup, so a single rebuild takes the workspace out of everything this capacity publishes.
>
> The `PolicyException` row, if there is one, is left alone. It says *"this workspace may create anything"*, not *"on this capacity"* (§3), so it correctly stops applying here and starts applying wherever the workspace has gone, once that capacity is rebuilt. On a move, that means calling `AddWorkspaceToPolicy` against the new capacity — the same second call the whitelist already needs.

> ### It fails in the opposite direction to `AddWorkspaceToPolicy`
>
> Add **refuses** when the state is not what the caller assumed — rebuilding and reporting success would tell a user they have access they do not have.
>
> Remove **proceeds anyway**. Republishing the current truth can only ever narrow or preserve access, never widen it, so there is no unsafe case to guard against. A missing row, a repointed `Node`, a cleared flag — all of them mean *rebuild and report*. The two cases that need a distinct answer are a workspace whose flag is **still set** and one that is **still excepted**, because in both the workspace is still on this capacity and the rules will keep it.
>
> Getting this backwards — refusing to rebuild because the row looks odd — would leave access in place that somebody has asked to take away. For a leaver or a security incident that is the wrong way to be cautious.

> ### The exception list is the trap in this flow
>
> Rule 3 (`PolicyException`, [CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §3) never looks at `ubsppcoe_oapenabled`. So a workspace that is **still on this capacity** can have the flag cleared — everything the caller asked for — and still create **anything**, because the exception grants it independently.
>
> Without the check in Step 3b this flow would answer `Removed` in exactly that situation. That is not a wrong rebuild; it is a **correct rebuild described wrongly**, which is worse, because the operator stops looking.
>
> It does **not** arise on a move or a deletion. Those take the `Node` with them, and rule 3 goes with the `Node`.

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
| Filter rows | `ubsppcoe_workspaceid eq '@{triggerBody()['text_1']}'` |
| Select columns | `ubsppcoe_workspaceid,ubsppcoe_oapenabled,_ubsppcoe_nodeid_value` |
| Row count | `50` |

**Rows, plural, deliberately.** This table is not ours and has no uniqueness key we control. If the same workspace GUID appears on two rows and either of them is still enabled, the workspace stays in the rules — so the check below has to see all of them, not the first.

Note the asymmetry with [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md), which refuses outright on more than one row. Acting on an ambiguous record is a guess; *reporting* on all copies of it is not.

`Filter_enabled` — **Filter array**:

| Field | Value |
|---|---|
| From | `coalesce(body('Get_workspace_row')?['value'], createArray())` |
| Condition | `item()?['ubsppcoe_oapenabled']` **is equal to** `true` |

A **Filter array** action, not an expression. There is no `filter()` function in Power Automate's expression language — the only ways to narrow an array are this action and `Select`.

**`false` and null fall out of this filter identically.** The column is nullable, and a row nobody has set compares unequal to `true` just as an explicit `false` does. Neither keeps the workspace whitelisted, so neither produces `StillEnabled`.

> **The capacity id is not used to find the row.** A workspace belongs to one Node, so the workspace GUID alone identifies it. Requiring the `Node` to still match `capacityId` would turn an already-completed move into a refusal to take access away — exactly the wrong way to fail here. The rebuild runs against the `capacityId` the caller gave, which is the capacity they want cleaned up.
>
> Step 3b compares the two anyway, but only to decide **what to report**, never whether to proceed.

---

## Step 3b — Is it still on this capacity, and still excepted?

Two questions, and `StillExcepted` needs **both** answered yes.

`Get_policy_row` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Capacity Policies` |
| Filter rows | `ubsppcoe_capacityid eq '@{triggerBody()['text']}'` |
| Select columns | `_ubsppcoe_node_value` |
| Row count | `1` |

`Filter_on_this_node` — **Filter array**:

| Field | Value |
|---|---|
| From | `coalesce(body('Get_workspace_row')?['value'], createArray())` |
| Condition | `item()?['_ubsppcoe_nodeid_value']` **is equal to** `first(body('Get_policy_row')?['value'])?['_ubsppcoe_node_value']` |

> **Those two names differ by three characters, and that is not a typo.** The left side is **`_ubsppcoe_nodeid_value`** — the `Node` lookup on a `ubsppcoe_Workspace` row. The right side is **`_ubsppcoe_node_value`** — our own lookup on the `ubsppcoe_CapacityPolicy` row. Different tables, different columns, and both resolve to the same capacity GUID, which is what makes the comparison meaningful: it asks *is this workspace on the capacity the caller named*. See [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §0.

`Get_exception_rows` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Policy Exceptions` |
| Filter rows | `ubsppcoe_workspaceid eq '@{triggerBody()['text_1']}' and ubsppcoe_active eq true` |
| Select columns | `ubsppcoe_workspaceid` |
| Row count | `50` |

**No capacity condition on that filter, because the table has no capacity column** ([CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §3). An exception is a statement about the workspace; `Filter_on_this_node` is what ties it to the capacity the caller named. Checking only the exception table would report `StillExcepted` for a workspace that moved away last week and is no longer in this capacity's rule 3 at all.

> **An empty policy row makes `Filter_on_this_node` empty too**, so the outcome falls through to `Removed` and Step 5's rebuild returns the `Failed` that explains the capacity is unregistered. Do not add a second early exit for it here; one flow should own that message.

---

## Step 4 — Decide what to report, then rebuild either way

`Condition_still_enabled` — **Condition**:

| Left | Operator | Right |
|---|---|---|
| `empty(body('Filter_enabled'))` | is equal to | `false` |

### Yes — the flag is still set

`outcome` = `StillEnabled`, and a message that says plainly what will happen: `This workspace still has OAP enabled, so it remains whitelisted on this capacity. The rules were republished as they stand. That flag is cleared by the platform team's process, not by this app.`

**Then continue to the rebuild anyway.** This is not an error branch — it sets a different message and falls through.

### No — not enabled, or no row at all

`outcome` = `Removed`. Both sub-cases mean the workspace no longer qualifies:

| State | Why it counts as removed |
|---|---|
| Row exists, `ubsppcoe_oapenabled` `false` or null | The flag has already been cleared upstream, or was never set |
| Row deleted entirely | The workspace is gone from the inventory, so it cannot match the filter |
| Row exists but `Node` now points elsewhere | Already moved; it is no longer this capacity's business |

> **A missing row is a success here and a refusal in `AddWorkspaceToPolicy`.** That is deliberate, and it is the clearest expression of the asymmetry in §0: you cannot whitelist a workspace that does not exist, but a workspace that does not exist is certainly not whitelisted.

> **The last two rows are the normal case, not the odd one.** A move or a deletion is why this flow is usually called, and both take the workspace out of rule 2 **and** rule 3 in one rebuild, because both rules are keyed on the `Node` lookup. Nothing is left behind on this capacity and no `Policy Exceptions` row needs editing.

### Step 4b — the exception overrides both answers

`Condition_excepted` — a second **Condition**, after the first, with **two** rows ANDed:

| Left | Operator | Right |
|---|---|---|
| `empty(body('Get_exception_rows')?['value'])` | is equal to | `false` |
| `empty(body('Filter_on_this_node'))` | is equal to | `false` |

**Yes** → overwrite `outcome` with `StillExcepted` and set the message to: `This workspace has an active policy exception, so it can still create any item type on this capacity regardless of whether OAP is enabled. The rules were republished as they stand. Deactivate its Policy Exceptions row and rebuild to stop that.`

**No** → leave whatever Step 4 decided.

> **Both conditions, not just the first.** An exception row for a workspace that has already left this capacity is not this capacity's problem — the rebuild will not put it in rule 3, and reporting `StillExcepted` would send someone to deactivate a row that is doing no harm here and may be doing something useful elsewhere.

> **This one does overwrite `StillEnabled`.** They are not equally urgent: `StillEnabled` means the workspace kept its whitelisted item types, `StillExcepted` means it kept **everything**. Reporting the narrower of the two would understate what is still live, and the message for the wider one already tells the operator where to go.

---

## Step 5 — Rebuild

`Run_rebuild` — **Run a Child Flow** → `RebuildCapacityPolicyRules`, passing `triggerBody()['text']`.

`Condition_rebuild_ok` — **Condition**, run after `Run_rebuild` on **is successful** and **has failed**:

| Left | Operator | Right |
|---|---|---|
| `body('Run_rebuild')?['outcome']` | is equal to | `Rebuilt` |

### Yes

Leave `outcome` as Step 4 set it — `Removed`, `StillEnabled` or `StillExcepted` — and append the counts to the message: `concat(variables('message'), ' Policy rules updated: ', body('Run_rebuild')?['workspacecount'], ' workspace(s) allowed on this capacity.')`

**Do not overwrite `outcome` with `Removed` here.** The rebuild succeeding says nothing about whether the workspace actually came out; that was decided in Step 4, and flattening the three would turn a warning into a false confirmation.

### No

`outcome` = `Failed`, `message` = `concat('The rules could not be republished: ', coalesce(body('Run_rebuild')?['message'], 'the rebuild flow failed.'), ' If the workspace has already been moved or disabled in Dataverse, the nightly rebuild will apply it.')`

---

## Step 6 — Why a failure here is not rolled back

There is nothing to roll back — this flow writes nothing. But the *reporting* still matters, because Dataverse and Fabric now disagree and the operator needs to know which way.

| | `AddWorkspaceToPolicy` fails | This flow fails |
|---|---|---|
| Dataverse says | whitelisted | not whitelisted |
| Fabric still says | not whitelisted | **whitelisted** |
| Consequence | The app promises access that does not exist | **Access that should be gone is still live** |

The second is the one with a security dimension. The change is recorded in Dataverse and the nightly rebuild in [RebuildAllCapacityPolicies.md](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) will converge Fabric to it — but not until tonight.

**Say so in the message.** An operator taking access away for a leaver needs to know whether it took effect now or tonight; that is the difference between finishing the task and escalating it. A bare "failed" tells them neither.

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
| `StillEnabled` | `ubsppcoe_oapenabled` is still `true`, so it **remains whitelisted**. Rules republished as they stand | Yes |
| `StillExcepted` | The workspace is **still on this capacity** and has an active `PolicyException` row, so it can create **any** item type whatever `ubsppcoe_oapenabled` says | Yes |
| `Failed` | Rules not republished. Access may still be live until the nightly run | Yes, and it failed |

Both **Text**. There is no `NotFound` — a workspace with no row is not whitelisted, which is `Removed`.

> **`StillEnabled` and `StillExcepted` are success statuses carrying a warning, and the app must not render either as an extreme.** They are not errors: the flow did everything it could. They are not confirmations: the workspace is still in the rules. If the app shows a green tick, someone will believe access was taken away when it was not.
>
> They also need **different remedies on screen**. `StillEnabled` is somebody else's flag and the message points at the platform team. `StillExcepted` is our own table, so the fix is in reach — deactivate the row and rebuild.

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | Row whose `ubsppcoe_oapenabled` is `false`, one of three formerly enabled | `Removed`; the whitelist rule holds two values |
| 2 | The **last** enabled workspace on a capacity, flag cleared | `Removed`; **exactly one rule remains** — the deny-all. No empty rule, no `PropertyMinCount` error |
| 3 | A row whose `ubsppcoe_oapenabled` is still `true` | `StillEnabled`; the rebuild **runs** and the workspace is still in the rules |
| 4 | A workspace GUID with no row at all | `Removed`; the rebuild runs, and **no row is created or deleted** |
| 5 | A row whose `Node` now points at a different capacity | `Removed`; this capacity's rules drop it |
| 6 | Crossing back under the chunk boundary, from 50 to 49 | Rules go from 3 to 2; the `(1/2)`/`(2/2)` naming is regenerated, not left stale |
| 7 | Break the child flow | `Failed`, with the message saying access may still be live until the nightly run |
| 8 | Duplicate rows, one enabled and one not | `StillEnabled`, not `Removed` |
| 9 | Inspect any run's action list | **No write action against `ubsppcoe_Workspace` or `ubsppcoe_Node`** |
| 10 | `ubsppcoe_oapenabled` cleared, workspace **still on this capacity**, active exception row | `StillExcepted`, and the workspace is still in rule 3. **The one that would otherwise report a removal that did not happen** |
| 11 | A row whose `ubsppcoe_oapenabled` is **null**, never set | `Removed`, identical to an explicit `false` |
| 11 | The same, with the exception row's `active` set to No | `Removed`, and no rule 3 for it |
| 12 | **Excepted workspace whose `Node` has already moved** to another capacity | `Removed`, **not** `StillExcepted` — and this capacity's rule 3 no longer contains it |
| 13 | The same workspace, then rebuild the **new** capacity | It appears in the new capacity's rule 3. The exception followed the workspace, and no row was edited |
| 14 | An excepted workspace whose row is deleted outright | `Removed`, and it is in no rule 3 anywhere |

Test 3 is the one that distinguishes this flow from a bare refresh, and test 8 is why Step 3 fetches every row rather than the first.

Tests 12 and 13 are the pair that prove the capacity move works: one call to this flow against the old capacity and one to `AddWorkspaceToPolicy` against the new one, and the exception moves with the workspace without anybody touching `Policy Exceptions`.

Test 10 is the one worth building the flow around. Everything else here reports on data owned elsewhere; this is the case where our own table quietly keeps access alive.

Test 2 is the one that would have been hard the other way. It is a single rule with a sentinel value that matches nothing, and it is what keeps the capacity governed after its last whitelist entry is gone.

> Testing from the designer reports **`ActionResponseSkipped`** on the Respond action — expected. The rebuild still happens.
