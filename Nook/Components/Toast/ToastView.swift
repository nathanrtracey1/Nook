//
//  ToastView.swift
//  Nook
//
//  Unified toast container component with standardized FindBar-style styling.
//  Uses material background and adaptive label colors so toasts stay readable on light and dark gradients.
//

import AppKit
import SwiftUI
import UniversalGlass

/// Adaptive foreground color for toast content: readable on both light and dark backgrounds.
private var toastLabelColor: Color {
    Color(nsColor: .labelColor)
}

/// Slightly muted color for secondary toast text.
private var toastSecondaryColor: Color {
    Color(nsColor: .secondaryLabelColor)
}

/// A reusable toast container that provides standardized visual styling.
/// Use with `.transition(.toast)` and `.animation(.smooth(duration: 0.25), value: condition)` in parent.
struct ToastView<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .fixedSize(horizontal: true, vertical: false)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 2)
    }
}

/// Custom toast transition matching FindBar animation exactly (opacity + blur)
extension AnyTransition {
    static var toast: AnyTransition {
        .modifier(
            active: ToastTransitionModifier(opacity: 0, blur: 8),
            identity: ToastTransitionModifier(opacity: 1, blur: 0)
        )
    }
}

private struct ToastTransitionModifier: ViewModifier {
    let opacity: Double
    let blur: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .blur(radius: blur)
    }
}

// MARK: - Toast Content Helpers

/// Standard icon + text toast content with adaptive styling (readable on light and dark).
struct ToastContent: View {
    let icon: String
    let text: String
    var iconForeground: Color = toastLabelColor
    var textForeground: Color = toastLabelColor

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(iconForeground)
                .frame(width: 14, height: 14)
                .padding(4)
                .background(toastLabelColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(toastLabelColor.opacity(0.25), lineWidth: 1)
                }

            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textForeground)
        }
    }
}

/// Multi-line toast content for showing a title with a subtitle (adaptive colors).
struct ToastContentWithSubtitle: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(toastLabelColor)
                .frame(width: 14, height: 14)
                .padding(4)
                .background(toastLabelColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(toastLabelColor.opacity(0.25), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(toastLabelColor)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(toastSecondaryColor)
            }
        }
    }
}
