//
//  PasswordSuggestionPopoverView.swift
//  Nook
//
//  Safari-style password suggestion popover: NSVisualEffectView background,
//  rounded corners, hover highlighting, keyboard navigation.
//

import AppKit
import SwiftUI
import WebKit

// MARK: - Popover content (SwiftUI)

struct PasswordSuggestionPopoverContent: View {
    let entries: [SavedPasswordEntry]
    let onSelect: (SavedPasswordEntry) -> Void
    let onCancel: () -> Void

    @State private var hoveredId: String?
    @State private var selectedId: String?
    @FocusState private var listFocused: Bool

    private let rowHeight: CGFloat = 44
    private let maxVisibleRows: Int = 6
    private let popoverWidth: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                emptyContent
            } else {
                listContent
            }
        }
        .frame(width: popoverWidth)
        .background(PasswordPopoverBackground())
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear {
            selectedId = entries.first?.id
            listFocused = true
        }
        .onExitCommand {
            onCancel()
        }
    }

    private var emptyContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.slash")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("No saved passwords for this site")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: rowHeight * 2)
        .padding()
    }

    private var listContent: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                PasswordSuggestionRow(
                    entry: entry,
                    isHovered: hoveredId == entry.id,
                    isSelected: selectedId == entry.id,
                    onTap: { selectAndFill(entry) }
                )
                .onHover { hovering in
                    hoveredId = hovering ? entry.id : nil
                }
                .id(entry.id)
            }
        }
        .padding(.vertical, 4)
        .background(Color.clear)
        .focusable(true)
        .focusSection()
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            if let id = selectedId, let entry = entries.first(where: { $0.id == id }) {
                selectAndFill(entry)
            }
            return .handled
        }
    }

    private func moveSelection(by delta: Int) {
        guard !entries.isEmpty else { return }
        let currentIndex = entries.firstIndex(where: { $0.id == selectedId }) ?? 0
        let newIndex = max(0, min(entries.count - 1, currentIndex + delta))
        selectedId = entries[newIndex].id
    }

    private func selectAndFill(_ entry: SavedPasswordEntry) {
        onSelect(entry)
    }
}

// MARK: - Single row

private struct PasswordSuggestionRow: View {
    let entry: SavedPasswordEntry
    let isHovered: Bool
    let isSelected: Bool
    let onTap: () -> Void

    private var displayDomain: String {
        guard let url = URL(string: entry.origin) else { return entry.origin }
        return url.host ?? url.absoluteString
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.username)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)

                    Text(displayDomain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill((isHovered || isSelected) ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Vibrancy background

private struct PasswordPopoverBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Popover presenter (AppKit bridge)

@MainActor
final class PasswordSuggestionPopoverController: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var hostingController: NSHostingController<PasswordSuggestionPopoverContent>?
    private weak var webView: WKWebView?
    private var onSelect: ((SavedPasswordEntry) -> Void)?
    private var onClose: (() -> Void)?

    func show(
        entries: [SavedPasswordEntry],
        anchorRect: CGRect,
        in webView: WKWebView,
        onSelect: @escaping (SavedPasswordEntry) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.webView = webView
        self.onSelect = onSelect
        self.onClose = onClose

        let content = PasswordSuggestionPopoverContent(
            entries: entries,
            onSelect: { [weak self] entry in
                self?.onSelect?(entry)
                self?.dismiss()
            },
            onCancel: { [weak self] in
                self?.dismiss()
            }
        )

        let hosting = NSHostingController(rootView: content)
        hostingController = hosting

        let rowHeight: CGFloat = 44
        let verticalPadding: CGFloat = 16
        let contentHeight: CGFloat = entries.isEmpty
            ? (rowHeight * 2 + verticalPadding)
            : min(CGFloat(entries.count) * rowHeight + verticalPadding, CGFloat(6) * rowHeight + verticalPadding)

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: contentHeight)
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        self.popover = popover

        // Show relative to webView; if it's not in a window yet, show anyway so it appears when the view is visible
        popover.show(relativeTo: anchorRect, of: webView, preferredEdge: .maxY)
    }

    func dismiss() {
        popover?.performClose(nil)
        popover = nil
        hostingController = nil
        onClose?()
        onClose = nil
        onSelect = nil
    }

    func popoverDidClose(_ notification: Notification) {
        onClose?()
        onClose = nil
        onSelect = nil
        popover = nil
        hostingController = nil
    }
}
