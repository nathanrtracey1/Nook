//
//  PrivacySettingsView.swift
//  Nook
//
//  Created by Jonathan Caudill on 15/08/2025.
//

import SwiftUI
import WebKit
import AppKit
import UniformTypeIdentifiers

struct PrivacySettingsView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(\.nookSettings) var nookSettings
    @StateObject private var cookieManager = CookieManager()
    @StateObject private var cacheManager = CacheManager()
    @State private var showingCookieManager = false
    @State private var showingCacheManager = false
    @State private var isClearing = false
    @State private var newExceptionHost: String = ""
    @State private var newFilterRule: String = ""
    @State private var newListName: String = ""
    @State private var newListURL: String = ""
    @ObservedObject private var customListManager = CanopyCustomListManager.shared

    var body: some View {
        @Bindable var settings = nookSettings

        return VStack(alignment: .leading, spacing: 20) {
            // Cookie Management Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Cookie Management")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    cookieStatsView
                    
                    HStack {
                        Button("Manage Cookies") {
                            showingCookieManager = true
                        }
                        .buttonStyle(.bordered)
                        
                        Menu("Clear Data") {
                            Button("Clear Expired Cookies") {
                                clearExpiredCookies()
                            }
                            
                            Button("Clear Third-Party Cookies") {
                                clearThirdPartyCookies()
                            }
                            
                            Button("Clear High-Risk Cookies") {
                                clearHighRiskCookies()
                            }
                            
                            Divider()
                            
                            Button("Clear All Cookies") {
                                clearAllCookies()
                            }
                            
                            Button("Privacy Cleanup") {
                                performCookiePrivacyCleanup()
                            }
                            
                            Divider()
                            
                            Button("Clear All Website Data", role: .destructive) {
                                clearAllWebsiteData()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isClearing)
                        
                        if isClearing {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            Divider()
            
            // Cache Management Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Cache Management")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    cacheStatsView
                    
                    HStack {
                        Button("Manage Cache") {
                            showingCacheManager = true
                        }
                        .buttonStyle(.bordered)
                        
                        Menu("Clear Cache") {
                            Button("Clear Stale Cache") {
                                clearStaleCache()
                            }
                            
                            Button("Clear Personal Data Cache") {
                                clearPersonalDataCache()
                            }
                            
                            Button("Clear Disk Cache") {
                                clearDiskCache()
                            }
                            
                            Button("Clear Memory Cache") {
                                clearMemoryCache()
                            }
                            
                            Divider()
                            
                            Button("Privacy Cleanup") {
                                performCachePrivacyCleanup()
                            }
                            
                            Divider()
                            
                            Button("Clear All Cache", role: .destructive) {
                                clearAllCache()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isClearing)
                        
                        if isClearing {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            Divider()
            
            // Privacy Controls Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Privacy Controls")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    // Activated: Block cross‑site tracking via content rules + iframe cookie shim
                    Toggle("Block Cross-Site Tracking", isOn: $settings.blockCrossSiteTracking)
                        .onChange(of: nookSettings.blockCrossSiteTracking) { _, enabled in
                            browserManager.trackingProtectionManager.setEnabled(enabled)
                        }

                    // Canopy Ad Blocker
                    Toggle("Canopy Ad Blocker", isOn: $settings.contentBlockingEnabled)
                        .onChange(of: nookSettings.contentBlockingEnabled) { _, enabled in
                            CanopyAdBlockManager.shared.setEnabled(enabled)
                        }

                    if settings.contentBlockingEnabled {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Block ads (EasyList, AdGuard, uBlock Origin)", isOn: Binding(
                                get: { CanopyAdBlockManager.shared.isAdBlockEnabled },
                                set: { CanopyAdBlockManager.shared.isAdBlockEnabled = $0 }
                            ))
                            .font(.subheadline)

                            Toggle("Block trackers (EasyPrivacy, Peter Lowe's)", isOn: Binding(
                                get: { CanopyAdBlockManager.shared.isTrackerBlockEnabled },
                                set: { CanopyAdBlockManager.shared.isTrackerBlockEnabled = $0 }
                            ))
                            .font(.subheadline)

                            Toggle("Cosmetic filtering (hide ad containers)", isOn: Binding(
                                get: { CanopyAdBlockManager.shared.isCosmeticEnabled },
                                set: { CanopyAdBlockManager.shared.isCosmeticEnabled = $0 }
                            ))
                            .font(.subheadline)

                            Toggle("Strip tracking parameters (utm, fbclid, gclid)", isOn: Binding(
                                get: { CanopyAdBlockManager.shared.isParamStrippingEnabled },
                                set: { CanopyAdBlockManager.shared.isParamStrippingEnabled = $0 }
                            ))
                            .font(.subheadline)

                            Toggle("Unwrap tracking links (Google, Facebook, Reddit)", isOn: Binding(
                                get: { CanopyLinkCleaner.shared.isTrackingRedirectsEnabled },
                                set: { CanopyLinkCleaner.shared.isTrackingRedirectsEnabled = $0 }
                            ))
                            .font(.subheadline)

                            Toggle("Redirect AMP pages to original", isOn: Binding(
                                get: { CanopyLinkCleaner.shared.isAmpRedirectEnabled },
                                set: { CanopyLinkCleaner.shared.isAmpRedirectEnabled = $0 }
                            ))
                            .font(.subheadline)

                            Toggle("YouTube ad blocking", isOn: .constant(true))
                                .disabled(true)
                                .font(.subheadline)

                            Toggle("Spotify ad muting", isOn: Binding(
                                get: { CanopyExtras.shared.isSpotifyAdBlockEnabled },
                                set: { CanopyExtras.shared.isSpotifyAdBlockEnabled = $0 }
                            ))
                            .font(.subheadline)

                            Toggle("Block ad popups", isOn: Binding(
                                get: { CanopyExtras.shared.isPopupBlockEnabled },
                                set: { CanopyExtras.shared.isPopupBlockEnabled = $0 }
                            ))
                            .font(.subheadline)

                            Toggle("Auto-dismiss cookie banners", isOn: Binding(
                                get: { CanopyExtras.shared.isCookieConsentEnabled },
                                set: { CanopyExtras.shared.isCookieConsentEnabled = $0 }
                            ))
                            .font(.subheadline)

                            Toggle("Clean tracking params in page links", isOn: Binding(
                                get: { CanopyExtras.shared.isSubresourceParamEnabled },
                                set: { CanopyExtras.shared.isSubresourceParamEnabled = $0 }
                            ))
                            .font(.subheadline)

                            HStack(spacing: 6) {
                                Image(systemName: "shield.checkered")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                                Text("\(CanopyStatsManager.shared.formattedTotalCount) requests blocked total")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                        .padding(.leading, 20)
                    }

                    // Placeholders for future refinements
                    Toggle("Block Third-Party Cookies", isOn: .constant(false))
                        .disabled(true)
                    Toggle("Prevent Cross-Site Tracking (ITP)", isOn: .constant(false))
                        .disabled(true)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }

            // Canopy Settings
            if settings.contentBlockingEnabled {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Canopy Settings")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 8) {
                        // wBlock integration
                        if WBlockBridge.shared.isAvailable {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("wBlock rules loaded (\(WBlockBridge.shared.loadedSlots.joined(separator: ", ")))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // Filter list update
                        HStack(spacing: 8) {
                            Button("Update Filter Lists Now") {
                                Task {
                                    await CanopyAdBlockManager.shared.updateListsIfNeeded()
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Text("Auto-updates every 7 days from GitHub")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)

                    // Custom cosmetic filters
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Custom Filters")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text("Use standard adblock syntax to hide elements. Examples:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("##.ad-banner — hide on all sites\nexample.com##.popup — hide on specific site\na.com,b.com##.tracker — multiple domains")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.bottom, 4)

                        let filters = CanopyElementPicker.shared.rawFilters
                        if !filters.isEmpty {
                            ForEach(filters, id: \.self) { filter in
                                HStack {
                                    Text(filter)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                    Spacer()
                                    Button(role: .destructive) {
                                        CanopyElementPicker.shared.removeFilterRule(filter)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            TextField("##.ad-banner or example.com##.popup", text: $newFilterRule)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            Button("Add") {
                                let trimmed = newFilterRule.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmed.isEmpty else { return }
                                CanopyElementPicker.shared.addFilterRule(trimmed)
                                newFilterRule = ""
                            }
                            .buttonStyle(.bordered)
                            .disabled(newFilterRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        if !filters.isEmpty {
                            Button("Clear All Custom Filters") {
                                CanopyElementPicker.shared.clearAllCustomRules()
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                            .buttonStyle(.plain)
                        }

                        // Per-domain blocked elements from element picker
                        let pickerRules = CanopyElementPicker.shared.customRules
                        if !pickerRules.isEmpty {
                            Divider().opacity(0.4)
                            Text("Blocked Elements by Domain")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)

                            ForEach(Array(pickerRules.keys.sorted()), id: \.self) { domain in
                                if let selectors = pickerRules[domain], !selectors.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(domain == "*" ? "All sites" : domain)
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                        ForEach(selectors, id: \.self) { selector in
                                            HStack {
                                                Text(selector)
                                                    .font(.system(.caption2, design: .monospaced))
                                                    .lineLimit(1)
                                                    .foregroundStyle(.secondary)
                                                Spacer()
                                                Button {
                                                    CanopyElementPicker.shared.removeRule(host: domain, selector: selector)
                                                } label: {
                                                    Image(systemName: "xmark.circle")
                                                        .foregroundStyle(.red.opacity(0.7))
                                                }
                                                .buttonStyle(.borderless)
                                                .controlSize(.small)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }
            }

            // Custom Filter Lists
            if settings.contentBlockingEnabled {
                customFilterListsSection
            }

            Divider()
            
            // Content Blocker Website Exceptions
            VStack(alignment: .leading, spacing: 12) {
                Text("Website Exceptions")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    if settings.contentBlockerAllowlist.isEmpty {
                        Text("No websites are whitelisted. Canopy will block ads on all sites.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(settings.contentBlockerAllowlist, id: \.self) { host in
                            HStack {
                                Text(host)
                                    .lineLimit(1)
                                Spacer()
                                Button(role: .destructive) {
                                    settings.contentBlockerAllowlist.removeAll { $0 == host }
                                    CanopyAdBlockManager.shared.removeWhitelist(host: host)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Remove this site from the allowlist")
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("Add website (example.com)", text: $newExceptionHost)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            let trimmed = newExceptionHost.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            let normalized = trimmed.lowercased()
                            if !settings.contentBlockerAllowlist.contains(where: { $0 == normalized }) {
                                settings.contentBlockerAllowlist.append(normalized)
                                Task { await CanopyAdBlockManager.shared.addWhitelist(host: normalized) }
                            }
                            newExceptionHost = ""
                        }
                        .buttonStyle(.bordered)
                        .disabled(newExceptionHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            Divider()
            
            // Website Data Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Website Data")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    Button("Clear Browsing History") {
                        clearBrowsingHistory()
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Clear Cache") {
                        clearCache()
                    }
                    .buttonStyle(.bordered)
                    
                                    }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            Spacer()
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360)
        .onAppear {
            Task {
                await cookieManager.loadCookies()
                await cacheManager.loadCacheData()
            }
        }
        .sheet(isPresented: $showingCookieManager) {
            CookieManagementView()
        }
        .sheet(isPresented: $showingCacheManager) {
            CacheManagementView()
        }
    }

    // MARK: - Cache Stats View

    private var cacheStatsView: some View {
        let stats = cacheManager.getCacheStats()
        
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundColor(.blue)
                Text("Stored Cache")
                    .fontWeight(.medium)
                Spacer()
                Text("\(stats.total)")
                    .foregroundColor(.secondary)
            }
            
            if stats.total > 0 {
                HStack {
                    Spacer().frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Disk: \(formatSize(stats.diskSize))")
                            Text("•")
                            Text("Memory: \(formatSize(stats.memorySize))")
                            if stats.staleCount > 0 {
                                Text("•")
                                Text("Stale: \(stats.staleCount)")
                                    .foregroundColor(.orange)
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        
                        Text("Total size: \(formatSize(stats.totalSize))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }
    
    // MARK: - Custom Filter Lists Section

    private var customFilterListsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Filter Lists")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Add filter lists by URL (EasyList, AdGuard, uBO format). Network rules compile to WebKit content blockers; cosmetic rules (##) are applied via CSS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !customListManager.lists.isEmpty {
                    ForEach(customListManager.lists) { list in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { list.isEnabled },
                                set: { customListManager.toggleList(id: list.id, enabled: $0) }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()

                            VStack(alignment: .leading, spacing: 2) {
                                Text(list.name.isEmpty ? list.urlString : list.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text("\(list.ruleCount) rules")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let date = list.lastUpdated {
                                        Text("Updated \(date, style: .relative) ago")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }

                            Spacer()

                            Button(role: .destructive) {
                                customListManager.removeList(id: list.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(Color(.controlBackgroundColor).opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                HStack(spacing: 8) {
                    TextField("List name (optional)", text: $newListName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    TextField("Filter list URL", text: $newListURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let url = newListURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !url.isEmpty else { return }
                        customListManager.addList(name: name, urlString: url)
                        newListName = ""
                        newListURL = ""
                    }
                    .buttonStyle(.bordered)
                    .disabled(newListURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !customListManager.lists.isEmpty {
                    Button("Refresh All Lists") {
                        Task { await customListManager.refreshAll() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    // MARK: - Cookie Stats View
    
    private var cookieStatsView: some View {
        let stats = cookieManager.getCookieStats()
        
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "doc.on.doc")
                    .foregroundColor(.blue)
                Text("Stored Cookies")
                    .fontWeight(.medium)
                Spacer()
                Text("\(stats.total)")
                    .foregroundColor(.secondary)
            }
            
            if stats.total > 0 {
                HStack {
                    Spacer().frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Session: \(stats.session)")
                            Text("•")
                            Text("Persistent: \(stats.persistent)")
                            if stats.expired > 0 {
                                Text("•")
                                Text("Expired: \(stats.expired)")
                                    .foregroundColor(.orange)
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        
                        Text("Total size: \(formatSize(stats.totalSize))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }
    
    // MARK: - Actions
    
    private func clearExpiredCookies() {
        isClearing = true
        Task {
            await cookieManager.deleteExpiredCookies()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearAllCookies() {
        isClearing = true
        Task {
            await cookieManager.deleteAllCookies()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearAllWebsiteData() {
        isClearing = true
        Task {
            let dataStore = WKWebsiteDataStore.default()
            let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
            await dataStore.removeData(ofTypes: dataTypes, modifiedSince: Date.distantPast)
            await cookieManager.loadCookies()
            await cacheManager.loadCacheData()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearBrowsingHistory() {
        browserManager.historyManager.clearHistory()
    }
    
    private func clearCache() {
        Task {
            let dataStore = WKWebsiteDataStore.default()
            await dataStore.removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], modifiedSince: Date.distantPast)
        }
    }
    
        
    // MARK: - Helper Methods
    
    // MARK: - Cache Action Methods
    
    private func clearStaleCache() {
        isClearing = true
        Task {
            await cacheManager.clearStaleCache()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearDiskCache() {
        isClearing = true
        Task {
            await cacheManager.clearDiskCache()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearMemoryCache() {
        isClearing = true
        Task {
            await cacheManager.clearMemoryCache()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearAllCache() {
        isClearing = true
        Task {
            await cacheManager.clearAllCache()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    // MARK: - Privacy-Compliant Actions
    
    private func clearThirdPartyCookies() {
        isClearing = true
        Task {
            await cookieManager.deleteThirdPartyCookies()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearHighRiskCookies() {
        isClearing = true
        Task {
            await cookieManager.deleteHighRiskCookies()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func performCookiePrivacyCleanup() {
        isClearing = true
        Task {
            await cookieManager.performPrivacyCleanup()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearPersonalDataCache() {
        isClearing = true
        Task {
            await cacheManager.clearPersonalDataCache()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func performCachePrivacyCleanup() {
        isClearing = true
        Task {
            await cacheManager.performPrivacyCompliantCleanup()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) bytes"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
    }
    
    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    PrivacySettingsView()
        .environmentObject(BrowserManager())
}
