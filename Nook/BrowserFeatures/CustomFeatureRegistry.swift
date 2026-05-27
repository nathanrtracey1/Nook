//
//  CustomFeatureRegistry.swift
//  Nook
//
//  Central registry for custom browser features. Provides user scripts and message
//  handler dispatch so that core upstream files (BrowserConfig, Tab) need only a
//  single integration point. All custom script and handler logic lives in feature
//  modules (e.g. BrowserFeatures, Managers/CanvasKalturaCompatibility, etc.).
//

import Foundation
import WebKit

enum CustomFeatureRegistry {

    /// User scripts to inject into the shared WKWebView configuration (Canvas/Kaltura, password manager, credit card).
    /// Builds scripts on main thread so WKUserScript (MainActor-isolated) can be created from any caller.
    /// Note: Ad blocking scripts (cosmetic hiding, Spotify ad skip, tracker stubs) are now handled by Canopy.
    static func sharedUserScripts() -> [WKUserScript] {
        func buildOnMain() -> [WKUserScript] {
            MainActor.assumeIsolated {
                [
                    CanvasKalturaCompatibilityManager.storageAccessUserScript(),
                    CanvasKalturaCompatibilityManager.hideThirdPartyCookieWarningScript(),
                    PasswordManager.userScript(),
                    CreditCardManager.userScript(),
                    extensionStorageShimScript(),
                    downloadsPolyfillScript()
                ]
            }
        }
        if Thread.isMainThread {
            return buildOnMain()
        }
        return DispatchQueue.main.sync(execute: buildOnMain)
    }

    /// Host-backed chrome.storage.local / browser.storage.local shim for extension pages.
    /// Only runs on extension schemes so it doesn't affect normal websites.
    static func extensionStorageShimScript() -> WKUserScript {
        let source = """
        (function() {
          try {
            var proto = (location && location.protocol) ? location.protocol : '';
            var isExtensionPage = (proto === 'webkit-extension:' || proto === 'safari-web-extension:');
            if (!isExtensionPage) return;

            if (typeof chrome === 'undefined') { window.chrome = {}; }
            if (typeof browser === 'undefined') { window.browser = window.chrome; }

            var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nookExtensionStorage;
            if (!handler || typeof handler.postMessage !== 'function') return;

            // One request map for all calls
            var pending = Object.create(null);
            function uuid() {
              return String(Date.now()) + '-' + String(Math.random()).slice(2);
            }

            // Exposed for Swift to call back into
            window.__nookStorageResolve = function(requestId, result) {
              try {
                var p = pending[requestId];
                if (!p) return;
                delete pending[requestId];
                p.resolve(result);
              } catch (e) {}
            };
            window.__nookStorageReject = function(requestId, errorMessage) {
              try {
                var p = pending[requestId];
                if (!p) return;
                delete pending[requestId];
                p.reject(new Error(errorMessage || 'Storage error'));
              } catch (e) {}
            };

            function runtimeId() {
              try {
                if (window.browser && browser.runtime && browser.runtime.id) return browser.runtime.id;
                if (window.chrome && chrome.runtime && chrome.runtime.id) return chrome.runtime.id;
              } catch (e) {}
              return null;
            }

            function post(op, payload) {
              var requestId = uuid();
              var extId = runtimeId();
              return new Promise(function(resolve, reject) {
                pending[requestId] = { resolve: resolve, reject: reject };
                try {
                  handler.postMessage({
                    requestId: requestId,
                    op: op,
                    area: 'local',
                    extensionId: extId,
                    payload: payload || null
                  });
                } catch (e) {
                  delete pending[requestId];
                  reject(e);
                }
              });
            }

            function normalizeGetKeys(keys) {
              // chrome.storage.local.get(null|key|[keys]|{defaults})
              if (typeof keys === 'undefined') return null;
              return keys;
            }

            function normalizeRemoveKeys(keys) {
              if (typeof keys === 'string') return [keys];
              if (Array.isArray(keys)) return keys;
              return [];
            }

            function makeArea() {
              return {
                get: function(keys, callback) {
                  var k = normalizeGetKeys(keys);
                  var cb = (typeof callback === 'function') ? callback : null;
                  return post('get', { keys: k }).then(function(result) {
                    if (cb) cb(result || {});
                    return result || {};
                  });
                },
                set: function(items, callback) {
                  var cb = (typeof callback === 'function') ? callback : null;
                  return post('set', { items: items || {} }).then(function(result) {
                    if (cb) cb();
                    return result;
                  });
                },
                remove: function(keys, callback) {
                  var cb = (typeof callback === 'function') ? callback : null;
                  return post('remove', { keys: normalizeRemoveKeys(keys) }).then(function(result) {
                    if (cb) cb();
                    return result;
                  });
                },
                clear: function(callback) {
                  var cb = (typeof callback === 'function') ? callback : null;
                  return post('clear', {}).then(function(result) {
                    if (cb) cb();
                    return result;
                  });
                }
              };
            }

            // Force local to our shim for stability (WebKit MV3 storage can be flaky).
            chrome.storage = chrome.storage || {};
            browser.storage = browser.storage || chrome.storage;
            chrome.storage.local = makeArea();
            browser.storage.local = chrome.storage.local;

            // Many extensions (including Safari builds) may write to storage.sync.
            // Map sync to the same host-backed store for persistence.
            chrome.storage.sync = chrome.storage.local;
            browser.storage.sync = chrome.storage.local;
          } catch (e) {
            // Swallow to avoid breaking extension pages
          }
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    /// Spotify web player helper: detects ad tracks and skips or fast-forwards them.
    /// Runs only on open.spotify.com and related player hosts.
    static func spotifyAdSkipUserScript() -> WKUserScript {
        let source = """
        (function() {
          try {
            if (typeof window === 'undefined' || typeof document === 'undefined') return;
            var host = (window.location && window.location.hostname) || '';
            host = host.toLowerCase();
            // Strict Isolation for academic/LTI domains (Canvas/Kaltura/Okta/etc.)
            if (host.indexOf('canvas') !== -1) return;
            if (host === 'instructure.com' || host.endsWith('.instructure.com')) return;
            if (host === 'kaltura.com' || host.endsWith('.kaltura.com')) return;
            if (host === 'okta.com' || host.endsWith('.okta.com')) return;
            if (host !== 'open.spotify.com' && !host.endsWith('.spotify.com')) return;

            function trySkipAd() {
              try {
                var adLabel = document.querySelector('[data-testid="track-info-advertiser"]');
                var skipButton = document.querySelector('[data-testid="control-button-skip-forward"]');
                if (adLabel && skipButton) {
                  skipButton.click();
                  return true;
                }
              } catch (e) {}
              return false;
            }

            function speedThroughAd() {
              try {
                var media = document.querySelector('video, audio');
                if (!media) return;
                if (media.duration && media.duration > 0 && media.duration <= 60) {
                  try { media.muted = true; } catch (e) {}
                  try { media.playbackRate = 16.0; } catch (e) {}
                }
              } catch (e) {}
            }

            function restoreIfNotAd() {
              try {
                var media = document.querySelector('video, audio');
                if (!media) return;
                if (media.duration && media.duration > 60) {
                  try { media.playbackRate = 1.0; } catch (e) {}
                  try { media.muted = false; } catch (e) {}
                }
              } catch (e) {}
            }

            var observer = new MutationObserver(function() {
              if (trySkipAd()) {
                return;
              }
              speedThroughAd();
              restoreIfNotAd();
            });

            if (document.body) {
              observer.observe(document.body, { childList: true, subtree: true });
            } else {
              document.addEventListener('DOMContentLoaded', function() {
                try {
                  observer.observe(document.body, { childList: true, subtree: true });
                } catch (e) {}
              });
            }
          } catch (e) {
          }
        })();
        """
        if #available(macOS 14.0, *) {
            return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        } else {
            return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        }
    }

    /// Simple cosmetic filtering to hide common ad containers and Playwire shells.
    static func adContainerHiderUserScript() -> WKUserScript {
        let source = """
        (function() {
          try {
            if (typeof document === 'undefined') return;
            var host = (window.location && window.location.hostname) || '';
            host = host.toLowerCase();
            // Strict Isolation for academic/LTI domains (Canvas/Kaltura/Okta/etc.)
            if (host.indexOf('canvas') !== -1) return;
            if (host === 'instructure.com' || host.endsWith('.instructure.com')) return;
            if (host === 'kaltura.com' || host.endsWith('.kaltura.com')) return;
            if (host === 'okta.com' || host.endsWith('.okta.com')) return;
            var style = document.createElement('style');
            style.type = 'text/css';
            style.textContent = [
              'div[class*="ad-"]',
              'div[class*="-ad"]',
              'aside[class*="ad-"]',
              '.playwire-ad',
              '.advertisement',
              '.ad-container',
              '.ad-wrapper'
            ].join(',') + ' { display: none !important; }';
            (document.head || document.documentElement).appendChild(style);
          } catch (e) {
          }
        })();
        """
        if #available(macOS 14.0, *) {
            return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        } else {
            return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        }
    }

    static func downloadsPolyfillScript() -> WKUserScript {
        let source = """
        (function() {
            try {
                if (typeof chrome === 'undefined') { window.chrome = {}; }
                if (typeof browser === 'undefined') { window.browser = window.chrome; }
                chrome.downloads = chrome.downloads || {};
                chrome.downloads.download = chrome.downloads.download || function(options, callback) {
                    try {
                        if (window.webkit && window.webkit.messageHandlers.nookExtensionDownload) {
                            window.webkit.messageHandlers.nookExtensionDownload.postMessage(options);
                        } else {
                            // Fallback to a tag
                            var a = document.createElement('a');
                            a.href = options.url;
                            if (options.filename) a.download = options.filename;
                            document.body.appendChild(a);
                            a.click();
                            a.remove();
                        }
                        if (callback) callback(1); // Fake download ID
                    } catch(e) {
                        console.error("Download polyfill error", e);
                    }
                };
                browser.downloads = chrome.downloads;
                
                if (!chrome.webNavigation) { chrome.webNavigation = {}; }
                if (!chrome.webNavigation.onHistoryStateUpdated) {
                    chrome.webNavigation.onHistoryStateUpdated = { addListener: function() {}, removeListener: function() {}, hasListener: function() { return false; } };
                }
                if (!chrome.webNavigation.onReferenceFragmentUpdated) {
                    chrome.webNavigation.onReferenceFragmentUpdated = { addListener: function() {}, removeListener: function() {}, hasListener: function() { return false; } };
                }
                
                // Polyfill tabs.query to never return undefined for url
                if (!chrome.tabs) chrome.tabs = {};
                if (!browser.tabs) browser.tabs = chrome.tabs;
                if (chrome.tabs.query) {
                    var origQuery = chrome.tabs.query;
                    chrome.tabs.query = function(queryInfo, callback) {
                        var fallbackUrl = window.location.href; // At least it's a URL
                        var ret = origQuery.call(chrome.tabs, queryInfo, function(tabs) {
                            if (tabs) {
                                for (var i = 0; i < tabs.length; i++) {
                                    if (tabs[i] && typeof tabs[i].url === 'undefined') {
                                        tabs[i].url = fallbackUrl;
                                    }
                                }
                            }
                            if (callback) callback(tabs);
                        });
                        if (ret && typeof ret.then === 'function') {
                            return ret.then(function(tabs) {
                                if (tabs) {
                                    for (var i = 0; i < tabs.length; i++) {
                                        if (tabs[i] && typeof tabs[i].url === 'undefined') {
                                            tabs[i].url = fallbackUrl;
                                        }
                                    }
                                }
                                return tabs;
                            });
                        }
                        return ret;
                    };
                    browser.tabs.query = chrome.tabs.query;
                }
                
                // Polyfill events to provide hasListeners and inject port.sender/sender.url
                function fixEvent(obj, eventName) {
                    if (!obj || !obj.runtime || !obj.runtime[eventName]) { return; }
                    if (obj.runtime[eventName]._nookPatched) { return; }
                    
                    var origEvent = obj.runtime[eventName];
                    var origAddListener = origEvent.addListener;
                    
                    try {
                        var patchedEvent = {
                            addListener: function(listener) {
                                return origAddListener.call(origEvent, function() {
                                    var args = Array.prototype.slice.call(arguments);
                                    if (eventName === 'onConnect' && args.length > 0) {
                                        var port = args[0];
                                        if (port && !port.sender) {
                                            port.sender = { id: obj.runtime.id || 'unknown', url: "webkit-extension://fallback", origin: "webkit-extension://fallback" };
                                        }
                                    } else if (eventName === 'onMessage' && args.length > 1) {
                                        var sender = args[1];
                                        if (sender && !sender.url) {
                                            sender.url = "webkit-extension://fallback";
                                        }
                                    }
                                    // Inject id into sender if missing
                                    if (args.length > 1 && args[1] && typeof args[1] === 'object' && !args[1].id) {
                                        args[1].id = obj.runtime.id || 'unknown';
                                    }
                                    return listener.apply(this, args);
                                });
                            },
                            removeListener: origEvent.removeListener.bind(origEvent),
                            hasListeners: function() { return origEvent.hasListeners ? origEvent.hasListeners() : false; },
                            hasListener: function(l) { return origEvent.hasListener ? origEvent.hasListener(l) : false; },
                            _nookPatched: true
                        };
                        
                        Object.defineProperty(obj.runtime, eventName, {
                            get: function() { return patchedEvent; },
                            configurable: true
                        });
                    } catch(e) {}
                }
                
                fixEvent(window.chrome, 'onConnect');
                fixEvent(window.browser, 'onConnect');
                fixEvent(window.chrome, 'onMessage');
                fixEvent(window.browser, 'onMessage');
                
                // Polyfill localStorage if it is null (WebKit sometimes blocks it in custom schemes/popups)
                try {
                    if (!window.localStorage) {
                        var _ls = {};
                        Object.defineProperty(window, 'localStorage', {
                            value: {
                                getItem: function(key) { return _ls.hasOwnProperty(key) ? _ls[key] : null; },
                                setItem: function(key, value) { _ls[key] = String(value); },
                                removeItem: function(key) { delete _ls[key]; },
                                clear: function() { _ls = {}; },
                                get length() { return Object.keys(_ls).length; },
                                key: function(i) { return Object.keys(_ls)[i] || null; }
                            },
                            configurable: true,
                            enumerable: true
                        });
                    }
                } catch(e) {}
                
                // Debug connect
                try {
                    function wrapConnect(obj) {
                        if (!obj || !obj.runtime || !obj.runtime.connect || obj.runtime.connect._nookPatched) return;
                        var origConnect = obj.runtime.connect;
                        obj.runtime.connect = function() {
                            try {
                                var port = origConnect.apply(this, arguments);
                                if (!port) {
                                    window.webkit.messageHandlers.nookPopupError.postMessage("runtime.connect returned falsy: " + String(port));
                                } else {
                                    if (!port.onMessage || !port.onMessage.addListener) {
                                        window.webkit.messageHandlers.nookPopupError.postMessage("runtime.connect port missing onMessage");
                                    }
                                }
                                return port;
                            } catch(e) {
                                window.webkit.messageHandlers.nookPopupError.postMessage("runtime.connect threw: " + e.message);
                                throw e;
                            }
                        };
                        obj.runtime.connect._nookPatched = true;
                    }
                    wrapConnect(window.chrome);
                    wrapConnect(window.browser);
                } catch(e) {}
                
            } catch(e) {}
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    /// Message handler names that must be registered on each tab's userContentController.
    static func customHandlerNames() -> [String] {
        ["nookPassword", "nookCreditCard", "nookCanvasKalturaIframeDetected", "nookExtensionDownload", "nookExtensionStorage", "nookPopupError", "canopyProceed", "canopyStats", "canopyAmpRedirect", "canopyElementPicker"]
    }

    /// Returns true if the message was handled by a custom feature.
    /// Pass fallbackWebView when the handler (e.g. Tab) owns the webview; WKScriptMessage.webView is often nil in that case.
    static func handleMessage(name: String, message: WKScriptMessage, fallbackWebView: WKWebView? = nil) -> Bool {
        let webView = message.frameInfo.webView ?? message.webView ?? fallbackWebView
        switch name {
        case "nookPassword":
            Task { @MainActor in
                PasswordManager.shared.handleMessage(message, webView: webView)
            }
            return true
        case "nookCreditCard":
            Task { @MainActor in
                CreditCardManager.shared.handleMessage(message, webView: webView)
            }
            return true
        case "nookCanvasKalturaIframeDetected":
            Task { @MainActor in
                CanvasKalturaCompatibilityManager.shared.onKalturaIframeDetected()
            }
            return true
        case "nookExtensionDownload":
            if let options = message.body as? [String: Any], let urlStr = options["url"] as? String {
                let filename = options["filename"] as? String ?? "download"
                Task { @MainActor in
                    if urlStr.starts(with: "data:") {
                        handleDataURIDownload(urlStr: urlStr, filename: filename)
                    } else if urlStr.starts(with: "blob:") {
                        // Blob URLs are hard to download directly from swift without evaluating JS in the same context to read the blob.
                        // Wait, if it's a blob, we might have to use JS to read it as a data URL first or create an anchor tag.
                        // Let's try evaluating an anchor tag download directly in the webview.
                        if let wv = webView {
                            let js = """
                            var a = document.createElement('a');
                            a.href = '\(urlStr)';
                            a.download = '\(filename)';
                            document.body.appendChild(a);
                            a.click();
                            a.remove();
                            """
                            wv.evaluateJavaScript(js)
                        }
                    } else {
                        // Regular URL download
                        if let url = URL(string: urlStr) {
                            let config = URLSessionConfiguration.default
                            let session = URLSession(configuration: config)
                            let task = session.downloadTask(with: url) { localURL, response, error in
                                guard let localURL = localURL, error == nil else { return }
                                let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                                let destURL = downloadsDir.appendingPathComponent(filename)
                                try? FileManager.default.moveItem(at: localURL, to: destURL)
                            }
                            task.resume()
                        }
                    }
                }
            }
            return true
        case "nookPopupError":
            // Previously this case attempted to POST debug data to a local
            // HTTP endpoint on every error. That endpoint often isn't running,
            // which caused repeated connection attempts and slowed things down.
            // The popup error is now handled entirely in-app via the popup console.
            return true
        case "canopyProceed":
            if let urlString = message.body as? String,
               let url = URL(string: urlString),
               let webView = webView {
                Task { @MainActor in
                    CanopyAdBlockManager.shared.bypassedHosts.insert(url.host?.lowercased() ?? "")
                    webView.load(URLRequest(url: url))
                }
            }
            return true
        case "canopyStats":
            Task { @MainActor in
                CanopyStatsManager.shared.handleMessage(message)
            }
            return true
        case "canopyAmpRedirect":
            Task { @MainActor in
                CanopyLinkCleaner.shared.handleAmpRedirect(message, webView: webView)
            }
            return true
        case "canopyElementPicker":
            Task { @MainActor in
                CanopyElementPicker.shared.handleMessage(message, webView: webView)
            }
            return true
        default:
            return false
        }
    }

    private static func handleDataURIDownload(urlStr: String, filename: String) {
        guard let url = URL(string: urlStr), let data = try? Data(contentsOf: url) else { return }
        
        // Find a unique filename
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        var destURL = downloadsDir.appendingPathComponent(filename)
        var counter = 1
        let baseName = destURL.deletingPathExtension().lastPathComponent
        let ext = destURL.pathExtension
        
        while FileManager.default.fileExists(atPath: destURL.path) {
            let newName = "\(baseName) (\(counter)).\(ext)"
            destURL = downloadsDir.appendingPathComponent(newName)
            counter += 1
        }
        
        try? data.write(to: destURL)
    }
}
