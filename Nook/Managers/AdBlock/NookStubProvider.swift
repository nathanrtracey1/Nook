import Foundation
import WebKit

/// Provides stub responses for redirected ad-library scripts via the nookstub:// scheme.
/// Mirrors uBlock Origin's redirect/surrogate resource system.
@MainActor
final class NookStubProvider: NSObject, WKURLSchemeHandler {
    static let shared = NookStubProvider()

    private override init() {}

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: "NookStubProvider", code: -1))
            return
        }

        let name = (url.host ?? "") + url.path
        let (body, mimeType) = stubResource(for: name)
        let data = Data(body.utf8)

        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    // MARK: - Silent audio for Spotify ad redirect

    private static let silentMP3Bytes: Data = {
        // Minimal valid MP3 frame — 0.1s of silence
        Data(base64Encoded: "SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjU4Ljc2LjEwMAAAAAAAAAAAAAAA//tQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAWGluZwAAAA8AAAACAAABhgC7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7//////////////////////////////////////////////////////////////////8AAAAATGF2YzU4LjEzAAAAAAAAAAAAAAAAJAAAAAAAAAAAAYYoRwBHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=") ?? Data()
    }()

    private func stubResource(for name: String) -> (body: String, mime: String) {
        let lower = name.lowercased()

        // Google AdSense
        if lower.contains("adsbygoogle") {
            return (Self.adsbyGoogleStub, "application/javascript")
        }

        // Google Publisher Tags (GPT)
        if lower.contains("gpt.js") || lower.contains("googletagservices") {
            return (Self.gptStub, "application/javascript")
        }

        // Google Tag Manager
        if lower.contains("gtm.js") || lower.contains("googletagmanager") {
            return (Self.gtmStub, "application/javascript")
        }

        // Google Analytics
        if lower.contains("analytics.js") || lower.contains("google-analytics") {
            return (Self.gaStub, "application/javascript")
        }

        // Google IMA SDK (video ads)
        if lower.contains("ima3") || lower.contains("imasdk") {
            return (Self.imaStub, "application/javascript")
        }

        // Amazon apstag
        if lower.contains("apstag") || lower.contains("amazon-adsystem") {
            return (Self.apstagsStub, "application/javascript")
        }

        // Playwire
        if lower.contains("playwire") {
            return ("(function(){ window.playwire = window.playwire || {}; })();", "application/javascript")
        }

        // Fingerprint2
        if lower.contains("fingerprint") {
            return (Self.fingerprintStub, "application/javascript")
        }

        // 1x1 transparent GIF
        if lower.hasSuffix(".gif") || lower.contains("pixel") || lower.contains("1x1") {
            return (Self.transparentGIF, "image/gif")
        }

        // Noop MP3
        if lower.hasSuffix(".mp3") || lower.contains("noop") && lower.contains("mp3") {
            return ("", "audio/mpeg")
        }

        // Noop HTML
        if lower.hasSuffix(".html") || lower.contains("noop") && lower.contains("html") {
            return ("<!DOCTYPE html><html><head></head><body></body></html>", "text/html")
        }

        // Default: noop JS
        return ("(function(){})();", "application/javascript")
    }

    // MARK: - Surrogate scripts (matching uBO's redirect resources)

    private static let adsbyGoogleStub = """
    (function(){
        window.adsbygoogle = window.adsbygoogle || [];
        window.adsbygoogle.loaded = true;
        window.adsbygoogle.push = function(){};
    })();
    """

    private static let gptStub = """
    (function(){
        var p = function(){};
        var s = {addEventListener:p,enableServices:p,enableSingleRequest:p,
                 collapseEmptyDivs:p,disableInitialLoad:p,display:p,refresh:p,
                 setTargeting:p,enableVideoAds:p,setAdIframeTitle:p,
                 defineSlot:function(){return{addService:function(){return this},
                 defineSizeMapping:function(){return this},setTargeting:function(){return this},
                 setCollapseEmptyDiv:function(){return this},get:p}},
                 defineSizeMapping:function(){return{addSize:function(){return this},build:function(){return[]}}},
                 defineOutOfPageSlot:function(){return{addService:function(){return this},setTargeting:function(){return this}}}};
        window.googletag = window.googletag || {};
        window.googletag.cmd = window.googletag.cmd || [];
        window.googletag.cmd.push = function(f){try{f()}catch(e){}};
        window.googletag.pubads = function(){return s};
        window.googletag.companionAds = function(){return{setRefreshUnfilledSlots:p}};
        window.googletag.content = function(){return{setContent:p}};
        window.googletag.defineSlot = s.defineSlot;
        window.googletag.defineOutOfPageSlot = s.defineOutOfPageSlot;
        window.googletag.defineSizeMapping = s.defineSizeMapping;
        window.googletag.display = p;
        window.googletag.enableServices = p;
        window.googletag.destroySlots = p;
        window.googletag.apiReady = true;
        window.googletag.pubadsReady = true;
        while(window.googletag.cmd.length){var c=window.googletag.cmd.shift();try{c()}catch(e){}}
    })();
    """

    private static let gtmStub = """
    (function(){
        window.dataLayer = window.dataLayer || [];
        window.dataLayer.push = function(){};
    })();
    """

    private static let gaStub = """
    (function(){
        var p = function(){};
        var T = function(){return{get:p,set:p,send:p}};
        window.ga = window.ga || function(){(window.ga.q=window.ga.q||[]).push(arguments)};
        window.ga.create = T;
        window.ga.getByName = T;
        window.ga.getAll = function(){return[]};
        window.ga.loaded = true;
        window.__gaTracker = window.ga;
    })();
    """

    private static let imaStub = """
    (function(){
        var p = function(){};
        var E = function(){this.listeners={}};
        E.prototype.addEventListener=function(e,f){this.listeners[e]=this.listeners[e]||[];this.listeners[e].push(f)};
        E.prototype.removeEventListener=function(e,f){var l=this.listeners[e];if(l){var i=l.indexOf(f);if(i>-1)l.splice(i,1)}};
        var g=window.google=window.google||{};
        g.ima={AdDisplayContainer:function(){this.initialize=p;this.destroy=p},
               AdError:function(){this.getErrorCode=function(){return 0};this.getMessage=function(){return''}},
               AdsLoader:function(){E.call(this);this.requestAds=p;this.getSettings=function(){return{setAutoPlayAdBreaks:p,setLocale:p,setPlayerType:p,setPlayerVersion:p}};this.contentComplete=p;this.destroy=p},
               AdsManager:function(){E.call(this);this.init=p;this.start=p;this.resize=p;this.destroy=p;this.getRemainingTime=function(){return 0};this.getVolume=function(){return 1};this.setVolume=p;this.pause=p;this.resume=p;this.skip=p;this.stop=p;this.discardAdBreak=p;this.isCustomClickTrackingUsed=function(){return false};this.isCustomPlaybackUsed=function(){return false};this.getCuePoints=function(){return[]}},
               AdsManagerLoadedEvent:{Type:{ADS_MANAGER_LOADED:'adsManagerLoaded'}},
               AdErrorEvent:{Type:{AD_ERROR:'adError'}},
               AdEvent:{Type:{CONTENT_PAUSE_REQUESTED:'contentPauseRequested',CONTENT_RESUME_REQUESTED:'contentResumeRequested',ALL_ADS_COMPLETED:'allAdsCompleted',LOADED:'loaded',STARTED:'started',COMPLETE:'complete',SKIPPED:'skipped',AD_BREAK_READY:'adBreakReady'}},
               AdsRenderingSettings:function(){},
               ViewMode:{NORMAL:'normal',FULLSCREEN:'fullscreen'}};
    })();
    """

    private static let apstagsStub = """
    (function(){
        window.apstag = {init:function(){},fetchBids:function(o,c){if(c)c([])},setDisplayBids:function(){},targetingKeys:function(){return[]}};
    })();
    """

    private static let fingerprintStub = """
    (function(){
        window.Fingerprint2 = function(){};
        window.Fingerprint2.prototype = {get:function(o,c){if(typeof o==='function'){o([],this)}else if(c){c([],this)}},
        x64hash128:function(){return'0'.repeat(32)}};
        window.Fingerprint2.x64hash128 = function(){return'0'.repeat(32)};
        window.Fingerprint2.getPromise = function(){return Promise.resolve([])};
        window.Fingerprint2.getV18 = function(){return Promise.resolve('0'.repeat(32))};
    })();
    """

    private static let transparentGIF = "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
}
