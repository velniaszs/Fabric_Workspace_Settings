# Outbound tab — hide everything when OAP is off

Defect and fix for the Outbound tab of `crbab_app5`. Raised 2026-08-12.

> The `.msapp` export is stale — it predates the whole Git tab. The Outbound tab has not been touched since the export, so the evidence below is current, but **re-export before trusting any other part of that file**.

---

## Symptom

With Outbound Access Protection disabled on the selected workspace, the tab still shows:

- the **Allow Git Integration** toggle
- the **Allowed gateways** block — title, gateway picker, Add, the selected-gateways gallery, and **Save gateways**

Expected: nothing but the read-only `OAP Enabled` toggle and the `LblOapOff` explanation.

---

## Root cause

Two controls have no `Visible` property at all, so they default to `true`.

| Control | `Visible` as built | Effect |
|---|---|---|
| `TglGitAllowed` | *(absent)* | always shown, merely `DisplayMode.Disabled` |
| `GatewaysContainer` | *(absent)* | always shown, along with all five children |

Everything else on the tab is already correct:

| Control | `Visible` as built |
|---|---|
| `RulesContainer` | `gblFlowResult.oapenabled` |
| `LblOapOff` | `!gblFlowResult.oapenabled` |
| `OAPEnabled` | *(absent — correct, it is the state readout)* |

`Form Screen.OnVisible` is correct too. Its OAP-off branch clears `colManaged`, `colElements`, `colGateways`, `colGwSelected` and `colGwOther`, and sets `gblGitAllowed` to false. **The panels are empty, not stale — they simply have no instruction to hide.**

`BtnSave` and `BtnSaveGateways` need no change of their own: the first is inside `RulesContainer`, the second inside `GatewaysContainer`, and a hidden container hides its children.

---

## Why hide rather than disable

A greyed toggle is not a neutral choice here. The OAP-off branch forces `gblGitAllowed` to false, so the disabled toggle renders **off** — which reads as *Git integration is blocked*. The opposite is true: with OAP disabled there is no outbound restriction at all, so Git is permitted. The control as built misinforms the owner about the workspace's actual security posture.

The same argument covers the gateway list. Every endpoint behind this tab lives under `networking/communicationPolicy/outbound/*` — these are OAP's own settings. With OAP off they are inert configuration, and an empty *Allowed gateways* list invites the reading "no gateways are permitted" when in fact all are.

---

## Fix

Two property changes. Both in `OutboundContent`.

### 1. `TglGitAllowed`

| Property | Value |
|---|---|
| `Visible` | `gblFlowResult.oapenabled` |

Leave `DisplayMode` as it is. It is now redundant, but harmless, and it keeps the control safe if the `Visible` formula is ever loosened.

### 2. `GatewaysContainer`

| Property | Value |
|---|---|
| `Visible` | `gblFlowResult.oapenabled` |

Select the container itself in the tree view, not `LblGatewaysTitle` or `AddGwRow`. Its five children inherit the change.

No comparison operator is needed on either. `oapenabled` is a **genuine boolean** — `GetOAPSetting` emits it as the bare expression `@equals(...)` against a `boolean` schema, not the `@{...}` string interpolation that broke `GetWorkspaceGitState.isConnected`. Verified in the exported flow JSON, 2026-08-12. Writing `= true` would work but is noise.

---

## Optional — the load flash

`LblOapOff.Visible` is `!gblFlowResult.oapenabled`, and `gblFlowResult` is blank until `GetOAPSetting` returns. Blank is falsy, so **"Outbound Access Protection is disabled" appears for the duration of the call on every workspace**, including protected ones, before being replaced.

If that proves annoying, gate on a load flag rather than lengthening the formula:

1. In `Form Screen.OnVisible`, immediately before `Set(gblFlowResult, GetOAPSetting.Run(gblWsId));` add:

   ```
   Set(gblOapLoaded, false);
   ```

2. Immediately after that same line add:

   ```
   Set(gblOapLoaded, true);
   ```

3. Set `LblOapOff.Visible` to:

   ```
   gblOapLoaded && !gblFlowResult.oapenabled
   ```

Not required for the fix. The two `Visible` changes above do not flash, because a blank `gblFlowResult` keeps them hidden — which is the correct starting state.

---

## No OAP APIs are called when OAP is off

Verified 2026-08-12 by auditing every `.Run(` in `Form Screen.pa.yaml`. **No change is needed** — the guard already exists and predates this defect.

`OnVisible` calls `GetOAPSetting` unconditionally, then wraps everything else in `If(gblFlowResult.oapenabled, ...)`:

| Call | Guarded |
|---|---|
| `GetOAPSetting` | no — required to learn the state |
| `GetOutboundRules` | yes |
| `GetGitPolicy` | yes |
| `ListGateways` | yes |
| `GetGatewayRules` | yes |

The write paths need no guard of their own once the two `Visible` fixes are applied, because each sits on a control that is then hidden:

| Call | Lives on | Hidden by |
|---|---|---|
| `SetGitPolicy` | `TglGitAllowed.OnCheck` / `.OnUncheck` | fix 1 |
| `SetOutboundRules`, `GetOutboundRules` | `BtnSave.OnSelect` | `RulesContainer.Visible` (already correct) |
| `SetGatewayRules`, `GetGatewayRules` | `BtnSaveGateways.OnSelect` | fix 2 |

So the visibility fix and the "don't call the APIs" requirement are the same fix. The only reason the panels looked live is that they were drawn, not that they were fetching.

---

## Verify

| # | Setup | Expect |
|---|---|---|
| 1 | Workspace with OAP **disabled** | Only `OAP Enabled` (off) and `LblOapOff`. No Git toggle, no gateways block, no Save buttons |
| 2 | Workspace with OAP **enabled** | `OAP Enabled` (on), rules gallery, Git toggle, gateways block — `LblOapOff` hidden |
| 3 | Switch from an enabled workspace to a disabled one without leaving the screen | Panels disappear; no stale gateway rows |

Test 3 is the one worth doing deliberately. It is the only path that exercises the OAP-off branch of `OnVisible` against collections that already hold data.
