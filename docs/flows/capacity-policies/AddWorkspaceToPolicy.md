# Flow — `AddWorkspaceToPolicy`

Whitelists a workspace on a capacity. Writes one Dataverse row, then rebuilds that capacity's rules.

> **Not built yet.** Specification, not a description of something that exists.

Related: [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md), [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md), [RemoveWorkspaceFromPolicy.md](docs/flows/capacity-policies/RemoveWorkspaceFromPolicy.md).

---

## 0. Before you start

- Build [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) first. This flow is mostly a wrapper around it.
- Needs a **Dataverse connection**. It makes **no Fabric calls of its own** — every Fabric interaction happens inside the child flow.
- Put a **uniqueness key on `(crbab_capacityid, crbab_workspaceid)`** in the `Capacity Workspaces` table. Step 3 checks for duplicates, but the key is what makes it true rather than merely likely.

> ### This flow does not touch rules
>
> No `PATCH`, no "find a rule with space", no 49-chunking. The row is the change; the rebuild recomputes the entire rule layout from scratch. If you find yourself reading policy rules in this flow, the design has been misunderstood — see [CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §2.

---

## Step 1 — Create the flow

**Solutions** → **New** → **Automation** → **Cloud flow** → **Instant** → name `AddWorkspaceToPolicy` → trigger **Power Apps (V2)**.

Two **Text** inputs, in this order:

| Order | Title | Key | Reference |
|---|---|---|---|
| 1 | `capacityId` | `text` | `triggerBody()['text']` |
| 2 | `workspaceId` | `text_1` | `triggerBody()['text_1']` |

Both required, and both are GUIDs — so getting them the wrong way round produces a syntactically valid pair that quietly whitelists nothing. Add them in the order above and check the first run in the history.

---

## Step 2 — Variables

| Rename to | Name | Type | Value |
|---|---|---|---|
| `Initialize_outcome` | `outcome` | String | `Failed` |
| `Initialize_message` | `message` | String | *(empty)* |

---

## Step 3 — Is it already there?

`Get_existing_link` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Capacity Workspaces` |
| Filter rows | `crbab_capacityid eq '@{triggerBody()['text']}' and crbab_workspaceid eq '@{triggerBody()['text_1']}'` |
| Row count | `1` |

`Condition_already_linked` — **Condition**:

| Left | Operator | Right |
|---|---|---|
| `empty(body('Get_existing_link')?['value'])` | is equal to | `false` |

**Yes** → `outcome` = `AlreadyPresent`, `message` = `This workspace is already whitelisted on this capacity.` **Do not rebuild** — nothing changed, and a rebuild would spend a Fabric write to produce an identical rule set.

Everything below goes in the **No** branch.

---

## Step 4 — The ceiling check

`Count_existing` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Capacity Workspaces` |
| Filter rows | `crbab_capacityid eq '@{triggerBody()['text']}'` |
| Select columns | `crbab_workspaceid` |
| Row count | `5000` |

Pagination **On** in Settings, threshold `5000`.

`Condition_at_ceiling` — **Condition**, advanced:

```
@greaterOrEquals(
  length(body('Count_existing')?['value']),
  mul(int(parameters('PolicyMaxWorkspacesPerRule (ab_PolicyMaxWorkspacesPerRule)')), sub(int(parameters('PolicyMaxRulesPerPolicy (ab_PolicyMaxRulesPerPolicy)')), 1))
)
```

**Yes** → `outcome` = `Failed`, message naming the limit. Stop.

The ceiling is **49 workspaces × 49 whitelist rules = 2401 per capacity** — one of the 50 rules is always rule 1. Catch it here rather than letting the child flow discover it, so the row is never written for a change that cannot be applied.

---

## Step 5 — Write the row

`Add_link_row` — Dataverse **Add a new row**:

| Column | Value |
|---|---|
| Table name | `Capacity Workspaces` |
| `crbab_capacityid` | `triggerBody()['text']` |
| `crbab_workspaceid` | `triggerBody()['text_1']` |

---

## Step 6 — Rebuild

`Run_rebuild` — **Run a Child Flow** → `RebuildCapacityPolicyRules`, passing `triggerBody()['text']`.

`Condition_rebuild_ok` — **Condition**:

| Left | Operator | Right |
|---|---|---|
| `body('Run_rebuild')?['outcome']` | is equal to | `Rebuilt` |

Configure this Condition to run after `Run_rebuild` on **is successful** and **has failed**, so a hard failure of the child flow lands here rather than ending the run with no response.

### Yes

`outcome` = `Added`, `message` = `Workspace whitelisted.`

### No — undo the row

1. `Delete_link_row` — Dataverse **Delete a row**, Row ID `body('Add_link_row')?['crbab_capacityworkspaceid']`.
2. `outcome` = `Failed`, `message` = `concat('Rules could not be rebuilt, so the whitelist was not changed: ', coalesce(body('Run_rebuild')?['message'], 'the rebuild flow failed.'))`

> **The compensating delete is not optional.** Dataverse is the source of truth, so a row that never reached Fabric is a lie: the app would show the workspace as whitelisted while item creation there still fails. Rolling back keeps the two consistent and gives the user an honest failure.
>
> It is not a transaction — the delete can itself fail. If it does, the nightly rebuild in [RebuildAllCapacityPolicies.md](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) reconciles it by making Fabric match the row, which is the safe direction to converge.

---

## Step 7 — Respond

**Respond to a Power App or flow**, run after the Condition on **is successful** and **has failed**. Two **Text** outputs:

| Output | Value |
|---|---|
| `Outcome` | `variables('outcome')` |
| `Message` | `variables('message')` |

| `outcome` | Meaning |
|---|---|
| `Added` | Row written and rules rebuilt |
| `AlreadyPresent` | Nothing done, nothing needed |
| `Failed` | Nothing changed — the row was rolled back if it had been written |

Both outputs **Text**. A non-Text field fails schema validation at runtime and makes *every* output of the flow unreadable to the app.

---

## What the app must do before calling this

**Validate the workspace.** Fabric accepts any well-formed GUID in a `workspace.id` condition — a typo, a deleted workspace, or one from another tenant is stored happily and simply never matches. Nothing fails, and the owner is left with a policy that looks correct and denies them.

Before calling, confirm the workspace exists and is **assigned to that capacity**. `GET /v1/workspaces/{id}` returns `capacityId`; a workspace on a different capacity should not be whitelisted here, because the policy governing it is the other capacity's.

This is the app's job, not the flow's — the flow has no way to distinguish a typo from a deliberate entry, and neither does the API.

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | Add a workspace to a capacity with none | `Added`; rules go from 1 to 2 |
| 2 | Add the same workspace again | `AlreadyPresent`; **no Fabric call** in the child flow's history |
| 3 | Add a 50th workspace | `Added`; rules go from 2 to 3, split 49 + 1 |
| 4 | Break the child flow deliberately, then add | `Failed`, and the row is **gone** from `Capacity Workspaces` |
| 5 | Add to a capacity with no `Capacity Policies` row | `Failed` with the child flow's "run InitializeCapacityPolicySet first" message |
| 6 | Two adds for the same capacity at once | Both succeed and both appear. The child flow's concurrency limit of 1 serialises the rebuilds |

Test 4 is the one people skip. It is the only test that proves Dataverse and Fabric cannot silently disagree.

> Testing from the designer reports **`ActionResponseSkipped`** on the Respond action — expected, since nothing is waiting for the response. The row and the rebuild still happen.
