import AppKit
import AVKit
import WebKit

/// Native macOS video/audio player window.
/// Opens media URLs in an AVPlayer window outside the browser.
@MainActor
final class CanopyNativePlayer {
    static let shared = CanopyNativePlayer()

    private let enabledKey = "canopy.nativePlayer.enabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private init() {}

    /// Open a URL in a native AVPlayer window.
    func openInNativePlayer(url: URL) {
        let player = AVPlayer(url: url)
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 854, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = playerView
        window.title = url.lastPathComponent
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        player.play()
    }

    /// Detect media URL from a webview and open in native player.
    func openCurrentMedia(from webView: WKWebView) {
        let script = """
        (function() {
            var media = document.querySelector('video[src], audio[src]');
            if (media && media.src) return media.src;
            var source = document.querySelector('video source[src], audio source[src]');
            if (source && source.src) return source.src;
            var video = document.querySelector('video');
            if (video && video.currentSrc) return video.currentSrc;
            var audio = document.querySelector('audio');
            if (audio && audio.currentSrc) return audio.currentSrc;
            return null;
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let urlString = result as? String, let url = URL(string: urlString) else {
                self?.showNoMediaAlert()
                return
            }
            self?.openInNativePlayer(url: url)
        }
    }

    /// Extract media URL from a right-clicked element.
    func openMediaFromContextMenu(src: String) {
        guard let url = URL(string: src) else { return }
        openInNativePlayer(url: url)
    }

    private func showNoMediaAlert() {
        let alert = NSAlert()
        alert.messageText = "No Media Found"
        alert.informativeText = "No video or audio element was found on this page."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
