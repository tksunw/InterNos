// Persistence, validation, corruption handling, and import/export for the
// customization store (feature handoff, persistent customization store).
// All I/O goes to a per-test temporary directory.

import XCTest
@testable import Internos

@MainActor
final class CustomizationStoreTests: XCTestCase {
    private var directory: URL!

    private func makeStore(file: String = "customizations.json") -> CustomizationStore {
        if directory == nil {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("internos-tests-\(UUID().uuidString)", isDirectory: true)
        }
        return CustomizationStore(fileURL: directory.appendingPathComponent(file))
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        super.tearDown()
    }

    // MARK: - basic persistence

    func testRoundTripAcrossRelaunch() throws {
        let store = makeStore()
        try store.addReplacement(Replacement(trigger: "cube control", replacement: "kubectl"))
        try store.addSnippet(Snippet(name: "calendar link", content: "https://example.com/schedule"))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.replacements.map(\.trigger), ["cube control"])
        XCTAssertEqual(reloaded.snippets.map(\.name), ["calendar link"])
    }

    func testArrayOrderIsStable() throws {
        let store = makeStore()
        for trigger in ["zeta", "alpha", "mid"] {
            try store.addReplacement(Replacement(trigger: trigger, replacement: "x"))
        }
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.replacements.map(\.trigger), ["zeta", "alpha", "mid"],
                       "entries must not reorder themselves between launches")
    }

    // MARK: - validation

    func testValidationRules() throws {
        let store = makeStore()
        XCTAssertThrowsError(try store.addReplacement(Replacement(trigger: "   ", replacement: "x")))
        XCTAssertThrowsError(try store.addReplacement(Replacement(trigger: "ok", replacement: " ")))

        try store.addReplacement(Replacement(trigger: "Power  Shell ", replacement: "PowerShell"))
        XCTAssertEqual(store.replacements[0].trigger, "Power Shell", "whitespace normalized on save")
        // Duplicate normalized trigger (different case/whitespace) rejected.
        XCTAssertThrowsError(try store.addReplacement(Replacement(trigger: "power shell", replacement: "y"))) {
            XCTAssertEqual($0 as? CustomizationError, .duplicateTrigger("power shell"))
        }

        XCTAssertThrowsError(try store.addSnippet(Snippet(name: String(repeating: "n", count: 101), content: "x")))
        XCTAssertThrowsError(try store.addSnippet(Snippet(name: "two\nlines", content: "x")))
        XCTAssertThrowsError(try store.addSnippet(
            Snippet(name: "big", content: String(repeating: "a", count: Snippet.maxContentBytes + 1))))
        try store.addSnippet(Snippet(name: "sig", content: "line1\r\nline2\rline3"))
        XCTAssertEqual(store.snippets[0].content, "line1\nline2\nline3", "line endings normalized to \\n")
        XCTAssertThrowsError(try store.addSnippet(Snippet(name: "SIG", content: "other"))) {
            XCTAssertEqual($0 as? CustomizationError, .duplicateName("SIG"))
        }
    }

    func testDisabledRulesExcludedFromSnapshot() throws {
        let store = makeStore()
        try store.addReplacement(Replacement(trigger: "cube control", replacement: "kubectl"))
        try store.setReplacementEnabled(id: store.replacements[0].id, enabled: false)

        let segments = store.matcher.apply(to: "cube control here")
        XCTAssertEqual(segments, [.text("cube control here")], "disabled rules do nothing")
    }

    // MARK: - corruption and schema handling

    func testMalformedFileIsPreservedAndSurfaced() throws {
        var store = makeStore()
        try store.addReplacement(Replacement(trigger: "keep", replacement: "me"))
        let fileURL = directory.appendingPathComponent("customizations.json")
        let garbage = Data("{not json".utf8)
        try garbage.write(to: fileURL)

        store = makeStore()
        XCTAssertNotNil(store.loadError, "a malformed file must surface a recoverable error")
        XCTAssertTrue(store.replacements.isEmpty, "in-memory configuration starts empty")
        XCTAssertEqual(try Data(contentsOf: fileURL), garbage,
                       "the damaged file is preserved until the user saves valid data")

        // A deliberate user save may replace it.
        try store.addReplacement(Replacement(trigger: "fresh", replacement: "start"))
        XCTAssertNil(store.loadError)
        XCTAssertNotEqual(try Data(contentsOf: fileURL), garbage)
    }

    func testFutureSchemaVersionIsReadOnly() throws {
        let fileURL: URL
        do {
            let store = makeStore()
            try store.addReplacement(Replacement(trigger: "old", replacement: "value"))
            fileURL = directory.appendingPathComponent("customizations.json")
        }
        let future = Data(#"{"schemaVersion": 99, "replacements": [], "snippets": []}"#.utf8)
        try future.write(to: fileURL)

        let store = makeStore()
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.addReplacement(Replacement(trigger: "x", replacement: "y"))) {
            XCTAssertEqual($0 as? CustomizationError, .readOnlyConfiguration)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), future, "a newer-schema file is never overwritten")
    }

    // MARK: - import / export

    func testExportImportRoundTrip() throws {
        let store = makeStore()
        try store.addReplacement(Replacement(trigger: "cube control", replacement: "kubectl"))
        try store.addSnippet(Snippet(name: "sig", content: "Cheers,\nTim"))
        let data = try store.exportData()

        let other = makeStore(file: "other.json")
        let summary = try other.importData(data, mode: .replace)
        XCTAssertEqual(summary, ImportSummary(replacementsAdded: 1, replacementsSkipped: 0,
                                              snippetsAdded: 1, snippetsSkipped: 0))
        XCTAssertEqual(other.replacements.map(\.trigger), ["cube control"])
        XCTAssertEqual(other.snippets.first?.content, "Cheers,\nTim")
    }

    func testMergeKeepsExistingOnConflictAndReportsCounts() throws {
        let store = makeStore()
        try store.addReplacement(Replacement(trigger: "power shell", replacement: "PowerShell"))

        let incoming = CustomizationDocument(replacements: [
            Replacement(trigger: "Power Shell", replacement: "power-shell"), // conflict → skipped
            Replacement(trigger: "cube control", replacement: "kubectl"),    // new → added
        ])
        let summary = try store.importData(try JSONEncoder().encode(incoming), mode: .merge)

        XCTAssertEqual(summary.replacementsAdded, 1)
        XCTAssertEqual(summary.replacementsSkipped, 1)
        XCTAssertEqual(store.replacements.first?.replacement, "PowerShell", "existing entries win on conflict")
        XCTAssertEqual(store.replacements.count, 2)
    }

    func testReplaceModeRejectsInvalidFileWithoutChanges() throws {
        let store = makeStore()
        try store.addReplacement(Replacement(trigger: "keep", replacement: "me"))

        // Duplicate normalized triggers inside the import file: whole import rejected.
        let bad = CustomizationDocument(replacements: [
            Replacement(trigger: "dup", replacement: "a"),
            Replacement(trigger: "DUP", replacement: "b"),
        ])
        XCTAssertThrowsError(try store.importData(try JSONEncoder().encode(bad), mode: .replace))
        XCTAssertEqual(store.replacements.map(\.trigger), ["keep"], "failed import changes nothing")

        XCTAssertThrowsError(try store.importData(Data("junk".utf8), mode: .replace))
        XCTAssertEqual(store.replacements.map(\.trigger), ["keep"])

        let future = Data(#"{"schemaVersion": 99, "replacements": [], "snippets": []}"#.utf8)
        XCTAssertThrowsError(try store.importData(future, mode: .replace)) {
            XCTAssertEqual($0 as? CustomizationError, .unsupportedSchema(99))
        }
        XCTAssertEqual(store.replacements.map(\.trigger), ["keep"])
    }

    func testNoTranscriptContentInStoreFile() throws {
        let store = makeStore()
        try store.addReplacement(Replacement(trigger: "cube control", replacement: "kubectl"))
        let contents = try String(contentsOf: directory.appendingPathComponent("customizations.json"), encoding: .utf8)
        XCTAssertFalse(contents.contains("raw"), "only configuration keys belong in the store file")
        XCTAssertTrue(contents.contains("schemaVersion"))
    }
}
