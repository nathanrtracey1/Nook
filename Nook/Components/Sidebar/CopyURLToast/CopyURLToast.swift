//
//  CopyURLToast.swift
//  Nook
//
//  Created on 2025-01-XX.
//

import AppKit
import SwiftUI

struct CopyURLToast: View {
    @Environment(BrowserWindowState.self) private var windowState

    var body: some View {
        ToastView {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .frame(width: 14, height: 14)
                    .padding(4)
                    .background(Color(nsColor: .labelColor).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text("Copied Current URL")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: .labelColor))
            }
        }
        .transition(.toast)
        .onAppear {
            // Auto-dismiss after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                windowState.isShowingCopyURLToast = false
            }
        }
        .onTapGesture {
            windowState.isShowingCopyURLToast = false
        }
    }
}

