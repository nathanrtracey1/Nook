//
//  TabClosureToast.swift
//  Nook
//
//  Created by Jonathan Caudill on 02/10/2025.
//

import AppKit
import SwiftUI

struct TabClosureToast: View {
    @EnvironmentObject var browserManager: BrowserManager

    var body: some View {
        ToastView {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .frame(width: 14, height: 14)
                    .padding(4)
                    .background(Color(nsColor: .labelColor).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(browserManager.tabClosureToastCount) tab\(browserManager.tabClosureToastCount > 1 ? "s" : "") closed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(nsColor: .labelColor))

                    Text("Press ⌘Z to undo")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
            }
        }
        .transition(.toast)
        .onAppear {
            // Auto-dismiss after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                browserManager.hideTabClosureToast()
            }
        }
        .onTapGesture {
            browserManager.hideTabClosureToast()
        }
    }
}
