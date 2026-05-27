//
//  SettingsUtils.swift
//  Nook
//
//  Created by Maciek Bagiński on 03/08/2025.
//
import Foundation

enum SettingsTabs: Hashable, CaseIterable {
    case general
    case appearance
    case ai
    case privacy
    case autofill
    case profiles
    case shortcuts
    case extensions
    case userscripts
    case advanced

    // Ordered list for horizontal tab bar
    static var ordered: [SettingsTabs] {
        return [.general, .appearance, .ai, .privacy, .autofill, .profiles, .shortcuts, .extensions, .userscripts, .advanced]
    }

    var name: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .ai: return "AI"
        case .privacy: return "Privacy"
        case .autofill: return "AutoFill"
        case .profiles: return "Profiles"
        case .shortcuts: return "Shortcuts"
        case .extensions: return "Extensions"
        case .userscripts: return "Userscripts"
        case .advanced: return "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "rectangle.3.offgrid"
        case .ai: return "sparkles"
        case .privacy: return "lock.shield"
        case .autofill: return "key.fill"
        case .profiles: return "person.crop.circle"
        case .shortcuts: return "keyboard"
        case .extensions: return "puzzlepiece.extension"
        case .userscripts: return "applescript"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}
