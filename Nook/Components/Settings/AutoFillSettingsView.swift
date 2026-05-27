//
//  AutoFillSettingsView.swift
//  Nook
//
//  AutoFill (passwords and credit cards) lives in its own settings tab and is gated:
//  the list and actions are only visible after Touch ID or device password authentication.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AutoFillSettingsView: View {
    @State private var isUnlocked = false
    @State private var passwordEntries: [SavedPasswordEntry] = []
    @State private var revealedPasswords: [String: String] = [:]
    @State private var cardEntries: [SavedCardEntry] = []
    @State private var unlockFailed = false

    var body: some View {
        if !isUnlocked {
            unlockGate
        } else {
            VStack {
                HStack {
                    Spacer()
                    Button(action: { isUnlocked = false }) {
                        Label("Lock", systemImage: "lock.fill")
                    }
                    .buttonStyle(.bordered)
                    .padding(.trailing)
                    .padding(.top, 12)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        savedPasswordsSection
                        Divider()
                        savedCardsSection
                    }
                    .padding()
                }
            }
            .onAppear {
                refreshEntries()
            }
        }
    }

    // MARK: - Unlock gate (Touch ID or device password)

    private var unlockGate: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.key.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("AutoFill Settings Locked")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Use Touch ID or your Mac password to view and manage saved passwords and payment methods.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button {
                unlockWithBiometrics()
            } label: {
                Label("Unlock with Touch ID or Password", systemImage: "lock.open.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if unlockFailed {
                Text("Authentication failed. Try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unlockWithBiometrics() {
        unlockFailed = false
        Task {
            let ok = await PasswordManager.shared.authenticateWithTouchID(reason: "Unlock AutoFill settings")
            await MainActor.run {
                if ok {
                    isUnlocked = true
                    refreshEntries()
                } else {
                    unlockFailed = true
                }
            }
        }
    }

    private func refreshEntries() {
        passwordEntries = PasswordManager.shared.listEntries()
        cardEntries = CreditCardManager.shared.listEntries()
    }

    // MARK: - Saved Passwords Section

    private var savedPasswordsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved Passwords")
                .font(.headline)
            HStack(spacing: 8) {
                Button("Add Password") {
                    addPasswordManually()
                }
                Button("Import CSV…") {
                    importPasswordsFromCSV()
                }
                Button("Export CSV…") {
                    exportPasswordsToCSV()
                }
                .disabled(passwordEntries.isEmpty)
                Button("Clear All Passwords…") {
                    clearAllPasswords()
                }
                .foregroundColor(.red)
                .disabled(passwordEntries.isEmpty)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                if passwordEntries.isEmpty {
                    Text("No saved passwords.")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(passwordEntries) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.origin)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(entry.username)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if let pwd = revealedPasswords[entry.id] {
                                HStack(spacing: 8) {
                                    Text(pwd)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                    Button("Hide") {
                                        revealedPasswords.removeValue(forKey: entry.id)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            } else {
                                Button("Show") {
                                    Task {
                                        let ok = await PasswordManager.shared.authenticateWithTouchID(reason: "Show saved password")
                                        if ok, let pwd = PasswordManager.shared.getPassword(origin: entry.origin, username: entry.username) {
                                            revealedPasswords[entry.id] = pwd
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            Button(role: .destructive) {
                                _ = PasswordManager.shared.delete(origin: entry.origin, username: entry.username)
                                refreshEntries()
                                revealedPasswords.removeValue(forKey: entry.id)
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                        .padding(8)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                    }
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    // MARK: - Saved Cards Section

    private var savedCardsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved Cards")
                .font(.headline)
            HStack(spacing: 8) {
                Button("Add Card") {
                    addCardManually()
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                if cardEntries.isEmpty {
                    Text("No saved cards.")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(cardEntries) { entry in
                        HStack {
                            Text(entry.displayLabel)
                                .font(.subheadline)
                            Text(entry.name)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(role: .destructive) {
                                _ = CreditCardManager.shared.delete(entryId: entry.id)
                                refreshEntries()
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                        .padding(8)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                    }
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    // MARK: - Password helpers

    private func addPasswordManually() {
        let alert = NSAlert()
        alert.messageText = "Add Password"
        alert.informativeText = "Save a login for a website. Use the full URL (e.g. https://example.com), the username or email you sign in with, and the password. Saved passwords are stored in the system Keychain and can be used to autofill login forms."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let urlLabel = NSTextField(labelWithString: "Website URL")
        urlLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        let originField = NSTextField(string: "")
        originField.placeholderString = "https://example.com"
        originField.font = .systemFont(ofSize: NSFont.systemFontSize)

        let userLabel = NSTextField(labelWithString: "Username or email")
        userLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        let usernameField = NSTextField(string: "")
        usernameField.placeholderString = "Username or email"
        usernameField.font = .systemFont(ofSize: NSFont.systemFontSize)

        let passLabel = NSTextField(labelWithString: "Password")
        passLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        let passwordField = NSSecureTextField(string: "")
        passwordField.placeholderString = "Password"
        passwordField.font = .systemFont(ofSize: NSFont.systemFontSize)

        let fieldWidth: CGFloat = 320
        let fieldHeight: CGFloat = 22
        [originField, usernameField, passwordField].forEach { field in
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
            field.heightAnchor.constraint(equalToConstant: fieldHeight).isActive = true
        }

        let stack = NSStackView(views: [
            urlLabel, originField,
            userLabel, usernameField,
            passLabel, passwordField
        ])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.required, for: .horizontal)
        stack.widthAnchor.constraint(equalToConstant: 340).isActive = true
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let originRaw = originField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordField.stringValue

        guard !originRaw.isEmpty,
              let url = URL(string: originRaw),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              !username.isEmpty,
              !password.isEmpty
        else {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Invalid Details"
            errorAlert.informativeText = "Please enter a valid http or https URL, a username or email, and a password."
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: "OK")
            errorAlert.runModal()
            return
        }

        _ = PasswordManager.shared.save(origin: url.absoluteString, username: username, password: password)
        refreshEntries()
    }

    private func clearAllPasswords() {
        let alert = NSAlert()
        alert.messageText = "Clear All Passwords?"
        alert.informativeText = "This will permanently remove all \(passwordEntries.count) saved password\(passwordEntries.count == 1 ? "" : "s") from this device. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            let deleted = PasswordManager.shared.deleteAll()
            refreshEntries()
            revealedPasswords.removeAll()
            let done = NSAlert()
            done.messageText = "Passwords Cleared"
            done.informativeText = "\(deleted) password\(deleted == 1 ? "" : "s") removed."
            done.alertStyle = .informational
            done.addButton(withTitle: "OK")
            done.runModal()
        }
    }

    private func importPasswordsFromCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let fileURL = url
        DispatchQueue.main.async {
            guard var contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
            if contents.hasPrefix("\u{FEFF}") { contents = String(contents.dropFirst()) }
            let rows = parseCSVRows(contents)
            var savedCount = 0
            var skippedInvalid = 0
            
            guard !rows.isEmpty else { return }
            
            // Dynamically determine column indices from header
            var originIdx = -1
            var userIdx = -1
            var passIdx = -1
            
            let header = rows[0].map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            for (i, col) in header.enumerated() {
                if col == "url" || col == "origin" || col == "website" { originIdx = i }
                if col == "username" || col == "user" || col == "login" { userIdx = i }
                if col == "password" || col == "pass" { passIdx = i }
            }
            
            // Fallback for no header
            let hasHeader = originIdx != -1 || userIdx != -1 || passIdx != -1
            if !hasHeader {
                // Guess based on column count
                let maxCols = rows[0].count
                if maxCols >= 4 {
                    originIdx = 1; userIdx = 2; passIdx = 3
                } else if maxCols >= 3 {
                    originIdx = 0; userIdx = 1; passIdx = 2
                } else {
                    return // Cannot parse
                }
            }
            
            let dataRows = hasHeader ? rows.dropFirst() : rows[...]
            
            for columns in dataRows {
                let trimmed = columns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard trimmed.count > max(originIdx, userIdx, passIdx) else { skippedInvalid += 1; continue }
                
                var originRaw = trimmed[originIdx]
                let username = trimmed[userIdx]
                let password = trimmed[passIdx]
                
                if !originRaw.contains("://") && !originRaw.isEmpty { originRaw = "https://" + originRaw }
                guard !originRaw.isEmpty,
                      let parsedURL = URL(string: originRaw),
                      let scheme = parsedURL.scheme?.lowercased(),
                      (scheme == "http" || scheme == "https"),
                      !username.isEmpty,
                      !password.isEmpty
                else { skippedInvalid += 1; continue }
                
                if PasswordManager.shared.save(origin: parsedURL.absoluteString, username: username, password: password) { savedCount += 1 }
            }
            
            passwordEntries = PasswordManager.shared.listEntries()
            var message = "Parsed \(dataRows.count) row\(dataRows.count == 1 ? "" : "s"). Saved \(savedCount) password\(savedCount == 1 ? "" : "s")."
            if skippedInvalid > 0 { message += " \(skippedInvalid) row\(skippedInvalid == 1 ? "" : "s") skipped." }
            let a = NSAlert()
            a.messageText = "Import Complete"
            a.informativeText = message
            a.alertStyle = .informational
            a.addButton(withTitle: "OK")
            a.runModal()
        }
    }

    private func parseCSVRows(_ contents: String) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false
        var i = contents.startIndex
        while i < contents.endIndex {
            let char = contents[i]
            if inQuotes {
                if char == "\"" {
                    let nextIndex = contents.index(after: i)
                    if nextIndex < contents.endIndex && contents[nextIndex] == "\"" {
                        currentField.append("\"")
                        i = nextIndex
                    } else {
                        inQuotes = false
                    }
                } else { 
                    currentField.append(char) 
                }
                i = contents.index(after: i)
                continue
            }
            switch char {
            case "\"": inQuotes = true; i = contents.index(after: i)
            case ",": currentRow.append(currentField); currentField = ""; i = contents.index(after: i)
            case "\n":
                currentRow.append(currentField); currentField = ""
                if currentRow.count > 1 || (currentRow.count == 1 && !currentRow[0].isEmpty) { rows.append(currentRow) }
                currentRow = []
                i = contents.index(after: i)
            case "\r":
                currentRow.append(currentField); currentField = ""
                if currentRow.count > 1 || (currentRow.count == 1 && !currentRow[0].isEmpty) { rows.append(currentRow) }
                currentRow = []
                i = contents.index(after: i)
                if i < contents.endIndex && contents[i] == "\n" { i = contents.index(after: i) }
            default: currentField.append(char); i = contents.index(after: i)
            }
        }
        if !currentRow.isEmpty || !currentField.isEmpty {
            currentRow.append(currentField)
            if currentRow.count > 1 || (currentRow.count == 1 && !currentRow[0].isEmpty) { rows.append(currentRow) }
        }
        return rows
    }

    private func exportPasswordsToCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "nook-passwords.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func csvEscape(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var rows = ["origin,username,password"]
        for entry in passwordEntries {
            let password = PasswordManager.shared.getPassword(origin: entry.origin, username: entry.username) ?? ""
            rows.append([csvEscape(entry.origin), csvEscape(entry.username), csvEscape(password)].joined(separator: ","))
        }
        try? rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Card helper

    private func addCardManually() {
        let alert = NSAlert()
        alert.messageText = "Add Card"
        alert.informativeText = "Save a credit or debit card. Stored in the system Keychain and protected by Touch ID."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let nameLabel = NSTextField(labelWithString: "Name on card")
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        let nameField = NSTextField(string: "")
        nameField.placeholderString = "Name on card"
        nameField.font = .systemFont(ofSize: NSFont.systemFontSize)

        let numberLabel = NSTextField(labelWithString: "Card number")
        numberLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        let numberField = NSTextField(string: "")
        numberField.placeholderString = "Card number"
        numberField.font = .systemFont(ofSize: NSFont.systemFontSize)

        let expiryLabel = NSTextField(labelWithString: "Expiration")
        expiryLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        let expiryMonthField = NSTextField(string: "")
        expiryMonthField.placeholderString = "MM"
        expiryMonthField.font = .systemFont(ofSize: NSFont.systemFontSize)
        let expiryYearField = NSTextField(string: "")
        expiryYearField.placeholderString = "YYYY"
        expiryYearField.font = .systemFont(ofSize: NSFont.systemFontSize)

        let expiryRow = NSStackView(views: [expiryMonthField, NSTextField(labelWithString: "/"), expiryYearField])
        expiryRow.orientation = .horizontal
        expiryRow.spacing = 4

        let cvvLabel = NSTextField(labelWithString: "CVV (optional)")
        cvvLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        let cvvField = NSSecureTextField(string: "")
        cvvField.placeholderString = "CVV"
        cvvField.font = .systemFont(ofSize: NSFont.systemFontSize)

        let fieldWidth: CGFloat = 320
        let fieldHeight: CGFloat = 22
        [nameField, numberField, cvvField].forEach { field in
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
            field.heightAnchor.constraint(equalToConstant: fieldHeight).isActive = true
        }

        let stack = NSStackView(views: [
            nameLabel, nameField,
            numberLabel, numberField,
            expiryLabel, expiryRow,
            cvvLabel, cvvField
        ])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 340).isActive = true
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = numberField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let expiryMonth = expiryMonthField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let expiryYear = expiryYearField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let cvv = cvvField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty, !number.isEmpty, !expiryMonth.isEmpty, !expiryYear.isEmpty else {
            let err = NSAlert()
            err.messageText = "Invalid Details"
            err.informativeText = "Please enter name, card number, expiration month, and year."
            err.alertStyle = .warning
            err.addButton(withTitle: "OK")
            err.runModal()
            return
        }

        _ = CreditCardManager.shared.save(number: number, expiryMonth: expiryMonth, expiryYear: expiryYear, name: name, cvv: cvv.isEmpty ? nil : cvv)
        cardEntries = CreditCardManager.shared.listEntries()
    }
}

#Preview {
    AutoFillSettingsView()
}
