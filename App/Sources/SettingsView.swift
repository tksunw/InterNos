// SwiftUI settings window (PRD F8 + feature handoff settings layout):
// General (hotkey, mode, mic, sounds, login, updates), Processing (smart
// cleanup + spoken-command reference), Customizations (replacements & snippets
// with search, editing, import/export). Resizable; lists stay responsive with
// hundreds of entries because rows are lazy.

import AppKit
import Speech
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var customizations: CustomizationStore
    var onChange: (() -> Void)?

    var body: some View {
        TabView {
            GeneralSettingsView(onChange: onChange)
                .tabItem { Label("General", systemImage: "gearshape") }
            ProcessingSettingsView()
                .tabItem { Label("Processing", systemImage: "wand.and.stars") }
            CustomizationsView(store: customizations)
                .tabItem { Label("Customizations", systemImage: "text.badge.plus") }
        }
        .frame(minWidth: 620, minHeight: 460)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @State private var hotkey = AppSettings.shared.hotkey
    @State private var mode = AppSettings.shared.mode
    @State private var inputDeviceUID: String = AppSettings.shared.inputDeviceUID ?? ""
    @State private var playSounds = AppSettings.shared.playSounds
    @State private var launchAtLogin = AppSettings.shared.launchAtLogin
    @State private var checkUpdatesAtLaunch = AppSettings.shared.checkUpdatesAtLaunch
    @State private var devices = AudioDevices.inputDevices()
    @State private var recognitionLocale = AppSettings.shared.recognitionLocale
    @State private var supportedLocales: [(id: String, name: String)] = []
    @State private var commandHotkey = AppSettings.shared.commandHotkey

    var onChange: (() -> Void)?

    var body: some View {
        Form {
            Section {
                Picker("Dictation key", selection: $hotkey) {
                    ForEach(HotkeyChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                Picker("Activation", selection: $mode) {
                    ForEach(ActivationMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                Picker("Command key", selection: $commandHotkey) {
                    ForEach(HotkeyChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .accessibilityLabel("Command mode key")
            } footer: {
                if commandHotkey == hotkey {
                    Text("Command mode is off while the command key matches the dictation key. Pick a different key to enable it.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Hold the command key with text selected, speak an instruction (\u{201C}fix the spelling\u{201D}, \u{201C}make this friendlier\u{201D}), release. The selection is rewritten on-device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Microphone", selection: $inputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                Picker("Language", selection: $recognitionLocale) {
                    if supportedLocales.isEmpty {
                        Text(displayName(recognitionLocale)).tag(recognitionLocale)
                    }
                    ForEach(supportedLocales, id: \.id) { locale in
                        Text(locale.name).tag(locale.id)
                    }
                }
                .accessibilityLabel("Recognition language")
            } footer: {
                Text("Changing the language may download that language's speech model (a one-time system download). Spoken commands — new line, snippet, emoji names — are English-only for now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Play sounds", isOn: $playSounds)
                Toggle("Launch at login", isOn: $launchAtLogin)
            }
            Section {
                Toggle("Check for updates at launch", isOn: $checkUpdatesAtLaunch)
            } footer: {
                Text("One request to GitHub at startup; silent unless an update exists. Off means Internos makes no network calls you don't click for.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: hotkey) { AppSettings.shared.hotkey = hotkey; onChange?() }
        .onChange(of: commandHotkey) { AppSettings.shared.commandHotkey = commandHotkey; onChange?() }
        .onChange(of: mode) { AppSettings.shared.mode = mode; onChange?() }
        .onChange(of: inputDeviceUID) {
            AppSettings.shared.inputDeviceUID = inputDeviceUID.isEmpty ? nil : inputDeviceUID
            onChange?()
        }
        .onChange(of: playSounds) { AppSettings.shared.playSounds = playSounds }
        .onChange(of: launchAtLogin) { AppSettings.shared.launchAtLogin = launchAtLogin }
        .onChange(of: checkUpdatesAtLaunch) { AppSettings.shared.checkUpdatesAtLaunch = checkUpdatesAtLaunch }
        .onChange(of: recognitionLocale) {
            AppSettings.shared.recognitionLocale = recognitionLocale
            onChange?()
        }
        .task {
            let locales = await SpeechTranscriber.supportedLocales
            supportedLocales = locales
                .map { (id: $0.identifier, name: displayName($0.identifier)) }
                .sorted { $0.name < $1.name }
        }
    }

    private func displayName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

// MARK: - Processing

private struct ProcessingSettingsView: View {
    @State private var cleanupMode = AppSettings.shared.cleanupMode
    @State private var unavailableReason = CleanupAvailability.explanation

    private var modelAvailable: Bool { unavailableReason == nil }

    var body: some View {
        Form {
            Section {
                Picker("Smart cleanup", selection: $cleanupMode) {
                    ForEach(CleanupMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!modelAvailable && cleanupMode == .off)
                .accessibilityLabel("Smart cleanup mode")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tidies dictated text on this Mac using Apple Intelligence — removes filler, false starts, and self-corrections (Light), or smooths fragments into prose (Polished). Nothing leaves the Mac; snippets and personal-dictionary output are never altered.")
                    if let unavailableReason {
                        Text(unavailableReason).foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Spoken commands") {
                commandReference
            }
        }
        .formStyle(.grouped)
        .onChange(of: cleanupMode) { AppSettings.shared.cleanupMode = cleanupMode }
        .onAppear { refreshAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAvailability()
        }
    }

    private func refreshAvailability() {
        unavailableReason = CleanupAvailability.explanation
        // Light/Polished need the model; snap back to Off if it went away.
        if unavailableReason != nil, cleanupMode != .off {
            cleanupMode = .off
            AppSettings.shared.cleanupMode = .off
        }
    }

    private var commandReference: some View {
        let rows: [(String, String)] = [
            ("new line", "line break"),
            ("new paragraph", "blank line"),
            ("bullet point …", "• list item"),
            ("numbered item …", "1. list item (numbers continue)"),
            ("open quote / close quote", "\u{201C} \u{201D}"),
            ("open parenthesis / close parenthesis", "( )"),
            ("hashtag word", "#word"),
            ("emoji thumbs up", "👍 (see README for all names)"),
            ("at sign / dollar sign / percent sign", "@ $ %"),
            ("snippet <name>", "inserts the saved snippet"),
            ("literal <command>", "keeps the phrase as plain words"),
        ]
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0).font(.system(.caption, design: .monospaced))
                    Spacer()
                    Text(row.1).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Customizations

private struct CustomizationsView: View {
    enum Category: String, CaseIterable, Identifiable {
        case replacements = "Replacements"
        case snippets = "Snippets"
        var id: String { rawValue }
    }

    @ObservedObject var store: CustomizationStore
    @State private var category: Category = .replacements
    @State private var search = ""
    @State private var editingReplacement: Replacement?
    @State private var editingSnippet: Snippet?
    @State private var addingNew = false
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let loadError = store.loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Customization file problem: \(loadError)")
            }

            HStack {
                Picker("Category", selection: $category) {
                    ForEach(Category.allCases) { c in Text(c.rawValue).tag(c) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Search \(category.rawValue)")
            }

            switch category {
            case .replacements: replacementList
            case .snippets: snippetList
            }

            if category == .snippets {
                Text("Snippets are stored on this Mac as plain text. Don't put passwords or private keys in them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let actionError {
                Text(actionError).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Add \(category == .replacements ? "Replacement" : "Snippet")…") { addingNew = true }
                    .keyboardShortcut("n", modifiers: [.command])
                Spacer()
                Button("Import…") { runImport() }
                Button("Export…") { runExport() }
            }
        }
        .padding(16)
        .sheet(isPresented: $addingNew) { addSheet }
        .sheet(item: $editingReplacement) { rule in
            ReplacementEditor(replacement: rule) { updated in
                try store.updateReplacement(updated)
            }
        }
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditor(snippet: snippet) { updated in
                try store.updateSnippet(updated)
            }
        }
    }

    @ViewBuilder
    private var addSheet: some View {
        switch category {
        case .replacements:
            ReplacementEditor(replacement: Replacement(trigger: "", replacement: "")) { new in
                try store.addReplacement(new)
            }
        case .snippets:
            SnippetEditor(snippet: Snippet(name: "", content: "")) { new in
                try store.addSnippet(new)
            }
        }
    }

    private var filteredReplacements: [Replacement] {
        guard !search.isEmpty else { return store.replacements }
        return store.replacements.filter {
            $0.trigger.localizedCaseInsensitiveContains(search)
                || $0.replacement.localizedCaseInsensitiveContains(search)
        }
    }

    private var filteredSnippets: [Snippet] {
        guard !search.isEmpty else { return store.snippets }
        return store.snippets.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.content.localizedCaseInsensitiveContains(search)
        }
    }

    private var replacementList: some View {
        List(filteredReplacements) { rule in
            HStack {
                Toggle("", isOn: Binding(
                    get: { rule.enabled },
                    set: { enabled in attempt { try store.setReplacementEnabled(id: rule.id, enabled: enabled) } }
                ))
                .labelsHidden()
                .accessibilityLabel("Enable replacement \(rule.trigger)")
                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.trigger).font(.body)
                    Text(rule.replacement).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Edit") { editingReplacement = rule }
                    .accessibilityLabel("Edit replacement \(rule.trigger)")
                Button(role: .destructive) {
                    attempt { try store.deleteReplacement(id: rule.id) }
                } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Delete replacement \(rule.trigger)")
            }
            .opacity(rule.enabled ? 1 : 0.5)
        }
        .frame(minHeight: 220)
    }

    private var snippetList: some View {
        List(filteredSnippets) { snippet in
            HStack {
                Toggle("", isOn: Binding(
                    get: { snippet.enabled },
                    set: { enabled in attempt { try store.setSnippetEnabled(id: snippet.id, enabled: enabled) } }
                ))
                .labelsHidden()
                .accessibilityLabel("Enable snippet \(snippet.name)")
                VStack(alignment: .leading, spacing: 1) {
                    Text(snippet.name).font(.body)
                    Text(snippet.content).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Edit") { editingSnippet = snippet }
                    .accessibilityLabel("Edit snippet \(snippet.name)")
                Button(role: .destructive) {
                    attempt { try store.deleteSnippet(id: snippet.id) }
                } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Delete snippet \(snippet.name)")
            }
            .opacity(snippet.enabled ? 1 : 0.5)
        }
        .frame(minHeight: 220)
    }

    private func attempt(_ work: () throws -> Void) {
        do {
            try work()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: import / export (explicit file-panel actions only)

    private func runExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Internos Customizations.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attempt {
            try store.exportData().write(to: url, options: .atomic)
        }
    }

    private func runImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let alert = NSAlert()
        alert.messageText = "Import customizations?"
        alert.informativeText = "Merge adds entries that don't conflict with existing ones (existing entries win). Replace validates the file and replaces everything."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        let choice = alert.runModal()
        let mode: ImportMode
        switch choice {
        case .alertFirstButtonReturn: mode = .merge
        case .alertSecondButtonReturn: mode = .replace
        default: return
        }

        attempt {
            let data = try Data(contentsOf: url)
            let summary = try store.importData(data, mode: mode)
            let report = NSAlert()
            report.messageText = "Import complete"
            report.informativeText = """
            Replacements: \(summary.replacementsAdded) added, \(summary.replacementsSkipped) skipped.
            Snippets: \(summary.snippetsAdded) added, \(summary.snippetsSkipped) skipped.
            """
            report.runModal()
        }
    }
}

// MARK: - Editors

private struct ReplacementEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var replacement: Replacement
    @State private var validationError: String?
    let onSave: (Replacement) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Replacement").font(.headline)
            TextField("When I say…", text: $replacement.trigger)
                .accessibilityLabel("Trigger phrase")
            TextField("Internos types…", text: $replacement.replacement)
                .accessibilityLabel("Replacement output")
            Text("Matching is case-insensitive and whole-word. The output is typed exactly as written here.")
                .font(.caption).foregroundStyle(.secondary)
            if let validationError {
                Text(validationError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        do {
            try onSave(replacement)
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }
}

private struct SnippetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var snippet: Snippet
    @State private var validationError: String?
    let onSave: (Snippet) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snippet").font(.headline)
            TextField("Name (spoken as \u{201C}snippet <name>\u{201D})", text: $snippet.name)
                .accessibilityLabel("Snippet name")
            TextEditor(text: $snippet.content)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .border(Color.secondary.opacity(0.3))
                .accessibilityLabel("Snippet content")
            Text("Inserted exactly as written, line breaks included. Stored on this Mac as plain text — don't put passwords or private keys here.")
                .font(.caption).foregroundStyle(.secondary)
            if let validationError {
                Text(validationError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 340)
    }

    private func save() {
        do {
            try onSave(snippet)
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }
}

// MARK: - Window controller

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(customizations: CustomizationStore, onChange: @escaping () -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = SettingsView(customizations: customizations, onChange: onChange)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Internos Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 640, height: 500))
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
