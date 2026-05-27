import Foundation
import WebKit

/// Element picker: lets the user visually select and permanently hide page elements.
/// Injects a JS overlay on activation, receives the generated CSS selector via message handler,
/// and persists it as a custom cosmetic rule.
@MainActor
final class CanopyElementPicker {
    static let shared = CanopyElementPicker()

    private let rulesKey = "canopy.customCosmeticRules"
    private let rawFiltersKey = "canopy.customFilters"

    private init() {}

    /// All user-created element hiding rules, keyed by domain. "*" = global.
    var customRules: [String: [String]] {
        get {
            guard let data = UserDefaults.standard.data(forKey: rulesKey),
                  let dict = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: rulesKey)
            }
        }
    }

    /// Raw adblock-syntax filter strings entered by the user (for display/editing).
    var rawFilters: [String] {
        get { UserDefaults.standard.stringArray(forKey: rawFiltersKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: rawFiltersKey) }
    }

    // MARK: - Adblock syntax parsing

    /// Parse and add rules in standard adblock cosmetic syntax:
    ///   ##.selector              → global
    ///   example.com##.selector   → domain-specific
    ///   a.com,b.com##.selector   → multiple domains
    ///   example.com#@#.selector  → exception (removes a rule)
    func addFilterRule(_ rule: String) {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("!"), !trimmed.hasPrefix("[") else { return }

        // Store raw filter for display
        var filters = rawFilters
        if !filters.contains(trimmed) {
            filters.append(trimmed)
            rawFilters = filters
        }

        // Exception rule: domain#@#selector
        if trimmed.contains("#@#") {
            let parts = trimmed.components(separatedBy: "#@#")
            guard parts.count == 2 else { return }
            let domains = parts[0].trimmingCharacters(in: .whitespaces)
            let selector = parts[1].trimmingCharacters(in: .whitespaces)
            guard !selector.isEmpty else { return }

            if domains.isEmpty {
                removeRule(host: "*", selector: selector)
            } else {
                for domain in domains.split(separator: ",") {
                    removeRule(host: String(domain).trimmingCharacters(in: .whitespaces).lowercased(), selector: selector)
                }
            }
            return
        }

        // Hiding rule: domain##selector or ##selector
        if trimmed.contains("##") {
            let parts = trimmed.components(separatedBy: "##")
            guard parts.count == 2 else { return }
            let domains = parts[0].trimmingCharacters(in: .whitespaces)
            let selector = parts[1].trimmingCharacters(in: .whitespaces)
            guard !selector.isEmpty else { return }

            if domains.isEmpty {
                addRule(host: "*", selector: selector)
            } else {
                for domain in domains.split(separator: ",") {
                    addRule(host: String(domain).trimmingCharacters(in: .whitespaces).lowercased(), selector: selector)
                }
            }
            return
        }
    }

    /// Parse multiple rules (one per line).
    func addFilterRules(_ text: String) {
        for line in text.split(separator: "\n") {
            addFilterRule(String(line))
        }
    }

    func removeFilterRule(_ rule: String) {
        var filters = rawFilters
        filters.removeAll { $0 == rule }
        rawFilters = filters
        // Re-parse all remaining rules to rebuild the rules dict
        rebuildFromRawFilters()
    }

    func clearAllCustomRules() {
        customRules = [:]
        rawFilters = []
    }

    private func rebuildFromRawFilters() {
        customRules = [:]
        for filter in rawFilters {
            addFilterRule(filter)
        }
    }

    func addRule(host: String, selector: String) {
        var rules = customRules
        var hostRules = rules[host] ?? []
        if !hostRules.contains(selector) {
            hostRules.append(selector)
        }
        rules[host] = hostRules
        customRules = rules
    }

    func removeRule(host: String, selector: String) {
        var rules = customRules
        rules[host]?.removeAll { $0 == selector }
        if rules[host]?.isEmpty == true { rules.removeValue(forKey: host) }
        customRules = rules
    }

    func clearRules(for host: String) {
        var rules = customRules
        rules.removeValue(forKey: host)
        customRules = rules
    }

    /// Inject saved custom rules for a domain after page load.
    func injectCustomRules(for url: URL, in webView: WKWebView) {
        guard let host = url.host?.lowercased() else { return }
        var selectors: [String] = []

        // Global rules (##.selector with no domain)
        if let global = customRules["*"] { selectors.append(contentsOf: global) }

        // Exact domain match
        if let exact = customRules[host] { selectors.append(contentsOf: exact) }

        // Parent domain matches
        var parts = host.split(separator: ".").map(String.init)
        while parts.count > 1 {
            parts.removeFirst()
            if let parent = customRules[parts.joined(separator: ".")] {
                selectors.append(contentsOf: parent)
            }
        }

        guard !selectors.isEmpty else { return }
        let escaped = selectors.map { $0.replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "") }
        let joined = escaped.joined(separator: ",")
        let script = "(function(){try{var s=document.createElement('style');s.textContent='\(joined){display:none!important}';(document.head||document.documentElement).appendChild(s)}catch(e){}})();"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Activate the element picker overlay in the given webview.
    func activate(in webView: WKWebView) {
        webView.evaluateJavaScript(Self.pickerScript, completionHandler: nil)
    }

    /// Handle the selector message from the picker overlay.
    func handleMessage(_ message: WKScriptMessage, webView: WKWebView?) {
        guard let dict = message.body as? [String: Any],
              let type = dict["type"] as? String else { return }

        if type == "picked", let selector = dict["selector"] as? String,
           let host = (webView?.url?.host ?? dict["host"] as? String)?.lowercased() {
            addRule(host: host, selector: selector)
            // Immediately apply the new rule
            let escaped = selector.replacingOccurrences(of: "'", with: "\\'")
            webView?.evaluateJavaScript("(function(){try{document.querySelectorAll('\(escaped)').forEach(function(e){e.style.display='none'});var s=document.createElement('style');s.textContent='\(escaped){display:none!important}';document.head.appendChild(s)}catch(e){}})();", completionHandler: nil)
        }

        if type == "cancel" {
            // Picker was dismissed, nothing to do
        }
    }

    // MARK: - Picker overlay JS

    nonisolated static let pickerScript = """
    (function() {
        if (window.__canopyPickerActive) return;
        window.__canopyPickerActive = true;

        var overlay = document.createElement('div');
        overlay.id = '__canopy_picker_overlay';
        overlay.style.cssText = 'position:fixed;top:0;left:0;right:0;bottom:0;z-index:2147483647;cursor:crosshair;background:transparent;';

        var highlight = document.createElement('div');
        highlight.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483646;border:2px solid #50fa7b;background:rgba(80,250,123,0.15);transition:all 0.05s ease;display:none;';
        document.documentElement.appendChild(highlight);

        var infoBar = document.createElement('div');
        infoBar.style.cssText = 'position:fixed;bottom:20px;left:50%;transform:translateX(-50%);z-index:2147483647;background:#1a1a2e;color:#e0e0e0;padding:12px 20px;border-radius:12px;font:13px/1.4 -apple-system,sans-serif;box-shadow:0 4px 20px rgba(0,0,0,0.4);display:flex;gap:12px;align-items:center;flex-wrap:wrap;max-width:600px;';
        infoBar.innerHTML = '<span style="color:#50fa7b;font-weight:600">🛡 Element Picker</span>'
            + '<label style="color:#8892b0;display:flex;align-items:center;gap:6px">Depth <input id="__canopy_depth" type="range" min="0" max="10" value="0" style="width:80px;accent-color:#50fa7b"></label>'
            + '<button id="__canopy_preview" style="background:#334;border:1px solid #556;color:#aaa;padding:4px 12px;border-radius:6px;cursor:pointer;font:inherit">Preview</button>'
            + '<button id="__canopy_pick" style="background:#50fa7b;border:none;color:#1a1a2e;padding:4px 12px;border-radius:6px;cursor:pointer;font:inherit;font-weight:600" disabled>Block</button>'
            + '<button id="__canopy_picker_cancel" style="background:#334;border:1px solid #556;color:#aaa;padding:4px 12px;border-radius:6px;cursor:pointer;font:inherit">Cancel</button>'
            + '<span id="__canopy_sel_display" style="color:#556;font:11px/1 monospace;max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"></span>';
        document.documentElement.appendChild(infoBar);

        var lastTarget = null;
        var depthTarget = null;
        var currentSelector = null;
        var isPreviewing = false;
        var previewedElements = [];

        function ancestors(el) {
            var chain = [];
            var node = el;
            while (node && node !== document.body && node !== document.documentElement) {
                chain.push(node);
                node = node.parentElement;
            }
            return chain;
        }

        function getSelector(el) {
            if (!el || el === document.body || el === document.documentElement) return null;
            if (el.id && !el.id.startsWith('__canopy')) return '#' + CSS.escape(el.id);
            var cls = Array.from(el.classList).filter(function(c) {
                return c.length > 1 && !c.startsWith('__canopy') && !c.match(/^(js-|is-|has-|active|hover|focus|visible|hidden|show|open)/i);
            });
            if (cls.length > 0) {
                var sel = el.tagName.toLowerCase() + '.' + cls.map(function(c){return CSS.escape(c)}).join('.');
                if (document.querySelectorAll(sel).length <= 3) return sel;
            }
            var tag = el.tagName.toLowerCase();
            var parent = el.parentElement;
            if (parent) {
                var siblings = Array.from(parent.children).filter(function(c){return c.tagName===el.tagName});
                if (siblings.length > 1) {
                    var idx = siblings.indexOf(el) + 1;
                    var parentSel = getSelector(parent);
                    if (parentSel) return parentSel + ' > ' + tag + ':nth-child(' + idx + ')';
                }
                var parentSel = getSelector(parent);
                if (parentSel) return parentSel + ' > ' + tag;
            }
            return tag;
        }

        function updateHighlight(el) {
            if (!el) { highlight.style.display = 'none'; return; }
            var rect = el.getBoundingClientRect();
            highlight.style.display = 'block';
            highlight.style.top = rect.top + 'px';
            highlight.style.left = rect.left + 'px';
            highlight.style.width = rect.width + 'px';
            highlight.style.height = rect.height + 'px';
        }

        function resolveDepthTarget() {
            if (!lastTarget) return null;
            var depth = parseInt(document.getElementById('__canopy_depth').value) || 0;
            var chain = ancestors(lastTarget);
            var idx = Math.min(depth, chain.length - 1);
            return chain[idx] || lastTarget;
        }

        function updateSelection() {
            depthTarget = resolveDepthTarget();
            updateHighlight(depthTarget);
            currentSelector = depthTarget ? getSelector(depthTarget) : null;
            document.getElementById('__canopy_sel_display').textContent = currentSelector || '';
            document.getElementById('__canopy_pick').disabled = !currentSelector;
        }

        overlay.addEventListener('mousemove', function(e) {
            overlay.style.pointerEvents = 'none';
            var target = document.elementFromPoint(e.clientX, e.clientY);
            overlay.style.pointerEvents = 'auto';
            if (!target || target === overlay || target === highlight || target === infoBar || infoBar.contains(target)) {
                // Keep the current selection when hovering over the picker UI
                return;
            }
            lastTarget = target;
            updateSelection();
        });

        document.getElementById('__canopy_depth').addEventListener('input', updateSelection);

        document.getElementById('__canopy_preview').addEventListener('click', function(e) {
            e.preventDefault(); e.stopPropagation();
            if (isPreviewing) {
                previewedElements.forEach(function(item) { item.el.style.display = item.orig; });
                previewedElements = [];
                isPreviewing = false;
                this.textContent = 'Preview';
                this.style.color = '#aaa';
            } else if (currentSelector) {
                var els = document.querySelectorAll(currentSelector);
                els.forEach(function(el) {
                    previewedElements.push({ el: el, orig: el.style.display });
                    el.style.display = 'none';
                });
                isPreviewing = true;
                this.textContent = 'Undo Preview';
                this.style.color = '#ff6b6b';
            }
        });

        document.getElementById('__canopy_pick').addEventListener('click', function(e) {
            e.preventDefault(); e.stopPropagation();
            if (currentSelector && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.canopyElementPicker) {
                window.webkit.messageHandlers.canopyElementPicker.postMessage({type:'picked', selector:currentSelector, host:location.hostname});
            }
            cleanup();
        });

        document.getElementById('__canopy_picker_cancel').addEventListener('click', function(e) {
            e.preventDefault(); e.stopPropagation();
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.canopyElementPicker) {
                window.webkit.messageHandlers.canopyElementPicker.postMessage({type:'cancel'});
            }
            cleanup();
        });

        document.documentElement.appendChild(overlay);

        function cleanup() {
            window.__canopyPickerActive = false;
            previewedElements.forEach(function(item) { item.el.style.display = item.orig; });
            previewedElements = [];
            overlay.remove();
            highlight.remove();
            infoBar.remove();
        }

        document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape' && window.__canopyPickerActive) {
                cleanup();
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.canopyElementPicker) {
                    window.webkit.messageHandlers.canopyElementPicker.postMessage({type:'cancel'});
                }
            }
            if (window.__canopyPickerActive && (e.key === 'ArrowUp' || e.key === 'ArrowDown')) {
                e.preventDefault();
                var slider = document.getElementById('__canopy_depth');
                var val = parseInt(slider.value) || 0;
                slider.value = e.key === 'ArrowUp' ? Math.min(10, val + 1) : Math.max(0, val - 1);
                updateSelection();
            }
        });
    })();
    """
}
