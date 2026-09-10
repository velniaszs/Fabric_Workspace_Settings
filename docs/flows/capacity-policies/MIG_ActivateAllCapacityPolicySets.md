# Flow — `MIG_ActivateAllCapacityPolicySets`

**Migration only.** Activates every registered-but-inactive policy set. **This is the step that puts deny-all into force across the estate**, and it is the only migration flow that changes anyone's access.

> **Not built yet.** Specification, not a description of something that exists.

Related: [MIG_RegisterAllCapacityPolicySets.md](docs/flows/capacity-policies/MIG_RegisterAllCapacityPolicySets.md), [RebuildAllCapacityPolicies.md](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) (must have run first), [InitializeCapacityPolicySet.md](docs/flows/capacity-policies/InitializeCapacityPolicySet.md) 8c (the same call, for one capacity), [../../CAPACITY-POLICY-FLOWS.md](docs/CAPACITY-POLICY-FLOWS.md) §8.

---

## 0. Read this before building it

Everything before this flow is reversible. Policy sets with no rules, deactivated, are inert — a wrong registration run is undone by deleting rows and items, and nobody notices. **This flow ends that.**

An activated policy set whose rule 1 is a deny-all baseline genuinely stops item creation on its capacity. Get it wrong across 200 capacities and the estate stops working, all at once, during whatever people were doing.

Three consequences, all of which shape the design below:

**It runs last.** Rules must already be published. Activating a policy set that holds *only* rule 1 denies every governed item type on that capacity — that is the correct default for a brand-new capacity and catastrophic for a live one.

**It has a dry-run mode.** The PowerShell path had `-WhatIf` via `SupportsShouldProcess`. A flow has nothing equivalent unless you build it, so Step 1 takes a `mode` input and `Report` is the default posture.

**It is rate-limited in a way the other flows are not.** See §3.

> ### The precondition, stated plainly
>
> **Do not run this until [RebuildAllCapacityPolicies](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) has completed successfully across the estate, and `Policy Exceptions` was seeded before it ran.**
>
> The check is in Step 3's filter — `ubsppcoe_rulecount` must be greater than 1 — but a filter is not a substitute for knowing. A capacity that reached this flow with `rulecount` = 1 either has no whitelisted workspaces at all, which is legitimate for a genuinely new capacity, or its rebuild never ran, which is not.

---

## 1. Before you start

- [MIG_RegisterAllCapacityPolicySets](docs/flows/capacity-policies/MIG_RegisterAllCapacityPolicySets.md) and [RebuildAllCapacityPolicies](docs/flows/capacity-policies/RebuildAllCapacityPolicies.md) must both have run.
- Needs a **Dataverse connection** and the *HTTP with Microsoft Entra ID (preauthorized)* connector.
- The connection's identity needs **Capacity Admin on every capacity being activated**. Registration only needed Contributor on the holder workspace, so **this is the first time that permission is exercised at scale** — and a gap in it shows up as a per-capacity failure, not a run failure.
- No child flow. The activate call is three lines; wrapping it would add a 120-second budget for nothing.

---

## Step 1 — Create the flow

**Solutions** → **New** → **Automation** → **Cloud flow** → **Instant** → name `MIG_ActivateAllCapacityPolicySets` → trigger **Manually trigger a flow**.

One **Text** input:

| Order | Title | Key | Values |
|---|---|---|---|
| 1 | `mode` | `text` | `Report` or `Activate` |

**Required, and there is no default.** Power Apps V2 optional inputs vanish when blank, and a blank that falls through to "activate" is exactly the accident this input exists to prevent. Making it required means the person running it has to type `Activate`.

⋯ → **Settings** → **Concurrency Control On, Degree of Parallelism 1** on the trigger.

> ### `Report` is the whole safety mechanism
>
> In `Report` mode the flow reads everything, builds the same list, and **makes no Fabric call and no Dataverse write**. The output is exactly what `Activate` would do.
>
> **Run `Report` first, every time, including on re-runs.** The list it produces is the thing to check before anyone types `Activate` — and on a re-run it is how you confirm the remaining set is the remaining set, rather than something that grew because a rebuild failed overnight.

---

## Step 2 — Variables

Four `Initialize variable` actions, **at the top level**.

| Rename to | Name | Type | Value |
|---|---|---|---|
| `Initialize_mode` | `mode` | **String** | `toLower(trim(coalesce(triggerBody()['text'], '')))` |
| `Initialize_activated` | `activated` | Integer | `0` |
| `Initialize_failures` | `failures` | **Array** | *(leave empty)* |
| `Initialize_wouldActivate` | `wouldActivate` | **Array** | *(leave empty)* |

> **`mode` is a String, not a Boolean, and that is deliberate.** The obvious version is a Boolean `isReport` holding `equals(toLower(triggerBody()['text']), 'report')`, then a Condition comparing it to `true`. **Do not do that.** Comparing a real boolean against a right-hand box containing the text `true` is the classic silent mismatch in this editor — the same trap documented at [RebuildCapacityPolicyRules.md](docs/flows/capacity-policies/RebuildCapacityPolicyRules.md) Step 4. Two strings compared as strings cannot misfire.
>
> `toLower` and `trim` mean `Activate`, `activate` and ` ACTIVATE ` all work. `coalesce(…, '')` keeps the expression from throwing if the input somehow arrives null.

### 2b. `Condition_valid_mode` — **Condition**

| Left | Operator | Right |
|---|---|---|
| `variables('mode')` | is equal to | `report` |

Set the group's join to **Or** and add a second row:

| Left | Operator | Right |
|---|---|---|
| `variables('mode')` | is equal to | `activate` |

**No branch** — **Control** → **Terminate**, Status **`Failed`**, with the message `mode must be exactly 'Report' or 'Activate'.`

**Yes branch** — leave empty; Steps 3 onward are siblings at the top level.

> ### This guard exists because the flow otherwise fails open
>
> Without it the logic is *"report if the mode says report, activate otherwise"* — so `Reprot`, `REPOR`, an empty string or a stray space **activates the entire estate**. That is the wrong direction to fail for the only flow here that takes access away from people.
>
> With the guard, anything that is not one of the two exact words stops the run before Step 3 reads a single row. **Terminate is safe in this flow** because there is no `Respond` — nothing is waiting on it, unlike the child flows where a Terminate would leave the caller with a bare fault.

---

## Step 3 — What needs activating

`List_inactive_rows` — Dataverse **List rows**:

| Field | Value |
|---|---|
| Table name | `Capacity Policies` |
| Filter rows | `ubsppcoe_status eq 'Inactive' and ubsppcoe_policysetid ne null and ubsppcoe_rulecount gt 1` |
| Select columns | `ubsppcoe_capacitypolicyid,ubsppcoe_capacityid,ubsppcoe_capacityname,ubsppcoe_policysetid,ubsppcoe_rulecount,ubsppcoe_workspacecount,ubsppcoe_exceptioncount` |
| Sort by | `ubsppcoe_capacityname asc` |
| Row count | `5000` |

Pagination **On**, threshold `5000`.

Each clause earns its place:

| Clause | Excludes |
|---|---|
| `ubsppcoe_status eq 'Inactive'` | Anything already activated. **This is what makes re-runs safe** |
| `ubsppcoe_policysetid ne null` | Rows registered by hand or half-written. Nothing to activate |
| `ubsppcoe_rulecount gt 1` | **Capacities whose rebuild never ran.** Activating rule 1 alone is a deny-all with no whitelist |

> **`rulecount gt 1` is the guard, and it is not paranoia.** `RebuildAllCapacityPolicies` stamps that column on every attempt, success or failure, so a capacity whose rebuild failed carries the count it *tried* to publish rather than a stale one. An unrebuilt capacity has the column **empty**, and `gt 1` excludes empty — so a capacity that never made it through the rebuild phase cannot be activated by accident.
>
> **It will also exclude a legitimately empty capacity** — one with no OAP-enabled workspaces and no exceptions, whose rebuild correctly published rule 1 alone. That is the right trade during migration: such a capacity is locked completely once activated, so it should be a deliberate decision rather than a row in a batch. Activate those individually afterwards, or leave them for the provisioning app.

`Compose_candidate_count` — **Compose**, `@{length(body('List_inactive_rows')?['value'])}`. So the run history answers "how many?" without expanding the array.

---

## Step 4 — The loop

**Apply to each** over `@body('List_inactive_rows')?['value']`, renamed `For_each_policy`.

⋯ → **Settings** → **Concurrency Control On, Degree of Parallelism 1**.

### 4a. `Condition_report_mode` — **Condition**

| Left | Operator | Right |
|---|---|---|
| `variables('mode')` | is equal to | `report` |

**Yes** — `Append_would_activate`, **Append to array variable** `wouldActivate`:

```
@{concat(items('For_each_policy')?['ubsppcoe_capacityname'], ' (', items('For_each_policy')?['ubsppcoe_capacityid'], ') — ', string(items('For_each_policy')?['ubsppcoe_rulecount']), ' rules, ', string(items('For_each_policy')?['ubsppcoe_workspacecount']), ' whitelisted workspace(s), ', string(items('For_each_policy')?['ubsppcoe_exceptioncount']), ' exception(s)')}
```

And nothing else. **No Fabric call, no Dataverse write.**

> **The workspace and exception counts are in that line for the coverage read.** They cost nothing — the rebuild already stamped them and the query already selects them — and they turn the dry run into a first look at who is about to be denied.
>
> A capacity showing **many rules and few whitelisted workspaces** is the shape to look for. It passes the `rulecount gt 1` filter and will activate cleanly, and it may still deny item creation to most of the teams working on it, because `workspacecount` counts only workspaces with `ubsppcoe_oapenabled = true`.
>
> What this still cannot tell you is the **total** number of workspaces under each capacity's Node, which is what turns these counts into a denial count. That needs a query against `ubsppcoe_Workspace` per capacity and is not built yet — so read this list as a smell test, not as sign-off.

**No** — 4b, 4c and 4d go here.

### 4b. `Activate` — **Invoke an HTTP request**

| Field | Value |
|---|---|
| Method | `POST` |
| URL of the request | `https://api.fabric.microsoft.com/v1/workspaces/@{parameters('PolicyHolderWorkspaceId (ubsppcoe_PolicyHolderWorkspaceId)')}/policySets/@{items('For_each_policy')?['ubsppcoe_policysetid']}/activate` |
| Header `Content-Type` | `application/json` |

Body:

```json
{
  "scopeType": "Capacity",
  "scopeId": "@{items('For_each_policy')?['ubsppcoe_capacityid']}",
  "capacityId": "@{items('For_each_policy')?['ubsppcoe_capacityid']}"
}
```

> **`capacityId` is required and is not in the published API reference.** The reference documents `scopeType` and `scopeId`; the preview service additionally validates `capacityId` and rejects the call with `PropertyCannotBeDefault — property capacityId is not expected to have its default value`. All three carry the same capacity GUID: `scopeId` names the target in the generic form the endpoint shares with tenant-scoped activation, `capacityId` names it again in a capacity-specific form left over from before the API was generalised.
>
> Confirmed against the live service 2026-09-09, and documented in `activate_policy_set.ps1` in `C:\GIT\ubs-policies`.

> **Do not pass `allowReplace`.** It is a **query parameter**, `?allowReplace=True`, not a body property. `PolicySetActivationConflict` means another policy set already governs that capacity — during migration that is a genuine surprise and wants a human, not a silent takeover.

**Retry Policy: Default.** It covers `429`, which matters here more than anywhere else — see 4e.

### 4c. `Update_status` — Dataverse **Update a row**

⋯ → **Configure run after** `Activate` on **is successful** and **has failed**.

| Field | Value |
|---|---|
| Table name | `Capacity Policies` |
| Row ID | `items('For_each_policy')?['ubsppcoe_capacitypolicyid']` |
| `ubsppcoe_status` | `if(less(coalesce(outputs('Activate')?['statusCode'], 0), 300), 'Active', 'Inactive')` |
| `ubsppcoe_lasterror` | `if(less(coalesce(outputs('Activate')?['statusCode'], 0), 300), '', coalesce(body('Activate')?['message'], body('Activate')?['errorCode'], string(body('Activate'))))` |

**Writing on both paths is what makes the run restartable.** A row left `Inactive` with a populated `lasterror` is picked up by the next run and carries the reason it failed last time.

Tolerate `PolicySetIsAlreadyActive` — the end state is what was wanted. If it appears often, something outside this flow is activating too.

### 4d. `Condition_activated_ok` — **Condition**

⋯ → **Configure run after** `Update_status` on **is successful** and **has failed**.

| Left | Operator | Right |
|---|---|---|
| `less(coalesce(outputs('Activate')?['statusCode'], 0), 300)` | is equal to | `true` |

**Yes** → `Increment_activated` — **Increment variable** `activated` by `1`.

**No** → `Append_failure` — **Append to array variable** `failures`:

```
@{concat(items('For_each_policy')?['ubsppcoe_capacityname'], ' (', items('For_each_policy')?['ubsppcoe_capacityid'], '): ', coalesce(body('Activate')?['message'], body('Activate')?['errorCode'], 'activation failed'))}
```

### 4e. `Delay_rate_limit` — **Delay**, 6 seconds

**Inside the loop, inside the `No` branch of 4a**, after 4d.

> ### This is the one place the 10-per-minute limit actually bites
>
> The Admin activation endpoints are documented at **10 requests per minute** — one every 6 seconds.
>
> It does not constrain [MIG_RegisterAllCapacityPolicySets](docs/flows/capacity-policies/MIG_RegisterAllCapacityPolicySets.md), because each of its iterations is a long-running create plus two Dataverse round trips, roughly 10 seconds — already under the limit without trying.
>
> **Here the work is a single fast POST.** Left alone, the loop would issue 200 activations in about four minutes, roughly 50 per minute, and spend the rest of the run in retry backoff. Retries do not show as failures, so it would present as a mysteriously slow flow rather than as throttling.
>
> Six seconds makes 200 capacities take **about 20 minutes**, which is the floor the service imposes. Accept it. Raising the parallelism cannot help — the limit is per tenant, not per connection.

---

## Step 5 — Report

After the loop, **at the top level**.

`Condition_report_summary` — **Condition**:

| Left | Operator | Right |
|---|---|---|
| `variables('mode')` | is equal to | `report` |

Both branches send **Office 365 Outlook** → *Send an email (V2)*. Two separate actions, because a dry run and a live run should not look alike in an inbox.

### Yes — the dry run

**Subject:**

```
@{concat('DRY RUN — ', string(length(variables('wouldActivate'))), ' capacity policy set(s) would be activated')}
```

**Body** — switch the box to **</>** and paste:

```html
<p><b>Nothing was activated.</b> This was a dry run of <code>MIG_ActivateAllCapacityPolicySets</code>, @{utcNow()}.</p>
<p><b>@{length(variables('wouldActivate'))}</b> policy set(s) would be activated by running it again with mode <code>Activate</code>.</p>
<p>Each has a rule count greater than 1, meaning its rules have been rebuilt. Activating puts the deny-all baseline into force on that capacity.</p>
@{if(empty(variables('wouldActivate')), '<p>Nothing is pending. Either the estate is already activated, or RebuildAllCapacityPolicies has not run.</p>', concat('<p>', join(variables('wouldActivate'), '<br>'), '</p>'))}
```

### No — the live run

**Subject:**

```
@{concat('Capacity policy ACTIVATION — ', string(variables('activated')), ' activated, ', string(length(variables('failures'))), ' failed')}
```

**Body:**

```html
<p><b>@{variables('activated')}</b> of <b>@{length(body('List_inactive_rows')?['value'])}</b> candidate policy set(s) were activated, @{utcNow()}.</p>
<p><b>Item creation is now restricted on those capacities.</b> Only whitelisted workspaces may create governed item types; Power BI items are unaffected.</p>
@{if(empty(variables('failures')), '<p>No failures.</p>', concat('<h3>Failed &mdash; still inactive, not enforced</h3><p>These capacities were left unchanged and are not governed. Their <code>last_error</code> column carries the reason.</p><p>', join(variables('failures'), '<br>'), '</p>'))}
<p>Re-running is safe: only rows still marked <code>Inactive</code> are picked up.</p>
<p>To reverse one capacity: <code>deactivate_policy_set.ps1</code>, then set its <code>Status</code> back to <code>Inactive</code>.</p>
```

**Send the live one on a clean run too.** Unlike the nightly job, this runs once and somebody needs the record of when the estate went under enforcement.

> **Do not use `'\n'` for line breaks in these expressions.** This expression language does not interpret `\n` as a newline — it emits a literal backslash-n. In HTML use `<br>`, as above; in a plain-text Compose use `decodeUriComponent('%0A')`.

---

## Running it

```
1  Run with mode = Report          → read the list. Is the count what you expect?
2  Run with mode = Activate, cancel after ~5
3  Verify those 5 in the portal, and verify creation still works on one of them
4  Run with mode = Activate to completion
```

**Step 3 is the one that cannot be skipped.** Activation is the first moment anything is enforced, so it is the first moment a mistake anywhere in the chain — a wrong item-type seed, an unseeded exception, a capacity whose rebuild silently produced rule 1 alone — becomes visible as someone unable to create a lakehouse. Five capacities is a recoverable blast radius; 200 is an incident.

**To undo one:** `deactivate_policy_set.ps1` in `C:\GIT\ubs-policies`, then set the row's `ubsppcoe_status` back to `Inactive`. Know this before you start rather than while people are complaining.

**Announce it.** Rule 1 denies creation of every governed item type on every capacity, and Power BI items are the only thing unaffected. Someone will hit it within the hour.

---

## To verify after building

| # | Test | Expect |
|---|---|---|
| 1 | `Report` against a populated table | The list, a count, and **zero** Fabric calls in the run history. Check the action list, not just the output |
| 2 | `Report` twice | Identical output. It writes nothing, so it cannot converge on anything |
| 2b | **Mode `Reprot`, and mode left blank** | Terminates at 2b. **Nothing activated.** The fail-closed guard |
| 3 | `Activate` on one throwaway capacity | Policy set active in the portal, row flips to `Active`, `lasterror` empty |
| 4 | Run again immediately | **Zero candidates.** The `status eq 'Inactive'` filter is what makes this safe |
| 5 | A row whose `ubsppcoe_rulecount` is empty | Absent from the candidate list. **The unrebuilt-capacity guard** |
| 6 | Revoke Capacity Admin on one capacity, run `Activate` | That capacity in `failures` with a permission message, row still `Inactive` with `lasterror` set, **and the others still activated** |
| 7 | Time a run of 20 | Roughly two minutes. Materially faster means the Delay is missing or outside the loop |
| 8 | After activating one capacity, try creating a governed item in a **non-whitelisted** workspace on it | **Refused.** This is the only test that proves the whole chain works |
| 9 | The same in a **whitelisted** workspace | **Allowed** |

Tests 8 and 9 are the acceptance criteria for the entire project. Everything else verifies that the machinery ran; only these two verify that it did the right thing.

Test 6 matters because Capacity Admin is exercised here for the first time at scale. One capacity missing it must not stop the other 199.

---

## After cutover

**Turn this flow off and delete it**, with the other two `MIG_` flows. New capacities are activated by `InitializeCapacityPolicySet` 8c as part of provisioning, one at a time, where the blast radius is one capacity that nobody is using yet.
