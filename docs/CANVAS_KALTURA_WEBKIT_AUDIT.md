# Canvas LMS & Kaltura WebKit Compatibility Audit

This document summarizes the audit of Nook’s WebKit configuration for compatibility with Canvas LMS and embedded Kaltura videos. Canvas and Kaltura depend on cross-domain authentication, iframe communication, postMessage, and third-party cookies.

---

## 1. WKWebViewConfiguration uses a persistent data store

**Check:** `configuration.websiteDataStore = .default()` (or equivalent persistent store).

**Finding:**  
- **Shared base config** (`BrowserConfig.webViewConfiguration`): Uses `WKWebsiteDataStore.default()` (persistent).  
- **Profile-aware config** (`webViewConfiguration(for: profile)`): For the default profile (`profile.isDefault`), the config uses `WKWebsiteDataStore.default()`. For other profiles it uses `profile.dataStore` (persistent when not incognito).

**Result:** Default profile uses the system default persistent store. Canvas/Kaltura should be used with the default profile for full compatibility.

---

## 2. No nonPersistent or ephemeral store for Canvas/Kaltura

**Check:** Browser does not use a non-persistent or ephemeral website data store for normal Canvas use.

**Finding:**  
- **Default profile:** Uses `WKWebsiteDataStore.default()` — persistent.  
- **Other named profiles:** Use `WKWebsiteDataStore(forIdentifier:)` — persistent.  
- **Incognito/ephemeral profile:** Uses `WKWebsiteDataStore.nonPersistent()`; only when the user explicitly chooses the incognito profile.

**Result:** Canvas LMS and Kaltura are compatible when using the default (or any non-incognito) profile. Incognito uses a non-persistent store by design; cookies are not shared there.

---

## 3. Domain allowlist for cross-site authentication cookies

**Check:** Allowlist for cross-site auth cookies includes: canvaslms.com, instructure.com, sso.canvaslms.com, kaltura.com, kalturausercontent.com.

**Finding:**  
- **CanvasKalturaCompatibilityManager:** Cookie sync and Storage Access script use host suffixes: `canvaslms.com`, `.canvaslms.com`, `instructure.com`, `.instructure.com`, `kaltura.com`, `.kaltura.com`, `kalturausercontent.com`, `.kalturausercontent.com` (covers sso.canvaslms.com and all subdomains).  
- **TrackingProtectionManager:** Same domain set used so third-party cookie blocking and script neutering are skipped for these hosts.

**Result:** Domain allowlist is implemented and includes all requested domains (including sso.canvaslms.com via *.canvaslms.com).

---

## 4. Cookies preserved and synchronized with WKHTTPCookieStore

**Check:** Cookies from allowlisted domains are preserved and synchronized with WKHTTPCookieStore.

**Finding:**  
- **CanvasKalturaCompatibilityManager.performSync():** Reads all cookies from `WKWebsiteDataStore.default().httpCookieStore` (WKHTTPCookieStore), filters to allowlisted Canvas/Kaltura domains, and writes them to `HTTPCookieStorage.shared` so system and WebKit stay in sync.  
- Runs on start and every 60 seconds.  
- WebKit’s cookie store is the source of truth; sync ensures the system store is updated for any code that reads from it.

**Result:** Cookies for Canvas/Kaltura domains are preserved in the WebKit data store and synchronized from WKHTTPCookieStore to the system cookie storage.

---

## 5. Third-party cookies and custom cookie policies

**Check:** Third-party cookies not blocked by custom policies on Canvas/Kaltura.

**Finding:**  
- **Tracking protection** (`TrackingProtectionManager`): When “Block Cross-Site Tracking” is on, it (1) adds a content rule that blocks third-party cookies (`block-cookies` with `load-type: third-party`) and (2) injects a script that neuters `document.cookie` and `requestStorageAccess` in third-party iframes.  
- That would break Kaltura embeds in Canvas (Kaltura loads as a third-party iframe).

**Fixes applied:**  
1. **Content rule:** The third-party cookie rule uses `unless-top-url` so it does **not** run when the top frame is Canvas or Kaltura:  
   `["*canvaslms.com*", "*instructure.com*", "*kaltura.com*", "*kalturausercontent.com*"]`.  
2. **Script:** The third-party-cookie script skips any frame whose host is in the allowlist (canvaslms.com, instructure.com, kaltura.com, kalturausercontent.com and subdomains), so those iframes keep normal cookie and Storage Access behavior.  
3. **Per-tab:** Tabs whose main frame URL is on the allowlist are excluded from tracking protection (`shouldApplyTracking` returns false), so the rule list and script are removed for that tab and re-applied when navigating away (with a single reload only when re-applying).

**Result:** Third-party cookies and storage are allowed when the top frame or the iframe is on the Canvas/Kaltura allowlist.

---

## 6. Storage Access API (third-party iframes can request cookie access)

**Check:** Enable the Storage Access API so third-party iframes can request cookie access.

**Finding:**  
- **Canvas/Kaltura script** (`CanvasKalturaCompatibilityManager.storageAccessUserScript()`): Injects at document start (main and subframes) and calls `document.requestStorageAccess().catch(()=>{})` on allowlisted hosts (canvaslms.com, instructure.com, kaltura.com, kalturausercontent.com and subdomains).  
- **Tracking protection:** Does not override `requestStorageAccess` in allowlisted iframes; those frames keep the real API.

**Result:** Storage Access API is enabled for the allowlisted domains; third-party iframes on those domains can request cookie access.

---

## 7. window.postMessage between cross-origin frames

**Check:** No blocking of `window.postMessage` between origins.

**Finding:**  
- No code disables or intercepts `window.postMessage`.  
- The app uses `webkit.messageHandlers` and its own `postMessage`-based bridges; it does not restrict page-to-iframe or iframe-to-parent `postMessage`.

**Result:** Cross-domain `postMessage` is not restricted by the browser.

---

## 8. iframe sandbox (allow-scripts, allow-same-origin)

**Check:** iframe sandbox attributes are respected and not further restricted.

**Finding:**  
- Sandbox is controlled by the page’s iframe attributes.  
- WKWebView does not override or tighten sandbox; there is no custom handling of `allow-scripts` or `allow-same-origin` in the project.

**Result:** iframe sandbox is honored as set by the page.

---

## 9. Inline media playback and user-action requirements

**Check:** Enable inline media playback and disable unnecessary user-action requirements for media playback.

**Finding:**  
- `BrowserConfig`:  
  - `config.mediaTypesRequiringUserActionForPlayback = []` (no user gesture required for media).  
  - `config.preferences.setValue(true, forKey: "allowsInlineMediaPlayback")`.  
  - `config.preferences.setValue(true, forKey: "mediaDevicesEnabled")`.  
  - `config.preferences.isElementFullscreenEnabled = true`.  
- Same preferences are set in `cacheOptimizedWebViewConfiguration(for:)`.

**Result:** Inline and fullscreen media playback are enabled; no extra user-action requirement for playback.

---

## (Additional) IndexedDB, LocalStorage, SessionStorage

**Check:** All three storage mechanisms enabled.

**Finding:**  
- No `WKPreferences` or configuration disables these.  
- They are only referenced in code for cache/clear-data (e.g. `CacheManager`, `BrowserManager`).  
- With a persistent `WKWebsiteDataStore` (default or profile-specific), WebKit enables IndexedDB, Local Storage, and Session Storage by default.

**Result:** IndexedDB, LocalStorage, and SessionStorage are enabled.

---

## 10. Navigation delegates do not block cross-origin iframe navigation

**Check:** Verify navigation delegates do not block cross-origin iframe navigation.

**Finding:**  
- **Tab (WKNavigationDelegate):**  
  - `decidePolicyFor navigationAction`: calls `decisionHandler(.allow)` for all navigations except Option+click (Peek) and downloads. No check on `targetFrame` or request URL origin; subframes and cross-origin loads are allowed.  
  - `decidePolicyFor navigationResponse`: allows responses unless attachment or unshowable MIME for main frame.  
- No policy blocks subframes or cross-origin iframe navigation.

**Result:** Cross-origin iframe navigation is not blocked.

---

## (Additional) Scripts and Canvas/Kaltura authentication

**Check:** No injected scripts that break Canvas auth or Kaltura player init.

**Finding:**  
- **Canvas/Kaltura:** Only the compatibility script that (1) syncs cookies to the system store and (2) calls `requestStorageAccess()` on Canvas/Kaltura; it does not touch auth or player init.  
- **Password/Credit card:** Run on focus and do not modify Canvas/Kaltura auth flows.  
- **Tracking protection:** The third-party-cookie script now skips Canvas/Kaltura hosts, so it no longer interferes with auth or Kaltura in those iframes.

**Result:** Injected scripts do not interfere with Canvas authentication or Kaltura player initialization when the fixes above are in place.

---

## Summary of changes made (this audit)

| Area | Change |
|------|--------|
| **Domain allowlist** | Added `canvaslms.com` and `.canvaslms.com` to cookie sync, Storage Access script, tracking exceptions, and content rule `unless-top-url` (covers sso.canvaslms.com). |
| **Tracking protection – content rule** | Third-party cookie rule uses `unless-top-url` for `*canvaslms.com*`, `*instructure.com*`, `*kaltura.com*`, `*kalturausercontent.com*`. |
| **Tracking protection – script** | Third-party-cookie script skips frames whose host is on the allowlist (canvaslms.com, instructure.com, kaltura.com, kalturausercontent.com and subdomains). |
| **Tracking protection – per tab** | Tabs on allowlisted hosts are excluded from tracking protection; tracking is removed without reload when navigating to Canvas/Kaltura and re-applied (with one reload) when leaving. |
| **Navigation** | After main-frame load, `refreshForTabAfterNavigation(tab:)` is called so tracking state is updated when switching between Canvas/Kaltura and other sites. |

---

## Goal

Canvas LMS should authenticate normally and Kaltura video players embedded in course pages should load and play without login loops or blocked cookies. The audit and changes ensure:

1. **Persistent data store:** Default profile uses `WKWebsiteDataStore.default()`.  
2. **No nonPersistent/ephemeral for normal use:** Only the incognito profile uses a non-persistent store.  
3. **Domain allowlist:** canvaslms.com, instructure.com, sso.canvaslms.com, kaltura.com, kalturausercontent.com (and subdomains) are allowlisted for cookie sync and tracking exceptions.  
4. **Cookies preserved and synced:** Canvas/Kaltura cookies are kept in the WebKit store and synced from WKHTTPCookieStore to the system store.  
5. **Storage Access API:** Third-party iframes on allowlisted domains can request cookie access; the compatibility script calls `requestStorageAccess()` and tracking protection does not override it there.  
6. **postMessage:** Cross-origin `window.postMessage` is not blocked.  
7. **iframe sandbox:** allow-scripts and allow-same-origin are respected (no extra restriction by the app).  
8. **Inline media:** Inline playback is enabled and there is no extra user-action requirement for media.  
9. **Cross-origin iframe navigation:** Navigation delegates allow subframe and cross-origin navigation; nothing blocks iframe loads.
