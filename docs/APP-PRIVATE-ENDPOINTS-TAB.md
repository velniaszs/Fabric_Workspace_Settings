# Canvas app — Private endpoints tab

Build guide for a new **Private endpoints** tab in `crbab_app5` (`CanvasApps/crbab_app5_baf10_DocumentUri.msapp`), sitting on the tab bar alongside Git and Outbound.

Everything here is built in the maker portal. **Never hand-edit the `.msapp`.**

Design rationale lives in [APP-PRIVATE-ENDPOINTS.md](docs/APP-PRIVATE-ENDPOINTS.md) — read §2.1, §5.2 and §5.6 before building the create panel. Flow build specs are in [flows/nocustomcon/](docs/flows/nocustomcon/).

---

## Status

| Step | What | State |
|---|---|---|
| 1 | Dataverse table `crbab_PrivateLinkTarget` + seed import | Not started |
| 2 | Tab button and container | Not started |
| 3 | Load block and gallery | Not started |
| 4 | Create panel | Not started |
| 5 | Delete with confirmation | Not started |

All three flows are **built and tested** as of 2026-09-02.

---

## How to read this

Steps 1–5 are the build, in order. Everything before Step 1 is reference — read it once and come back when a step points you there.

| Section | Kind |
|---|---|
| Flow contracts | reference |
| Variables and collections | reference |
| The load block | reference |
| Control tree | reference |
| Steps 1–5 | **do this** |
| Test matrix | do this, after step 5 |

Control types (classic vs modern, which template the app already uses) are in [APP-GIT-TAB.md](docs/APP-GIT-TAB.md) *Control types*. Match them or this tab will look wrong beside the others.

---

## Flow contracts — reference

Inputs are **positional** in Power Fx, in the order shown. All outputs are strings and come back **lowercased** regardless of the title typed into the flow.

| Flow | Inputs | Outputs |
|---|---|---|
| `ListPrivateEndpoints` | `workspaceId` | `endpointsjson`, `errormessage` |
| `CreatePrivateEndpoint` | `workspaceId`, `name`, `targetPrivateLinkResourceId`, `targetSubresourceType`, `requestMessage` | `outcome`, `endpointid`, `provisioningstate`, `message` |
| `DeletePrivateEndpoint` | `workspaceId`, `managedPrivateEndpointId` | `outcome`, `message` |

| Flow | `outcome` values |
|---|---|
| `CreatePrivateEndpoint` | `Created`, `Failed` |
| `DeletePrivateEndpoint` | `Deleted`, `NotFound`, `Failed` |

`GetFabricToken` is a child flow and is **not** added to the app.

> **`outcome: Created` means the request was accepted, not that the endpoint works.** Fabric does not validate the sub-resource against the target resource at create time — a mismatch is accepted and fails during provisioning. Always re-list after creating; never assume the new row is healthy. See [APP-PRIVATE-ENDPOINTS.md](docs/APP-PRIVATE-ENDPOINTS.md) §5.2.

---

## Variables and collections — reference

| Name | Set by | Holds |
|---|---|---|
| `gblPeLoaded` | load block | true once a load has succeeded |
| `gblPeError` | load block, writes | banner text, blank when healthy |
| `colPrivateEndpoints` | load block | the shaped endpoint rows |
| `varPeView` | tab, create panel | `""` or `"Create"` |
| `varPeType` | create panel | the parsed resource type, lowercased |
| `colPeSubres` | create panel | valid sub-resources for `varPeType` |
| `varPeSubres` | create panel | the chosen `targetSubresourceType` |
| `varPeDeleteId` | delete | the row awaiting confirmation, blank when idle |

Declare all of them in Step 2a before typing any formula that mentions them. Power Fx only resolves a global name at design time if some `Set()` for it exists somewhere in the app.

---

## The load block — reference

Used verbatim in three places: `BtnPrivateEndpoints.OnSelect`, `IcoPeRefresh.OnSelect`, and after any write completes.

```
Set(gblPeError, "");
Set(gblPeLoaded, false);
IfError(
    With(
        { r: ListPrivateEndpoints.Run(gblWsId) },
        If(
            !IsBlank(r.errormessage),
            Set(gblPeError, "Could not load private endpoints: " & r.errormessage),
            ClearCollect(
                colPrivateEndpoints,
                ForAll(
                    Table(ParseJSON(r.endpointsjson)),
                    {
                        peId:          Text(ThisRecord.Value.id),
                        peName:        Text(ThisRecord.Value.name),
                        resourceId:    Text(ThisRecord.Value.targetPrivateLinkResourceId),
                        subResource:   Text(ThisRecord.Value.targetSubresourceType),
                        provisioning:  Text(ThisRecord.Value.provisioningState),
                        connStatus:    Text(ThisRecord.Value.connectionState.status),
                        connMessage:   Text(ThisRecord.Value.connectionState.description)
                    }
                )
            );
            Set(gblPeLoaded, true)
        )
    ),
    Set(gblPeError, "Could not load private endpoints: " & FirstError.Message)
)
```

**`errormessage` is checked before the rows are used.** A multi-page read that fails partway returns *both* partial data and an error; rendering the partial list silently would be worse than reporting the failure.

**`Text(ThisRecord.Value.connectionState.status)` is safe when `connectionState` is absent** — it returns blank rather than erroring. That matters: the field is genuinely missing on a freshly created endpoint.

**Always refetch, never cache.** This tab changes the state it displays.

---

## Control tree — reference

```
PrivateEndpointsContent        Visible: varActiveTab = "PrivateEndpoints"
├── PeErrorBanner              Visible: !IsBlank(gblPeError)
├── PeList                     Visible: varPeView <> "Create" && IsBlank(varPeDeleteId)
│   ├── LblPeTitle
│   ├── IcoPeRefresh
│   ├── BtnPeNew
│   ├── GalPrivateEndpoints
│   └── LblPeEmpty             Visible: gblPeLoaded && CountRows(colPrivateEndpoints) = 0
├── PeCreate                   Visible: varPeView = "Create"
└── PeDeleteConfirm            Visible: !IsBlank(varPeDeleteId)
```

`LblPeEmpty` is gated on `gblPeLoaded`, not just on the row count. A blank collection is falsy, so without the flag the "no private endpoints" message flashes on every workspace that *does* have some — the same defect documented in [APP-OUTBOUND-TAB.md](docs/APP-OUTBOUND-TAB.md).

> **Do not gate any of this on `gblFlowResult.oapenabled`.** Managed private endpoints are independent of Outbound Access Protection. The Fabric UI puts both under *Network security*, which makes them easy to confuse, but everything on the Outbound tab lives under `networking/communicationPolicy/outbound/*` and nothing here does. Gating on OAP would hide a working feature on every workspace with OAP off.

---

## Step 1 — the Dataverse table

The create panel needs a lookup of resource type → valid sub-resources. Seed data is in [data/PrivateLinkTargets.csv](data/PrivateLinkTargets.csv) (28 rows). Rationale and the full mapping are in [APP-PRIVATE-ENDPOINTS.md](docs/APP-PRIVATE-ENDPOINTS.md) §5.6.

### 1a. Create the table

[make.powerapps.com](https://make.powerapps.com) → **Solutions** → open **WorkspaceSol** → **New** → **Table** → **Table (blank)**.

| Field | Value |
|---|---|
| Display name | `Private Link Target` |
| Plural name | `Private Link Targets` |
| Primary column display name | `Display Name` |

Expand **Advanced options** and confirm the schema name comes out as `crbab_PrivateLinkTarget`. The primary column becomes `crbab_displayname`.

**Create it in the maker portal, never by editing `customizations.xml`** (ARCHITECTURE §4).

### 1b. Add the three remaining columns

Table → **Columns** → **+ New column**, three times:

| Display name | Schema name | Data type | Format / length |
|---|---|---|---|
| `Resource Type` | `crbab_resourcetype` | Single line of text | 100 |
| `Sub Resource` | `crbab_subresource` | Single line of text | 100 |
| `Sort Order` | `crbab_sortorder` | Whole number | — |

`crbab_subresource` is **case-sensitive in use** — `sqlServer`, `SqlOnDemand`, `MongoDB` are sent verbatim to Fabric. Dataverse will not correct a typo and Fabric will accept it, then fail during provisioning.

### 1c. Import the seed data

Table → **Import** → **Import data** → **Text/CSV** → upload `data/PrivateLinkTargets.csv`.

In the mapping screen, map all four columns by name:

| CSV column | Table column |
|---|---|
| `crbab_resourcetype` | Resource Type |
| `crbab_subresource` | Sub Resource |
| `crbab_displayname` | Display Name |
| `crbab_sortorder` | Sort Order |

**Check the mapping rather than trusting auto-match.** The CSV headers use schema names and the mapping screen shows display names, so auto-match may leave one unmapped — an unmapped `crbab_subresource` imports 28 rows with a blank sub-resource and the create panel then sends `""` to Fabric on every attempt.

After publishing, confirm **28 rows** and spot-check that `microsoft.storage/storageaccounts` has five.

### 1d. Grant read access

Solution → **Security role** `Fabric Workspace Owner` → add **Read** on `Private Link Target`, alongside `crbab_Workspaces` and `crbab_AllowedConnectionType` (ARCHITECTURE §6).

Owners only ever read this table. A missing privilege shows up as an **empty dropdown**, not an error — so if the sub-resource picker is blank for a type you know is seeded, check the role before checking the formula.

### 1e. Add it to the app

Left rail → **Data** → **+ Add data** → search `Private Link Targets`.

---

## Step 2 — the tab

### 2a. Declare the variables

Add to the **end** of `Form Screen.OnVisible`, outside the existing `If`:

```
Set(varPeView, "");
Set(varPeType, "");
Set(varPeSubres, "");
Set(varPeDeleteId, "");
Set(gblPeLoaded, false);
Set(gblPeError, "")
```

Do this **first**, or every `Visible` formula below fails to type-check.

It also guarantees the tab opens clean when the user switches workspaces rather than inheriting the previous one's view state.

### 2b. Add the flows

Left rail → **Power Automate** → **+ Add flow** → add `ListPrivateEndpoints` only.

Add `CreatePrivateEndpoint` in Step 4 and `DeletePrivateEndpoint` in Step 5. Adding all three now leaves two untested bindings while you debug the first.

### 2c. The tab button

Tree view → `TabBar` → copy an existing tab button (`BtnGit` is the closest) and rename it `BtnPrivateEndpoints`. Copying inherits the styling; a fresh button will not match.

| Property | Value |
|---|---|
| `Text` | `"Private endpoints"` |
| `DisplayMode` | `If(IsBlank(gblWsId), DisplayMode.Disabled, DisplayMode.Edit)` |
| `OnSelect` | the block below |

```
Set(varActiveTab, "PrivateEndpoints");
Set(varPeView, "");
Set(varPeDeleteId, "");
Set(gblPeError, "");
Set(gblPeLoaded, false);
IfError(
    With(
        { r: ListPrivateEndpoints.Run(gblWsId) },
        If(
            !IsBlank(r.errormessage),
            Set(gblPeError, "Could not load private endpoints: " & r.errormessage),
            ClearCollect(
                colPrivateEndpoints,
                ForAll(
                    Table(ParseJSON(r.endpointsjson)),
                    {
                        peId:          Text(ThisRecord.Value.id),
                        peName:        Text(ThisRecord.Value.name),
                        resourceId:    Text(ThisRecord.Value.targetPrivateLinkResourceId),
                        subResource:   Text(ThisRecord.Value.targetSubresourceType),
                        provisioning:  Text(ThisRecord.Value.provisioningState),
                        connStatus:    Text(ThisRecord.Value.connectionState.status),
                        connMessage:   Text(ThisRecord.Value.connectionState.description)
                    }
                )
            );
            Set(gblPeLoaded, true)
        )
    ),
    Set(gblPeError, "Could not load private endpoints: " & FirstError.Message)
)
```

`DisplayMode` mirrors `BtnGit` — every flow here takes a `workspaceId` and there is nothing to show without one.

### 2d. The container

Insert → **Layout → Vertical container**, rename `PrivateEndpointsContent`, drag it to sit as a sibling of `GitContent` and `OutboundContent`.

| Property | Value |
|---|---|
| `Visible` | `varActiveTab = "PrivateEndpoints"` |

Match its `X`, `Y`, `Width` and `Height` to `OutboundContent` exactly. Sibling containers that differ by a few pixels are obvious when switching tabs.

---

## Step 3 — the list

### 3a. Error banner

Inside `PrivateEndpointsContent`, add a container `PeErrorBanner` holding one label bound to `gblPeError`.

| Property | Value |
|---|---|
| `Visible` | `!IsBlank(gblPeError)` |

It sits outside `PeList` deliberately, so an error and a stale list can show together. An error alongside old data is more useful than an empty tab.

### 3b. The list panel

Container `PeList`.

| Property | Value |
|---|---|
| `Visible` | `varPeView <> "Create" && IsBlank(varPeDeleteId)` |

Inside it: `LblPeTitle`, `IcoPeRefresh`, `BtnPeNew`, `GalPrivateEndpoints`, `LblPeEmpty`.

| Control | Property | Value |
|---|---|---|
| `IcoPeRefresh` | `OnSelect` | the load block (reference section) — without the first three `Set` lines |
| `BtnPeNew` | `Text` | `"New private endpoint"` |
| `BtnPeNew` | `OnSelect` | `Set(varPeType, ""); Set(varPeSubres, ""); Reset(TxtPeName); Reset(TxtPeResourceId); Reset(TxtPeJustification); Set(varPeView, "Create")` |
| `LblPeEmpty` | `Text` | `"No private endpoints in this workspace."` |
| `LblPeEmpty` | `Visible` | `gblPeLoaded && CountRows(colPrivateEndpoints) = 0` |

`BtnPeNew.OnSelect` clears the form **before** switching view. Reusing the panel without resetting leaves the previous attempt's values in the boxes, which reads as a half-filled form the user did not fill in.

### 3c. The gallery

`GalPrivateEndpoints`, blank vertical, `Items` = `colPrivateEndpoints`.

Per row:

| Label | `Text` |
|---|---|
| name | `ThisItem.peName` |
| target | `Last(Split(ThisItem.resourceId, "/")).Value` |
| sub-resource | `ThisItem.subResource` |
| activation | `ThisItem.provisioning` |
| approval | `If(IsBlank(ThisItem.connStatus), "—", ThisItem.connStatus)` |

Set the resource label's `Tooltip` to `ThisItem.resourceId` so the full ID is available without widening the column.

**Two status fields, both shown, never merged.** `provisioning` is Fabric's; `connStatus` belongs to the data source admin in the Azure portal. `Succeeded` + `Pending` is the **normal** state for minutes to days after creation and must not render as an error ([APP-PRIVATE-ENDPOINTS.md](docs/APP-PRIVATE-ENDPOINTS.md) §2.1).

Colour the activation label:

```
If(ThisItem.provisioning = "Failed", Color.Firebrick,
   ThisItem.provisioning = "Succeeded", Color.Green,
   Color.DimGray)
```

And the approval label:

```
If(ThisItem.connStatus = "Approved", Color.Green,
   ThisItem.connStatus = "Rejected", Color.Firebrick,
   Color.DarkOrange)
```

Add a delete icon per row — `IcoPeDelete`, `OnSelect` = `Set(varPeDeleteId, ThisItem.peId)`.

### 3d. What a `Failed` row means

Add a label below the gallery, visible when any row has failed:

| Property | Value |
|---|---|
| `Visible` | `CountRows(Filter(colPrivateEndpoints, provisioning = "Failed")) > 0` |
| `Text` | `"A failed endpoint usually means the sub-resource does not match the target resource. Delete it and create a new one with the correct type."` |

Microsoft's documentation says a `Failed` provisioning state warrants a support request. That is right for an infrastructure fault and wrong for the common case here, which is self-inflicted and self-fixable. Do not send owners to support for a mis-picked sub-resource.

---

## Step 4 — the create panel

Add `CreatePrivateEndpoint` to the app first (left rail → Power Automate → **+ Add flow**).

Container `PeCreate`, `Visible` = `varPeView = "Create"`.

### 4a. Fields

| Control | Type | Notes |
|---|---|---|
| `TxtPeName` | text input | max 64 characters |
| `TxtPeResourceId` | text input | the full Azure resource ID |
| `CmbPeSubres` | combo box *(classic)* | only shown when the type is ambiguous |
| `LblPeSubresFixed` | label | shown when the type resolves to exactly one |
| `TxtPeJustification` | text input, multiline | the owner's reason |
| `BtnPeCreate` | button | |
| `BtnPeCancel` | button | `Set(varPeView, "")` |

### 4b. Parse the resource ID

`TxtPeResourceId.OnChange`:

```
Set(varPeType,
    With(
        { m: Match(Trim(TxtPeResourceId.Text), "/providers/(?<ns>[^/]+)/(?<type>[^/]+)/") },
        If(IsBlank(m), "", Lower(m.ns & "/" & m.type))
    )
);
ClearCollect(
    colPeSubres,
    SortByColumns(
        Filter(PrivateLinkTargets, crbab_resourcetype = varPeType),
        "crbab_sortorder"
    )
);
Set(varPeSubres, If(CountRows(colPeSubres) = 1, First(colPeSubres).crbab_subresource, ""))
```

This is the whole point of Step 1. For a 1:1 type the sub-resource is decided here and the owner never sees a choice; for a 1:many type the dropdown appears with **no default**.

| Control | Property | Value |
|---|---|---|
| `CmbPeSubres` | `Visible` | `CountRows(colPeSubres) > 1` |
| `CmbPeSubres` | `Items` | `colPeSubres` |
| `CmbPeSubres` | display field | `crbab_displayname` |
| `CmbPeSubres` | `OnChange` | `Set(varPeSubres, CmbPeSubres.Selected.crbab_subresource)` |
| `LblPeSubresFixed` | `Visible` | `CountRows(colPeSubres) = 1` |
| `LblPeSubresFixed` | `Text` | `First(colPeSubres).crbab_displayname` |

**No default on the dropdown, deliberately.** A wrong-but-valid sub-resource — `blob` where the work needs `dfs` — provisions cleanly, gets approved, and then fails to carry traffic, with every signal the app can see reporting success. Making the owner choose is the only protection against that.

If `colPeSubres` is empty the type is unrecognised. Show `CmbPeSubres` as a free-text input instead, or leave `varPeSubres` bound to a plain text box, and let Fabric reject it. Do not block: Fabric's supported-source list grows faster than this table will.

### 4c. Validation

`BtnPeCreate.DisplayMode`:

```
If(
    !IsBlank(Trim(TxtPeName.Text))
    && Len(Trim(TxtPeName.Text)) <= 64
    && !IsBlank(varPeType)
    && !IsBlank(varPeSubres)
    && CountRows(Filter(colPrivateEndpoints, Lower(peName) = Lower(Trim(TxtPeName.Text)))) = 0
    && CountRows(
           Filter(
               colPrivateEndpoints,
               Lower(resourceId) = Lower(Trim(TxtPeResourceId.Text))
               && Lower(subResource) = Lower(varPeSubres)
           )
       ) = 0,
    DisplayMode.Edit,
    DisplayMode.Disabled
)
```

Two duplicate rules, and the second keys on the **pair** — resource ID *and* sub-resource. Keying on the resource ID alone would block a storage account needing both `blob` and `dfs`, which Fabric explicitly supports.

Both rules are also enforced server-side (`DuplicatePrivateEndpointName`, `DuplicateTargetPrivateLinkResourceId`, both `400`), so this check is a courtesy — it puts the error next to the field instead of after a round trip. If the collection is stale, Fabric rejects the call and the owner sees a readable message.

Add inline error labels beside the name and resource ID fields using the same two `Filter` expressions, so a disabled button always has a visible reason.

### 4d. Create

`BtnPeCreate.OnSelect`:

```
Set(gblPeError, "");
IfError(
    With(
        {
            r: CreatePrivateEndpoint.Run(
                   gblWsId,
                   Trim(TxtPeName.Text),
                   Trim(TxtPeResourceId.Text),
                   varPeSubres,
                   Left(gblWsId & " — " & User().Email & " — " & Trim(TxtPeJustification.Text), 140)
               )
        },
        If(
            r.outcome = "Created",
            Set(varPeView, "");
            Notify("Endpoint requested. It must be approved by the owner of the target resource before it can be used.", NotificationType.Success),
            Set(gblPeError, r.message)
        )
    ),
    Set(gblPeError, "Create failed: " & FirstError.Message)
);
// always refetch — see note below
Set(gblPeLoaded, false);
IfError(
    With(
        { r2: ListPrivateEndpoints.Run(gblWsId) },
        ClearCollect(
            colPrivateEndpoints,
            ForAll(
                Table(ParseJSON(r2.endpointsjson)),
                {
                    peId:          Text(ThisRecord.Value.id),
                    peName:        Text(ThisRecord.Value.name),
                    resourceId:    Text(ThisRecord.Value.targetPrivateLinkResourceId),
                    subResource:   Text(ThisRecord.Value.targetSubresourceType),
                    provisioning:  Text(ThisRecord.Value.provisioningState),
                    connStatus:    Text(ThisRecord.Value.connectionState.status),
                    connMessage:   Text(ThisRecord.Value.connectionState.description)
                }
            )
        );
        Set(gblPeLoaded, true)
    ),
    Set(gblPeError, "Created, but the list could not be refreshed: " & FirstError.Message)
)
```

**Substitute the workspace display name for `gblWsId` in the `requestMessage`** if the app already holds one — check what the Outbound tab shows. A stranger in another organisation reads this string in the Azure portal, and a GUID tells them nothing about who is asking or why.

**The refresh runs on every path, success or failure.** `Created` means *accepted*, not provisioned, and a mismatched sub-resource fails a minute later. Without the refetch the owner sees a success toast and a list that never shows the failure.

The success message says *requested*, not *created*. Nothing works until the far-side admin approves it, and overclaiming here produces a support ticket a day later.

---

## Step 5 — delete

Add `DeletePrivateEndpoint` to the app first.

Container `PeDeleteConfirm`, `Visible` = `!IsBlank(varPeDeleteId)`.

| Control | Property | Value |
|---|---|---|
| `LblPeDeleteWarn` | `Text` | see below |
| `TxtPeDeleteConfirm` | text input | the owner types the endpoint name |
| `BtnPeDeleteCancel` | `OnSelect` | `Set(varPeDeleteId, ""); Reset(TxtPeDeleteConfirm)` |
| `BtnPeDeleteGo` | `DisplayMode` | `If(Trim(TxtPeDeleteConfirm.Text) = LookUp(colPrivateEndpoints, peId = varPeDeleteId).peName, DisplayMode.Edit, DisplayMode.Disabled)` |

Warning text:

```
"Deleting this endpoint breaks any workload using it, immediately. Recreating it takes at least 15 minutes and needs a fresh approval from the owner of the target resource. Type the endpoint name to confirm."
```

`BtnPeDeleteGo.OnSelect`:

```
Set(gblPeError, "");
IfError(
    With(
        { r: DeletePrivateEndpoint.Run(gblWsId, varPeDeleteId) },
        If(
            r.outcome = "Failed",
            Set(gblPeError, r.message),
            Notify("Delete accepted. The endpoint may show as Deleting for a short while.", NotificationType.Success)
        )
    ),
    Set(gblPeError, "Delete failed: " & FirstError.Message)
);
Set(varPeDeleteId, "");
Reset(TxtPeDeleteConfirm)
```

Then re-run the load block, exactly as Step 4d does.

**`NotFound` is not an error.** It means the endpoint was already gone — refresh and move on rather than alarming the owner.

**A row still present after a successful delete is not a failed delete.** Fabric returns `200` immediately and the endpoint then passes through `provisioningState: Deleting`. Let it render as its own state.

---

## Test matrix

| # | Setup | Expect |
|---|---|---|
| 1 | Workspace with no endpoints | Empty message, no flash of it on workspaces that *do* have some |
| 2 | Workspace with endpoints | Gallery lists them; `Succeeded` + `Pending` renders normally, not as an error |
| 3 | Create against a 1:1 type (`Microsoft.Sql/servers`) | Sub-resource resolves to `sqlServer` automatically, no dropdown |
| 4 | Create against a storage account | Dropdown offers five options with no default; Create disabled until one is picked |
| 5 | Create with a name already in use | Create disabled, inline error on the name field |
| 6 | Create with the same resource ID **and** sub-resource | Create disabled, inline error |
| 7 | Create `blob`, then `dfs`, on the same storage account | **Both allowed** — this is the case the duplicate check must not block |
| 8 | Create with a deliberately wrong sub-resource | Success toast, then the refreshed list shows `Failed` with the explanatory label |
| 9 | Delete | Typed-name confirmation required; row shows `Deleting` on refresh |
| 10 | Switch workspaces, return to the tab | No stale rows from the previous workspace |

Test 7 is the one worth doing deliberately — it is the case a naive duplicate check breaks, and the failure would only surface for owners using ADLS.

---

## Known limitations

- **No auto-refresh.** `Provisioning` and `Pending` are states owners will watch; they must press refresh. A timer was considered and left out — polling every workspace's endpoints on a timer is a lot of flow runs to save one click.
- **Approval cannot be done here.** It happens in the Azure portal, by the data source admin. There is no Fabric API for it and the app must not imply otherwise.
- **No authorization check.** The three flows take `gblWsId` at face value. This tab must not ship before the `crbab_Workspaces` ownership check (OPEN-ISSUES F5.9) — a forged call to `DeletePrivateEndpoint` breaks a live data path in someone else's workspace.
- **No `targetFQDNs` support**, so Private Link Service targets are out of scope and deliberately absent from the sub-resource table.
