//
//  WebViewCoordinator.swift
//  Nook
//
//  Manages WebView instances across multiple windows.
//  Uses a small pre-warmed WebView pool (Arc-style) so new tab creation is instant.
//

import Foundation
import AppKit
import WebKit

@MainActor
@Observable
class WebViewCoordinator {
    /// Window-specific web views: tabId -> windowId -> WKWebView
    private var webViewsByTabAndWindow: [UUID: [UUID: WKWebView]] = [:]

    /// Prevent recursive sync calls
    private var isSyncingTab: Set<UUID> = []

    /// Weak wrapper for NSView references stored per window
    private struct WeakNSView { weak var view: NSView? }

    /// Container views per window so the compositor can manage multiple windows safely
    private var compositorContainerViews: [UUID: WeakNSView] = [:]

    // MARK: - Pre-Warmed WebView Pool (Arc-style) + Pinned Tab Rules
    // • Pinned tabs (isPinned || isSpacePinned) never use the pool; they get a dedicated WebView
    //   and are never suspended (always warm). Switching to a pinned tab is instant.
    // • Pool is only for new regular tabs: acquire here, replenish async. Cold regular tabs
    //   get a WebView on activate (from pool or create). Shared WKProcessPool for all.
    private var preWarmedPool: [FocusableWKWebView] = []
    /// Target size for the warm WebView pool. Keeping 3 instances strikes a balance
    /// between instant tab creation and overall memory usage.
    private let preWarmedPoolMaxSize = 3

    // MARK: - Compositor Container Management

        func setCompositorContainerView(_ view: NSView?, for windowId: UUID) {
        if let view {
            compositorContainerViews[windowId] = WeakNSView(view: view)
            // Ensure the pool is ready whenever a compositor container appears.
            if preWarmedPool.count < preWarmedPoolMaxSize {
                preWarmPool(count: preWarmedPoolMaxSize - preWarmedPool.count)
            }
        } else {
            compositorContainerViews.removeValue(forKey: windowId)
        }
    }

    func compositorContainerView(for windowId: UUID) -> NSView? {
        if let view = compositorContainerViews[windowId]?.view {
            return view
        }
        compositorContainerViews.removeValue(forKey: windowId)
        return nil
    }

    func removeCompositorContainerView(for windowId: UUID) {
        compositorContainerViews.removeValue(forKey: windowId)
    }

    func compositorContainers() -> [(UUID, NSView)] {
        var result: [(UUID, NSView)] = []
        var staleIdentifiers: [UUID] = []
        for (windowId, entry) in compositorContainerViews {
            if let view = entry.view {
                result.append((windowId, view))
            } else {
                staleIdentifiers.append(windowId)
            }
        }
        for id in staleIdentifiers {
            compositorContainerViews.removeValue(forKey: id)
        }
        return result
    }

    // MARK: - WebView Pool Management

    func getWebView(for tabId: UUID, in windowId: UUID) -> WKWebView? {
        let webView = webViewsByTabAndWindow[tabId]?[windowId]
        #if DEBUG
        if let wv = webView {
            print("🔍 [MEMDEBUG] WebViewCoordinator.getWebView() FOUND existing - Tab: \(tabId.uuidString.prefix(8)), Window: \(windowId.uuidString.prefix(8)), WebView: \(Unmanaged.passUnretained(wv).toOpaque())")
        } else {
            print("🔍 [MEMDEBUG] WebViewCoordinator.getWebView() NOT FOUND - Tab: \(tabId.uuidString.prefix(8)), Window: \(windowId.uuidString.prefix(8))")
        }
        #endif
        return webView
    }

    func getAllWebViews(for tabId: UUID) -> [WKWebView] {
        guard let windowWebViews = webViewsByTabAndWindow[tabId] else { return [] }
        return Array(windowWebViews.values)
    }

    func setWebView(_ webView: WKWebView, for tabId: UUID, in windowId: UUID) {
        if webViewsByTabAndWindow[tabId] == nil {
            webViewsByTabAndWindow[tabId] = [:]
        }
        webViewsByTabAndWindow[tabId]?[windowId] = webView
    }

    // MARK: - Smart WebView Assignment (Memory Optimization)
    
    /// Gets or creates a WebView for the specified tab and window.
    /// Reuses the tab's existing WebView when present (no new WKWebView or reload).
    /// Uses shared WKWebViewConfiguration and WKProcessPool from BrowserEnvironment.
    /// - If this window already has a WebView for this tab, returns it (visibility swap only).
    /// - If the tab already owns a primary WebView for another window, this window gets a clone.
    /// - Otherwise creates the tab's primary WebView and assigns it to the tab.
    func getOrCreateWebView(for tab: Tab, in windowId: UUID, tabManager: TabManager) -> WKWebView {
        let tabId = tab.id

        // Reuse existing WebView for this window — do not create or reload when switching tabs
        if let existing = getWebView(for: tabId, in: windowId) {
            return existing
        }
        
        // Check if another window already has this tab displayed
        let allWindowsForTab = webViewsByTabAndWindow[tabId] ?? [:]
        let otherWindows = allWindowsForTab.filter { $0.key != windowId }
        
        print("🔍 [MEMDEBUG]   Tab currently displayed in \(allWindowsForTab.count) window(s), other windows: \(otherWindows.count)")
        
        if otherWindows.isEmpty {
            // This is the FIRST window to display this tab
            // Create the "primary" WebView and assign it to this tab
            print("🔍 [MEMDEBUG]   -> No other windows, creating PRIMARY WebView")
            let primaryWebView = createPrimaryWebView(for: tab, in: windowId)
            
            // Assign this WebView as the tab's primary
            tab.assignWebViewToWindow(primaryWebView, windowId: windowId)
            
            return primaryWebView
        } else {
            // Another window is already displaying this tab
            // Create a "clone" WebView for this window
            print("🔍 [MEMDEBUG]   -> Other window(s) exist, creating CLONE WebView")
            let cloneWebView = createCloneWebView(for: tab, in: windowId, primaryWindowId: otherWindows.first!.key)
            
            return cloneWebView
        }
    }
    
    /// Creates the "primary" WebView - the first WebView for a tab.
    /// Pinned tabs always get a dedicated WebView (never from pool). Regular tabs use the pre-warmed pool when available (default profile).
    private func createPrimaryWebView(for tab: Tab, in windowId: UUID) -> WKWebView {
        let isRegularTab = !tab.isPinned && !tab.isSpacePinned
        let usePool = isRegularTab && (tab.resolveProfile()?.isDefault ?? true)

        if usePool, let pooled = acquirePreWarmedWebView() {
            configureWebViewForTab(pooled, tab: tab, windowId: windowId)
            setWebView(pooled, for: tab.id, in: windowId)
            replenishPoolAsync()
            return pooled
        }

        let webView = createWebViewInternal(for: tab, in: windowId, isPrimary: true)
        replenishPoolAsync()
        return webView
    }

    /// Take a pre-warmed WebView from the pool if available. Caller must configure and assign to tab.
    private func acquirePreWarmedWebView() -> FocusableWKWebView? {
        guard !preWarmedPool.isEmpty else { return nil }
        return preWarmedPool.removeLast()
    }

    /// Replenish the pre-warmed pool asynchronously so new tab creation stays instant.
    private func replenishPoolAsync() {
        Task { @MainActor in
            preWarmPool(count: 1)
        }
    }

    /// Ensure the pool has up to `count` more pre-warmed WebViews (max total = preWarmedPoolMaxSize). No URL loaded.
    private func preWarmPool(count: Int = 1) {
        var added = 0
        while added < count, preWarmedPool.count < preWarmedPoolMaxSize {
            let config = BrowserConfiguration.shared.webViewConfiguration.copy() as! WKWebViewConfiguration
            config.userContentController = BrowserConfiguration.shared.freshUserContentController()
            let wv = FocusableWKWebView(frame: .zero, configuration: config)
            wv.isHidden = true
            wv.allowsBackForwardNavigationGestures = true
            wv.allowsMagnification = true
            wv.setValue(false, forKey: "drawsBackground")
            preWarmedPool.append(wv)
            added += 1
        }
    }

    /// Configure a WebView (from pool or new) for a tab: delegates, handlers, load URL.
    private func configureWebViewForTab(_ webView: FocusableWKWebView, tab: Tab, windowId: UUID) {
        let tabId = tab.id
        let configuration = webView.configuration

        webView.isHidden = false
        webView.navigationDelegate = tab
        webView.uiDelegate = tab
        webView.owningTab = tab
        webView.contextMenuBridge = WebContextMenuBridge(tab: tab, configuration: configuration)

        let ucc = webView.configuration.userContentController
        ucc.add(tab, name: "linkHover")
        ucc.add(tab, name: "commandHover")
        ucc.add(tab, name: "commandClick")
        ucc.add(tab, name: "pipStateChange")
        ucc.add(tab, name: "mediaStateChange_\(tabId.uuidString)")
        ucc.add(tab, name: "backgroundColor_\(tabId.uuidString)")
        ucc.add(tab, name: "historyStateDidChange")
        ucc.add(tab, name: "nookShortcutDetect")
        ucc.add(tab, name: "NookIdentity")
        for name in CustomFeatureRegistry.customHandlerNames() {
            ucc.add(tab, name: name)
        }

        tab.setupThemeColorObserver(for: webView)
        if let url = URL(string: tab.url.absoluteString) {
            webView.load(URLRequest(url: url))
        }
        webView.isMuted = tab.isAudioMuted
    }
    
    /// Creates a "clone" WebView - additional WebViews for multi-window display
    /// These share the configuration but are separate instances
    private func createCloneWebView(for tab: Tab, in windowId: UUID, primaryWindowId: UUID) -> WKWebView {
        let tabId = tab.id
        
        print("🔍 [MEMDEBUG] Creating CLONE WebView - Tab: \(tabId.uuidString.prefix(8)), Window: \(windowId.uuidString.prefix(8)), PrimaryWindow: \(primaryWindowId.uuidString.prefix(8))")
        
        // Get the primary WebView to copy configuration
        let primaryWebView = getWebView(for: tabId, in: primaryWindowId)
        
        // Create clone with shared configuration
        let webView = createWebViewInternal(for: tab, in: windowId, isPrimary: false, copyFrom: primaryWebView)
        
        print("🔍 [MEMDEBUG]   -> Clone WebView created: \(Unmanaged.passUnretained(webView).toOpaque())")
        return webView
    }
    
    /// Internal method to create a WebView with proper configuration
    private func createWebViewInternal(for tab: Tab, in windowId: UUID, isPrimary: Bool, copyFrom: WKWebView? = nil) -> WKWebView {
        let tabId = tab.id
        
        // Derive config from shared config or existing webview to preserve
        // process pool + extension controller (fresh configs break content script injection)
        let configuration: WKWebViewConfiguration
        if let sourceWebView = copyFrom ?? tab.existingWebView {
            // .configuration returns a copy — preserves process pool, extension controller, etc.
            configuration = sourceWebView.configuration
        } else {
            let resolvedProfile = tab.resolveProfile()
            if let profile = resolvedProfile {
                configuration = BrowserConfiguration.shared.cacheOptimizedWebViewConfiguration(for: profile)
            } else {
                configuration = BrowserConfiguration.shared.webViewConfiguration.copy() as! WKWebViewConfiguration
            }
        }
        // Fresh user content controller per webview to avoid cross-tab handler conflicts
        // (preserves shared scripts like extension bridge polyfills)
        configuration.userContentController = BrowserConfiguration.shared.freshUserContentController()

        let newWebView = FocusableWKWebView(frame: .zero, configuration: configuration)
        newWebView.navigationDelegate = tab
        newWebView.uiDelegate = tab
        newWebView.allowsBackForwardNavigationGestures = true
        newWebView.allowsMagnification = true
        newWebView.setValue(false, forKey: "drawsBackground")
        newWebView.owningTab = tab
        newWebView.contextMenuBridge = WebContextMenuBridge(tab: tab, configuration: configuration)
        
        newWebView.configuration.userContentController.add(tab, name: "linkHover")
        newWebView.configuration.userContentController.add(tab, name: "commandHover")
        newWebView.configuration.userContentController.add(tab, name: "commandClick")
        newWebView.configuration.userContentController.add(tab, name: "pipStateChange")
        newWebView.configuration.userContentController.add(tab, name: "mediaStateChange_\(tabId.uuidString)")
        newWebView.configuration.userContentController.add(tab, name: "backgroundColor_\(tabId.uuidString)")
        newWebView.configuration.userContentController.add(tab, name: "historyStateDidChange")
        newWebView.configuration.userContentController.add(tab, name: "NookIdentity")
        newWebView.configuration.userContentController.add(tab, name: "nookShortcutDetect")
        for name in CustomFeatureRegistry.customHandlerNames() {
            newWebView.configuration.userContentController.add(tab, name: name)
        }
        
        tab.setupThemeColorObserver(for: newWebView)
        
        // Only load URL if this is the primary or if we're creating a clone
        // For clones, we sync the URL via syncTab later
        if let url = URL(string: tab.url.absoluteString) {
            newWebView.load(URLRequest(url: url))
        }
        newWebView.isMuted = tab.isAudioMuted
        
        setWebView(newWebView, for: tabId, in: windowId)
        
        let typeStr = isPrimary ? "PRIMARY" : "CLONE"
        print("🔍 [MEMDEBUG] WebViewCoordinator CREATED \(typeStr) WebView - Tab: \(tabId.uuidString.prefix(8)), Window: \(windowId.uuidString.prefix(8)), WebView: \(Unmanaged.passUnretained(newWebView).toOpaque()), DataStore: \(configuration.websiteDataStore.identifier?.uuidString.prefix(8) ?? "default")")
        
        // Log all WebViews now tracked for this tab
        let allWebViewsForTab = getAllWebViews(for: tabId)
        print("🔍 [MEMDEBUG]   Total WebViews for tab \(tabId.uuidString.prefix(8)): \(allWebViewsForTab.count)")
        for (index, wv) in allWebViewsForTab.enumerated() {
            print("🔍 [MEMDEBUG]     [\(index)] WebView: \(Unmanaged.passUnretained(wv).toOpaque())")
        }
        
        return newWebView
    }

    func removeWebViewFromContainers(_ webView: WKWebView) {
        for (windowId, entry) in compositorContainerViews {
            guard let container = entry.view else {
                compositorContainerViews.removeValue(forKey: windowId)
                continue
            }
            for subview in container.subviews where subview === webView {
                subview.removeFromSuperview()
            }
        }
    }

    /// Remove the tab's primary webview from tracking so the next display creates a fresh one (e.g. after explicit unload).
    func removeWebViewForTab(_ tab: Tab, windowId: UUID) {
        webViewsByTabAndWindow[tab.id]?.removeValue(forKey: windowId)
        if webViewsByTabAndWindow[tab.id]?.isEmpty == true {
            webViewsByTabAndWindow.removeValue(forKey: tab.id)
        }
    }

    func removeAllWebViews(for tab: Tab) {
        guard let entries = webViewsByTabAndWindow.removeValue(forKey: tab.id) else { return }
        for (_, webView) in entries {
            tab.cleanupCloneWebView(webView)
            removeWebViewFromContainers(webView)
        }
    }

    // MARK: - Window Cleanup

    func cleanupWindow(_ windowId: UUID, tabManager: TabManager) {
        let webViewsToCleanup = webViewsByTabAndWindow.compactMap {
            (tabId, windowWebViews) -> (UUID, WKWebView)? in
            guard let webView = windowWebViews[windowId] else { return nil }
            return (tabId, webView)
        }

        print("🧹 [WebViewCoordinator] Cleaning up \(webViewsToCleanup.count) WebViews for window \(windowId)")

        for (tabId, webView) in webViewsToCleanup {
            // Use comprehensive cleanup from Tab class
            if let tab = tabManager.allTabs().first(where: { $0.id == tabId }) {
                tab.cleanupCloneWebView(webView)
            } else {
                // Fallback cleanup if tab is not found
                performFallbackWebViewCleanup(webView, tabId: tabId)
            }

            // Remove from containers
            removeWebViewFromContainers(webView)

            // Remove from tracking
            webViewsByTabAndWindow[tabId]?.removeValue(forKey: windowId)
            if webViewsByTabAndWindow[tabId]?.isEmpty == true {
                webViewsByTabAndWindow.removeValue(forKey: tabId)
            }

            print("✅ [WebViewCoordinator] Cleaned up WebView for tab \(tabId) in window \(windowId)")
        }
    }

    func cleanupAllWebViews(tabManager: TabManager) {
        print("🧹 [WebViewCoordinator] Starting comprehensive cleanup for ALL WebViews")

        let totalWebViews = webViewsByTabAndWindow.values.flatMap { $0.values }.count
        print("🧹 [WebViewCoordinator] Cleaning up \(totalWebViews) WebViews across all windows")

        // Clean up all WebViews for all tabs in all windows
        for (tabId, windowWebViews) in webViewsByTabAndWindow {
            for (windowId, webView) in windowWebViews {
                // Use comprehensive cleanup from Tab class
                if let tab = tabManager.allTabs().first(where: { $0.id == tabId }) {
                    tab.cleanupCloneWebView(webView)
                } else {
                    // Fallback cleanup if tab is not found
                    performFallbackWebViewCleanup(webView, tabId: tabId)
                }

                // Remove from containers
                removeWebViewFromContainers(webView)

                print("✅ [WebViewCoordinator] Cleaned up WebView for tab \(tabId) in window \(windowId)")
            }
        }

        // Clear all tracking
        webViewsByTabAndWindow.removeAll()
        compositorContainerViews.removeAll()

        print("✅ [WebViewCoordinator] Completed comprehensive cleanup for ALL WebViews")
    }

    // MARK: - WebView Creation & Cross-Window Sync

    /// Create a new web view for a specific tab in a specific window
    func createWebView(for tab: Tab, in windowId: UUID) -> WKWebView {
        let tabId = tab.id
        
        print("🔍 [MEMDEBUG] WebViewCoordinator.createWebView() START - Tab: \(tabId.uuidString.prefix(8)), Window: \(windowId.uuidString.prefix(8)), TabName: \(tab.name)")
        print("🔍 [MEMDEBUG]   tab.existingWebView exists: \(tab.existingWebView != nil), tab.webView exists: \(tab.webView != nil)")
        if let tabWebView = tab.existingWebView {
            print("🔍 [MEMDEBUG]   Tab's existingWebView: \(Unmanaged.passUnretained(tabWebView).toOpaque())")
        }

        // Derive config from shared config or existing webview to preserve
        // process pool + extension controller (fresh configs break content script injection)
        let configuration: WKWebViewConfiguration
        if let originalWebView = tab.existingWebView {
            configuration = originalWebView.configuration
        } else {
            let resolvedProfile = tab.resolveProfile()
            if let profile = resolvedProfile {
                configuration = BrowserConfiguration.shared.cacheOptimizedWebViewConfiguration(for: profile)
            } else {
                configuration = BrowserConfiguration.shared.webViewConfiguration.copy() as! WKWebViewConfiguration
            }
        }
        configuration.userContentController = BrowserConfiguration.shared.freshUserContentController()

        let newWebView = FocusableWKWebView(frame: .zero, configuration: configuration)
        newWebView.navigationDelegate = tab
        newWebView.uiDelegate = tab
        newWebView.allowsBackForwardNavigationGestures = true
        newWebView.allowsMagnification = true
        newWebView.setValue(true, forKey: "drawsBackground")
        newWebView.owningTab = tab
        newWebView.contextMenuBridge = WebContextMenuBridge(tab: tab, configuration: configuration)

        newWebView.configuration.userContentController.add(tab, name: "linkHover")
        newWebView.configuration.userContentController.add(tab, name: "commandHover")
        newWebView.configuration.userContentController.add(tab, name: "commandClick")
        newWebView.configuration.userContentController.add(tab, name: "pipStateChange")
        newWebView.configuration.userContentController.add(tab, name: "mediaStateChange_\(tabId.uuidString)")
        newWebView.configuration.userContentController.add(tab, name: "backgroundColor_\(tabId.uuidString)")
        newWebView.configuration.userContentController.add(tab, name: "historyStateDidChange")
        newWebView.configuration.userContentController.add(tab, name: "NookIdentity")
        for name in CustomFeatureRegistry.customHandlerNames() {
            newWebView.configuration.userContentController.add(tab, name: name)
        }

        tab.setupThemeColorObserver(for: newWebView)

        if let url = URL(string: tab.url.absoluteString) {
            newWebView.load(URLRequest(url: url))
        }
        newWebView.isMuted = tab.isAudioMuted

        setWebView(newWebView, for: tabId, in: windowId)

        print("🔍 [MEMDEBUG] WebViewCoordinator CREATED WINDOW-SPECIFIC WebView - Tab: \(tabId.uuidString.prefix(8)), Window: \(windowId.uuidString.prefix(8)), WebView: \(Unmanaged.passUnretained(newWebView).toOpaque()), DataStore: \(configuration.websiteDataStore.identifier?.uuidString.prefix(8) ?? "default")")
        
        // Log all WebViews now tracked for this tab
        let allWebViewsForTab = getAllWebViews(for: tabId)
        print("🔍 [MEMDEBUG]   Total WebViews for tab \(tabId.uuidString.prefix(8)): \(allWebViewsForTab.count)")
        for (index, wv) in allWebViewsForTab.enumerated() {
            print("🔍 [MEMDEBUG]     [\(index)] WebView: \(Unmanaged.passUnretained(wv).toOpaque())")
        }
        
        return newWebView
    }

    // MARK: - Private Helpers

    private func performFallbackWebViewCleanup(_ webView: WKWebView, tabId: UUID) {
        print("🧹 [WebViewCoordinator] Performing fallback WebView cleanup for tab: \(tabId)")

        // Stop loading
        webView.stopLoading()

        // Remove all message handlers
        let controller = webView.configuration.userContentController
        let allMessageHandlers = [
            "linkHover",
            "commandHover",
            "commandClick",
            "pipStateChange",
            "mediaStateChange_\(tabId.uuidString)",
            "backgroundColor_\(tabId.uuidString)",
            "historyStateDidChange",
            "NookIdentity",
            "nookShortcutDetect",
        ]

        for handlerName in allMessageHandlers {
            controller.removeScriptMessageHandler(forName: handlerName)
        }

        // MEMORY LEAK FIX: Detach contextMenuBridge
        if let focusableWebView = webView as? FocusableWKWebView {
            focusableWebView.contextMenuBridge?.detach()
            focusableWebView.contextMenuBridge = nil
        }

        // Clear delegates
        webView.navigationDelegate = nil
        webView.uiDelegate = nil

        // Remove from view hierarchy
        webView.removeFromSuperview()

        print("✅ [WebViewCoordinator] Fallback WebView cleanup completed for tab: \(tabId)")
    }

    // MARK: - Cross-Window Sync

    /// Sync a tab's URL across all windows displaying it
    func syncTab(_ tabId: UUID, to url: URL) {
        // Prevent recursive sync calls
        guard !isSyncingTab.contains(tabId) else {
            print("🪟 [WebViewCoordinator] Skipping recursive sync for tab \(tabId)")
            return
        }

        isSyncingTab.insert(tabId)
        defer { isSyncingTab.remove(tabId) }

        // Get all web views for this tab across all windows
        let allWebViews = getAllWebViews(for: tabId)

        for webView in allWebViews {
            // Sync the URL if it's different
            if webView.url != url {
                print("🔄 [WebViewCoordinator] Syncing tab \(tabId) to URL: \(url)")
                webView.load(URLRequest(url: url))
            }
        }
    }

    /// Reload a tab across all windows displaying it
    func reloadTab(_ tabId: UUID) {
        let allWebViews = getAllWebViews(for: tabId)
        for webView in allWebViews {
            print("🔄 [WebViewCoordinator] Reloading tab \(tabId) across windows")
            webView.reload()
        }
    }

    /// Set mute state for a tab across all windows
    func setMuteState(_ muted: Bool, for tabId: UUID, excludingWindow originatingWindowId: UUID?) {
        guard let windowWebViews = webViewsByTabAndWindow[tabId] else { return }

        for (windowId, webView) in windowWebViews {
            // Simple: just set all webviews to the same mute state
            webView.isMuted = muted
            print("🔇 [WebViewCoordinator] Window \(windowId): muted=\(muted)")
        }
    }
}
