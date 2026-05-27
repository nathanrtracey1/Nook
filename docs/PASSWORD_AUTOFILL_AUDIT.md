# WebKit Password Autofill Audit

**Goal:** Determine why the native macOS (iCloud Keychain) password suggestion UI does not appear when focusing login fields in WKWebView, and suggest minimal changes to restore or improve system autofill behavior.

**Note:** Apple’s documentation and forums indicate that [Password AutoFill and the system “Save Password” UI are designed for Safari/SFSafariViewController](https://developer.apple.com/documentation/security/password-autofill). WKWebView on macOS does **not** get the same level of system credential UI as Safari. The checks below explain why, in this project, native autofill is unlikely to appear and what can be adjusted to give it the best chance.

---

## 1. WKWebViewConfiguration and websiteDataStore

**Check:** Use default website data store for credential UI.

**Finding:**

- **Shared/base config** (`BrowserConfig.webViewConfiguration`): Uses `config.websiteDataStore = WKWebsiteDataStore.default()` ✅
- **Actual tab config:** WebViews are created with **profile-specific** configuration:
  - `WebViewCoordinator.createWebViewInternal` uses `BrowserConfiguration.shared.cacheOptimizedWebViewConfiguration(for: profile)` when a profile exists.
  - `BrowserConfiguration.webViewConfiguration(for: profile)` sets `config.websiteDataStore = profile.dataStore`.
- **Profile data store** (`Profile.createDataStore(for:)`):
  - On **macOS 15.4+**: `WKWebsiteDataStore(forIdentifier: profileId)` — a **custom persistent** store, **not** `.default()`.
  - On older macOS: falls back to `WKWebsiteDataStore.default()`.

**Conclusion:** For normal (non-incognito) browsing on macOS 15.4+, every tab uses a **custom persistent data store** keyed by profile ID. The system password autofill UI is tied to the **default** website data store. Using a custom store is a **primary reason** native macOS password autofill does not appear.

---

## 2. Non-persistent / ephemeral data store

**Check:** Avoid non-persistent or ephemeral store for credential UI.

**Finding:**

- **Incognito:** Uses `Profile.createEphemeral()` → `dataStore: .nonPersistent()`. No system autofill is expected there ✅ (by design).
- **Normal profiles:** Use persistent `WKWebsiteDataStore(forIdentifier:)`; not non-persistent ✅

**Conclusion:** Ephemeral is only used for incognito. The main issue for native autofill is use of a **custom** (non-default) store for normal profiles, not use of non-persistent.

---

## 3. WKPreferences and form / text interaction

**Check:** Nothing disables text interaction or form/credential detection.

**Finding:**

- `BrowserConfig`: `preferences.allowsContentJavaScript = true`, `javaScriptCanOpenWindowsAutomatically = true`, various media/fullscreen keys, `developerExtrasEnabled`. No preference that explicitly turns off forms or credentials.
- No use of private/undocumented keys that would disable credential or form detection.

**Conclusion:** No evidence that preferences are disabling form detection or text interaction. This is **not** a cause of missing native autofill.

---

## 4. Custom password manager and injected scripts

**Check:** Custom password logic and scripts that could prevent WebKit from detecting login fields.

**Finding:**

- **Custom feature:** `PasswordManager` (Keychain + Touch ID) with:
  - **User script** (`PasswordManager.userScript()`) injected via `CustomFeatureRegistry.sharedUserScripts()` into the **shared** config, so it runs in **all** pages:
    - Adds `focusin` / `focusout` listeners on login-related inputs.
    - On focus, posts `autofillRequest` to native code (Nook’s own popover).
    - Defines `window.__nookPasswordFill(username, password)` and uses it to set `inputs[0].value` and `pass.value` + dispatch `Event('input')`.
    - Listens for `submit` and posts `saveRequest` to native.
  - Script runs at **document end**, in **all frames** (`forMainFrameOnly: false`).
- **Impact:**
  - The script does **not** set `autocomplete="off"` or remove password fields.
  - It does **not** prevent the default focus behavior.
  - It **does** run before or alongside WebKit’s own handling and injects a **custom** autofill path (message to native → Nook popover → fill via JS). On macOS, WebKit’s built-in credential UI is already limited; a custom store (see §1) is the main blocker. The custom script does not obviously “disable” system autofill but provides a **separate** autofill mechanism that does not rely on the system UI.

**Conclusion:** Custom password manager and injected script are **not** the root cause of missing **native** UI, but they are the only autofill the user sees. The root cause is the use of a non-default data store (§1).

---

## 5. WKUIDelegate

**Check:** WKUIDelegate is set so WebKit can present UI (e.g. credential UI if supported).

**Finding:**

- `WebViewCoordinator`: `newWebView.uiDelegate = tab` (Tab is the delegate).
- `Tab`: Conforms to `WKUIDelegate` (e.g. `webView(_:createWebViewWith:for:windowFeatures:)` for popups). No override of credential-related delegate methods.
- No code sets `uiDelegate = nil` for normal tabs; nil is used only during cleanup.

**Conclusion:** WKUIDelegate is correctly assigned. There are no delegate methods in this project that would explicitly block credential UI. This is **not** a cause of missing native autofill.

---

## 6. JavaScript / DOM affecting password fields

**Check:** No JS or DOM changes that block or alter password inputs in a way that breaks credential detection.

**Finding:**

- **PasswordManager script:** Only reads and sets `input.value` and dispatches `Event('input')` when **Nook** autofill runs. It does not:
  - Set `autocomplete="off"` on inputs or form.
  - Remove or clone password fields.
  - Override `focus`/`blur` in a way that would prevent WebKit from seeing focus.
- **CreditCardManager:** Targets `autocomplete="cc-*"` and card fields; does not touch username/password.
- **Other scripts:** Canvas/Kaltura, tracking protection, extensions — none modify login form structure or password field attributes for credential detection.

**Conclusion:** No DOM or JS in this project is clearly **modifying** login forms so as to prevent WebKit from detecting them. Again, the main issue is the data store (§1).

---

## 7. Content blockers and extensions

**Check:** Content blockers or extensions blocking form/credential detection.

**Finding:**

- **TrackingProtectionManager:** Installs a `WKContentRuleList` (tracker blocking) and a third-party cookie script in iframes. Rules are resource/URL-based; they do not target form or credential scripts.
- **Extensions:** WKWebExtensionController is used; extensions can inject their own scripts. None of the project’s own code disables or filters “form detection” or credential scripts.

**Conclusion:** Content blockers and extensions in this project are **not** identified as a cause of missing native password UI.

---

## 8. Other modifications to login forms

**Check:** Any other code that might interfere with WebKit credential detection.

**Finding:**

- No code in the codebase sets `autocomplete="off"` on forms or password fields.
- No removal or structural changes to password/username fields.
- No overlay or view that would capture clicks before they reach the password field in a way that’s implemented in this repo (focus reaches the input; Nook’s script then runs).

**Conclusion:** No other login-form modifications found that would explain the missing native UI.

---

# Summary: Why native macOS password autofill does not appear

| # | Reason | Severity |
|---|--------|----------|
| 1 | **Non-default website data store** — On macOS 15.4+, all normal tabs use `WKWebsiteDataStore(forIdentifier: profileId)` instead of `WKWebsiteDataStore.default()`. System credential UI is tied to the default store, so native iCloud Keychain autofill does not appear. | **Primary** |
| 2 | **Platform limitation** — Apple’s design gives full password autofill and “Save Password” UI to Safari/SFSafariViewController; WKWebView on macOS does not get the same level of system credential UI even with the default store. | **Platform** |
| 3 | Custom password script and Nook popover do not disable WebKit’s detection but provide a separate path; they don’t fix the store or platform limitation. | N/A |

---

# Minimal changes to give system autofill the best chance

These are the smallest code changes that address what this project can control. They do **not** guarantee that the system bubble will appear (due to §2), but they remove the main config barrier.

## Option A: Use default data store for the “default” profile (recommended minimal change) — IMPLEMENTED

If the app has a notion of a single “default” profile (e.g. the one used for normal, non-incognito browsing), use the **default** website data store for that profile so it matches what the system uses for credentials.

**Implementation in this repo:**

1. **Profile** (`Profile.swift`): `isDefault` is now true when `name` is `"default"` or `"default profile"` (case-insensitive).
2. **BrowserConfiguration** (`BrowserConfig.swift`): In `webViewConfiguration(for: profile)`, when `profile.isDefault` is true, `config.websiteDataStore = WKWebsiteDataStore.default()`; otherwise `config.websiteDataStore = profile.dataStore`. No change to Profile creation or persistence.
3. **Entitlements:** Unchanged; not required for this minimal change.

**Result:** Tabs using the default profile (name “Default” or “Default Profile”) now use the system default website data store, giving the best chance for native macOS password autofill where WebKit supports it. Other profiles keep isolated stores.

## Option B: Make the password user script conditional (optional)

To avoid any theoretical interaction with WebKit’s own handling on the default store:

- Only inject `PasswordManager.userScript()` when the profile is **not** the default profile (or when a “Use system password UI” setting is on), so that for the default profile no custom focus/postMessage/fill path runs.
- Keep the script for other profiles so Nook’s own autofill still works there.

## Option C: Do nothing for native UI; rely on Nook’s autofill

- Keep current design: custom store per profile + Nook’s own password manager and popover.
- Improves compatibility with multi-profile isolation and avoids mixing credentials across profiles. Native macOS password UI will still not appear for the reasons above.

---

# References

- [Password AutoFill (Apple)](https://developer.apple.com/documentation/security/password-autofill)
- [WKWebsiteDataStore](https://developer.apple.com/documentation/webkit/wkwebsitedatastore)
- [WKWebView password autofill (Apple Developer Forums)](https://developer.apple.com/forums/thread/654338)
- This project: `BrowserConfig.swift`, `Profile.swift`, `WebViewCoordinator.swift`, `PasswordManager.swift`, `CustomFeatureRegistry.swift`
