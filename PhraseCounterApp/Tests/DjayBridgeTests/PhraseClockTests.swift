import XCTest
@testable import DjayBridge

final class PhraseClockTests: XCTestCase {

    // MARK: - Uncalibrated

    func testNoOffset_returnsNil() {
        let clock = PhraseClock(beatsPerPhrase: 32)
        XCTAssertNil(clock.position(elapsed: 10, rawBPM: 126))
    }

    func testZeroBPM_returnsNil() {
        var clock = PhraseClock(beatsPerPhrase: 32)
        clock.downbeatOffsetSeconds = 0
        XCTAssertNil(clock.position(elapsed: 10, rawBPM: 0))
    }

    // MARK: - Exact calibration instant

    func testAtCalibrationInstant_isPhrase1Bar1Beat1() {
        var clock = PhraseClock(beatsPerPhrase: 32)
        clock.downbeatOffsetSeconds = 4.2
        let pos = clock.position(elapsed: 4.2, rawBPM: 126)!
        XCTAssertEqual(pos.phraseNumber, 1)
        XCTAssertEqual(pos.barInPhrase, 1)
        XCTAssertEqual(pos.beatInBar, 1)
        XCTAssertEqual(pos.beatInPhrase, 1)
        XCTAssertEqual(pos.fractionalBeat, 0, accuracy: 1e-9)
        XCTAssertFalse(pos.isInAlertWindow)
    }

    // MARK: - Worked example mid-phrase

    func testMidPhrase_matchesHandComputedValues() {
        var clock = PhraseClock(beatsPerPhrase: 32)
        clock.downbeatOffsetSeconds = 4.2
        // beatDuration = 60/126 = 0.476190...; elapsedSince = 15.8; beatFloat = 33.18
        // beatIndex = 33 -> beatInPhrase0 = 1 (33 mod 32) -> phrase 2, bar 1, beat 2
        let pos = clock.position(elapsed: 20.0, rawBPM: 126)!
        XCTAssertEqual(pos.phraseNumber, 2)
        XCTAssertEqual(pos.barInPhrase, 1)
        XCTAssertEqual(pos.beatInBar, 2)
        XCTAssertEqual(pos.beatsUntilNextPhrase, 31)
        XCTAssertFalse(pos.isInAlertWindow)
    }

    // MARK: - Phrase boundary crossing

    func testCrossingPhraseBoundary_incrementsPhraseNumber() {
        var clock = PhraseClock(beatsPerPhrase: 32, alertWindowBeats: 4)
        clock.downbeatOffsetSeconds = 0
        let beatDuration = 60.0 / 120.0 // 0.5s per beat at 120 BPM

        // Beat 31 (0-indexed), last beat of phrase 1: beatIndex = 31 -> beatInPhrase0 = 31
        let justBefore = clock.position(elapsed: 31.0 * beatDuration, rawBPM: 120)!
        XCTAssertEqual(justBefore.phraseNumber, 1)
        XCTAssertEqual(justBefore.beatInPhrase, 32)
        XCTAssertEqual(justBefore.beatsUntilNextPhrase, 1)
        XCTAssertTrue(justBefore.isInAlertWindow)

        // Beat 32 (0-indexed) -> beatInPhrase0 = 0 -> phrase 2
        let justAfter = clock.position(elapsed: 32.0 * beatDuration, rawBPM: 120)!
        XCTAssertEqual(justAfter.phraseNumber, 2)
        XCTAssertEqual(justAfter.beatInPhrase, 1)
        XCTAssertEqual(justAfter.beatsUntilNextPhrase, 32)
        XCTAssertFalse(justAfter.isInAlertWindow)
    }

    // MARK: - Negative elapsed-since-downbeat (before calibration point)

    func testBeforeCalibrationPoint_doesNotCrashAndUsesFloorSemantics() {
        var clock = PhraseClock(beatsPerPhrase: 32)
        clock.downbeatOffsetSeconds = 4.2
        // elapsed=1.0, rawBPM=126 -> elapsedSince = -3.2, beatDuration ~0.4762
        // beatFloat = -6.72 -> beatIndex = -7 (floor, not truncation toward zero)
        let pos = clock.position(elapsed: 1.0, rawBPM: 126)!
        XCTAssertEqual(pos.phraseNumber, 0) // floorDiv(-7, 32) = -1 -> phraseNumber 0
        XCTAssertEqual(pos.beatInPhrase, 26) // floorMod(-7, 32) = 25 -> beatInPhrase 26
    }

    // MARK: - 16 vs 32 beats per phrase

    func test16BeatsPerPhrase_hasFourBars() {
        var clock = PhraseClock(beatsPerPhrase: 16)
        clock.downbeatOffsetSeconds = 0
        let beatDuration = 60.0 / 120.0
        // Beat index 15 (0-indexed) is the last beat of a 16-beat phrase -> bar 4
        let pos = clock.position(elapsed: 15.0 * beatDuration, rawBPM: 120)!
        XCTAssertEqual(pos.barInPhrase, 4)
        XCTAssertEqual(pos.beatInPhrase, 16)
    }

    func test32BeatsPerPhrase_hasEightBars() {
        var clock = PhraseClock(beatsPerPhrase: 32)
        clock.downbeatOffsetSeconds = 0
        let beatDuration = 60.0 / 120.0
        let pos = clock.position(elapsed: 31.0 * beatDuration, rawBPM: 120)!
        XCTAssertEqual(pos.barInPhrase, 8)
        XCTAssertEqual(pos.beatInPhrase, 32)
    }

    // MARK: - Alert window boundary

    func testAlertWindow_trueAtFourBeatsRemaining_falseAtFive() {
        var clock = PhraseClock(beatsPerPhrase: 32, alertWindowBeats: 4)
        clock.downbeatOffsetSeconds = 0
        let beatDuration = 60.0 / 120.0

        // beatIndex 27 -> beatInPhrase0 = 27 -> beatsUntilNext = 5 -> not in window
        let fiveLeft = clock.position(elapsed: 27.0 * beatDuration, rawBPM: 120)!
        XCTAssertEqual(fiveLeft.beatsUntilNextPhrase, 5)
        XCTAssertFalse(fiveLeft.isInAlertWindow)

        // beatIndex 28 -> beatsUntilNext = 4 -> in window
        let fourLeft = clock.position(elapsed: 28.0 * beatDuration, rawBPM: 120)!
        XCTAssertEqual(fourLeft.beatsUntilNextPhrase, 4)
        XCTAssertTrue(fourLeft.isInAlertWindow)
    }

    // MARK: - Statelessness

    func testStatelessness_sameInputsGiveSameResultRegardlessOfPriorCalls() {
        var clock = PhraseClock(beatsPerPhrase: 32)
        clock.downbeatOffsetSeconds = 4.2
        let first = clock.position(elapsed: 20.0, rawBPM: 126)!
        // Call with different args in between, simulating tempo changes / other frames.
        _ = clock.position(elapsed: 100.0, rawBPM: 130, bpmPercent: 3.5)
        _ = clock.position(elapsed: 0.5, rawBPM: 90)
        let second = clock.position(elapsed: 20.0, rawBPM: 126)!
        XCTAssertEqual(first, second)
    }

    // MARK: - effectiveBPM

    func testEffectiveBPM_atZeroPercent_returnsRawBPMUnchanged() {
        XCTAssertEqual(PhraseClock.effectiveBPM(rawBPM: 126, bpmPercent: 0), 126, accuracy: 1e-9)
    }

    /// Verified empirically (live drift test, two synced decks: 127 BPM @ 0%
    /// and 127 BPM @ +3.8%): djay's displayed BPM already reflects the pitch
    /// fader, but TimeInterpolator's `elapsed` is in file-content-seconds, so
    /// effectiveBPM must divide the percentage back OUT to recover the base
    /// tempo — reapplying it forward (or ignoring it) both cause drift.
    func testEffectiveBPM_dividesOutPercent_recoversBaseBPM() {
        XCTAssertEqual(PhraseClock.effectiveBPM(rawBPM: 127, bpmPercent: 3.8), 127 / 1.038, accuracy: 1e-9)
        XCTAssertEqual(PhraseClock.effectiveBPM(rawBPM: 100, bpmPercent: -10), 100 / 0.9, accuracy: 1e-9)
    }

    // MARK: - Parsing helpers

    func testParseBPM() {
        XCTAssertEqual(PhraseClock.parseBPM("126.0"), 126.0)
        XCTAssertNil(PhraseClock.parseBPM(nil))
        XCTAssertNil(PhraseClock.parseBPM("—"))
    }

    func testParsePercent() {
        XCTAssertEqual(PhraseClock.parsePercent("+7.3%"), 7.3, accuracy: 1e-9)
        XCTAssertEqual(PhraseClock.parsePercent("-2.0%"), -2.0, accuracy: 1e-9)
        XCTAssertEqual(PhraseClock.parsePercent("0.0%"), 0.0, accuracy: 1e-9)
        XCTAssertEqual(PhraseClock.parsePercent(nil), 0.0, accuracy: 1e-9)
    }
}
