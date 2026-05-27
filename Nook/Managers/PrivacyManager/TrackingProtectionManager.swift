//
//  TrackingProtectionManager.swift
//  Nook
//
//  Provides opt-in cross-site tracking protections using a combination of
//  WKContentRuleList (tracker domain/resource blocking) and a conservative
//  third‑party storage shim for iframes. New and existing WKWebViews are updated
//  when the setting changes.
//
//  Canvas/Kaltura: Content blocking is disabled per-WebView when the top-level URL
//  is a Canvas or Kaltura domain (see isCanvasOrKalturaHost). This ensures Canvas LMS
//  and Kaltura embedded video players load correctly; otherwise blocked scripts/analytics
//  can cause the player to falsely report third-party cookies as blocked.
//
import Foundation
import WebKit

@MainActor
final class TrackingProtectionManager {
    weak var browserManager: BrowserManager?
    private(set) var isEnabled: Bool = false

    /// Bump version when rule JSON changes so WKContentRuleListStore doesn't reuse an old cached list.
    private let ruleListIdentifier = "NookTrackingBlocker4"
    private var installedRuleList: WKContentRuleList?
    private var thirdPartyCookieScript: WKUserScript {
        // Disable document.cookie in third‑party iframes only (never main-frame).
        // Skip Canvas LMS and Kaltura iframes so embedded video and cross-domain auth work.
        let js = """
        (function() {
          try {
            if (window.top === window) return;
            var host = (window.location && window.location.hostname) || '';
            var h = host.toLowerCase();
            function isCanvasKaltura() {
              return (h === 'canvaslms.com' || h.endsWith('.canvaslms.com')) ||
                (h === 'instructure.com' || h.endsWith('.instructure.com')) ||
                (h === 'instructuremedia.com' || h.endsWith('.instructuremedia.com')) ||
                (h === 'kaltura.com' || h.endsWith('.kaltura.com')) ||
                (h === 'kaf.kaltura.com' || h.endsWith('.kaf.kaltura.com')) ||
                (h === 'kalturausercontent.com' || h.endsWith('.kalturausercontent.com')) ||
                (h === 'canvas.liberty.edu');
            }
            if (isCanvasKaltura()) return;
            var ref = document.referrer || "";
            var thirdParty = false;
            try {
              var refHost = ref ? new URL(ref).hostname : null;
              thirdParty = !!refHost && refHost !== host;
            } catch (e) { thirdParty = false; }
            if (!thirdParty) return;
            Object.defineProperty(document, 'cookie', {
              configurable: false,
              enumerable: false,
              get: function() { return ''; },
              set: function(_) { return true; }
            });
            try {
              document.requestStorageAccess = function() { return Promise.reject(new DOMException('Blocked by Nook', 'NotAllowedError')); };
            } catch (e) {}
          } catch (e) {}
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    // MARK: - Exceptions
    private var temporarilyDisabledTabs: [UUID: Date] = [:]
    private var allowedDomains: Set<String> = []

    func isTemporarilyDisabled(tabId: UUID) -> Bool {
        if let until = temporarilyDisabledTabs[tabId] {
            if until > Date() { return true }
            temporarilyDisabledTabs.removeValue(forKey: tabId)
        }
        return false
    }

    func disableTemporarily(for tab: Tab, duration: TimeInterval) {
        let until = Date().addingTimeInterval(duration)
        temporarilyDisabledTabs[tab.id] = until
        if let wv = tab.webView {
            removeTracking(from: wv)
            wv.reloadFromOrigin()
        }
        // Schedule re-apply after expiration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak tab] in
            guard let self, let tab else { return }
            // Cleanup expired entry
            if let exp = self.temporarilyDisabledTabs[tab.id], exp <= Date() {
                self.temporarilyDisabledTabs.removeValue(forKey: tab.id)
                if self.shouldApplyTracking(to: tab), let wv = tab.webView {
                    self.applyTracking(to: wv)
                    wv.reloadFromOrigin()
                }
            }
        }
    }

    func allowDomain(_ host: String, allowed: Bool = true) {
        let norm = host.lowercased()
        if allowed { allowedDomains.insert(norm) } else { allowedDomains.remove(norm) }
        // Update existing views for this host
        if let bm = browserManager {
            for tab in bm.tabManager.allTabs() {
                if tab.webView?.url?.host?.lowercased() == norm, let wv = tab.webView {
                    if allowed { removeTracking(from: wv) } else { applyTracking(to: wv) }
                    wv.reloadFromOrigin()
                }
            }
        }
    }

    func isDomainAllowed(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return allowedDomains.contains(h)
    }

    func attach(browserManager: BrowserManager) {
        self.browserManager = browserManager
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        Task { @MainActor in
            if enabled {
                await installRuleListIfNeeded()
                applyToSharedConfiguration()
                applyToExistingWebViews()
            } else {
                removeFromSharedConfiguration()
                removeFromExistingWebViews()
            }
        }
    }

    // MARK: - Installation
    private func installRuleListIfNeeded() async {
        // Try to fetch a cached compiled list first
        guard let store = WKContentRuleListStore.default() else { return }
        if let existing = await withCheckedContinuation({ (cont: CheckedContinuation<WKContentRuleList?, Never>) in
            store.lookUpContentRuleList(forIdentifier: ruleListIdentifier) { list, _ in cont.resume(returning: list) }
        }) {
            self.installedRuleList = existing
            return
        }

        // Compile JSON rules (attempt cookie‑blocking first, then fallback to domain blocks only)
        let rules = Self.makeRuleJSON()
        var compiled = await withCheckedContinuation { (cont: CheckedContinuation<WKContentRuleList?, Never>) in
            store.compileContentRuleList(forIdentifier: ruleListIdentifier, encodedContentRuleList: rules) { list, error in
                if let error { print("[TrackingProtection] Rule compile error: \(error)") }
                cont.resume(returning: list)
            }
        }
        if compiled == nil {
            let fallback = Self.makeRuleJSON(blockCookies: false)
            compiled = await withCheckedContinuation { (cont: CheckedContinuation<WKContentRuleList?, Never>) in
                store.compileContentRuleList(forIdentifier: ruleListIdentifier + ".fallback", encodedContentRuleList: fallback) { list, error in
                    if let error { print("[TrackingProtection] Fallback rule compile error: \(error)") }
                    cont.resume(returning: list)
                }
            }
        }
        if let compiled { self.installedRuleList = compiled }
    }

    private func applyToSharedConfiguration() {
        // Do NOT add the rule list to shared config. New webviews would then get it before we know the tab URL.
        // We only add the rule list per-webview in applyTracking(), and only when shouldApplyTracking(to:) is true (not on Google/sign-in).
        // Ensure the third-party cookie script is in shared config so it's available when we apply tracking to a webview.
        let config = BrowserConfiguration.shared.webViewConfiguration
        let ucc = config.userContentController
        ucc.removeAllContentRuleLists()
        if !ucc.userScripts.contains(where: { $0.source.contains("document.referrer") }) {
            ucc.addUserScript(thirdPartyCookieScript)
        }
    }

    private func removeFromSharedConfiguration() {
        let config = BrowserConfiguration.shared.webViewConfiguration
        let ucc = config.userContentController
        ucc.removeAllContentRuleLists()
        // Remove our specific script (identified by referrer check)
        let remaining = ucc.userScripts.filter { !$0.source.contains("document.referrer") }
        ucc.removeAllUserScripts()
        remaining.forEach { ucc.addUserScript($0) }
    }

    private func applyToExistingWebViews() {
        guard let bm = browserManager else { return }
        let allTabs = bm.tabManager.allTabs()
        for tab in allTabs {
            guard let wv = tab.webView else { continue }
            if shouldApplyTracking(to: tab) {
                applyTracking(to: wv)
            } else {
                removeTracking(from: wv)
            }
            // Reload to apply rules consistently
            wv.reloadFromOrigin()
        }
    }

    private func removeFromExistingWebViews() {
        guard let bm = browserManager else { return }
        let allTabs = bm.tabManager.allTabs()
        for tab in allTabs {
            guard let wv = tab.webView else { continue }
            removeTracking(from: wv)
            wv.reloadFromOrigin()
        }
    }

    // MARK: - Per-WebView helpers
    private func shouldApplyTracking(to tab: Tab) -> Bool {
        if !isEnabled { return false }
        if isTemporarilyDisabled(tabId: tab.id) { return false }
        if isDomainAllowed(tab.webView?.url?.host) { return false }
        if isCanvasOrKalturaHost(tab.url.host) { return false }
        if isCanvasOrKalturaHost(tab.webView?.url?.host) { return false }
        if isSignInProviderHost(tab.url.host) || isSignInProviderHost(tab.webView?.url?.host) { return false }
        if isAppHostThatNeedsThirdPartyServices(tab.url.host) || isAppHostThatNeedsThirdPartyServices(tab.webView?.url?.host) { return false }
        if tab.isOAuthFlow { return false }
        return true
    }

    /// Major sign-in providers (Google, Microsoft, Apple, etc.) need cross-site cookies; don't apply tracking so sign-in and password manager work.
    private func isSignInProviderHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        return OAuthDetector.matchesKnownProvider(host: h)
    }

    /// App hosts that rely on third-party services (e.g. Sentry, Google auth); don't apply tracking so the app works.
    private func isAppHostThatNeedsThirdPartyServices(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        // vidIQ itself and YouTube both rely heavily on Google endpoints like play.google.com/log.
        // Blocking those beacons breaks extensions and first-party behavior, so we disable our
        // tracking protection on these hosts and let user-installed blockers handle it instead.
        return h == "vidiq.com" || h.hasSuffix(".vidiq.com")
            || h == "youtube.com" || h.hasSuffix(".youtube.com")
    }

    /// Canvas LMS and Kaltura: content blocking is disabled for these hosts so scripts and analytics
    /// used by Canvas and Kaltura embedded video players can load. Otherwise the Kaltura player may
    /// incorrectly report that third-party cookies are blocked. Domains: *.instructure.com,
    /// *.canvaslms.com, *.kaltura.com, *.kaf.kaltura.com, canvas.liberty.edu. Do NOT disable
    /// content blocking globally—only for these domains.
    private func isCanvasOrKalturaHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        return h == "canvaslms.com" || h.hasSuffix(".canvaslms.com")
            || h == "instructure.com" || h.hasSuffix(".instructure.com")
            || h == "instructuremedia.com" || h.hasSuffix(".instructuremedia.com")
            || h == "kaltura.com" || h.hasSuffix(".kaltura.com")
            || h == "kaf.kaltura.com" || h.hasSuffix(".kaf.kaltura.com")
            || h == "kalturausercontent.com" || h.hasSuffix(".kalturausercontent.com")
            || h == "canvas.liberty.edu"
    }

    private func applyTracking(to webView: WKWebView) {
        guard let list = installedRuleList else { return }
        let ucc = webView.configuration.userContentController
        ucc.removeAllContentRuleLists()
        ucc.add(list)
        if !ucc.userScripts.contains(where: { $0.source.contains("document.referrer") }) {
            ucc.addUserScript(thirdPartyCookieScript)
        }
    }

    private func removeTracking(from webView: WKWebView) {
        let ucc = webView.configuration.userContentController
        ucc.removeAllContentRuleLists()
        // Remove our specific script (identified by referrer check)
        let remaining = ucc.userScripts.filter { !$0.source.contains("document.referrer") }
        ucc.removeAllUserScripts()
        remaining.forEach { ucc.addUserScript($0) }
    }

    func refreshFor(tab: Tab) {
        guard let wv = tab.webView else { return }
        if shouldApplyTracking(to: tab) {
            applyTracking(to: wv)
        } else {
            removeTracking(from: wv)
        }
        wv.reloadFromOrigin()
    }

    /// Updates tracking state after main-frame navigation (e.g. user navigated to Canvas). Removes tracking when on Canvas/Kaltura without reload; re-applies and reloads when leaving.
    func refreshForTabAfterNavigation(tab: Tab) {
        guard let wv = tab.webView else { return }
        if shouldApplyTracking(to: tab) {
            applyTracking(to: wv)
        } else {
            removeTracking(from: wv)
        }
    }

    /// Call before allowing a main-frame navigation: if the destination is Canvas/Kaltura, remove our content blocker
    /// and third-party cookie script from the webview immediately so the new page and all subresources (e.g. CloudFront
    /// chunks, RCE scripts) load without being blocked. Prevents ChunkLoadError and blank embeds.
    func removeTrackingIfNavigatingToCanvasKaltura(from webView: WKWebView, host: String?) {
        guard isCanvasOrKalturaHost(host) else { return }
        removeTracking(from: webView)
    }

    // MARK: - Rules
    /// Regex patterns for main document URL: when top URL matches any of these, we don't block (search, sign-in, first-party assets).
    /// WKContentRuleList unless-top-url uses regex; .* matches any chars, \\. is literal dot.
    /// Top-level URL regexes: when the main document URL matches, we don't apply blocker rules (e.g. Canvas/Kaltura, Google).
    /// When top document URL matches any of these, no content rule fires. Includes Canvas CDN (CloudFront) so RCE chunks load.
    private static let topURLExceptions: [String] = [
        ".*google\\.com.*", ".*accounts\\.google\\.com.*", ".*play\\.google\\.com.*", ".*gstatic\\.com.*",
        ".*canvaslms\\.com.*", ".*instructure\\.com.*", ".*instructuremedia\\.com.*", ".*kaltura\\.com.*", ".*kaf\\.kaltura\\.com.*", ".*kalturausercontent\\.com.*",
        ".*canvas\\.liberty\\.edu.*",
        ".*cloudfront\\.net.*"
    ]

    private static func makeRuleJSON(blockCookies: Bool = true) -> String {
        // Small built-in list of common tracking hosts and a generic third‑party cookie block.
        // If the 'block-cookies' action is unsupported, compile will fail; rule list store
        // will still return nil, and the manager will rely on domain block rules only.
        let trackers: [String] = [
            "google-analytics\\.com",
            "analytics\\.google\\.com",
            "googletagmanager\\.com",
            "googletagservices\\.com",
            "doubleclick\\.net",
            "facebook\\.net",
            "connect\\.facebook\\.net",
            "graph\\.facebook\\.com",
            "adsystem\\.com",
            "adservice\\.google\\.com",
            "hotjar\\.com",
            "segment\\.io",
            "cdn\\.segment\\.com",
            "mixpanel\\.com",
            "sentry\\.io",
            "optimizely\\.com",
            "newrelic\\.com",
            "clarity\\.ms",
        ]

        var rules: [[String: Any]] = []
        if blockCookies {
            // Third‑party cookie block; allow when top frame is Canvas/Kaltura or Google so sign-in and search work
            rules.append([
                "trigger": [
                    "url-filter": ".*",
                    "load-type": ["third-party"],
                    "unless-top-url": topURLExceptions
                ],
                "action": ["type": "block-cookies"]
            ])
        }

        for host in trackers {
            // Don't block tracker URLs when user is on Google (avoids breaking www.google.com first-party resources)
            rules.append([
                "trigger": [
                    "url-filter": host,
                    "unless-top-url": topURLExceptions
                ],
                "action": ["type": "block"]
            ])
        }

        // Encode to JSON
        if let data = try? JSONSerialization.data(withJSONObject: rules, options: []),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "[]"
    }
}
