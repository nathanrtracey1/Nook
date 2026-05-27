# Syncing with Upstream Nook Browser

This document describes how to keep this repository synchronized with the official [Nook Browser](https://github.com/nook-browser/Nook) project while preserving local customizations.

## Recommended update workflow

Run these commands whenever you want to pull in the latest changes from upstream:

```bash
git fetch upstream
git checkout main
git merge upstream/main
git checkout custom-dev
git rebase main
```

**What each step does:**

- **`git fetch upstream`** — Downloads the latest commits from the official Nook repo (no local branches are changed yet).
- **`git checkout main`** — Switches to your local `main` branch, which is intended to mirror upstream.
- **`git merge upstream/main`** — Updates local `main` to match upstream `main` (fast-forward when possible).
- **`git checkout custom-dev`** — Switches to your customization branch.
- **`git rebase main`** — Replays your custom commits on top of the updated `main`, reducing merge conflicts and keeping history linear.

After rebasing, resolve any conflicts in the “custom” areas listed below, then run `git add` and `git rebase --continue` until the rebase finishes.

## Branch roles

| Branch       | Role |
|-------------|------|
| **`main`**  | Tracks upstream Nook. Keep it clean of custom features so merges from `upstream/main` stay simple. |
| **`custom-dev`** | Holds your modifications and ongoing work. Rebase onto `main` after every upstream sync. |

## Remotes

- **`origin`** — Your fork (or the repo you push to). Set this to your own fork URL if you use one.
- **`upstream`** — The official Nook Browser repository: `https://github.com/nook-browser/Nook.git`

## Where customizations live

To make upstream syncs and conflict resolution easier, customizations are grouped as follows.

### Core upstream areas (minimize changes)

Try to avoid editing these except for small, well-marked hooks:

- **WebKit / WKWebView** — `Nook/Models/BrowserConfig/`, configuration and profile-aware configs.
- **Navigation & networking** — `Nook/Models/Tab/` (tab lifecycle, navigation delegate, loading state).
- **Rendering / window layout** — `App/Window/WindowView.swift`, `Nook/Components/WebsiteView/`.
- **Cookie and privacy** — `Nook/Managers/PrivacyManager/`, tracking protection, cookie policies.
- **Build and app entry** — `Nook.xcodeproj`, `App/NookApp.swift`, `App/AppDelegate.swift`, `Settings/NookSettingsService.swift`.

Any edits in these areas are wrapped in:

```text
// BEGIN CUSTOM MODIFICATION — <short description>
...
// END CUSTOM MODIFICATION
```

Search for these comments when resolving merge conflicts or when pulling upstream changes.

### Custom feature modules

- **`Nook/BrowserFeatures/`**  
  - **`CustomFeatureRegistry.swift`** — Single integration point for custom user scripts and script message handlers. Registers scripts (Canvas/Kaltura, password manager, credit card) and dispatches `nookPassword` / `nookCreditCard` to the right handlers.  
  - Other custom *logic* that plugs into the registry can live here or in dedicated subfolders.

- **`Nook/Managers/CanvasKalturaCompatibility/`** — Canvas LMS and Kaltura embedded video: storage access script and cookie sync. Wired into the app via `CustomFeatureRegistry` and `AppDelegate`.

- **`Nook/Managers/PasswordManager/`** — Saved passwords in Keychain, Touch ID, user script and message handling. Used by `CustomFeatureRegistry`.

- **`Nook/Managers/CreditCardManager/`** — Saved cards in Keychain, Touch ID, user script and message handling. Used by `CustomFeatureRegistry`.

- **`Nook/CustomUI/`**  
  - **`EditPinnedURLDialog.swift`** — “Edit Pinned URL…” dialog for pinned tabs. Used by sidebar and pinned grid.

- **`Nook/BrowserExtensions/`** — Reserved for future extension-related custom UI or logic (e.g. beyond the built-in WKWebExtension support).

### Customizations in upstream files

These files stay in their original locations but contain marked custom blocks:

- **`Nook/Models/BrowserConfig/BrowserConfig.swift`** — Adds scripts from `CustomFeatureRegistry`.
- **`Nook/Models/Tab/Tab.swift`** — Custom message handler dispatch via `CustomFeatureRegistry`; `estimatedProgress` and KVO.
- **`App/Window/WindowView.swift`** — Padding when “remove borders when sidebar hidden” is on; Arc-style loading indicator overlay.
- **`Settings/NookSettingsService.swift`** — `removeBordersWhenSidebarHidden` key, property, default, and init.
- **`Nook/Components/Settings/Tabs/Appearance.swift`** — Toggle for “Remove borders when sidebar is hidden”.
- **`Nook/Components/Settings/PrivacySettingsView.swift`** — Saved Passwords and Saved Cards sections.
- **`Nook/Components/WebsiteView/WebsiteLoadingIndicator.swift`** — Uses `tab.estimatedProgress` for progress width.
- **`Nook/Managers/TabManager/TabManager.swift`** — `updatePinnedTabURL(tab:newURL:)` for editable pinned URLs.
- **`App/AppDelegate.swift`** — Cookie policy and `CanvasKalturaCompatibilityManager.shared.start()`.

When merging or rebasing, pay special attention to these files and preserve the `// BEGIN CUSTOM MODIFICATION` … `// END CUSTOM MODIFICATION` sections while integrating upstream changes.

## Adding new custom features

1. **Scripts and message handlers**  
   - Implement the script and handler logic in the appropriate manager or a new type under `BrowserFeatures/` (or `Managers/`).  
   - Expose a `WKUserScript` and/or handler name and dispatch from **`CustomFeatureRegistry`** so `BrowserConfig` and `Tab` stay with a single, small integration point.

2. **UI and dialogs**  
   - Prefer new views or dialogs under **`CustomUI/`** (or a dedicated component folder) and call them from existing views, rather than embedding large custom blocks in core upstream files.

3. **Settings**  
   - Add new keys and properties in `NookSettingsService` (and optionally in a dedicated settings tab) and wrap them in `// BEGIN CUSTOM MODIFICATION` … `// END CUSTOM MODIFICATION` so they are easy to find during syncs.

4. **Site-specific enhancements**  
   - Keep scripts and assets under something like `SiteEnhancements/` or `BrowserFeatures/<FeatureName>/`, and inject from `Tab` (or a single helper used by `Tab`) only when the URL matches.

## Conflict resolution tips

- Prefer keeping upstream behavior outside the custom blocks and only adjusting the content *inside* `// BEGIN CUSTOM MODIFICATION` … `// END CUSTOM MODIFICATION` when resolving conflicts.
- If upstream adds or changes a method you override or call, update your custom code to match the new signature or behavior, and keep custom logic inside the marked blocks or in the custom modules above.
- After resolving conflicts, run a full build and a quick manual test of: loading a page, sidebar visibility, pinned tab edit, and password/card autofill (if enabled).

## Project and product identity

Do **not** rename the app (“Nook”), the project, or application identifiers (e.g. bundle ID) when syncing or customizing. This keeps the codebase clearly identifiable as Nook and avoids breaking references or tooling that expect the original names.
