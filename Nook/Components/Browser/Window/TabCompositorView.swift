import SwiftUI
import AppKit
import WebKit

struct TabCompositorView: NSViewRepresentable {
    let browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // Update the compositor when tabs change or compositor version changes
        updateCompositor(nsView)
    }
    
    private func updateCompositor(_ containerView: NSView) {
        // Remove all existing webview subviews
        containerView.subviews.forEach { $0.removeFromSuperview() }

        // Only add the current tab's webView to avoid WKWebView conflicts
        guard let currentTabId = windowState.currentTabId,
              let currentTab = browserManager.tabsForDisplay(in: windowState).first(where: { $0.id == currentTabId }),
              !currentTab.isUnloaded else {
            return
        }
        
        // Create a window-specific web view for this tab
        let webView = getOrCreateWebView(for: currentTab, in: windowState.id)
        webView.frame = containerView.bounds
        webView.autoresizingMask = [.width, .height]
        containerView.addSubview(webView)
        webView.isHidden = false
    }
    
    private func getOrCreateWebView(for tab: Tab, in windowId: UUID) -> WKWebView {
        // Check if we already have a web view for this tab in this window
        if let existingWebView = browserManager.getWebView(for: tab.id, in: windowId) {
            return existingWebView
        }
        
        // Create a new web view for this tab in this window
        return browserManager.createWebView(for: tab.id, in: windowId)
    }
}

// MARK: - Tab Compositor Manager (Active / Warm / Cold Lifecycle)
//
// Three-tier tab lifecycle for memory efficiency:
//
// • Active: The visible tab(s), one per window. Has WKWebView displayed in the container.
// • Warm: Background tabs that keep their WKWebView alive but hidden for instant switching.
//   Limited to warmTabLimit (default 10, range 8–12). LRU eviction uses lastAccessTimes.
// • Cold: Tabs with no WKWebView; Tab keeps URL, title, favicon. When activated, a WKWebView
//   is recreated (shared WKProcessPool and WKWebViewConfiguration) and the stored URL is
//   reloaded so cookies, sessions, and DRM remain functional.
//
// Pinned tabs (isPinned || isSpacePinned) are never suspended and always keep their webview.
// Pre-warmed WebView pool (in WebViewCoordinator) is used only for new regular tabs; pinned tabs get a dedicated WebView.
//
@MainActor
class TabCompositorManager: ObservableObject {
    private var unloadTimers: [UUID: Timer] = [:]
    private var lastAccessTimes: [UUID: Date] = [:]

    /// Maximum number of warm (background) tabs that keep a WKWebView. Beyond this, tabs become cold.
    var warmTabLimit: Int = 10

    // Legacy: still used for timer bookkeeping; cold eviction is driven by warmTabLimit
    var unloadTimeout: TimeInterval = 300

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTimeoutChange),
            name: .tabUnloadTimeoutChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleTimeoutChange(_ notification: Notification) {
        if let timeout = notification.userInfo?["timeout"] as? TimeInterval {
            setUnloadTimeout(timeout)
        }
    }

    func setUnloadTimeout(_ timeout: TimeInterval) {
        self.unloadTimeout = timeout
        restartAllTimers()
    }

    func markTabAccessed(_ tabId: UUID) {
        lastAccessTimes[tabId] = Date()
        restartTimer(for: tabId)
    }

    func unloadTab(_ tab: Tab) {
        unloadTimers[tab.id]?.invalidate()
        unloadTimers.removeValue(forKey: tab.id)
        lastAccessTimes.removeValue(forKey: tab.id)
        tab.unloadWebView()
    }

    func loadTab(_ tab: Tab) {
        markTabAccessed(tab.id)
        tab.loadWebViewIfNeeded()
        enforceWarmLimit()
    }

    /// Keep at most warmTabLimit warm tabs; suspend (cold) the rest. Pinned tabs are never suspended.
    private func enforceWarmLimit() {
        guard let browserManager = browserManager else { return }
        let tabManager = browserManager.tabManager
        let activeTabIds = Set(browserManager.windowRegistry?.windows.values.compactMap(\.currentTabId) ?? [])
        let allTabs = tabManager.allTabs()

        let warmCandidates = allTabs.filter { tab in
            tab.existingWebView != nil
            && !activeTabIds.contains(tab.id)
            && !tab.isPinned
            && !tab.isSpacePinned
        }

        if warmCandidates.count <= warmTabLimit { return }

        let sortedByAccess = warmCandidates.sorted { t1, t2 in
            let d1 = lastAccessTimes[t1.id] ?? .distantPast
            let d2 = lastAccessTimes[t2.id] ?? .distantPast
            return d1 < d2
        }

        let toEvict = sortedByAccess.dropFirst(warmTabLimit)
        for tab in toEvict {
            unloadTab(tab)
        }
    }

    private func restartTimer(for tabId: UUID) {
        unloadTimers[tabId]?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: unloadTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleTabTimeout(tabId)
            }
        }
        unloadTimers[tabId] = timer
    }

    private func restartAllTimers() {
        unloadTimers.values.forEach { $0.invalidate() }
        unloadTimers.removeAll()
        for tabId in lastAccessTimes.keys {
            restartTimer(for: tabId)
        }
    }

    private func handleTabTimeout(_ tabId: UUID) {
        guard let tab = findTab(by: tabId) else { return }
        if tab.isCurrentTab {
            restartTimer(for: tabId)
            return
        }
        if tab.hasPlayingVideo || tab.hasPlayingAudio || tab.hasAudioContent {
            restartTimer(for: tabId)
            return
        }
        // Cold eviction is handled by enforceWarmLimit(); timer no longer unloads here
    }
    
    private func findTab(by id: UUID) -> Tab? {
        guard let browserManager = browserManager else { return nil }
        return browserManager.tabManager.allTabs().first { $0.id == id }
    }

    private func findTabByWebView(_ webView: WKWebView) -> Tab? {
        guard let browserManager = browserManager else { return nil }
        return browserManager.tabManager.allTabs().first { $0.webView === webView }
    }
    
    // MARK: - Public Interface
    func updateTabVisibility(currentTabId: UUID?) {
        guard let browserManager = browserManager,
              let coordinator = browserManager.webViewCoordinator else { return }
        for (windowId, _) in coordinator.compositorContainers() {
            guard let windowState = browserManager.windowRegistry?.windows[windowId] else { continue }
            browserManager.refreshCompositor(for: windowState)
        }
    }
    
    /// Update tab visibility for a specific window
    func updateTabVisibility(for windowState: BrowserWindowState) {
        browserManager?.refreshCompositor(for: windowState)
    }
    
    // MARK: - Dependencies
    weak var browserManager: BrowserManager?
}
