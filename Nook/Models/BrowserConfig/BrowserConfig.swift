//
//  BrowserConfig.swift
//  Nook
//
//  Created by Maciek Bagiński on 31/07/2025.
//
//  Canvas/Kaltura + DRM sanity checklist (all must be true for reliable LMS/DRM playback):
//  1. Shared process pool across all tabs (no per-tab pool).
//  2. Persistent WKWebsiteDataStore.default() (no nonPersistent()).
//  3. UA override only for Canvas/Kaltura domains (Tab.swift CanvasKalturaUserAgent).
//  4. Inline media playback enabled; no user gesture required for media (below).
//  5. Storage Access API injected for Canvas/Kaltura (CanvasKalturaCompatibilityManager).
//  6. Content blockers disabled only for LMS domains (TrackingProtectionManager.isCanvasOrKalturaHost).
//  7. Keychain + Touch ID for passwords (PasswordManager); do not store in app sandbox.
//  8. Do not disable allowsAirPlayForMediaPlayback or require user action for FairPlay/EME.
//

import AppKit
import SwiftUI
import WebKit

class BrowserConfiguration {
    static let shared = BrowserConfiguration()
    
    private init() {}

    lazy var webViewConfiguration: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()

        // 1–2: Canvas/Kaltura compatibility: shared process pool and persistent data store.
        // All WKWebViews must share one WKProcessPool; per-tab pools break cross-frame auth
        // (e.g. sso.canvaslms.com post_message_forwarding, Kaltura iframe handshake).
        // Use WKWebsiteDataStore.default() so cookies and storage persist across tabs.
        config.processPool = BrowserEnvironment.shared.processPool
        config.websiteDataStore = BrowserEnvironment.shared.dataStore

        // Full JavaScript and iframe support so Canvas LMS / Kaltura postMessage and SSO work.
        // Safari effectively enables these; custom WebKit browsers often disable them and break iframe auth.
        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = pagePrefs
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        // Iframe / file URL access: allow so Canvas/Kaltura iframe chains and window.postMessage work.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        // MARK: - 4 & 8: Inline media + DRM / FairPlay (Canvas/Kaltura + Netflix/Disney+/Spotify)
        // allowsInlineMediaPlayback: required so Kaltura/Canvas videos don't force fullscreen or fail autoplay.
        // mediaTypesRequiringUserActionForPlayback = []: no user gesture required; Canvas can fail if autoplay is blocked.
        // Do NOT disable allowsAirPlayForMediaPlayback or add user-action requirements for FairPlay/EME.
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.setValue(true, forKey: "allowsInlineMediaPlayback")
        config.preferences.setValue(true, forKey: "mediaDevicesEnabled")
        config.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        config.preferences.isElementFullscreenEnabled = true
        config.allowsAirPlayForMediaPlayback = true
        
        // User agent for better compatibility with Client Hints support
        config.applicationNameForUserAgent = "Version/26.0.1 Safari/605.1.15"

        // Web inspector will be enabled per-webview using isInspectable property
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Note: webExtensionController will be set by ExtensionManager during initialization
        // Note: WebAuthn/Passkey support is enabled by default in WKWebView on macOS 13.3+
        // and requires only: entitlements, WKUIDelegate methods, and Info.plist descriptions

        // BEGIN CUSTOM MODIFICATION — custom feature scripts (Canvas/Kaltura, password, credit card)
        for script in CustomFeatureRegistry.sharedUserScripts() {
            config.userContentController.addUserScript(script)
        }
        // END CUSTOM MODIFICATION

        // Canopy Ad Blocker: inject cosmetic, tracker stub, and scriptlet user scripts
        for script in CanopyAdBlockManager.canopyUserScripts() {
            config.userContentController.addUserScript(script)
        }
        config.userContentController.addUserScript(CanopyStatsManager.countingScript())
        config.userContentController.addUserScript(CanopyLinkCleaner.ampDetectionScript())

        // Canopy: trim referrer to origin-only for cross-site navigations
        let referrerTrimScript = WKUserScript(
            source: """
            (function() {
                try {
                    var host = location.hostname.toLowerCase();
                    if (host.endsWith('.google.com') || host === 'google.com') return;
                    if (host.endsWith('.googleapis.com') || host.endsWith('.gstatic.com')) return;
                    if (host.endsWith('.youtube.com') || host === 'youtube.com') return;
                    if (document.referrer && !document.referrer.startsWith(location.origin)) {
                        Object.defineProperty(document, 'referrer', {
                            get: function() {
                                try { return new URL(document.referrer).origin + '/'; } catch(e) { return ''; }
                            }
                        });
                    }
                } catch(e) {}
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(referrerTrimScript)

        // Canopy extras: Spotify ad skip, cookie consent dismiss, subresource param stripping
        config.userContentController.addUserScript(CanopyExtras.spotifyAdScript())
        config.userContentController.addUserScript(CanopyExtras.cookieConsentScript())
        config.userContentController.addUserScript(CanopyExtras.subresourceParamScript())

        // Canopy: stub scheme for redirected ad-library scripts
        config.setURLSchemeHandler(NookStubProvider.shared, forURLScheme: "nookstub")

        return config
    }()

    // Creates a fresh WKUserContentController but preserves shared user scripts
    // (e.g., extension bridge scripts). This avoids cross-tab handler conflicts
    // while keeping scripts that must be present on every tab.
    func freshUserContentController() -> WKUserContentController {
        let controller = WKUserContentController()
        for script in webViewConfiguration.userContentController.userScripts {
            controller.addUserScript(script)
        }
        return controller
    }

    // MARK: - Cache-Optimized Configuration
    // Derives from shared config to preserve process pool + extension controller
    func cacheOptimizedWebViewConfiguration() -> WKWebViewConfiguration {
        let config = webViewConfiguration.copy() as! WKWebViewConfiguration
        config.userContentController = freshUserContentController()
        return config
    }

    // MARK: - Profile-Aware Configurations
    // Derive from the shared config so extension controller + process pool are inherited
    func webViewConfiguration(for profile: Profile) -> WKWebViewConfiguration {
        let config = webViewConfiguration.copy() as! WKWebViewConfiguration

        // Fresh UCC per tab to avoid cross-tab handler conflicts (preserves shared scripts)
        config.userContentController = freshUserContentController()

        // Force re-assignment of the extension controller so WebKit binds it to the new userContentController.
        // Without this, content scripts fail to inject into new tabs because the controller is still
        // bound to the shared configuration's old UCC.
        if #available(macOS 15.4, *) {
            if let extCtrl = webViewConfiguration.webExtensionController {
                config.webExtensionController = extCtrl
            }
        }

        // Use shared data store so all tabs/popups/iframes share cookies and auth (Canvas, Kaltura, Google).
        config.websiteDataStore = BrowserEnvironment.shared.dataStore

        // Re-apply Canvas/Kaltura iframe keys in case copy() did not preserve them (postMessage / universal access).
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        return config
    }

    // Returns a profile-scoped configuration with cache/perf optimizations applied
    func cacheOptimizedWebViewConfiguration(for profile: Profile) -> WKWebViewConfiguration {
        let config = webViewConfiguration(for: profile)
        // Enable aggressive caching and media capabilities (mirror default optimized config)
        config.preferences.setValue(true, forKey: "allowsInlineMediaPlayback")
        config.preferences.setValue(true, forKey: "mediaDevicesEnabled")
        config.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        
        return config
    }

    // MARK: - Chrome Web Store Integration
    
    /// Get the Web Store injector script
    static func webStoreInjectorScript() -> WKUserScript? {
        guard let scriptPath = Bundle.main.path(forResource: "WebStoreInjector", ofType: "js"),
              let scriptSource = try? String(contentsOfFile: scriptPath, encoding: .utf8) else {
            return nil
        }
        
        return WKUserScript(
            source: scriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }
    
    /// Check if URL is a Chrome Web Store page
    static func isChromeWebStore(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        
        // Check for Chrome Web Store
        if host.contains("chrome.google.com") && path.contains("webstore") {
            return true
        }
        
        // Check for new Chrome Web Store
        if host.contains("chromewebstore.google.com") {
            return true
        }
        
        // Check for Microsoft Edge Add-ons
        if host.contains("microsoftedge.microsoft.com") && path.contains("addons") {
            return true
        }
        
        return false
    }

}
