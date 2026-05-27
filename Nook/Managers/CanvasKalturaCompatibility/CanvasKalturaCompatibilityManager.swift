//
//  CanvasKalturaCompatibilityManager.swift
//  Nook
//
//  Canvas LMS + Kaltura compatibility: cookie sync and Storage Access API.
//  Allowlist: *.canvaslms.com, *.instructure.com, *.kaltura.com, *.kaf.kaltura.com,
//  canvas.liberty.edu, *.kalturausercontent.com. Does not change DRM or other sites.
//

import Foundation
import WebKit

/// Domains that may embed Kaltura and need cookie sync for iframe auth (allowlist for cross-site authentication cookies).
/// Includes instructuremedia.com (media host used by Canvas Kaltura, e.g. nv.instructuremedia.com).
private let kCanvasKalturaHostSuffixes = [
    "canvaslms.com", ".canvaslms.com",
    "instructure.com", ".instructure.com",
    "instructuremedia.com", ".instructuremedia.com",
    "kaltura.com", ".kaltura.com",
    "kaf.kaltura.com", ".kaf.kaltura.com",
    "kalturausercontent.com", ".kalturausercontent.com",
    "canvas.liberty.edu",
]

@MainActor
final class CanvasKalturaCompatibilityManager {
    static let shared = CanvasKalturaCompatibilityManager()

    private var syncTimer: Timer?
    private let syncInterval: TimeInterval = 60


    private init() {}

    /// Start periodic cookie sync from WebKit default store to system store.
    func start() {
        syncTimer?.invalidate()
        performSync()
        syncTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performSync()
            }
        }
        syncTimer?.tolerance = 15
        RunLoop.main.add(syncTimer!, forMode: .common)
    }

    /// Stop periodic sync.
    func stop() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    /// One-shot sync: copy cookies for Canvas/Kaltura domains from the shared WebKit store to HTTPCookieStorage.
    func performSync() {
        let store = BrowserEnvironment.shared.dataStore.httpCookieStore
        store.getAllCookies { [weak self] cookies in
            self?.applyCookiesToSystemStore(cookies)
        }
    }

    private func applyCookiesToSystemStore(_ cookies: [HTTPCookie]) {
        let systemStore = HTTPCookieStorage.shared
        for cookie in cookies {
            guard let host = cookie.domain.isEmpty ? nil : cookie.domain,
                  matchesCanvasKalturaDomain(host) else { continue }
            systemStore.setCookie(cookie)
        }
    }

    private func matchesCanvasKalturaDomain(_ host: String) -> Bool {
        Self.isCanvasOrKalturaHost(host)
    }

    /// Returns true if the host is a Canvas/Kaltura domain (for pre-populating cookies and sync triggers).
    /// Domains: kaltura.com, lu-canvas.kaf.kaltura.com, kaf.kaltura.com, canvas.liberty.edu, *.canvaslms.com, *.instructure.com, *.kalturausercontent.com.
    static func isCanvasOrKalturaHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        for suffix in kCanvasKalturaHostSuffixes {
            if suffix.hasPrefix(".") {
                if h == String(suffix.dropFirst()) || h.hasSuffix(suffix) { return true }
            } else {
                if h == suffix || h.hasSuffix("." + suffix) { return true }
            }
        }
        return false
    }

    /// Call when a Kaltura iframe is detected from the page script; runs cookie sync and retries once after 2s.
    func onKalturaIframeDetected() {
        performSync()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.performSync()
        }
    }

    /// Storage Access API: for Canvas/Kaltura domains, automatically request storage access so embedded
    /// Kaltura iframes can read required cookies/localStorage. Runs in all frames at document start and
    /// also detects Kaltura iframes on Canvas pages (even when added dynamically).
    static func storageAccessUserScript() -> WKUserScript {
        let source = """
        (function() {
          try {
            if (window === window.top) return;

            var host = (window.location && window.location.hostname) || '';
            var h = host.toLowerCase();

            var isCanvasHost =
              (h === 'canvaslms.com' || h.slice(-14) === '.canvaslms.com') ||
              (h === 'instructure.com' || h.slice(-18) === '.instructure.com') ||
              (h === 'canvas.liberty.edu');

            var isKalturaHost =
              (h === 'kaltura.com' || h.slice(-12) === '.kaltura.com') ||
              (h === 'kaf.kaltura.com' || h.slice(-14) === '.kaf.kaltura.com') ||
              (h === 'kalturausercontent.com' || h.slice(-22) === '.kalturausercontent.com') ||
              (h === 'instructuremedia.com' || h.slice(-22) === '.instructuremedia.com');

            if (isCanvasHost || isKalturaHost) {
              // Single attempt — with ITP properly disabled, storage access should already be granted.
              if (document.hasStorageAccess) {
                document.hasStorageAccess().then(function(has) {
                  if (!has && document.requestStorageAccess) {
                    document.requestStorageAccess().catch(function(err) {});
                  }
                }).catch(function(err) {});
              }
            }
          } catch (e) {}
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    /// No-op: ITP is disabled natively, so the cookie warning no longer appears.
    static func hideThirdPartyCookieWarningScript() -> WKUserScript {
        return WKUserScript(source: "", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }
}
