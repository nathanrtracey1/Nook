//
//  ShortcutConflictToast.swift
//  Nook
//
//  Created by AI Assistant on 2025.
//
//  Toast notification shown when a keyboard shortcut conflicts between
//  Nook and a website. Informs users they can press again for Nook action.
//

import AppKit
import SwiftUI
import UniversalGlass

// MARK: - Shortcut Conflict Toast View

struct ShortcutConflictToast: View {
    let conflictInfo: ShortcutConflictInfo
    
    var body: some View {
        ToastView {
            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .frame(width: 18, height: 18)
                    .padding(5)
                    .background(Color(nsColor: .labelColor).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(conflictInfo.keyCombination.displayString)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(nsColor: .labelColor))
                        Text("used by")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        Text(conflictInfo.websiteName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(nsColor: .labelColor))
                    }
                    
                    HStack(spacing: 4) {
                        Text("Press again for")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        Text(conflictInfo.nookActionName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                }
            }
        }
        .transition(.toast)
    }
}

// MARK: - Preview

#Preview {
    ShortcutConflictToast(
        conflictInfo: ShortcutConflictInfo(
            keyCombination: KeyCombination(key: "k", modifiers: [.command]),
            websiteName: "Figma",
            websiteShortcutDescription: "Search / Quick Actions",
            nookActionName: "Command Palette",
            windowId: UUID()
        )
    )
    .padding()
    .background(Color.gray.opacity(0.3))
}