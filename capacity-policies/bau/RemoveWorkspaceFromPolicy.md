# Flow — `RemoveWorkspaceFromPolicy`

Fires when a workspace stops being OAP-enabled, derives which capacity it belongs to, and rebuilds that capacity's rules. **Writes nothing to Dataverse except an error, and only when one occurs.**

> **Not built yet.** Specification, not a description of something that exists.

> ## Retriggered 2026-09-12 — no longer called by the app
>
> It was an instant flow with a **Power Apps (V2)** trigger taking `capacityId` and `workspaceId`. It now fires on a **Dataverse row trigger on `ubsppcoe_Workspace`** with the complementary filter to [AddWorkspaceToPolicy](docs/flows/capacity-policies/AddWorkspaceToPolicy.md), and the capacity is **derived**.
>
> | # | Edit | Where |
> |---|---|---|
> | 1 | Delete the Power Apps (V2) trigger, add the Dataverse one | Step 1 |
> | 2 | Three new variables — `workspaceId`, `capacityId`, `policyRowId` | Step 2 |
> | 3 | Move `Get_policy_row` earlier and refilter it on the Node | Step 2b |
> | 4 | `triggerBody()['text_1']` → `variables('workspaceId')` | Steps 3, 3b |
> | 5 | `triggerBody()['text']` → `variables('capacityId')` | Step 5 |
> | 6 | Replace `Respond` with a `Compose` | Step 7 |
> | 7 | Wrap Steps 2b–5 in `Scope_try`; add `Scope_catch` | Step 8 |
> | 8 | Concurrency Control On, Degree of Parallelism 1 | Settings |
>
> **The flow got narrower, and that is the thing to understand before building it.** See §0.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md), [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md), [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) — build and convert that one first, then copy it.

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

> ### What it is normally called for — and what it no longer covers
>
> **Under the app trigger this flow existed for two cases: a workspace moving capacity, and a workspace being deleted.** Under a row trigger it covers **neither**.
>
> | Case | Fires? | Why |
> |---|---|---|
> | `ubsppcoe_oapenabled` cleared, workspace stays put | **Yes** | The flag changed, and the Node still resolves to the capacity that needs rebuilding |
> | Workspace **moves** to another capacity | **No** | The flag did not change, so `ne true` never matches. And the row now points at the *new* Node, so even if it fired it would rebuild the wrong capacity |
> | Workspace row **deleted** | **No** | Deliberately excluded from the trigger — see below |
>
> **So this flow now handles exactly one case: the flag being cleared while the workspace stays where it is.** That is a real case and worth handling promptly — it is how a leaver or an incident response takes access away. But it is not the case the flow was originally written for, and the two it has lost are the common ones.
>
> **Moves and deletions fall to the nightly [RebuildAllCapacityPolicies](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md)**, exactly as they did before anyone called this flow reliably. This is **Q17**, unchanged and now structural rather than procedural: previously the app could forget to make the old-capacity call, and now there is no way to make it at all.

> ### Why `Deleted` is not in the trigger
>
> A deleted row cannot be read. The Dataverse trigger fires, but `_ubsppcoe_nodeid_value` is not reliably available, so there is **no way to work out which capacity to rebuild** — and rebuilding the wrong one, or every one, are both worse than waiting for the nightly run.
>
> Adding `Deleted` would produce a flow that fires, fails to derive a capacity, and exits — noise in the run history with no action taken. **Leave it off.** If same-day removal on deletion is ever a requirement, it needs a different mechanism: the workspace's last-known Node recorded somewhere we control, which nothing currently does.

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

## Step 1 — The trigger

**Solutions** → **New** → **Automation** → **Cloud flow** → **Automated** → name `RemoveWorkspaceFromPolicy` → trigger **Microsoft Dataverse — When a row is added, modified or deleted**.

| Field | Value |
|---|---|
| Change type | **Modified** |
| Table name | `Workspaces` (`ubsppcoe_Workspace`) |
| Scope | **Organization** |
| Select columns | `ubsppcoe_oapenabled,ubsppcoe_nodeid,ubsppcoe_isdeleted` |
| Filter rows | `(ubsppcoe_oapenabled ne true or ubsppcoe_isdeleted eq true) and _ubsppcoe_nodeid_value ne null` |

> ## Soft delete closes the gap this flow had — 2026-09-12
>
> **`ubsppcoe_isdeleted` is a PLACEHOLDER name.** See [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §1 (Q46) for the authoritative list of all six places it appears.
>
> The platform team's tables **soft-delete rather than hard-delete**. A deleted workspace is a `Modified` event on a row that is still fully readable — so `_ubsppcoe_nodeid_value` is still there, the capacity is still derivable, and **this flow can handle deletions after all.**
>
> That reverses what this document said an hour earlier. Deletion is no longer a gap left to the nightly run; it is the same event as any other removal.
>
> **The `or` needs its parentheses.** OData groups `A or B and C` as `A or (B and C)`, so without them a soft-deleted workspace with a blank Node would fire the flow and then fail to derive a capacity.
>
> **`ubsppcoe_isdeleted` must be in `Select columns` here and must *not* be in [AddWorkspaceToPolicy](docs/flows/capacity-policies/AddWorkspaceToPolicy.md)'s.** `Select columns` decides which column changes wake the flow: a deletion has to wake *this* one and must not wake that one. The two lists differ by exactly this column, on purpose.
>
> **The rebuild must exclude deleted rows too**, or this flow reports `Removed` while the workspace stays in the published rules — [RebuildCapacityPolicyRules](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) Steps 5b and 5l. That clause and this trigger are two halves of one change; neither works alone.

**`ne true`, never `eq false`.** `ubsppcoe_oapenabled` is nullable and null is the common state, so `eq false` would silently miss every row whose flag was never explicitly set. This is the one place in the design where the complement of the whitelist is genuinely wanted — [CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) Q38's *never use `ne true`* rule is about the rebuild's membership filter, not about this trigger.

**`Modified` only, not `Added or Modified`.** A newly created workspace row almost always arrives with the flag null, which matches `ne true` — so `Added` would fire this flow for **every new workspace in the tenant**, deriving a capacity and rebuilding it, to remove a workspace that was never in the rules. That is a rebuild storm generated by ordinary provisioning.

**Together with [AddWorkspaceToPolicy](docs/flows/capacity-policies/AddWorkspaceToPolicy.md)'s `eq true`, the two filters partition every modification with no overlap and no gap.** Exactly one of the two flows acts on any given change. Check them as a pair whenever either is edited.

⋯ → **Settings** → **Concurrency Control On, Degree of Parallelism 1**.

---

## Step 2 — Variables

| Rename to | Name | Type | Value |
|---|---|---|---|
| `Initialize_outcome` | `outcome` | String | `Failed` |
| `Initialize_message` | `message` | String | *(empty)* |
| `Initialize_workspaceId` | `workspaceId` | String | `triggerOutputs()?['body/ubsppcoe_workspaceid']` |
| `Initialize_capacityId` | `capacityId` | String | *(empty)* |
| `Initialize_policyRowId` | `policyRowId` | String | *(empty)* |

All five at the **top level and outside `Scope_try`**. `Initialize variable` cannot go inside a Condition, a Scope or an Apply to each.

`workspaceId` reads `ubsppcoe_workspaceid` — the **Fabric** workspace GUID, not the row key `ubsppcoe_workspaceuniqueid` ([CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §1).

---

## Step 2b — Derive the capacity

The trigger gives a Node row GUID; the child flow needs a capacity id.

`Get_policy_row` — Dataverse **List rows**. **This is the action that used to live in Step 3b**, moved earlier and refiltered:

| Field | Value |
|---|---|
| Table name | `Capacity Policies` |
| Filter rows | `_ubsppcoe_node_value eq @{triggerOutputs()?['body/_ubsppcoe_nodeid_value']}` |
| Select columns | `ubsppcoe_capacityid,ubsppcoe_capacitypolicyid,_ubsppcoe_node_value` |
| Row count | `2` |

The GUID is **unquoted**, as always for a lookup filter.

`Set_capacityId` and `Set_policyRowId` — two **Set variable** actions:

| Variable | Value |
|---|---|
| `capacityId` | `coalesce(first(body('Get_policy_row')?['value'])?['ubsppcoe_capacityid'], '00000000-0000-0000-0000-000000000000')` |
| `policyRowId` | `coalesce(first(body('Get_policy_row')?['value'])?['ubsppcoe_capacitypolicyid'], '')` |

> **It was filtered by capacity id before and is filtered by Node now, and that is the whole conversion.** Previously the caller supplied a capacity and this action confirmed it; now the workspace's Node supplies it and this action derives it. `_ubsppcoe_node_value` stays in **Select columns** because Step 3b's `Filter_on_this_node` still compares against it — that comparison is now trivially true for the triggering row, but not for any **duplicate** row carrying the same workspace GUID, which is the case it was written for.
>
> **An ungoverned capacity yields the zero GUID**, Step 5's rebuild then reports the capacity is unregistered, and the run ends green. Same sentinel idiom as [AddWorkspaceToPolicy](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) Step 2b, for the same reason: adding a Condition here would push Steps 3 onward into a branch.

---

> ### The shape of this flow — it is flat, unlike `AddWorkspaceToPolicy`
>
> **There are no guards here.** Nothing refuses, nothing exits early, and every path reaches the rebuild — which is the whole asymmetry in §0: a workspace that does not qualify is exactly what this flow was asked to handle. So every action sits at the top level, and the Conditions only decide *what to report*.
>
> ```
> trigger
> Step 2   Initialize_outcome / Initialize_message
> Step 3   Get_workspace_row / Filter_enabled
> Step 3b  Filter_on_this_node / Get_exception_rows
> Step 4   Condition_still_enabled     ├─ Yes: StillEnabled  │ No: Removed
> Step 4b  Condition_excepted          ├─ Yes: StillExcepted │ No: empty
> Step 5   Run_rebuild
>          Condition_rebuild_ok        ├─ Yes: append counts │ No: Failed
> Step 6   (nothing to build — rationale only)
> Scope_catch   runAfter Scope_try = Failed, Skipped, TimedOut
> Step 7   Compose_result
> ```
>
> **`Condition_excepted` is a sibling of `Condition_still_enabled`, not a child of either branch.** It has to overwrite `outcome` whichever way Step 4 went — `StillEnabled` → `StillExcepted` on one path, `Removed` → `StillExcepted` on the other. Nested inside one branch it would correct only half the cases, and the half it missed would report `Removed` for a workspace that can still create anything.
>
> Every branch in this flow contains **only `Set variable` actions**. If you find yourself putting a `List rows` or a `Run a Child Flow` inside one, the structure has drifted.
>
> **The flatness is what makes this flow easy to wrap.** Everything from 2b to 5 is an immediate child of `Scope_try`, so `result('Scope_try')` names the action that actually failed rather than a container — which [AddWorkspaceToPolicy](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) cannot do ([SCOPE-SANDBOX.md](docs/flows/capacity-policies/SCOPE-SANDBOX.md) E10). **This flow gets a real diagnosis in `ubsppcoe_lasterror` for free, and its sibling does not.** Keep it flat.

---

## Step 3 — Find the workspace row

`Get_workspace_row` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Workspaces` (`ubsppcoe_Workspace`) |
| Filter rows | `ubsppcoe_workspaceid eq '@{variables('workspaceId')}'` |
| Select columns | `ubsppcoe_workspaceid,ubsppcoe_oapenabled,_ubsppcoe_nodeid_value` |
| Row count | `50` |

**Rows, plural, deliberately — and the trigger does not make this redundant.** The trigger body is *one* row. This table is not ours and has no uniqueness key we control, so if the same workspace GUID appears on two rows and either of them is still enabled, the workspace stays in the rules. **Query for all of them rather than trusting the row that fired**, or `StillEnabled` becomes unreachable in exactly the case it was written for.

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

**`Get_policy_row` has moved to Step 2b**, where it now derives the capacity rather than confirming a caller's. It still selects `_ubsppcoe_node_value`, which is what the comparison below reads.

`Filter_on_this_node` — **Filter array**:

| Field | Value |
|---|---|
| From | `coalesce(body('Get_workspace_row')?['value'], createArray())` |
| Condition | `item()?['_ubsppcoe_nodeid_value']` **is equal to** `first(body('Get_policy_row')?['value'])?['_ubsppcoe_node_value']` |

> **Those two names differ by three characters, and that is not a typo.** The left side is **`_ubsppcoe_nodeid_value`** — the `Node` lookup on a `ubsppcoe_Workspace` row. The right side is **`_ubsppcoe_node_value`** — our own lookup on the `ubsppcoe_CapacityPolicy` row. Different tables, different columns, and both hold the same **Node row GUID**, which is what makes the comparison meaningful: it asks *is this workspace on the capacity the caller named*. See [CAPACITY-POLICY-TABLES.md](docs/CAPACITY-POLICY-TABLES.md) §0.
>
> **Neither side is a capacity id**, and comparing either against the trigger input would never match — the Node row key is `ubsppcoe_nodeid`, while the capacity GUID lives on the Node row in `ubsppcoe_nodeuniqueid`. Lookup-against-lookup is the only correct form here. Confirmed 2026-09-09, when the same mistake was found in `AddWorkspaceToPolicy` Step 4a; **this flow was already right.**

`Get_exception_rows` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Policy Exceptions` |
| Filter rows | `ubsppcoe_workspaceid eq '@{variables('workspaceId')}' and ubsppcoe_active eq true` |
| Select columns | `ubsppcoe_workspaceid` |
| Row count | `50` |

**No capacity condition on that filter, because the table has no capacity column** ([CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §3). An exception is a statement about the workspace; `Filter_on_this_node` is what ties it to the capacity the caller named. Checking only the exception table would report `StillExcepted` for a workspace that moved away last week and is no longer in this capacity's rule 3 at all.

> **No `Filter array` is needed after this action, and adding one would do nothing.** Both dimensions the table can express are already in the server-side filter, so every returned row is an active exception for this workspace. The capacity question is answered on the *workspace* rows by `Filter_on_this_node`, and the `And` in Step 4b is the join.
>
> Compare [RebuildCapacityPolicyRules](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) Step 5l, which does need a real join query: there the exception list is tenant-wide and has to be intersected with the capacity's workspaces. Here the workspace is pinned by the trigger input, so the same intersection collapses to two `empty(...)` checks.

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

`outcome` = `Removed`. Under the row trigger there is really only one way to get here, and the others are listed because the query — not the trigger — can still produce them:

| State | Reachable? | Why it counts as removed |
|---|---|---|
| Row exists, `ubsppcoe_oapenabled` `false` or null | **Yes — the normal path** | The flag has just been cleared, which is what fired the trigger |
| Row deleted between the trigger firing and Step 3 running | Rare | `Get_workspace_row` returns nothing, so nothing matches the filter |
| Row exists but `Node` now points elsewhere | Rare | Moved between trigger and run; no longer this capacity's business |

> **The last two used to be the normal case and are now edge cases.** A move or a deletion no longer reaches this flow at all — see §0. What is left is a race: the row changing again in the seconds between the trigger firing and Step 3 querying it. Both still resolve correctly, because republishing current truth can only narrow access.

> **A missing row is a success here and a refusal in `AddWorkspaceToPolicy`.** That is deliberate, and it is the clearest expression of the asymmetry in §0: you cannot whitelist a workspace that does not exist, but a workspace that does not exist is certainly not whitelisted.

### Step 4b — the exception overrides both answers

`Condition_excepted` — a second **Condition**, **at the top level immediately after `Condition_still_enabled`**, not inside either of its branches. Two rows ANDed:

| Left | Operator | Right |
|---|---|---|
| `empty(body('Get_exception_rows')?['value'])` | is equal to | `false` |
| `empty(body('Filter_on_this_node'))` | is equal to | `false` |

**Yes** → overwrite `outcome` with `StillExcepted` and set the message to: `This workspace has an active policy exception, so it can still create any item type on this capacity regardless of whether OAP is enabled. The rules were republished as they stand. Deactivate its Policy Exceptions row and rebuild to stop that.`

**No** → **leave the branch completely empty.** Step 4 has already set `outcome` and `message`; this branch's job is to not touch them. A `Set variable` here would clobber `StillEnabled` on the path where Step 4 correctly set it.

> **Both conditions, not just the first.** An exception row for a workspace that has already left this capacity is not this capacity's problem — the rebuild will not put it in rule 3, and reporting `StillExcepted` would send someone to deactivate a row that is doing no harm here and may be doing something useful elsewhere.

> **This one does overwrite `StillEnabled`.** They are not equally urgent: `StillEnabled` means the workspace kept its whitelisted item types, `StillExcepted` means it kept **everything**. Reporting the narrower of the two would understate what is still live, and the message for the wider one already tells the operator where to go.

---

## Step 5 — Rebuild

`Run_rebuild` — **Run a Child Flow** → `RebuildCapacityPolicyRules`, passing `variables('capacityId')`.

`Condition_rebuild_ok` — **Condition**, run after `Run_rebuild` on **is successful** only:

| Left | Operator | Right |
|---|---|---|
| `body('Run_rebuild')?['outcome']` | is equal to | `Rebuilt` |

### Yes

Leave `outcome` as Step 4 set it — `Removed`, `StillEnabled` or `StillExcepted` — and append the counts to the message.

`Append_rebuild_counts` — **Append to string variable**, *not* Set variable:

| Field | Value |
|---|---|
| Name | `message` |
| Value | `concat(' Policy rules updated: ', body('Run_rebuild')?['workspacecount'], ' workspace(s) allowed on this capacity.')` |

> **`Set variable` cannot reference the variable it assigns.** `message` = `concat(variables('message'), …)` fails at runtime with *"Self reference is not supported when updating the value of the variable"*. **Append to string variable** exists for exactly this, and it takes only the text to add — the existing value is implicit, so there is no `variables('message')` in the expression at all.
>
> Note the leading space inside the `concat`. Step 4's messages end with a full stop and no trailing space, so the join has to supply it.

**Do not overwrite `outcome` here.** The rebuild succeeding says nothing about whether the workspace actually came out; that was decided in Step 4, and flattening the three would turn a warning into a false confirmation.

### No

Two **Set variable** actions — `outcome` = `Failed`, and `message` set outright rather than appended, because the Step 4 text no longer applies:

`concat('The rules could not be republished: ', coalesce(body('Run_rebuild')?['message'], 'the rebuild flow failed.'), ' If the workspace has already been moved or disabled in Dataverse, the nightly rebuild will apply it.')`

---

## Step 6 — Why a failure here is not rolled back

> **Nothing is built in this step.** It explains the failure message Step 5's *No* branch already sets. Skip to Step 7 if you are following along in the designer.

There is nothing to roll back — this flow writes nothing. But the *reporting* still matters, because Dataverse and Fabric now disagree and the operator needs to know which way.

| | `AddWorkspaceToPolicy` fails | This flow fails |
|---|---|---|
| Dataverse says | whitelisted | not whitelisted |
| Fabric still says | not whitelisted | **whitelisted** |
| Consequence | The app promises access that does not exist | **Access that should be gone is still live** |

The second is the one with a security dimension. The change is recorded in Dataverse and the nightly rebuild in [RebuildAllCapacityPolicies.md](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) will converge Fabric to it — but not until tonight.

**Say so in the message.** An operator taking access away for a leaver needs to know whether it took effect now or tonight; that is the difference between finishing the task and escalating it. A bare "failed" tells them neither.

---

## Step 7 — Record the outcome

**Delete the `Respond to a Power App or flow` action** — invalid without a Power Apps or Request trigger, and it blocks the save.

Replace it with `Compose_result` — **Compose**, run after **both** `Scope_try` and `Scope_catch` on **all four** statuses:

```
@{variables('outcome')} — @{variables('message')}
```

| `outcome` | Meaning | Rebuild ran? | Run ends |
|---|---|---|---|
| `Removed` | The workspace no longer qualifies, and the rules now say so | Yes | Succeeded |
| `StillEnabled` | `ubsppcoe_oapenabled` is still `true` on another row, so it **remains whitelisted** | Yes | Succeeded |
| `StillExcepted` | Still on this capacity with an active `PolicyException` row, so it can create **any** item type | Yes | Succeeded |
| `Failed` | The child reported a Fabric error. Access may still be live until the nightly run | Yes, and it failed | Succeeded |
| `Caught` | An action failed outright. Set by `Scope_catch` | Maybe | **Failed** |

There is no `NotFound` — a workspace with no row is not whitelisted, which is `Removed`.

> **`StillEnabled` and `StillExcepted` are the two that used to need careful rendering in the app, and now nothing renders them.** That is a loss, not a simplification.
>
> Under the app trigger an operator taking access away saw the warning immediately and could act on it. Under a row trigger the warning goes into a `Compose` that nobody opens — the workspace stays able to create items, and the only record is a green run in a history that is mostly green runs.
>
> **`StillExcepted` is the one that matters**, because it means our own table is keeping access alive after somebody deliberately removed it. **Consider routing it somewhere a human sees** — the simplest being a `Terminate` with status **Failed** on that branch, which puts it in the failure list at the cost of a red run for a correctly-behaving flow. Not specified here because it is a judgement about who watches what, but it should not be left undecided: the whole point of converting this flow was same-day removal, and this is the case where removal does not happen.

---

## Step 8 — Try and Catch

Build **last**. Identical in shape to [AddWorkspaceToPolicy.md](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) Step 7 — build and convert that one first, then copy it.

### 8a. `Scope_try`

**Control** → **Scope**, renamed `Scope_try`. Drag Steps 2b, 3, 3b, 4, 4b and 5 into it. The five `Initialize variable` actions stay above it.

**Then check every action inside for *has failed*.** There should be none once `Condition_rebuild_ok` is set to *is successful* only. One such tick makes `Scope_try` report Succeeded and skips the Catch entirely ([SCOPE-SANDBOX.md](docs/flows/capacity-policies/SCOPE-SANDBOX.md) E3).

> ### This flow gets a better error message than its sibling, for free
>
> Everything inside `Scope_try` here is an **immediate child** of the scope — the Conditions in Steps 4 and 4b contain only `Set variable` actions, and nothing that can fail lives inside them.
>
> `result('Scope_try')` does not recurse ([SCOPE-SANDBOX.md](docs/flows/capacity-policies/SCOPE-SANDBOX.md) E1), so in [AddWorkspaceToPolicy](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) a failure three Conditions deep is reported as a container with the message *"An action failed. No dependent actions succeeded."* **Here it is reported as the action itself, with its real error** — E10 measured exactly that difference.
>
> **So keep the structure flat.** If a future change puts a `List rows` or a `Run a Child Flow` inside one of the Conditions, this flow silently loses its diagnosis and joins its sibling in writing signposts.

### 8b. `Scope_catch`

**Control** → **Scope**, renamed `Scope_catch`. **Configure run after** `Scope_try`: **has failed**, **is skipped**, **has timed out**.

| # | Action | Detail |
|---|---|---|
| 1 | `Compose_error` — **Compose** | `result('Scope_try')` |
| 2 | `Filter_failed` — **Filter array** | From `result('Scope_try')`, `item()?['status']` **is equal to** `Failed` |
| 3 | `Set variable` | `outcome` = `Caught` |
| 4 | `Set_message` — **Set variable** | `message` = the expression below |
| 5 | `Condition_row_known` — **Condition** | `empty(variables('policyRowId'))` is equal to `false` |
| 6 | └ **Yes** → `Update_policy_error` | `Capacity Policies`, row `variables('policyRowId')`, `ubsppcoe_lasterror` only |
| 7 | `Terminate` | Status **Failed**, message `concat(variables('outcome'), ' — ', variables('message'))` |

```
concat(coalesce(first(body('Filter_failed'))?['name'], 'no failed action in Scope_try'), ': ', coalesce(first(body('Filter_failed'))?['error']?['message'], 'scope was skipped or timed out'), ' | run ', workflow()?['run']?['name'])
```

Copy from the code block, not from a table cell — the `|` would need escaping, and a `\|` pasted into the designer fails at runtime rather than at save.

> **A caught failure here is more serious than in `AddWorkspaceToPolicy`.** That flow fails to *grant* access, which is an inconvenience. This one fails to *remove* it — so a caught error means somebody asked for access to be taken away and it is still live, until the nightly run. The `Terminate` is what makes that visible; without it the run reports success ([SCOPE-SANDBOX.md](docs/flows/capacity-policies/SCOPE-SANDBOX.md) E7).

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | Clear `ubsppcoe_oapenabled` on one of three enabled workspaces | Flow fires; `Removed`; the whitelist rule holds two values |
| 2 | Clear the flag on the **last** enabled workspace of a capacity | `Removed`; **exactly one rule remains** — the deny-all. No empty rule, no `PropertyMinCount` error |
| 3 | **Set** `ubsppcoe_oapenabled` to Yes | This flow does **not** fire; [AddWorkspaceToPolicy](docs/flows/capacity-policies/AddWorkspaceToPolicy.md) does. The two filters must not overlap |
| 4 | **Create** a new workspace row with the flag unset | This flow does **not** fire — the trigger is `Modified` only. If it fires, you have `Added` ticked and every new workspace in the tenant will rebuild a capacity |
| 5 | Clear the flag on a workspace with a **blank** Node | Does not fire — the `ne null` half of `Filter rows` |
| 6 | Crossing back under the chunk boundary, from 50 to 49 | Rules go from 3 to 2; the `(1/2)`/`(2/2)` naming is regenerated, not left stale |
| 7 | Break the child flow | `Failed`, with the message saying access may still be live until the nightly run |
| 8 | Duplicate rows for one workspace GUID, one enabled and one not | `StillEnabled`, not `Removed`. **This is why Step 3 queries instead of trusting the trigger body** |
| 9 | Inspect any run's action list | **No write action against `ubsppcoe_Workspace` or `ubsppcoe_Node`** |
| 10 | Clear the flag on a workspace that has an active exception row, still on this capacity | `StillExcepted`, and the workspace is still in rule 3. **The one that would otherwise report a removal that did not happen** |
| 11 | The same, with the exception row's `active` set to No | `Removed`, and no rule 3 for it |
| 12 | **Move a workspace to another capacity** | This flow does **not** fire at all. The old capacity keeps it until the nightly run — confirm that, rather than assuming it is handled |
| 13 | **Delete a workspace row** | This flow does **not** fire. Same as test 12: verify the gap exists rather than discovering it later |
| 14 | Break `Get_policy_row` with a bad column name | `Caught`, run ends **Failed**, and `ubsppcoe_lasterror` names `Get_policy_row` and its real error — not a container |

**Tests 3, 4, 12 and 13 all verify that the flow does *nothing*.** They are the most valuable tests here, because every one of them is a case where firing would be wrong or where not firing is a gap somebody needs to know about. A trigger filter that is too loose does not fail — it quietly rebuilds capacities all day.

**Test 4 is the expensive mistake.** Ticking `Added` alongside `Modified` makes this flow fire for every new workspace row in the tenant, each one deriving a capacity and rebuilding it, to remove a workspace that was never in the rules.

Test 10 is the one worth building the flow around. Everything else reports on data owned elsewhere; this is the case where our own table quietly keeps access alive.

Test 8 is why Step 3 still runs a query rather than reading the trigger body.

Test 14 is what proves the flat structure is paying for itself — see Step 8a.

Test 2 is the one that would have been hard the other way. It is a single rule with a sentinel value that matches nothing, and it is what keeps the capacity governed after its last whitelist entry is gone.
