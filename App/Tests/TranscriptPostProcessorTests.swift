import XCTest
@testable import Internos

final class TranscriptPostProcessorTests: XCTestCase {
    func testSubstitutions() {
        let p = TranscriptPostProcessor.process
        XCTAssertEqual(p("Hashtag yard sale this weekend."), "#yard sale this weekend.")
        XCTAssertEqual(p("Check out hashtag yard."), "Check out #yard.")
        XCTAssertEqual(p("Emoji thumbs up."), "👍.")
        XCTAssertEqual(p("Sounds good emoji smiley face"), "Sounds good 🙂")
        // Unknown emoji name and bare names stay literal.
        XCTAssertEqual(p("emoji flibbertigibbet"), "emoji flibbertigibbet")
        XCTAssertEqual(p("She sent me a smiley face."), "She sent me a smiley face.")
        // Explicit symbol phrases.
        XCTAssertEqual(p("tim at sign example.com"), "tim @ example.com")
        // Trailing "hashtag" with nothing after it stays literal.
        XCTAssertEqual(p("that's the hashtag"), "that's the hashtag")
    }

    @MainActor
    func testVersionCompare() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.5", than: "1.0.4"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.4", than: "1.0.5"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.0"))
    }
}
