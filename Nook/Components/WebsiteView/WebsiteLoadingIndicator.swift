//
//  WebsiteLoadingIndicator.swift
//  Nook
//
//  Arc-style loading bar: very thin line at the top of the page content, full width,
//  fills left-to-right. Overlaid on webpage content, not in the border. Safe for DRM/EME.
//

import SwiftUI

struct WebsiteLoadingIndicator: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState

    /// Arc uses a 2pt line at the very top of the content
    private let barHeight: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                let width = max(0, geo.size.width * progressFraction)
                Capsule()
                    .fill(progressColor)
                    .frame(width: width, height: barHeight)
                    .animation(.easeOut(duration: 0.12), value: progressFraction)
            }
            .frame(maxWidth: .infinity)
            .frame(height: barHeight)
        }
        .frame(height: barHeight)
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isVisible)
        .allowsHitTesting(false)
    }

    private var progressColor: Color {
        Color.accentColor
    }

    private var isVisible: Bool {
        guard let tab = browserManager.currentTab(for: windowState) else { return false }
        switch tab.loadingState {
        case .didStartProvisionalNavigation, .didCommit:
            return true
        case .idle, .didFinish, .didFail, .didFailProvisionalNavigation:
            return false
        }
    }

    private var progressFraction: CGFloat {
        guard let tab = browserManager.currentTab(for: windowState) else { return 0 }
        switch tab.loadingState {
        case .idle, .didFinish, .didFail, .didFailProvisionalNavigation:
            return 0
        case .didStartProvisionalNavigation, .didCommit:
            return min(1.0, max(0, CGFloat(tab.estimatedProgress)))
        }
    }
}
