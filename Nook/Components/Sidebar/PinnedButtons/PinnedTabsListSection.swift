//
//  PinnedTabsListSection.swift
//  Nook
//
//  Space-pinned tabs for the current space: same SidebarTabRow (SpaceTab) UI as in the space.
//  Favicon resets to root URL; Edit Pinned URL updates rootURL without reloading.
//

import SwiftUI

struct PinnedTabsListSection: View {
    let width: CGFloat
    /// Space whose pinned tabs are shown; nil shows empty section.
    let currentSpaceId: UUID?

    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var dragSession = NookDragSessionManager.shared

    private var items: [Tab] {
        guard let spaceId = currentSpaceId else { return [] }
        return browserManager.tabManager.spacePinnedTabs(for: spaceId)
    }

    private var zoneID: DropZoneID? {
        currentSpaceId.map { .spacePinned($0) }
    }

    var body: some View {
        Group {
            if let zone = zoneID {
                listContent(zone: zone)
            } else {
                emptyState
            }
        }
    }

    private func listContent(zone: DropZoneID) -> some View {
        NookDropZoneHostView(
            zoneID: zone,
            isVertical: true,
            manager: dragSession
        ) {
            Group {
                if items.isEmpty {
                    emptyState
                } else {
                    listContentInner(zone: zone)
                }
            }
            .onAppear {
                updateDragSessionForList(zone: zone)
            }
            .onChange(of: items.count) { _, newCount in
                dragSession.itemCounts[zone] = newCount
            }
            .onChange(of: dragSession.pendingDrop) { _, drop in
                handleDrop(drop, zone: zone)
            }
            .onChange(of: dragSession.pendingReorder) { _, reorder in
                handleReorder(reorder, zone: zone)
            }
        }
    }

    private var emptyState: some View {
        let isDragging = dragSession.isDragging
        return VStack(spacing: 8) {
            Image(systemName: "pin.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(spacing: 2) {
                Text("Drag to add Pinned")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Pinned tabs stay at the top and keep their session")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                .foregroundStyle(isDragging ? Color.primary.opacity(0.4) : Color.secondary.opacity(0.3))
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isDragging
                    ? (colorScheme == .dark ? AppColors.pinnedTabHoverLight : AppColors.pinnedTabHoverDark)
                    : Color.clear
                )
        }
        .animation(.easeInOut(duration: 0.15), value: isDragging)
    }

    private func listContentInner(zone: DropZoneID) -> some View {
        let insertionIdx = dragSession.insertionIndex[zone]
        return VStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, tab in
                if let ins = insertionIdx, ins == index, dragSession.sourceZone != zone {
                    insertionPlaceholder
                }
                row(for: tab, index: index, zone: zone)
            }
            if let ins = insertionIdx, ins >= items.count {
                insertionPlaceholder
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: insertionIdx)
    }

    private func row(for tab: Tab, index: Int, zone: DropZoneID) -> some View {
        let isDragged = dragSession.draggedItem?.tabId == tab.id
        return NookDragSourceView(
            item: NookDragItem(tabId: tab.id, title: tab.name, urlString: tab.url.absoluteString),
            tab: tab,
            zoneID: zone,
            index: index,
            manager: dragSession
        ) {
            SpaceTab(
                tab: tab,
                action: { browserManager.selectTab(tab, in: windowState) },
                onClose: { browserManager.tabManager.removeTab(tab.id) },
                onMute: { tab.toggleMute() },
                isSpacePinned: true,
                onMinimize: { browserManager.tabManager.unloadTab(tab) },
                onRemoveFromPinned: { browserManager.tabManager.unpinTabFromSpace(tab) },
                onFaviconTap: { browserManager.tabManager.reloadPinnedTabToRoot(tab) }
            )
            .environmentObject(browserManager)
            .environment(windowState)
        }
        .id(tab.id)
        .opacity(isDragged ? 0.4 : 1)
        .offset(y: dragSession.reorderOffset(for: zone, at: index))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dragSession.insertionIndex[zone])
    }

    private var insertionPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(0.12))
            .frame(height: 32)
            .frame(maxWidth: .infinity)
    }

    private func updateDragSessionForList(zone: DropZoneID) {
        dragSession.itemCellSize[zone] = 36
        dragSession.itemCellSpacing[zone] = 2
        dragSession.itemCounts[zone] = items.count
    }

    private func handleDrop(_ drop: PendingDrop?, zone: DropZoneID) {
        guard let drop = drop, drop.targetZone == zone else { return }
        let allTabs = browserManager.tabManager.allTabs()
        guard let tab = allTabs.first(where: { $0.id == drop.item.tabId }) else { return }
        let op = dragSession.makeDragOperation(from: drop, tab: tab)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            browserManager.tabManager.handleDragOperation(op)
        }
        dragSession.pendingDrop = nil
    }

    private func handleReorder(_ reorder: PendingReorder?, zone: DropZoneID) {
        guard let reorder = reorder, reorder.zone == zone else { return }
        guard reorder.fromIndex < items.count else {
            dragSession.pendingReorder = nil
            return
        }
        let tab = items[reorder.fromIndex]
        let op = dragSession.makeDragOperation(from: reorder, tab: tab)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            browserManager.tabManager.handleDragOperation(op)
        }
        dragSession.pendingReorder = nil
    }
}
