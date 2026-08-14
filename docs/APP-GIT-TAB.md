# Canvas app — Git Integration tab

Build guide for the Git tab in `crbab_app5` (`CanvasApps/crbab_app5_baf10_DocumentUri.msapp`).

Everything here is built in the maker portal. **Never hand-edit the `.msapp`.**

Flow contracts below were read from the exported JSON in `Workflows/`, not from memory. Formulas are Power Fx.

---

## Status

| Step | What | State |
|---|---|---|
| 1 | `gblWsId` hoisted out of the `If`, `BtnGit` gated | ✅ Done in portal 2026-08-11 — **not yet exported** |
| 2 | Data source, state load, connected panel | Not started |
| 3 | Connect wizard | Not started |
| 4 | Choice panel | Not started |
| 5 | Operation polling | Not started |
| 6 | Disconnect | Not started |

> **Two exports are outstanding.** `CanvasApps/crbab_app5_baf10_DocumentUri.msapp` predates step 1, and `Workflows/AddConnectionRoleAssignment-*.json` predates the paging work of 2026-08-11. Nothing in the repo can be trusted to describe those two until the solution is re-exported.

---

## How to read this

**Everything you actually do is in the numbered steps.** Work through Step 2 → Step 6 in order, top to bottom. Each step is self-contained and ends with something testable.

Everything before Step 2 is reference. Read it once, then come back to it when a step points you there.

| Section | Kind | Use it for |
|---|---|---|
| Status | reference | what is done and what is stale |
| What already exists | reference | orienting in the current app |
| Flow contracts | **reference only** | looking up input order and output names — **do not add flows from here** |
| Variables | reference | what each `gbl`/`var` holds |
| The load block | reference | the formula the steps tell you to paste |
| Control tree | reference | container names and their `Visible` formulas |
| **Steps 2–6** | **do this** | the build, in order |
| Test matrix | do this | after step 6 |
| Known limitations | reference | what this design does not solve |

**Flows are added inside the steps, not all at once:**

| Step | Flows to add |
|---|---|
| 2b | `GetWorkspaceGitState` |
| 3a | `ListMyConnections`, `AddConnectionRoleAssignment`, `ConnectWorkspaceToGit`, `SyncWorkspaceWithGit` |
| 5 | `GetGitOperationStatus` (binds as `PollFabricOperation`) |
| 6 | `DisconnectWorkspaceFromGit` |

The Flow contracts table lists all seven so you can check a name or argument order without leaving the file. Adding them all up front would leave six untested bindings in the app while you debug the first.

---

## What already exists — reference

`Form Screen` holds a tab bar driven by `varActiveTab`, with sibling containers whose `Visible` tests that variable. `OutboundContent` is the fully built example to copy from.

`GitContent` is a stub containing three controls — `git text`, `getEmailButton`, `Label1` — left over from a dropped `GetMyEmail` experiment. **Delete all three**; `GetMyEmail` is not used (OPEN-ISSUES decision 2026-08-11).

`gblWsId` is set on `Form Screen.OnVisible` before the `If`, so it is always the currently selected workspace or blank. `BtnGit.DisplayMode` disables the tab when it is blank.

---

## Flow contracts — reference

Verified against the exports 2026-08-11. Inputs are **positional** in Power Fx, in the order shown.

| Flow | Inputs | Outputs |
|---|---|---|
| `GetWorkspaceGitState` | `workspaceId` | `gitconnectionstate`, ~~`isconnected`~~, `gitproviderdetails`, `gitcredentials`, `errormessage` |
| `ListMyConnections` | *(none)* | `connections` *(JSON string)*, ~~`count`~~ |
| `AddConnectionRoleAssignment` | `connectionId` | `outcome`, `message` |
| `ConnectWorkspaceToGit` | `workspaceId`, `connectionId`, `organizationName`, `projectName`, `repositoryName`, `branchName`, `directoryName` | `outcome`, `message`, `operationid`, `requiredaction` |
| `SyncWorkspaceWithGit` | `workspaceId`, `requiredAction`, `initializationStrategy` | `outcome`, `operationid`, `requiredaction`, `message` |
| `DisconnectWorkspaceFromGit` | `workspaceId` | `outcome`, `message` |
| `GetGitOperationStatus` — **call it as `PollFabricOperation`** | `operationId` | `status`, `errorcode`, `errormessage`, `errordetails`, `percentcomplete`, `requiredaction`, `remotecommithash` |

`GetFabricToken` is a child flow and is **not** added to the app.

All PowerApp response values are strings except where marked. Output names are lowercased by the connector regardless of their `title`.

### Outcome vocabularies

| Flow | `outcome` values |
|---|---|
| `ConnectWorkspaceToGit` | `Connected`, `NeedsChoice`, `AlreadyConnected`, `Failed`, `Pending` |
| `SyncWorkspaceWithGit` | `Started`, `Completed`, `NothingToDo`, `Failed` |
| `AddConnectionRoleAssignment` | `Granted`, `AlreadyGranted`, `Failed` |
| `DisconnectWorkspaceFromGit` | see its own response bodies — `outcome` + `message` |

`Pending` is currently unreachable: Asynchronous Pattern is left On for `Initialize_connection` by decision, so the connector resolves the 202 itself. Handle it anyway.

`ListMyConnections` already filters to `AzureDevOpsSourceControl`, so its result needs no further filtering.

---

## Variables — reference

| Name | Set by | Holds |
|---|---|---|
| `gblGitState` | load block | the `GetWorkspaceGitState` record |
| `gblGitProvider` | load block | `ParseJSON(gblGitState.gitproviderdetails)` |
| `gblGitLoaded` | load block | true once a load has succeeded |
| `gblGitError` | any step | banner text, blank when healthy |
| `gblGitOpId` | sync / connect | outstanding operation ID, blank when idle |
| `gblGitOp` | poll | the `GetGitOperationStatus` record |
| `varGitView` | wizard | `""` (state-driven) or `"Choice"` |
| `varGitChoicePick` | choice panel | `""`, `"PreferRemote"` or `"PreferWorkspace"` \u2014 pending confirmation |
| `varGitConfirm` | disconnect | true while the confirm prompt is up |
| `colGitConns` | wizard | connections with parsed org/project/repo |

---

## The load block — reference

Used verbatim in three places: `BtnGit.OnSelect`, `BtnGitRefresh.OnSelect`, and after any write completes.

```
Set(gblGitError, "");
Set(gblGitLoaded, false);
IfError(
    Set(gblGitState, GetWorkspaceGitState.Run(gblWsId));
    Set(gblGitProvider, ParseJSON(gblGitState.gitproviderdetails));
    Set(gblGitLoaded, true),
    Set(gblGitError, "Could not load Git state: " & FirstError.Message)
)
```

`BtnGit.OnSelect` prefixes it with:

```
Set(varActiveTab, "Git");
Set(varGitView, "");
```

Duplicated rather than shared. Power Fx has no clean way to factor this out here, and a shared collection would be more machinery than the repetition costs.

**No loading spinner.** Canvas apps do not repaint between statements of a synchronous `OnSelect`, so a `varGitBusy` panel would never render. The pause is honest; a control that does nothing is not.

**Always refetch, never cache.** Git state changes as a direct result of what this tab does.

---

## Control tree — reference

```
GitContent                     Visible: varActiveTab = "Git"
├── GitErrorBanner             (coexists with the panels below)
├── GitConnected
├── GitNotConnected
├── GitChoice
└── GitBusy
```

| Container | `Visible` |
|---|---|
| `GitErrorBanner` | `!IsBlank(gblGitError) \|\| (gblGitLoaded && gblGitState.gitconnectionstate = "Error")` |
| `GitConnected` | `IsBlank(gblGitOpId) && varGitView <> "Choice" && gblGitLoaded && gblGitState.gitconnectionstate <> "NotConnected" && gblGitState.gitconnectionstate <> "Error"` |
| `GitNotConnected` | `IsBlank(gblGitOpId) && varGitView <> "Choice" && gblGitLoaded && gblGitState.gitconnectionstate = "NotConnected"` |
| `GitChoice` | `varGitView = "Choice"` |
| `GitBusy` | `!IsBlank(gblGitOpId)` |

`GitConnected` excludes both `NotConnected` and `Error`, so the first three panels cannot overlap. The banner is allowed to coexist — an error alongside a stale panel is more useful than an empty tab.

**Do not use the flow's `isconnected` output.** It is declared `boolean` in the response schema but emitted as `"@{not(or(...))}"`, and the `@{ }` form is string interpolation — the flow returns the string `"true"`, so Power Apps rejects the response with *JSON parsing error, expected 'boolean' but got 'string'*. Validation covers the **whole response**, so one bad field breaks every output of the flow; the field must be deleted from the Respond action, not merely ignored by the app. Compare `gitconnectionstate` instead.

`ListMyConnections.count` had the identical defect (`@{length(...)}` against `"type": "number"`) and was deleted for the same reason. Use `CountRows(ParseJSON(...))` if a count is ever needed. **Any non-string field in a PowerApp Respond action is suspect** — the designer writes `@{ }` around single expressions, which stringifies them.

**These `Visible` formulas reference variables from later steps.** Declare all of them in step 2a before typing any of them, or Power Fx will reject the names. Build the containers themselves as you reach them: `GitErrorBanner`, `GitConnected` and `GitNotConnected` in step 2, `GitChoice` in step 4, `GitBusy` in step 5.

---

## Control types — reference

The app mixes classic and modern controls. Match what the outbound tab already uses, or the Git tab will look wrong next to it. Types below were read from `Src\Form Screen.pa.yaml` inside the `.msapp` on 2026-08-12.

| Need | Insert menu | Template in use | Existing example |
|---|---|---|---|
| container | Layout → Vertical / Horizontal container | `GroupContainer@1.5.0` | `OutboundContent`, `AddGwRow` |
| button | Button | `ModernButton@1.0.0` | `BtnSave`, `BtnAddGw` |
| label | Text label | `Label@2.5.1` *(classic)* | `LblName`, `LblGwLabel` |
| text input | Text input | `ModernTextInput@1.1.1` | `TxtNewEntry` |
| combobox | Input → Combo box **(classic)** | `Classic/ComboBox@2.4.0` | `CmbGwToAdd` |
| gallery | Gallery → Blank vertical | `Gallery@2.15.0` | `GalRules`, `GalGwSelected` |
| toggle | Toggle | `Toggle@1.1.5` | `TglAllowed` |
| icon | Icons → Reload | `Icon@1.0.x` *(classic)* | none yet |
| timer | Input → Timer | `Timer@2.1.0` *(classic)* | none yet |

Two traps. The **combobox must be the classic one** — the modern combo box exposes a different selection model, and `CmbGitConn.Selected.org` in 3d assumes classic behaviour. And **"Text label" is the classic `Label`, not `ModernText`**; the app uses `ModernText` exactly once, for a placeholder that step 3 deletes.

If the Insert menu shows no classic controls, enable **Settings → Updates → Modern controls and themes**, which adds the classic section under each category.

---

## Step 2 — state load and connected view

### 2a. Declare the variables

Add to the **end** of `Form Screen.OnVisible`, outside the existing `If`:

```
Set(varGitView, "");
Set(gblGitOpId, "");
Set(varGitConfirm, false);
Set(gblGitLoaded, false);
Set(gblGitError, "")
```

Do this **first**. Power Fx resolves a global name at design time only if some `Set()` for it exists somewhere in the app, so without this block every `Visible` formula below fails to type-check — including ones whose variables belong to steps 4 and 5.

It also guarantees the Git tab opens clean when the user switches workspaces, rather than inheriting the previous workspace's view state.

### 2b. Add the flow

Left rail → **Power Automate** → **+ Add flow** → `GetWorkspaceGitState`.

Only this one for now. Adding all seven up front means many untested bindings at once.

### 2c. Clear the stub

Delete `git text`, `getEmailButton`, `Label1` from `GitContent`.

### 2d. Wire the load

Replace `BtnGit.OnSelect` entirely — the two-line prefix plus the load block:

```
Set(varActiveTab, "Git");
Set(varGitView, "");
Set(gblGitError, "");
Set(gblGitLoaded, false);
IfError(
    Set(gblGitState, GetWorkspaceGitState.Run(gblWsId));
    Set(gblGitProvider, ParseJSON(gblGitState.gitproviderdetails));
    Set(gblGitLoaded, true),
    Set(gblGitError, "Could not load Git state: " & FirstError.Message)
)
```

The property currently holds only `Set(varActiveTab, "Git")`, which is line 1 above — overwrite the whole thing rather than appending.

`gblGitLoaded` is set false before the call and true only on success, so a failed call leaves every panel hidden and only `GitErrorBanner` visible.

This will not save until 2b is done; `GetWorkspaceGitState` must be a bound data source before the name resolves.

### 2e. `GitConnected` — the connected view

This is the panel shown when the workspace already has a Git connection. A two-column detail table and a refresh control.

**Create the container**

| Where | What |
|---|---|
| Insert → Layout | **Vertical container** |
| Tree view | rename it `GitConnected` |
| Tree view | drag it so it sits **inside** `GitContent` |
| `Visible` | `IsBlank(gblGitOpId) && varGitView <> "Choice" && gblGitLoaded && gblGitState.gitconnectionstate <> "NotConnected" && gblGitState.gitconnectionstate <> "Error"` |

A vertical container, not a blank one: it owns the `X`/`Y`/`Width`/`Height` of its children, so the eight controls below stack themselves and you never position anything by hand.

**Add the detail table**

Seven separate `"Label: " & value` labels do not line up — each value starts wherever its own prefix ends. Use a gallery instead: one row template, two fixed columns, alignment guaranteed.

| Where | What |
|---|---|
| Insert → Gallery | **Blank vertical** |
| Tree view | rename `GalGitDetails`, place inside `GitConnected` |

| Property | Value |
|---|---|
| `Items` | the `Table()` below |
| `TemplateSize` | `32` |
| `TemplatePadding` | `0` |
| `ShowScrollbar` | `false` |
| `Height` | `224` |
| `FillPortions` | `0` |
| `AlignInContainer` | `AlignInContainer.Stretch` |

`Items`:

```
Table(
    { name: "State",        value: gblGitState.gitconnectionstate },
    { name: "Provider",     value: Text(gblGitProvider.gitProviderType) },
    { name: "Organization", value: Text(gblGitProvider.organizationName) },
    { name: "Project",      value: Text(gblGitProvider.projectName) },
    { name: "Repository",   value: Text(gblGitProvider.repositoryName) },
    { name: "Branch",       value: Text(gblGitProvider.branchName) },
    { name: "Directory",    value: Text(gblGitProvider.directoryName) }
)
```

An inline `Table()`, not a `ClearCollect` in the load block. It re-evaluates whenever `gblGitState` changes, so refresh and every write in steps 3–6 update it for free with nothing to keep in sync.

`gitconnectionstate` needs no `Text()` — flow outputs are already strings. The provider fields do: `ParseJSON` returns untyped values, which will not land in a table column until coerced.

Two labels in the row template.

**Getting them into the template**, which is the part that goes wrong: select `GalGitDetails` in the tree view first, *then* Insert → Text label. The label drops into the template. Inserting while the screen or the container is selected puts it on the screen next to the gallery instead.

Confirm in the tree view — indentation is the only reliable check:

```
GitConnected
└── GalGitDetails
    ├── LblGitKey
    └── LblGitVal
```

Same indent level as `GalGitDetails` means they are siblings, not children; drag them onto the gallery in the tree to fix it. The visual tell is that a template control repeats in every row, while one that missed draws once.

| Control | Property | Value |
|---|---|---|
| `LblGitKey` | `Text` | `ThisItem.name` |
| | `X` | `0` |
| | `Width` | `140` |
| | `FontWeight` | `FontWeight.Semibold` |
| `LblGitVal` | `Text` | `ThisItem.value` |
| | `X` | `150` |
| | `Width` | `Parent.Width - 160` |

Both `X` values are fixed, so every row breaks at the same column — that is the whole point of doing it this way.

`Height` is `7 × TemplateSize`. Hard-coded because the row count is fixed; if you add a row, change it to `224 + 32`.

**Add the refresh control**

Either a button or an icon. The icon matches the rest of the app better and takes less room.

*Icon (preferred):* Insert → **Icons** → **Reload**, rename `IcoGitRefresh`, drag inside `GitConnected`.

| Property | Value |
|---|---|
| `Icon` | `Icon.Reload` |
| `Tooltip` | `"Refresh Git state"` |
| `Color` | match the outbound tab's icons |
| `AlignInContainer` | `AlignInContainer.Start` |
| `FillPortions` | `0` |
| `Width` | `40` |
| `Height` | `40` |

The last four matter: a vertical container stretches its children to full width and divides leftover height by `FillPortions`. Without them the icon inflates to the width of the panel and the click target covers half the tab.

*Button alternative:* Insert → Button, rename `BtnGitRefresh`, `Text` = `"Refresh"`. Same `OnSelect`.

`OnSelect` for either:

```
Set(gblGitError, "");
Set(gblGitLoaded, false);
IfError(
    Set(gblGitState, GetWorkspaceGitState.Run(gblWsId));
    Set(gblGitProvider, ParseJSON(gblGitState.gitproviderdetails));
    Set(gblGitLoaded, true),
    Set(gblGitError, "Could not load Git state: " & FirstError.Message)
)
```

This is the 2d load block without its first two lines. `varActiveTab` is already `"Git"` and `varGitView` already `""` whenever this control is reachable — the panel it sits in is only visible under those conditions — so re-setting them would be noise.

Refresh matters more than it looks. Git state changes outside the app: someone commits in Fabric, or a sync started in step 5 finishes after the poll timer has stopped. This is the only way to see that without leaving and re-entering the tab.

Nothing else here is editable — step 2 is read-only on purpose. Connect, sync and disconnect arrive in steps 3, 4 and 6.

### 2f. `GitNotConnected` — placeholder

Same container recipe as 2e: Insert → Layout → **Vertical container**, rename `GitNotConnected`, place inside `GitContent`, then set:

| Property | Value |
|---|---|
| `Visible` | `IsBlank(gblGitOpId) && varGitView <> "Choice" && gblGitLoaded && gblGitState.gitconnectionstate = "NotConnected"` |

One label inside it:

```
"This workspace is not connected to Git."
```

The wizard replaces this in step 3. It exists now so step 2 can prove both live branches render.

### 2g. `GitErrorBanner`

Same recipe again, named `GitErrorBanner`, inside `GitContent`:

| Property | Value |
|---|---|
| `Visible` | `!IsBlank(gblGitError) \|\| (gblGitLoaded && gblGitState.gitconnectionstate = "Error")` |

One label:

```
If(!IsBlank(gblGitError), gblGitError, gblGitState.errormessage)
```

Two sources because a flow-level failure and a Fabric 4xx arrive by different routes.

### 2h. Test

| Workspace | Expect |
|---|---|
| `ab_demo_5` — `e9de0b2d-0cc1-42ed-9395-28da86acfd97` | `GitConnected`, `ConnectedAndInitialized`, repo `fabricrepo2`, directory `test2` |
| `ab_demo_git2` — `5e4516d9-6da1-4426-8e59-751ab93c5219` | `GitNotConnected` |

Those two cover both live branches. A wrong directory on `ab_demo_5` means the workspace drifted since 2026-08-11, not that the panel is broken — check Fabric before touching the app.

---

## Step 3 — the connect wizard

### 3a. Add flows

`ListMyConnections`, `AddConnectionRoleAssignment`, `ConnectWorkspaceToGit`, `SyncWorkspaceWithGit`.

### 3b. Load the connection list

This extends the load block, so it changes **two controls**: `BtnGit.OnSelect` and `IcoGitRefresh.OnSelect`. Both blocks below are complete — select all in the formula bar and paste over what is there.

The new part is the trailing `If`, guarded on `NotConnected`: there is no reason to pay for `ListMyConnections` when the connected panel is what will render.

**`BtnGit.OnSelect`** — tree view → `TabBar` → `BtnGit`:

```
Set(varActiveTab, "Git");
Set(varGitView, "");
Set(gblGitError, "");
Set(gblGitLoaded, false);
Reset(CmbGitConn);
Reset(TxtGitBranch);
Reset(TxtGitDir);
IfError(
    Set(gblGitState, GetWorkspaceGitState.Run(gblWsId));
    Set(gblGitProvider, ParseJSON(gblGitState.gitproviderdetails));
    Set(gblGitLoaded, true),
    Set(gblGitError, "Could not load Git state: " & FirstError.Message)
);
If(
    gblGitLoaded && gblGitState.gitconnectionstate = "NotConnected",
    IfError(
        Set(gblConnList, ListMyConnections.Run());
        ClearCollect(
            colGitConns,
            ForAll(
                Table(ParseJSON(gblConnList.connections)) As C,
                With(
                    {
                        pth: Text(C.Value.path)
                    },
                    With(
                        {
                            m: Match(pth, "https://dev\.azure\.com/(?<org>[^/]+)/(?<project>[^/]+)/_git/(?<repo>[^/?#]+)"),
                            l: Match(pth, "https://(?<org>[^./]+)\.visualstudio\.com/(?<project>[^/]+)/_git/(?<repo>[^/?#]+)")
                        },
                        {
                            id: Text(C.Value.id),
                            displayName: Text(C.Value.displayName),
                            path: pth,
                            org: Coalesce(m.org, l.org),
                            project: Coalesce(m.project, l.project),
                            repo: Coalesce(m.repo, l.repo)
                        }
                    )
                )
            )
        );
        Set(gblConnsLoaded, true),
        Set(gblGitError, "Could not list connections: " & FirstError.Message)
    )
)
```

**`IcoGitRefresh.OnSelect`** — tree view → `GitConnected` → `RowGitActions` → `IcoGitRefresh`. Identical, minus the two prefix lines:

```
Set(gblGitError, "");
Set(gblGitLoaded, false);
IfError(
    Set(gblGitState, GetWorkspaceGitState.Run(gblWsId));
    Set(gblGitProvider, ParseJSON(gblGitState.gitproviderdetails));
    Set(gblGitLoaded, true),
    Set(gblGitError, "Could not load Git state: " & FirstError.Message)
);
If(
    gblGitLoaded && gblGitState.gitconnectionstate = "NotConnected",
    IfError(
        Set(gblConnList, ListMyConnections.Run());
        ClearCollect(
            colGitConns,
            ForAll(
                Table(ParseJSON(gblConnList.connections)) As C,
                With(
                    {
                        pth: Text(C.Value.path)
                    },
                    With(
                        {
                            m: Match(pth, "https://dev\.azure\.com/(?<org>[^/]+)/(?<project>[^/]+)/_git/(?<repo>[^/?#]+)"),
                            l: Match(pth, "https://(?<org>[^./]+)\.visualstudio\.com/(?<project>[^/]+)/_git/(?<repo>[^/?#]+)")
                        },
                        {
                            id: Text(C.Value.id),
                            displayName: Text(C.Value.displayName),
                            path: pth,
                            org: Coalesce(m.org, l.org),
                            project: Coalesce(m.project, l.project),
                            repo: Coalesce(m.repo, l.repo)
                        }
                    )
                )
            )
        );
        Set(gblConnsLoaded, true),
        Set(gblGitError, "Could not list connections: " & FirstError.Message)
    )
)
```

Two regexes because Azure DevOps has two URL forms. Only `dev.azure.com` has ever been observed, so **the `visualstudio.com` branch is untested code**.

The trailing `Set(gblConnsLoaded, true)` is not decoration. `IfError` requires its value and fallback to be the same type, and `ClearCollect` returns a **Table** while `Set` returns a Boolean — ending the try branch on the `ClearCollect` gives *Invalid argument type (Boolean). Expecting a Table value instead* on the fallback. Any `IfError` whose branches end on different function kinds will do this.

Refresh reloads the connection list too. That is deliberate: an owner who creates a connection in Fabric, then comes back, must be able to make it appear without leaving the tab.

Step 6 will need a third copy of the state half of this. If keeping them aligned starts to hurt, move the whole thing to a hidden `BtnGitLoad.OnSelect` and call `Select(BtnGitLoad)` from all three.

### 3c. `GitNotConnected` contents

Delete the placeholder label from 2f first. Control types per the reference table above.

| Control | Type | Property | Value |
|---|---|---|---|
| `CmbGitConn` | **classic** Combo box | `Items` | `colGitConns` |
| | | `DisplayFields` | `["displayName", "path"]` |
| | | `SearchFields` | `["displayName", "path"]` |
| | | `SelectMultiple` | `false` |
| | | `DefaultSelectedItems` | *(leave empty)* |
| `LblGitConnPath` | Text label | `Text` | `"Repository: " & CmbGitConn.Selected.path` |
| `TxtGitBranch` | Text input | `Default` | `"main"` |
| `TxtGitDir` | Text input | `Default` | `"/"` |
| `BtnGitConnect` | Button | `Text` | `"Connect"` |
| | | `DisplayMode` | `If(IsBlank(CmbGitConn.Selected.id) \|\| IsBlank(CmbGitConn.Selected.repo), DisplayMode.Disabled, DisplayMode.Edit)` |

Two `DisplayFields` render as two stacked lines per row — the connection name above, the repository URL below. Names are chosen by whoever created the connection and often say nothing about which repository they point at, so a name-only list is unpickable when several exist. Raise the combo box `Height` if the rows crowd.

`SelectMultiple` defaults to true on a classic combo box, and `Selected` returns the first item either way — but a multi-select control invites the owner to pick two connections and then silently ignores one.

See [docs/APP-GIT-CONNECT-FORM.md](docs/APP-GIT-CONNECT-FORM.md) for why the form must also be reset on entry.

Org, project and repo are **derived and read-only** — the owner never pastes a URL. Disabling the button when `repo` is blank is what stops an unparsed URL reaching Fabric.

### 3d. `BtnGitConnect.OnSelect`

```
Set(gblGitError, "");
Set(gblGrant, AddConnectionRoleAssignment.Run(CmbGitConn.Selected.id));
If(
    gblGrant.outcome = "Failed",
    Set(gblGitError, "Could not share the connection with the service: " & gblGrant.message),
    Set(
        gblConnect,
        ConnectWorkspaceToGit.Run(
            gblWsId,
            CmbGitConn.Selected.id,
            CmbGitConn.Selected.org,
            CmbGitConn.Selected.project,
            CmbGitConn.Selected.repo,
            Coalesce(Trim(TxtGitBranch.Text), "main"),
            Coalesce(Trim(TxtGitDir.Text), "/")
        )
    );
    Switch(
        gblConnect.outcome,
        "Connected",
            Set(gblSync, SyncWorkspaceWithGit.Run(gblWsId, gblConnect.requiredaction, ""));
            Set(gblGitOpId, gblSync.operationid);
            If(gblSync.outcome = "Failed", Set(gblGitError, gblSync.message)),
        "NeedsChoice",
            Set(varGitView, "Choice"),
        "AlreadyConnected",
            Set(gblGitError, gblConnect.message),
        "Pending",
            Set(gblGitOpId, gblConnect.operationid),
        Set(gblGitError, gblConnect.message)
    )
);
If(
    IsBlank(gblGitOpId) && varGitView <> "Choice",
    Set(gblGitLoaded, false);
    IfError(
        Set(gblGitState, GetWorkspaceGitState.Run(gblWsId));
        Set(gblGitProvider, ParseJSON(gblGitState.gitproviderdetails));
        Set(gblGitLoaded, true),
        Set(gblGitError, "Could not reload Git state: " & FirstError.Message)
    )
)
```

**The trailing reload is not optional.** A sync that finishes inline returns `Completed` or `NothingToDo` with an **empty `operationid`**, so `gblGitOpId` stays blank, `GitBusy` never appears, and step 5's timer — which is what normally reloads state — never runs. Without this block `gblGitState` still holds the pre-connect `NotConnected`, the tab redraws `GitNotConnected`, and the owner presses Connect a second time and gets `AlreadyConnected`. The guard covers the `AlreadyConnected` and `Failed` branches too, where showing the true state is the honest answer.

**Order is load-bearing.** The grant must land before `connect`, or the broker cannot read the connection. Flow 7 runs delegated as the owner; flow 5 runs as the broker.

**`connect` is called once.** On `NeedsChoice` the workspace is already connected — Fabric refused only the *initialization*. Step 4 therefore calls `SyncWorkspaceWithGit` alone and must never call `ConnectWorkspaceToGit` again, which would return `AlreadyConnected`.

**Why the auto-sync is safe.** Fabric only returns a `requiredAction` when one side is empty, so the losing side has nothing on it. And if content appears between the probe and the sync, `commitToGit` fails with `WorkspaceHeadMismatch` and `updateFromGit` runs with `allowOverrideItems` false and refuses. Both degrade to an error rather than to data loss.

---

## Step 4 — the choice panel

Reached only from `NeedsChoice`: both the workspace and the repository directory hold items, and Fabric refuses to guess. Whichever side the owner picks, the other is overwritten — so this is the one panel in the tab that needs a confirm.

No new flow. `SyncWorkspaceWithGit` was added in 3a.

### 4a. Declare the variable

Add to `Form Screen.OnVisible`, beside the other Git declarations from 2a:

```
Set(varGitChoicePick, "");
```

It holds `""`, `"PreferRemote"` or `"PreferWorkspace"` — which side the owner clicked, pending confirmation.

### 4b. Create the container

| Where | What |
|---|---|
| Insert → Layout | **Vertical container** |
| Tree view | rename `GitChoice`, place inside `GitContent` |
| `Visible` | `varGitView = "Choice"` |

### 4c. The warning label

Insert → Text label inside `GitChoice`, named `LblGitChoiceWarn`.

| Property | Value |
|---|---|
| `Text` | `"Both this workspace and the repository folder contain items. Choose which one wins. The other is overwritten and cannot be recovered from this app."` |
| `AutoHeight` | `true` |

Say *overwritten*, not *synced*. The owner is about to lose one side.

### 4d. The two choice buttons

Insert → Layout → **Horizontal container** inside `GitChoice`, named `RowGitChoice`, then two buttons inside it.

| Control | Property | Value |
|---|---|---|
| `BtnGitPreferRemote` | `Text` | `"Use the repository"` |
| | `OnSelect` | `Set(varGitChoicePick, "PreferRemote")` |
| | `FillPortions` | `0` |
| `BtnGitPreferWorkspace` | `Text` | `"Use the workspace"` |
| | `OnSelect` | `Set(varGitChoicePick, "PreferWorkspace")` |
| | `FillPortions` | `0` |

Neither button calls the flow. They only record the intent, which is what makes 4e possible.

### 4e. The confirm row

Insert → Layout → **Horizontal container** inside `GitChoice`, named `RowGitChoiceConfirm`.

| Control | Type | Property | Value |
|---|---|---|---|
| `RowGitChoiceConfirm` | Horizontal container | `Visible` | `!IsBlank(varGitChoicePick)` |
| `LblGitChoiceConfirm` | Text label | `Text` | `If(varGitChoicePick = "PreferRemote", "The repository wins. Every item in this workspace is replaced. Continue?", "The workspace wins. Everything in the repository folder is replaced. Continue?")` |
| `BtnGitChoiceYes` | Button | `Text` | `"Yes, overwrite"` |
| | | `OnSelect` | the block below |
| | | `DisplayMode` | `If(IsBlank(varGitChoicePick), DisplayMode.Disabled, DisplayMode.Edit)` |
| | | `FillPortions` | `0` |
| `BtnGitChoiceNo` | Button | `Text` | `"Cancel"` |
| | | `OnSelect` | `Set(varGitChoicePick, "")` |
| | | `FillPortions` | `0` |

`BtnGitChoiceYes.OnSelect`:

```
Set(gblGitError, "");
Set(gblSync, SyncWorkspaceWithGit.Run(gblWsId, "", varGitChoicePick));
Set(varGitChoicePick, "");
Set(varGitView, "");
Set(gblGitOpId, gblSync.operationid);
If(gblSync.outcome = "Failed", Set(gblGitError, gblSync.message));
If(
    IsBlank(gblGitOpId),
    Set(gblGitLoaded, false);
    IfError(
        Set(gblGitState, GetWorkspaceGitState.Run(gblWsId));
        Set(gblGitProvider, ParseJSON(gblGitState.gitproviderdetails));
        Set(gblGitLoaded, true),
        Set(gblGitError, "Could not reload Git state: " & FirstError.Message)
    )
)
```

The closing `If` is the same guard as 3d, for the same reason: `Completed` and `NothingToDo` come back with an empty `operationid`, and without a reload the panel keeps showing pre-connect state.

One handler, not two. The strategy travels in `varGitChoicePick`, so there is a single call site to get right — and only one place where the confirm can be accidentally bypassed.

Setting `varGitView` back to `""` and `gblGitOpId` to the operation ID hands the screen to `GitBusy` and step 5's timer.

### 4f. Notes and test

`requiredAction` is passed empty on purpose: when a strategy is supplied, flow 8 initializes with it and derives the direction from the result.

`initializationStrategy` is passed **positionally**. It was originally an optional trigger input, and Power Apps silently **drops blank optional arguments from the payload entirely** — the key never reached the flow, `Condition_needs_strategy` evaluated false, and initialization never ran. Worse, an optional input that is missing looks identical in run history to one that was never wired. It was made **required** in flow 8's trigger on 2026-08-12 for that reason: a blank now arrives as `text_2: ""` and is visible.

After changing a trigger's inputs, **remove and re-add the flow in the app**. Power Apps caches the signature at bind time and keeps sending the old shape until it is rebound.

`NothingToDo` is a valid answer here and must not read as failure — phrase it *"No changes were needed."* rather than anything implying the choice was ignored.

Test with matrix row 4: connect a workspace holding items to a directory that also holds items. Expect `NeedsChoice` from 3d, this panel, then the confirm, then `GitBusy`.

> **The choice is currently blind.** Flow 4 does not return the workspace item list, so the owner picks a winning side without seeing what is in the workspace. For a destructive choice that is thin. See OPEN-ISSUES §10.6.

---

## Step 5 — polling

Connect and sync both return an operation ID rather than a result. This step builds the panel that watches it.

### 5a. Add the flow

Left rail → **Power Automate** → **+ Add flow** → `GetGitOperationStatus`. Do this before 5c and confirm the flow is listed in that pane afterwards.

> **In Power Fx this flow is called `PollFabricOperation`, not `GetGitOperationStatus`.**
> It was renamed in place on 2026-08-07 (OPEN-ISSUES §10.2). Renaming a cloud flow changes its display name only — the identifier Power Fx binds to is fixed at creation, so the formula bar still answers to the original. `GetGitOperationStatus.Run(...)` gives *'Run' is an unknown or unsupported function in namespace 'GetGitOperationStatus'*. **This is the only flow in the solution with that mismatch.** Everywhere else in these docs the two names are the same.

That error also appears if the flow was added to a different app, if the pane shows a suffixed name such as `PollFabricOperation_1` because it was added twice, or if the editor session predates the flow being created — reopen the app in that last case.

### 5b. Create the container

| Where | What |
|---|---|
| Insert → Layout | **Vertical container** |
| Tree view | rename `GitBusy`, place inside `GitContent` |
| `Visible` | `!IsBlank(gblGitOpId)` |

`gblGitOpId` is the single switch for this panel. Anything that starts a long operation sets it; 5c clears it.

### 5c. The timer

**Build this before the labels.** Power Fx only recognises a global name if a `Set()` for it exists somewhere in the app, and `gblGitOp` is first set here. Writing the labels first gives *Name isn't valid. 'gblGitOp' isn't recognized.*

Insert → Input → **Timer**, inside `GitBusy`, named `TmrGitPoll`.

| Property | Value |
|---|---|
| `Duration` | `20000` |
| `Repeat` | `true` |
| `AutoStart` | `false` |
| `Start` | `!IsBlank(gblGitOpId)` |
| `Visible` | `false` |

There is no modern timer — Insert → Input → **Timer** is classic only. A hidden timer still fires, so `Visible = false` is safe and keeps the panel clean.

20 seconds because that is the `Retry-After` Fabric returns on these operations — not a guess.

`OnTimerEnd`:

```
Set(gblGitOp, PollFabricOperation.Run(gblGitOpId));
If(
    gblGitOp.status = "Succeeded" || gblGitOp.status = "Failed",
    Set(gblGitOpId, "");
    If(gblGitOp.status = "Failed", Set(gblGitError, gblGitOp.errormessage));
    Set(gblGitLoaded, false);
    IfError(
        Set(gblGitState, GetWorkspaceGitState.Run(gblWsId));
        Set(gblGitProvider, ParseJSON(gblGitState.gitproviderdetails));
        Set(gblGitLoaded, true),
        Set(gblGitError, "Could not reload Git state: " & FirstError.Message)
    )
)
```

Clearing `gblGitOpId` stops the timer, hides `GitBusy` and reveals `GitConnected` in one move — the reload that follows is what fills it in.

### 5d. The status labels

Two text labels inside `GitBusy`:

| Control | `Text` |
|---|---|
| `LblGitBusyStatus` | `"Working: " & Coalesce(gblGitOp.status, "Starting…")` |
| `LblGitBusyPct` | `"Progress: " & Coalesce(gblGitOp.percentcomplete, 0) & "%"` |

Both are blank until the timer has fired once, roughly 20 seconds after the panel appears — hence the `Coalesce`. Without it the owner sees `Working:` and `Progress: %` and reasonably assumes the app has hung.

### 5e. Test

Matrix row 3: connect `ab_demo_git2` to an empty directory. Expect `GitBusy` to appear, the status to change within roughly 20 seconds, then `GitConnected` showing the new repository.

> `GET /v1/operations/{id}/result` returns **400 `OperationHasNoResult`** for both sync APIs, so `requiredaction` and `remotecommithash` come back **empty**. That is expected, not a defect — do not surface them as missing data.

---

## Step 6 — disconnect

The only destructive action on the tab, and the only route to a branch or directory change: Fabric has no update API for a Git connection.

### 6a. Add the flow

Left rail → **Power Automate** → **+ Add flow** → `DisconnectWorkspaceFromGit`.

### 6b. The disconnect button

Insert → Button, inside `RowGitActions`, to the right of `IcoGitRefresh`, named `BtnGitDisconnect`.

| Property | Value |
|---|---|
| `Text` | `"Disconnect"` |
| `OnSelect` | `Set(varGitConfirm, true)` |
| `FillPortions` | `0` |

`FillPortions = 0` matters here too, or the button takes the row's spare width and shoves the refresh icon out of position.

### 6c. The confirm panel

Insert → Layout → **Vertical container** inside `GitConnected`, below `RowGitActions`, named `GitConfirmPanel`.

> **Check the nesting first.** `RowGitActions` must be a *child* of `GitConnected`, not a sibling — drag it in the tree view and confirm by indentation. A sibling row is always visible, so the Disconnect button appears on unconnected workspaces and the refresh icon stays live during the busy poll. Gating it separately means maintaining a third copy of `GitConnected.Visible`.

| Property | Value |
|---|---|
| `Visible` | `varGitConfirm` |

Three controls inside it:

| Control | Type | Property | Value |
|---|---|---|---|
| `LblGitDisconnectWarn` | Text label | `Text` | `"Disconnect this workspace from Git? The Azure DevOps folder and everything in it is left untouched. To change the branch or folder you must disconnect and reconnect, which re-runs initialization."` |
| | | `AutoHeight` | `true` |
| `BtnGitDisconnectYes` | Button | `Text` | `"Yes, disconnect"` |
| | | `OnSelect` | the block below |
| `BtnGitDisconnectNo` | Button | `Text` | `"Cancel"` |
| | | `OnSelect` | `Set(varGitConfirm, false)` |

The wording is not optional. Owners assume disconnect deletes their code, and the branch-change consequence is the reason most of them will press it.

`BtnGitDisconnectYes.OnSelect`:

```
Set(varGitConfirm, false);
Set(gblGitError, "");
Set(gblDisc, DisconnectWorkspaceFromGit.Run(gblWsId));
Set(gblGitLoaded, false);
IfError(
    Set(gblGitState, GetWorkspaceGitState.Run(gblWsId));
    Set(gblGitProvider, ParseJSON(gblGitState.gitproviderdetails));
    Set(gblGitLoaded, true),
    Set(gblGitError, "Could not reload Git state: " & FirstError.Message)
)
```

Disconnect is not an LRO, so there is no operation ID and no polling — the reload runs immediately.

This is the third copy of the state reload. If it drifts from 2d and 5c, move all three into a hidden `BtnGitLoad.OnSelect` and call `Select(BtnGitLoad)`.

### 6d. Test

Matrix row 7: disconnect, confirm the panel flips to `GitNotConnected`, then check in the Fabric UI that the workspace is disconnected and the Azure DevOps folder still holds its files.

---

## Test matrix

| # | Setup | Expect |
|---|---|---|
| 1 | `ab_demo_5`, already connected | `GitConnected`, directory `test2` |
| 2 | `ab_demo_git2`, not connected | `GitNotConnected`, combobox populated |
| 3 | Connect `ab_demo_git2` to an empty directory | `Connected` → auto `CommitToGit` → poll → `Succeeded` |
| 4 | Connect a populated workspace to a populated directory | `NeedsChoice` → choice panel |
| 5 | Directory that does not exist | error banner, `GitProviderResourceNotFound` |
| 6 | Connect twice without disconnecting | `AlreadyConnected` in the banner |
| 7 | Disconnect, then confirm in the Fabric UI | state returns to `NotConnected`, ADO folder intact |

Test 5 matters most: it is the likeliest real-world failure, because Git cannot store an empty directory and a first-time connect needs a folder holding at least a placeholder file.

---

## Known limitations

**Filtering the workspace grid is not authorization.** The flows have no ownership check (F5.9, deferred). Any user who can run the app can call `ConnectWorkspaceToGit` directly from Power Automate against any workspace the broker administers. Nothing in this tab changes that.

**The choice screen is blind** — see step 4.

**The `visualstudio.com` URL branch is untested.**

**Percent-encoded project names are not decoded.** A project name containing a space arrives as `%20` in `connectionDetails.path`, and Power Fx has no URL-decode function. Such a connection will produce a wrong `projectName`. Not yet observed.

**`Pending` is unreachable today** but is handled, because it becomes reachable the moment Asynchronous Pattern is turned off on `Initialize_connection`.
