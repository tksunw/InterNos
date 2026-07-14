// Persistent customization store (feature handoff, features 1 & 5): personal
// replacements and snippets in one versioned JSON document under Application
// Support. Configuration only — never transcripts, never model output.
//
// Writes are serialized on the main actor and land atomically. A malformed file
// is preserved on disk and surfaced as a recoverable error; a file written by a
// newer schema is treated as read-only so it is never overwritten.

import Foundation

struct Replacement: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    /// Spoken/transcribed phrase; whitespace-normalized on save, matched case-insensitively.
    var trigger: String
    /// Emitted exactly as configured (line endings normalized to \n).
    var replacement: String
    var enabled: Bool = true
}

struct Snippet: Codable, Identifiable, Equatable, Sendable {
    static let maxContentBytes = 16 * 1024
    static let maxNameLength = 100

    var id: UUID = UUID()
    /// Invoked as "snippet <name>"; whitespace-normalized on save.
    var name: String
    /// Static text, expanded verbatim (line endings normalized to \n).
    var content: String
    var enabled: Bool = true
}

struct CustomizationDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var replacements: [Replacement] = []
    var snippets: [Snippet] = []
}

enum CustomizationError: LocalizedError, Equatable {
    case emptyTrigger
    case emptyReplacement
    case duplicateTrigger(String)
    case emptyName
    case nameTooLong
    case nameContainsControlCharacters
    case emptyContent
    case contentTooLarge
    case duplicateName(String)
    case unsupportedSchema(Int)
    case malformedFile(String)
    case readOnlyConfiguration

    var errorDescription: String? {
        switch self {
        case .emptyTrigger: "The trigger can't be empty."
        case .emptyReplacement: "The replacement text can't be empty."
        case .duplicateTrigger(let t): "A replacement with the trigger \u{201C}\(t)\u{201D} already exists."
        case .emptyName: "The snippet name can't be empty."
        case .nameTooLong: "Snippet names are limited to \(Snippet.maxNameLength) characters."
        case .nameContainsControlCharacters: "Snippet names can't contain line breaks or control characters."
        case .emptyContent: "The snippet content can't be empty."
        case .contentTooLarge: "Snippets are limited to 16 KB of text."
        case .duplicateName(let n): "A snippet named \u{201C}\(n)\u{201D} already exists."
        case .unsupportedSchema(let v):
            "This customization file uses a newer format (version \(v)) than this version of Internos understands. Update Internos to edit it."
        case .malformedFile(let detail): "The customization file couldn't be read: \(detail)"
        case .readOnlyConfiguration: "Customizations can't be saved until the file issue above is resolved."
        }
    }
}

enum ImportMode {
    case merge
    case replace
}

struct ImportSummary: Equatable {
    var replacementsAdded = 0
    var replacementsSkipped = 0
    var snippetsAdded = 0
    var snippetsSkipped = 0
}

@MainActor
final class CustomizationStore: ObservableObject {
    @Published private(set) var replacements: [Replacement] = []
    @Published private(set) var snippets: [Snippet] = []
    /// Set when the on-disk file is malformed or from a newer schema; shown in Settings.
    @Published private(set) var loadError: String?

    /// True when the on-disk file must not be overwritten (newer schema version).
    private var readOnly = false
    private let fileURL: URL

    /// Prebuilt match structures, rebuilt only when configuration changes.
    private(set) var matcher: ReplacementMatcher = .empty
    private(set) var snippetTable: SnippetTable = .empty

    nonisolated static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        // Bundle identifier keeps debug data separate from release data.
        let folder = Bundle.main.bundleIdentifier ?? "Internos"
        return support.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("customizations.json")
    }

    init(fileURL: URL = CustomizationStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - persistence

    private func load() {
        readOnly = false
        loadError = nil
        replacements = []
        snippets = []
        defer { rebuildMatchStructures() }

        guard let data = try? Data(contentsOf: fileURL) else { return } // first run
        do {
            let document = try JSONDecoder().decode(CustomizationDocument.self, from: data)
            guard document.schemaVersion <= CustomizationDocument.currentSchemaVersion else {
                readOnly = true
                loadError = CustomizationError.unsupportedSchema(document.schemaVersion).errorDescription
                return
            }
            replacements = document.replacements
            snippets = document.snippets
        } catch {
            // Preserve the damaged file; start empty in memory and surface the error.
            // The file is only rewritten when the user saves or imports valid data.
            loadError = CustomizationError.malformedFile(error.localizedDescription).errorDescription
        }
    }

    private func save() throws {
        guard !readOnly else { throw CustomizationError.readOnlyConfiguration }
        let document = CustomizationDocument(replacements: replacements, snippets: snippets)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        // A successful user save resolves a previously surfaced malformed-file error.
        loadError = nil
        rebuildMatchStructures()
    }

    private func rebuildMatchStructures() {
        matcher = ReplacementMatcher(rules: replacements.filter(\.enabled).map { ($0.trigger, $0.replacement) })
        snippetTable = SnippetTable(snippets: snippets.filter(\.enabled).map { ($0.id, $0.name, $0.content) })
    }

    /// Snapshot for one processing pass.
    func processingSnapshot(cleanupMode: CleanupMode) -> ProcessingSettings {
        ProcessingSettings(cleanupMode: cleanupMode, replacements: matcher, snippets: snippetTable)
    }

    // MARK: - normalization & validation

    /// Collapses runs of whitespace and trims the edges (triggers and names).
    static func normalizeTrigger(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Line-ending consistency only; content is otherwise untouched.
    static func normalizeLineEndings(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func foldedKey(_ value: String) -> String {
        normalizeTrigger(value).folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    private func validated(_ replacement: Replacement, excluding excludedID: UUID? = nil) throws -> Replacement {
        let keys = Set(replacements.filter { $0.id != excludedID }.map { Self.foldedKey($0.trigger) })
        return try validateStagedReplacement(replacement, existingKeys: keys)
    }

    private func validated(_ snippet: Snippet, excluding excludedID: UUID? = nil) throws -> Snippet {
        let keys = Set(snippets.filter { $0.id != excludedID }.map { Self.foldedKey($0.name) })
        return try validateStagedSnippet(snippet, existingKeys: keys)
    }

    // MARK: - replacement mutations

    func addReplacement(_ replacement: Replacement) throws {
        replacements.append(try validated(replacement))
        try save()
    }

    func updateReplacement(_ replacement: Replacement) throws {
        guard let index = replacements.firstIndex(where: { $0.id == replacement.id }) else { return }
        replacements[index] = try validated(replacement, excluding: replacement.id)
        try save()
    }

    func deleteReplacement(id: UUID) throws {
        replacements.removeAll { $0.id == id }
        try save()
    }

    func setReplacementEnabled(id: UUID, enabled: Bool) throws {
        guard let index = replacements.firstIndex(where: { $0.id == id }) else { return }
        replacements[index].enabled = enabled
        try save()
    }

    // MARK: - snippet mutations

    func addSnippet(_ snippet: Snippet) throws {
        snippets.append(try validated(snippet))
        try save()
    }

    func updateSnippet(_ snippet: Snippet) throws {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[index] = try validated(snippet, excluding: snippet.id)
        try save()
    }

    func deleteSnippet(id: UUID) throws {
        snippets.removeAll { $0.id == id }
        try save()
    }

    func setSnippetEnabled(id: UUID, enabled: Bool) throws {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[index].enabled = enabled
        try save()
    }

    // MARK: - import / export

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(CustomizationDocument(replacements: replacements, snippets: snippets))
    }

    /// Validates fully before touching anything; a thrown error changes nothing.
    @discardableResult
    func importData(_ data: Data, mode: ImportMode) throws -> ImportSummary {
        let document: CustomizationDocument
        do {
            document = try JSONDecoder().decode(CustomizationDocument.self, from: data)
        } catch {
            throw CustomizationError.malformedFile(error.localizedDescription)
        }
        guard document.schemaVersion <= CustomizationDocument.currentSchemaVersion else {
            throw CustomizationError.unsupportedSchema(document.schemaVersion)
        }

        // Stage on copies so failures leave the current configuration untouched.
        var stagedReplacements: [Replacement]
        var stagedSnippets: [Snippet]
        var summary = ImportSummary()

        switch mode {
        case .replace:
            stagedReplacements = []
            stagedSnippets = []
            var triggerKeys = Set<String>()
            var nameKeys = Set<String>()
            for rule in document.replacements {
                let validated = try validateStagedReplacement(rule, existingKeys: triggerKeys)
                triggerKeys.insert(Self.foldedKey(validated.trigger))
                stagedReplacements.append(validated)
                summary.replacementsAdded += 1
            }
            for snippet in document.snippets {
                let validated = try validateStagedSnippet(snippet, existingKeys: nameKeys)
                nameKeys.insert(Self.foldedKey(validated.name))
                stagedSnippets.append(validated)
                summary.snippetsAdded += 1
            }
        case .merge:
            stagedReplacements = replacements
            stagedSnippets = snippets
            var triggerKeys = Set(replacements.map { Self.foldedKey($0.trigger) })
            var nameKeys = Set(snippets.map { Self.foldedKey($0.name) })
            for rule in document.replacements {
                guard let validated = try? validateStagedReplacement(rule, existingKeys: triggerKeys) else {
                    summary.replacementsSkipped += 1
                    continue
                }
                triggerKeys.insert(Self.foldedKey(validated.trigger))
                stagedReplacements.append(validated)
                summary.replacementsAdded += 1
            }
            for snippet in document.snippets {
                guard let validated = try? validateStagedSnippet(snippet, existingKeys: nameKeys) else {
                    summary.snippetsSkipped += 1
                    continue
                }
                nameKeys.insert(Self.foldedKey(validated.name))
                stagedSnippets.append(validated)
                summary.snippetsAdded += 1
            }
        }

        replacements = stagedReplacements
        snippets = stagedSnippets
        try save()
        return summary
    }

    private func validateStagedReplacement(_ rule: Replacement, existingKeys: Set<String>) throws -> Replacement {
        var staged = rule
        staged.trigger = Self.normalizeTrigger(staged.trigger)
        staged.replacement = Self.normalizeLineEndings(staged.replacement)
        guard !staged.trigger.isEmpty else { throw CustomizationError.emptyTrigger }
        guard !staged.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CustomizationError.emptyReplacement
        }
        guard !existingKeys.contains(Self.foldedKey(staged.trigger)) else {
            throw CustomizationError.duplicateTrigger(staged.trigger)
        }
        return staged
    }

    private func validateStagedSnippet(_ snippet: Snippet, existingKeys: Set<String>) throws -> Snippet {
        var staged = snippet
        // Newlines/control characters are rejected, not normalized away — a name
        // pasted with a line break is a mistake the user should see (spec: limits).
        guard !staged.name.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
        }) else {
            throw CustomizationError.nameContainsControlCharacters
        }
        staged.name = Self.normalizeTrigger(staged.name)
        staged.content = Self.normalizeLineEndings(staged.content)
        guard !staged.name.isEmpty else { throw CustomizationError.emptyName }
        guard staged.name.count <= Snippet.maxNameLength else { throw CustomizationError.nameTooLong }
        guard !staged.content.isEmpty else { throw CustomizationError.emptyContent }
        guard staged.content.utf8.count <= Snippet.maxContentBytes else { throw CustomizationError.contentTooLarge }
        guard !existingKeys.contains(Self.foldedKey(staged.name)) else {
            throw CustomizationError.duplicateName(staged.name)
        }
        return staged
    }
}
