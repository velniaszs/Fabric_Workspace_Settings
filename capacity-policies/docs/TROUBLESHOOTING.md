# Capacity policies — troubleshooting

Symptom → cause → fix. Grouped by what you actually observed.

> **Two failures in this system look like success.** A rebuild against a deactivated policy set returns `200`, and a wrong workspace GUID is accepted and silently never matches. If someone reports being denied while every signal reads healthy, start at §6.

---

## 1. Triage

| First question | Where to look |
|---|---|
| Did the flow run at all? | Flow run history. **Empty** means it never triggered — §5 |
| Did it fail? | `ubsppcoe_lasterror` on the `Capacity Policies` row, then the run history |
| Is it one capacity or all of them? | **All at once = the connection.** One = data or permissions on that capacity |
| Was the change ever published? | `ubsppcoe_lastrebuild` on the row. Stale means nothing rebuilt it |

---

## 2. Authentication and permissions

| Symptom | Cause | Fix |
|---|---|---|
| **`401` on every capacity at once** | The `workspace provisioning` account: password rotated, MFA prompt, Conditional Access, licence removed, or disabled | Re-authenticate the connection. See [SECURITY-AND-IDENTITY.md](SECURITY-AND-IDENTITY.md) §2.5 |
| `GET /v1/capacities` returns far fewer capacities than exist | The account is not **Capacity Admin** on the missing ones | Grant Capacity Admin. They report `Skipped` until then |
| Creating a policy set fails | **Contributor** missing on the holder workspace | Grant it on that one workspace |
| Activation fails, policy set created | Capacity Admin missing on **that** capacity | Grant, then re-run. **Check the row first** — the set is already registered |
| Connection cannot be created at all | Tenant blocks user consent to apps | A tenant admin must grant consent |
| Flows will not save or run | DLP policy separates the Fabric connector from Dataverse | Put both connectors in the same data group |

---

## 3. Fabric API errors

| Error | Meaning | Fix |
|---|---|---|
| `404 Capacity not found` on **deactivate** | The capacity is already deprovisioned. The 404 is on the *capacity*, not the set | **Expected.** Skip deactivate; `DELETE` on the policy set still works |
| `404` on a capacity during an estate-wide rebuild | Orphaned policy set — the capacity is gone but the row still says `Active` | Delete the policy set item, set the row to `Deleted` |
| `PropertyMinCount` | A rule was emitted with an empty `values` list | Do not emit the rule at all |
| Rule 2 rejected | `Policy Item Types` is empty or has no active rows | Seed it — [input/PolicyItemTypes.csv](../input/PolicyItemTypes.csv) |
| `400 Failed to convert value '<x>' to the requested type at line 1 position N` | An enum value Fabric does not accept | Check spelling and casing against the API |
| Rule names truncated | The service caps rule display names at **60 characters** | Expected |

---

## 4. Rules are wrong, or a user is denied

| Symptom | Cause | Fix |
|---|---|---|
| **A whitelisted workspace still cannot create anything** | `ubsppcoe_oapenabled` is not `true`, or `ubsppcoe_statecode` is not `1`, or the `Node` lookup points elsewhere | Check the row. Membership is **derived**, never stored |
| Same, and the row looks correct | **The published GUID is wrong.** `ubsppcoe_workspaceid` is the Fabric GUID; `ubsppcoe_workspaceuniqueid` is the Dataverse row key. A row key published as a workspace id is well-formed and never matches | Correct the source row. Nothing detects this |
| A workspace can create **anything**, unexpectedly | An active `Policy Exceptions` row puts it in rule 3, which ignores `ubsppcoe_oapenabled` entirely | Set `ubsppcoe_active` to No, then rebuild |
| Revoking an exception changed nothing | The row was **deleted** instead of deactivated. A deleted row cannot be read, so no capacity can be derived and nothing fires | Run `MIG_RebuildAllCapacityPolicies`. **Deactivate, never delete** |
| An item type was added but nobody can create it | `Policy Item Types` has no trigger | Run `MIG_RebuildAllCapacityPolicies` |
| **A whole capacity is unexpectedly locked** | A filter returned nothing — usually a renamed column on `ubsppcoe_Workspace` or `ubsppcoe_Node` | Check with the platform team. The rebuild emits rule 1 alone and reports success |
| Rule count higher than the workspace count justifies | Deleted workspaces still hold 49-per-rule chunk slots | Cosmetic. Pruning the inventory is the platform team's |
| The 50-rule ceiling is hit | More than ~2,400 whitelisted workspaces on one capacity | Guarded in the rebuild so it fails readably. Needs a design decision |

---

## 5. A flow did not run

| Symptom | Cause | Fix |
|---|---|---|
| **No run at all, history empty** | Trigger `Scope` is `User`, not `Organization` | Set Organization. Nothing triggered, so there is nothing to find in history |
| Fires on inserts it should ignore | `Select columns` is **update-only** and ignored on the `Added` half | Constrain inserts with `Filter rows` |
| *"To use filtering attributes your trigger must include an update event"* | `Change type` has no *Modified* in it | Add Modified. The error points at the filters; the fault is the dropdown |
| A workspace became OAP-enabled and nothing fired | Change type is `Added` only | Must be **Added or Modified** |
| A capacity was never initialised | The trigger fired once, returned `Skipped`, and nothing retries | Re-run by touching the `ubsppcoe_Node` row |
| A workspace moved capacity and nothing fired | The flag did not change, so neither Add nor Remove fires | Run `MIG_RebuildAllCapacityPolicies` |

---

## 6. Everything reports healthy and it is still wrong

**These are the two cases where no signal in the system will help you.**

| Symptom | Cause |
|---|---|
| Rules look right, `lastrebuild` is fresh, `lasterror` empty — and users are denied | **Our policy set is not in force.** Someone deactivated it or activated a replacement. The rebuild writes to the dead set and returns `200` |
| A workspace is in the published rules and still denied | **The GUID never matched.** Fabric accepts any well-formed GUID; a typo or a deleted workspace is stored and simply ignored |

**How to confirm the first:** open the holder workspace and check that exactly one policy set is active for that capacity, and that it is ours. There is no automated detection — see Q11.

---

## 7. Run history reads oddly

| Symptom | Cause |
|---|---|
| Run is **green** but nothing happened | A failure was handled inside a Scope. Handled failures report Succeeded at every level |
| `Scope_catch` never fired | An action inside `Scope_try` uses *configure run after → has failed*. That silently disables the Catch |
| A scope shows **Aborted**, not Failed | A `Terminate` ran inside it. Aborted is not a `runAfter` status, so nothing can catch it |
| Error reads *"An action failed. No dependent actions succeeded."* | Boilerplate from a container whose child failed | Drill in with `result('<container name>')`, one level at a time |
| The Catch named the wrong action | `result()` returns **immediate children only** and its order is not execution order | Flatten the scope, or read the run history |
| A child flow cannot be called | Its trigger is Power Apps (V2). Child flows need the **manual** trigger |

---

## 8. Emergency — unlock a capacity

Deactivating the policy set removes all enforcement from that capacity immediately.

1. Deactivate the policy set for that capacity
2. Record why, and on which capacity
3. Set the `Capacity Policies` row so the next rebuild does not silently re-enforce

> ⚠ **The documented procedure uses PowerShell from `C:\GIT\ubs-policies`, which is not part of this handover** — register item D4. Confirm an accessible method exists *before* it is needed at short notice.
