import Foundation
import WebKit

/// Additional Canopy features: Spotify ad handling, popup blocking, cookie consent dismiss, subresource param stripping.
@MainActor
final class CanopyExtras {
    static let shared = CanopyExtras()

    private let spotifyEnabledKey = "canopy.spotify.enabled"
    private let popupBlockEnabledKey = "canopy.popupBlock.enabled"
    private let cookieConsentEnabledKey = "canopy.cookieConsent.enabled"
    private let subresourceParamEnabledKey = "canopy.subresourceParam.enabled"

    var isSpotifyAdBlockEnabled: Bool {
        get { UserDefaults.standard.object(forKey: spotifyEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: spotifyEnabledKey) }
    }
    var isPopupBlockEnabled: Bool {
        get { UserDefaults.standard.object(forKey: popupBlockEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: popupBlockEnabledKey) }
    }
    var isCookieConsentEnabled: Bool {
        get { UserDefaults.standard.object(forKey: cookieConsentEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: cookieConsentEnabledKey) }
    }
    var isSubresourceParamEnabled: Bool {
        get { UserDefaults.standard.object(forKey: subresourceParamEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: subresourceParamEnabledKey) }
    }

    private init() {}

    // MARK: - 1. Spotify ad muting + silent redirect

    nonisolated static func spotifyAdScript() -> WKUserScript {
        func buildOnMain() -> WKUserScript { MainActor.assumeIsolated {
        let source = """
        (function() {
            if (window !== window.top) return;
            var host = (location.hostname || '').toLowerCase();
            if (host !== 'open.spotify.com' && !host.endsWith('.spotify.com')) return;

            var SILENT_SRC = 'data:audio/mp3;base64,SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjU4Ljc2LjEwMAAAAAAAAAAAAAAA//tQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAWGluZwAAAA8AAAACAAABhgC7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7//////////////////////////////////////////////////////////////////8AAAAATGF2YzU4LjEzAAAAAAAAAAAAAAAAJAAAAAAAAAAAAYYoRwBHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

            // Intercept audio elements
            var origPlay = HTMLMediaElement.prototype.play;
            HTMLMediaElement.prototype.play = function() {
                var el = this;
                var checkAd = function() {
                    try {
                        if (el.duration && el.duration > 0 && el.duration <= 45) {
                            var src = (el.src || el.currentSrc || '').toLowerCase();
                            if (src.indexOf('spotify') !== -1 || src.indexOf('akamaized') !== -1 || src.indexOf('scdn') !== -1) {
                                el.muted = true;
                                el.playbackRate = 16.0;
                                el.currentTime = Math.max(0, el.duration - 0.1);
                                return;
                            }
                        }
                        if (el.duration && el.duration > 45) {
                            el.muted = false;
                            el.playbackRate = 1.0;
                        }
                    } catch(e) {}
                };
                setTimeout(checkAd, 200);
                setTimeout(checkAd, 1000);
                return origPlay.apply(this, arguments);
            };

            // Monitor for ad indicators in the DOM
            var observer = new MutationObserver(function() {
                try {
                    var adLabel = document.querySelector('[data-testid="ad-label"], [data-testid="track-info-advertiser"], .ad-slot');
                    if (adLabel) {
                        var audio = document.querySelector('audio, video');
                        if (audio) {
                            audio.muted = true;
                            audio.playbackRate = 16.0;
                            try { audio.currentTime = Math.max(0, (audio.duration || 30) - 0.1); } catch(e) {}
                        }
                        var skip = document.querySelector('[data-testid="control-button-skip-forward"]');
                        if (skip) skip.click();
                    } else {
                        var audio = document.querySelector('audio, video');
                        if (audio && audio.duration > 45) {
                            audio.muted = false;
                            audio.playbackRate = 1.0;
                        }
                    }
                } catch(e) {}
            });
            if (document.body) {
                observer.observe(document.body, { childList: true, subtree: true, attributes: true });
            } else {
                document.addEventListener('DOMContentLoaded', function() {
                    observer.observe(document.body, { childList: true, subtree: true, attributes: true });
                });
            }
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        }}
        if Thread.isMainThread { return buildOnMain() }
        return DispatchQueue.main.sync(execute: buildOnMain)
    }

    // MARK: - 4. Cookie consent auto-dismiss

    nonisolated static func cookieConsentScript() -> WKUserScript {
        func buildOnMain() -> WKUserScript { MainActor.assumeIsolated {
        let source = """
        (function() {
            if (window !== window.top) return;
            function dismissCookieBanners() {
                try {
                    var selectors = [
                        '[data-testid="cookie-policy-manage-dialog"] button:last-child',
                        '#onetrust-reject-all-handler',
                        '.onetrust-close-btn-handler',
                        '[aria-label="Reject all"]',
                        '[aria-label="Deny"]',
                        '[aria-label="Decline"]',
                        '[aria-label="Refuse"]',
                        'button[data-cookiebanner="reject_button"]',
                        '.cookie-banner__reject',
                        '.js-cookie-consent-reject',
                        '#cookie-consent-reject',
                        '.cookie-notice__decline',
                        '[data-gdpr-consent="reject"]',
                        '.qc-cmp2-summary-buttons button:first-child',
                        '#didomi-notice-disagree-button',
                        '.fc-cta-do-not-consent',
                        '.sp_choice_type_11',
                        '#CybotCookiebotDialogBodyButtonDecline',
                        '.cc-deny',
                        '.cc-dismiss',
                        '[data-cc-action="reject"]',
                        '.evidon-barrier-acceptbutton',
                    ];
                    for (var i = 0; i < selectors.length; i++) {
                        var btn = document.querySelector(selectors[i]);
                        if (btn && btn.offsetParent !== null) {
                            btn.click();
                            return true;
                        }
                    }
                    // Fallback: look for buttons with reject/deny/decline text
                    var buttons = document.querySelectorAll('button, a[role="button"]');
                    for (var j = 0; j < buttons.length; j++) {
                        var text = (buttons[j].textContent || '').trim().toLowerCase();
                        if (text === 'reject all' || text === 'deny' || text === 'decline' || text === 'refuse all' ||
                            text === 'reject' || text === 'nur notwendige' || text === 'ablehnen' ||
                            text === 'alles ablehnen' || text === 'tout refuser' || text === 'refuser') {
                            if (buttons[j].offsetParent !== null) {
                                buttons[j].click();
                                return true;
                            }
                        }
                    }
                } catch(e) {}
                return false;
            }
            setTimeout(dismissCookieBanners, 1000);
            setTimeout(dismissCookieBanners, 2500);
            setTimeout(dismissCookieBanners, 5000);
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        }}
        if Thread.isMainThread { return buildOnMain() }
        return DispatchQueue.main.sync(execute: buildOnMain)
    }

    // MARK: - 5. Subresource URL param stripping

    nonisolated static func subresourceParamScript() -> WKUserScript {
        func buildOnMain() -> WKUserScript { MainActor.assumeIsolated {
        let source = """
        (function() {
            if (window !== window.top) return;
            var trackingParams = ['utm_source','utm_medium','utm_campaign','utm_content','utm_term',
                'fbclid','gclid','gclsrc','dclid','gbraid','wbraid','msclkid','twclid','ttclid',
                'mc_cid','mc_eid','yclid','_openstat','ref','affiliate_id','spm','scm'];
            function cleanURL(href) {
                try {
                    var url = new URL(href, location.origin);
                    if (!url.search) return null;
                    var changed = false;
                    for (var i = 0; i < trackingParams.length; i++) {
                        if (url.searchParams.has(trackingParams[i])) {
                            url.searchParams.delete(trackingParams[i]);
                            changed = true;
                        }
                    }
                    return changed ? url.href : null;
                } catch(e) { return null; }
            }
            function cleanLinks() {
                var links = document.querySelectorAll('a[href*="utm_"], a[href*="fbclid"], a[href*="gclid"], a[href*="mc_cid"]');
                for (var i = 0; i < links.length; i++) {
                    var cleaned = cleanURL(links[i].href);
                    if (cleaned) links[i].href = cleaned;
                }
            }
            setTimeout(cleanLinks, 1500);
            setTimeout(cleanLinks, 4000);
            var observer = new MutationObserver(function(mutations) {
                var hasNew = false;
                for (var i = 0; i < mutations.length; i++) {
                    if (mutations[i].addedNodes.length > 0) { hasNew = true; break; }
                }
                if (hasNew) setTimeout(cleanLinks, 500);
            });
            if (document.body) {
                observer.observe(document.body, { childList: true, subtree: true });
            }
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        }}
        if Thread.isMainThread { return buildOnMain() }
        return DispatchQueue.main.sync(execute: buildOnMain)
    }

    // MARK: - 3. Popup blocking

    /// Check if a popup URL should be blocked. Called from WKUIDelegate.
    func shouldBlockPopup(url: URL?) -> Bool {
        guard isPopupBlockEnabled, let url = url, let host = url.host?.lowercased() else { return false }
        let adHosts = [
            "doubleclick.net", "googlesyndication.com", "googleadservices.com",
            "facebook.net", "facebook.com/tr", "amazon-adsystem.com",
            "adservice.google.com", "pagead2.googlesyndication.com",
            "popads.net", "popcash.net", "propellerads.com", "adsterra.com",
            "exoclick.com", "juicyads.com", "trafficjunky.com",
            "outbrain.com", "taboola.com", "mgid.com", "revcontent.com",
        ]
        for adHost in adHosts {
            if host == adHost || host.hasSuffix("." + adHost) { return true }
        }
        return false
    }
}
