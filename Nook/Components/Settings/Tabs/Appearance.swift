//
//  Appearance.swift
//  Nook
//
//  Created by Maciek Bagiński on 07/12/2025.
//

import SwiftUI

struct SettingsAppearanceTab: View {
    @Environment(\.nookSettings) var nookSettings


    var body: some View {
        @Bindable var settings = nookSettings
        Form {
            Picker(
                "Appearance",
                selection: $settings.appearanceMode
            ) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Picker(
                "Background Material",
                selection: $settings
                    .currentMaterialRaw
            ) {
                ForEach(materials, id: \.value.rawValue) {
                    material in
                    Text(material.name).tag(
                        material.value.rawValue
                    )
                }
            }
            Toggle("Liquid Glass", isOn: .constant(true))
            Picker(
                "Sidebar Position",
                selection: $settings
                    .sidebarPosition
            ) {
                ForEach(SidebarPosition.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            Toggle("Show URL bar in the web view", isOn: $settings.topBarAddressView)
            // BEGIN CUSTOM MODIFICATION — remove borders when sidebar hidden
            Toggle("Remove borders when sidebar is hidden", isOn: $settings.removeBordersWhenSidebarHidden)
                .help("When the sidebar is hidden, content can expand to full width with no side padding. Turn off to keep a border.")
            // END CUSTOM MODIFICATION
            Picker(
                "Favorites Appearance",
                selection: $settings.pinnedTabsLook
            ) {
                ForEach(PinnedTabsConfiguration.allCases) { config in
                    Text(config.name).tag(config)
                }
            }
            Toggle("Preview link URL on hover",
                isOn: $settings
                    .showLinkStatusBar
            )
        }
        .formStyle(.grouped)
    }
}
