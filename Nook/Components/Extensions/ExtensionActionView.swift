//
//  ExtensionActionView.swift
//  Nook
//
//  Clean ExtensionActionView using ONLY native WKWebExtension APIs
//

import SwiftUI
import WebKit
import AppKit
import os

@available(macOS 15.5, *)
struct ExtensionActionView: View {
    let extensions: [InstalledExtension]
    @EnvironmentObject var browserManager: BrowserManager
    @State private var isOverflowHovered: Bool = false
    @State private var isOverflowPresented: Bool = false
    @Environment(BrowserWindowState.self) private var windowState
    
    var body: some View {
        let enabled = extensions.filter { $0.isEnabled }
        let pinned = enabled.filter { $0.isPinnedToToolbar }

        HStack(spacing: 4) {
            // Pinned extensions shown directly in the toolbar
            ForEach(pinned, id: \.id) { ext in
                ExtensionActionButton(ext: ext)
                    .environmentObject(browserManager)
            }

            // Stable overflow anchor: always present while there are enabled extensions.
            if !enabled.isEmpty {
                Button {
                    isOverflowPresented.toggle()
                } label: {
                    Image(systemName: "puzzlepiece.extension")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .padding(6)
                        .background(isOverflowHovered ? Color.white.opacity(0.1) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("Extensions")
                .onHover { hovering in
                    isOverflowHovered = hovering
                }
                .popover(isPresented: $isOverflowPresented, arrowEdge: .bottom) {
                    ExtensionOverflowPopover(
                        extensions: enabled,
                        onTogglePin: { ext in
                            togglePinned(ext)
                        },
                        onOpenAction: { ext in
                            openExtensionAction(ext)
                        }
                    )
                }
            }
        }
    }

    private func togglePinned(_ ext: InstalledExtension) {
        ExtensionManager.shared.setExtensionPinned(ext.id, pinned: !ext.isPinnedToToolbar)
    }

    private static let logger = Logger(subsystem: "com.nook.browser", category: "ExtensionOverflow")

    private func openExtensionAction(_ ext: InstalledExtension) {
        guard let extensionContext = ExtensionManager.shared.getExtensionContext(for: ext.id) else {
            Self.logger.error("No extension context for id=\(ext.id, privacy: .public)")
            return
        }

        if extensionContext.webExtension.hasBackgroundContent {
            extensionContext.loadBackgroundContent { error in
                if let error {
                    Self.logger.error("Background wake failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        let tab = browserManager.currentTab(for: windowState)
        let adapter: ExtensionTabAdapter? = tab.flatMap { ExtensionManager.shared.stableAdapter(for: $0) }
        extensionContext.performAction(for: adapter)
    }
}

@available(macOS 15.5, *)
struct ExtensionActionButton: View {
    let ext: InstalledExtension
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @State private var isHovering: Bool = false
    
    var body: some View {
        Button(action: {
            showExtensionPopup()
        }) {
            Group {
                if let iconPath = ext.iconPath,
                   let nsImage = NSImage(contentsOfFile: iconPath) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .scaledToFit()
                } else {
                    Image(systemName: "puzzlepiece.extension")
                        .foregroundColor(.white)
                }
            }
            .frame(width: 16, height: 16)
            .padding(6)
            .background(isHovering ? .white.opacity(0.1) : .clear)
            .background(ActionAnchorView(extensionId: ext.id))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(ext.name)
        .onHover { state in
            isHovering = state
            
        }
    }
    
    private static let logger = Logger(subsystem: "com.nook.browser", category: "ExtensionAction")

    private func showExtensionPopup() {
        Self.logger.info("Action tapped for '\(self.ext.name, privacy: .public)' id=\(self.ext.id, privacy: .public)")

        guard let extensionContext = ExtensionManager.shared.getExtensionContext(for: ext.id) else {
            Self.logger.error("No extension context for id=\(self.ext.id, privacy: .public). Available: \(ExtensionManager.shared.loadedContextIDs.joined(separator: ", "), privacy: .public)")
            return
        }

        // Wake background worker before triggering the action so the popup
        // doesn't hang waiting for a dead service worker to respond.
        if extensionContext.webExtension.hasBackgroundContent {
            extensionContext.loadBackgroundContent { error in
                if let error {
                    Self.logger.error("Background wake failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        let tab = browserManager.currentTab(for: windowState)
        let adapter: ExtensionTabAdapter? = tab.flatMap { ExtensionManager.shared.stableAdapter(for: $0) }
        Self.logger.info("Calling performAction (tab=\(tab?.name ?? "nil", privacy: .public), adapter=\(adapter != nil ? "yes" : "nil", privacy: .public))")
        extensionContext.performAction(for: adapter)
    }
}

@available(macOS 15.5, *)
#Preview {
    ExtensionActionView(extensions: [])
}

@available(macOS 15.5, *)
private struct ExtensionOverflowPopover: View {
    let extensions: [InstalledExtension]
    let onTogglePin: (InstalledExtension) -> Void
    let onOpenAction: (InstalledExtension) -> Void
    @EnvironmentObject private var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.nookSettings) private var nookSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Extensions")
                .font(.headline)

            if let currentTab = browserManager.currentTab(for: windowState),
               let host = currentTab.url.host {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(
                        "Block ads & trackers on \(host)",
                        isOn: Binding(
                            get: {
                                !browserManager.contentBlockerManager.isDomainAllowed(host)
                            },
                            set: { newValue in
                                // When toggle is ON, we want blocking enabled (so host should NOT be in allowlist).
                                // When toggle is OFF, we allow the domain (disable blocking for this host).
                                browserManager.contentBlockerManager.allowDomain(host, allowed: !newValue)
                                var list = nookSettings.contentBlockerAllowlist
                                let normalized = host.lowercased()
                                if !newValue {
                                    if !list.contains(normalized) {
                                        list.append(normalized)
                                    }
                                } else {
                                    list.removeAll { $0 == normalized }
                                }
                                nookSettings.contentBlockerAllowlist = list
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    .help("Turn Nook’s content blocker on or off for this site")
                }
                .padding(.vertical, 4)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(extensions, id: \.id) { ext in
                        HStack(spacing: 10) {
                            Button {
                                onOpenAction(ext)
                            } label: {
                                Group {
                                    if let iconPath = ext.iconPath,
                                       let nsImage = NSImage(contentsOfFile: iconPath) {
                                        Image(nsImage: nsImage)
                                            .resizable()
                                            .interpolation(.high)
                                            .antialiased(true)
                                            .scaledToFit()
                                    } else {
                                        Image(systemName: "puzzlepiece.extension")
                                    }
                                }
                                .frame(width: 16, height: 16)
                                .padding(4)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                            .help("Open \(ext.name)")

                            Text(ext.name)
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            Button {
                                onTogglePin(ext)
                            } label: {
                                Image(systemName: ext.isPinnedToToolbar ? "pin.fill" : "pin")
                                    .foregroundStyle(ext.isPinnedToToolbar ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(ext.isPinnedToToolbar ? "Unpin from toolbar" : "Pin to toolbar")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(12)
        .frame(minWidth: 260)
    }
}

// MARK: - Anchor View for Popover Positioning
private struct ActionAnchorView: NSViewRepresentable {
    let extensionId: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        if #available(macOS 15.5, *) {
            ExtensionManager.shared.setActionAnchor(for: extensionId, anchorView: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if #available(macOS 15.5, *) {
            ExtensionManager.shared.setActionAnchor(for: extensionId, anchorView: nsView)
        }
    }
}
