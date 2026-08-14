# Git tab — connect form fixes

Three defects in the `GitNotConnected` wizard, raised 2026-08-12. Step-by-step fix.

The canonical build instructions in [docs/APP-GIT-TAB.md](docs/APP-GIT-TAB.md) (steps 2d, 3b, 3c) have already been updated to match, so a rebuild from scratch produces the fixed version. This file is for patching the app that exists now.

---

## Symptoms

1. Opening the Git tab on a workspace that is **not** connected shows a connection already chosen in the dropdown, plus branch and directory values left over from the previous workspace.
2. The dropdown lists connection **names** only, so several connections pointing at different repositories look identical.
3. The dropdown accepts **multiple** selections.

---

## Why it happens

**1 — leftover values.** Canvas controls keep their state for the lifetime of the app session. A screen's `OnVisible` does not reset them, and `Default` is applied only on first render or after an explicit reset. So `CmbGitConn.Selected`, `TxtGitBranch.Text` and `TxtGitDir.Text` survive a change of workspace.

The dropdown is the worst of the three, and for a reason that is easy to miss: `ListMyConnections` takes **no `workspaceId`** — it returns the signed-in user's connections, which are the same set on every workspace. Reloading `colGitConns` therefore re-creates the very record that was selected, so the selection sticks instead of being invalidated. The form looks pre-filled and correct when it is neither.

This is not cosmetic. A owner who does not notice can connect a workspace to the wrong repository in two clicks, and there is no update API — fixing it means disconnect and reconnect, which re-runs initialization.

**2 — unhelpful labels.** `DisplayFields` was `["displayName"]`. Connection names are free text chosen by whoever created the connection and frequently describe the team, not the repository. A combo box can display more than one field, so the URL can sit under the name.

**3 — multi-select.** `SelectMultiple` defaults to **true** on a classic combo box. `CmbGitConn.Selected` returns the first item regardless, so a second pick is accepted and then silently ignored.

---

## Fix

### 1. `CmbGitConn` properties

Tree view → `GitContent` → `GitNotConnected` → `CmbGitConn`.

| Property | Set to |
|---|---|
| `SelectMultiple` | `false` |
| `DisplayFields` | `["displayName", "path"]` |
| `SearchFields` | `["displayName", "path"]` |
| `DefaultSelectedItems` | leave **empty** |

`DisplayFields` and `SearchFields` are edited in the properties pane under **Fields → Edit**, not typed into the formula bar. Both fields already exist on `colGitConns`, so no formula change is needed for this step.

Two display fields render as two stacked lines per row — name above, repository URL below — and the URL matches what `LblGitConnPath` shows once a row is picked. Raise the combo box `Height` if the rows crowd.

If `DefaultSelectedItems` holds anything, clear it. A value there re-applies a selection after every reset and defeats step 3.

### 2. Nothing to change in the load block

An earlier version of this fix added a computed `label` field to `colGitConns`. It is not needed — `displayName` and `path` are already collected, and the combo box can display both directly. If you added `label`, it is harmless; drop it next time you edit `BtnGit.OnSelect` and `IcoGitRefresh.OnSelect`.

The blocks in [docs/APP-GIT-TAB.md](docs/APP-GIT-TAB.md) step 3b are the current version and do **not** contain `label`.

### 3. Reset the form on entry

Add three lines to `BtnGit.OnSelect`, immediately after `Set(gblGitLoaded, false);` and before the first `IfError(`:

```
Reset(CmbGitConn);
Reset(TxtGitBranch);
Reset(TxtGitDir);
```

`Reset()` returns each control to its `Default` — blank for the combo box, `main` for the branch, `/` for the directory. That is why the branch and directory defaults are set as `Default` and not as literal text.

**Do not add these to `IcoGitRefresh.OnSelect`.** Refresh is meant to pick up a connection the owner has just created in Fabric without losing what they have already typed. The icon lives inside `GitConnected` and so is not reachable from the wizard today, but that will not survive a redesign.

Entering through the tab button is the only route to the wizard, so `BtnGit.OnSelect` is the only place this is needed. `Form Screen.OnVisible` opens on the Outbound tab.

---

## Verify

| # | Steps | Expect |
|---|---|---|
| 1 | Open `ab_demo_git2` → Git tab. Pick a connection, type a branch and directory. Go Back, open `ab_demo_git2` again → Git tab | Empty dropdown, branch `main`, directory `/` |
| 2 | Same, but return to a **different** unconnected workspace | Same — no carry-over |
| 3 | Open the dropdown | Each row shows the connection name with its repository URL beneath |
| 4 | Click a second item in the dropdown | Selection replaces the first; no second chip appears |
| 5 | Connect normally | Unchanged behaviour — `org`, `project`, `repo` still resolve |

Test 2 is the one that matters. Test 1 can pass on cached state alone.

---

## Not fixed here

`TxtGitDir` still defaults to `/`, and a root-level connect is **untested** — it is the leading suspect for the unexplained `400 UnknownError` from `initializeConnection` recorded in [docs/OPEN-ISSUES.md](docs/OPEN-ISSUES.md). Every successful connect so far has used a named folder. Changing that default is a separate decision, not part of this fix.
