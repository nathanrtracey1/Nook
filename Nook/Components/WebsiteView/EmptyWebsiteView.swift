//
//  EmptyWebsiteView.swift
//  Nook
//
//  Created by Maciek Bagiński on 28/07/2025.
//

import SwiftUI

struct EmptyWebsiteView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.webContentBorderless) private var webContentBorderless
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                let radius: CGFloat = webContentBorderless ? 0 : (/* macOS 26 */ 6)
                // Match the exact background and styling of the real webview
                Color(nsColor: .windowBackgroundColor).opacity(0.2)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .shadow(color: webContentBorderless ? .clear : Color.black.opacity(0.3), radius: webContentBorderless ? 0 : 4, x: 0, y: 0)

                VStack(spacing: 16) {
                    Image(systemName: "moon.stars")
                        .font(.system(size: 32, weight: .medium))
                        .blendMode(.overlay)

                    Text("Ah, peace.")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .black.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
