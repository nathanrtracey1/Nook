import SwiftUI
import AppKit

struct UserScriptsSettingsView: View {
    @ObservedObject private var manager = CanopyUserScriptManager.shared
    @State private var showingInstallSheet = false
    @State private var installURL = ""
    @State private var showingPasteSheet = false
    @State private var pasteSource = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Userscripts")
                    .font(.headline)
                Spacer()
                Button("Install from URL...") { showingInstallSheet = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Paste Script...") { showingPasteSheet = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Import File...") { importFromFile() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            if manager.scripts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "applescript")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No userscripts installed")
                        .foregroundStyle(.secondary)
                    Text("Install .user.js scripts from a URL, paste code, or import a file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 8) {
                    ForEach(manager.scripts) { script in
                        HStack(spacing: 12) {
                            Toggle("", isOn: Binding(
                                get: { script.isEnabled },
                                set: { manager.toggleScript(id: script.id, enabled: $0) }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()

                            VStack(alignment: .leading, spacing: 2) {
                                Text(script.name)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    if !script.version.isEmpty {
                                        Text("v\(script.version)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if !script.description.isEmpty {
                                        Text(script.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Text("\(script.matchPatterns.joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text(script.runAt)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())

                            Button(role: .destructive) {
                                manager.removeScript(id: script.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(10)
                        .background(Color(.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding()
        .sheet(isPresented: $showingInstallSheet) {
            installURLSheet
        }
        .sheet(isPresented: $showingPasteSheet) {
            pasteSheet
        }
    }

    private var installURLSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install Userscript from URL")
                .font(.headline)
            TextField("https://example.com/script.user.js", text: $installURL)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showingInstallSheet = false }
                    .buttonStyle(.bordered)
                Button("Install") {
                    guard let url = URL(string: installURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                    Task {
                        _ = await manager.installFromURL(url)
                        installURL = ""
                        showingInstallSheet = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(installURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 450)
    }

    private var pasteSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Paste Userscript")
                .font(.headline)
            TextEditor(text: $pasteSource)
                .font(.system(.body, design: .monospaced))
                .frame(height: 200)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel") { showingPasteSheet = false; pasteSource = "" }
                    .buttonStyle(.bordered)
                Button("Install") {
                    let trimmed = pasteSource.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    _ = manager.addScript(source: trimmed)
                    pasteSource = ""
                    showingPasteSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(pasteSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.javaScript]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let source = try? String(contentsOf: url, encoding: .utf8) {
                _ = manager.addScript(source: source)
            }
        }
    }
}
