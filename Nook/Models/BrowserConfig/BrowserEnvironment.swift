//
//  BrowserEnvironment.swift
//  Nook
//
//  Canvas/Kaltura compatibility: single shared WKProcessPool and WKWebsiteDataStore.default().
//  All WKWebViews must use config.processPool = shared.processPool and
//  config.websiteDataStore = shared.dataStore so cross-frame auth (Canvas LMS, Kaltura)
//  works. Does not change DRM, streaming, or cookie architecture.
//

import Foundation
import WebKit

/// Shared WebKit environment: one process pool and one website data store for all browser webviews.
/// All WKWebViewConfigurations must use config.processPool = BrowserEnvironment.shared.processPool
/// and config.websiteDataStore = WKWebsiteDataStore.default() (or this shared dataStore) so
/// Canvas LMS and Kaltura embedded players function correctly.
final class BrowserEnvironment {
    static let shared = BrowserEnvironment()

    /// Single process pool used by every WKWebViewConfiguration. Sharing this ensures
    /// cookies and authentication state are shared across all tabs and windows.
    let processPool: WKProcessPool = WKProcessPool()

    /// Persistent website data store (WKWebsiteDataStore.default()) used by every
    /// WKWebViewConfiguration. Persists across tabs and navigation so login sessions
    /// and Canvas/Kaltura embedded video work correctly.
    let dataStore: WKWebsiteDataStore = {
        let store = WKWebsiteDataStore.default()
        BrowserEnvironment.disableITP(on: store, label: "BrowserEnvironment.shared")
        return store
    }()

    private init() {
        Task { @MainActor in
            await self.dataStore.httpCookieStore.setCookiePolicy(.allow)
        }
    }

    /// Disable ITP using the correct calling convention for the ObjC BOOL parameter.
    /// `perform(_:with:)` passes object pointers — a `false` value is bridged to
    /// NSNumber(false) whose non-nil pointer is read as `true` by the BOOL param.
    /// We use `unsafeBitCast` to call the IMP directly with a native Bool.
    static func disableITP(on store: WKWebsiteDataStore, label: String) {
        // 1. Disable Resource Load Statistics (ITP)
        let sel = NSSelectorFromString("_setResourceLoadStatisticsEnabled:")
        if store.responds(to: sel) {
            typealias SetITPFunc = @convention(c) (AnyObject, Selector, Bool) -> Void
            let imp = store.method(for: sel)
            let fn = unsafeBitCast(imp, to: SetITPFunc.self)
            fn(store, sel, false)
        }

        // 2. Disable explicit Third-Party Cookie Blocking Mode
        let blockSel = NSSelectorFromString("_setThirdPartyCookieBlockingMode:onlyOnSitesWithoutUserInteraction:completionHandler:")
        if store.responds(to: blockSel) {
            typealias SetThirdPartyCookieBlockingModeFunc = @convention(c) (AnyObject, Selector, Bool, Bool, @escaping @convention(block) () -> Void) -> Void
            let imp = store.method(for: blockSel)
            let fn = unsafeBitCast(imp, to: SetThirdPartyCookieBlockingModeFunc.self)
            fn(store, blockSel, false, false, {
            })
        }
    }
}
