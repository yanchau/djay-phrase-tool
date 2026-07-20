import XCTest
@testable import DjayBridge

final class DownbeatOffsetStoreTests: XCTestCase {

    private func scratchFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DownbeatOffsetStoreTests-\(UUID().uuidString).json")
    }

    // MARK: - Round trip

    func testUpsertThenLookup_roundTrips() {
        let url = scratchFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DownbeatOffsetStore(fileURL: url)

        XCTAssertTrue(store.upsert(artist: "Test Artist", title: "Test Track", elapsedSecondsAtDownbeat: 4.2))
        let entry = store.lookup(artist: "Test Artist", title: "Test Track")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.elapsedSecondsAtDownbeat, 4.2)
        XCTAssertEqual(entry?.source, "manual")
    }

    func testLookup_beforeAnyUpsert_returnsNil() {
        let store = DownbeatOffsetStore(fileURL: scratchFileURL())
        XCTAssertNil(store.lookup(artist: "Test Artist", title: "Test Track"))
    }

    // MARK: - Key normalization

    func testKeyNormalization_caseAndWhitespaceInsensitive() {
        let url = scratchFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DownbeatOffsetStore(fileURL: url)

        store.upsert(artist: "Test Artist", title: "Test Track", elapsedSecondsAtDownbeat: 4.2)
        let entry = store.lookup(artist: "  TEST ARTIST  ", title: "  test track  ")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.elapsedSecondsAtDownbeat, 4.2)
    }

    // MARK: - Nil/empty inputs

    func testLookup_withNilOrEmptyTitle_returnsNilWithoutCrashing() {
        let store = DownbeatOffsetStore(fileURL: scratchFileURL())
        XCTAssertNil(store.lookup(artist: "Test Artist", title: nil))
        XCTAssertNil(store.lookup(artist: "Test Artist", title: ""))
        XCTAssertNil(store.lookup(artist: nil, title: nil))
    }

    func testUpsert_withNilTitle_failsWithoutCrashing() {
        let store = DownbeatOffsetStore(fileURL: scratchFileURL())
        XCTAssertFalse(store.upsert(artist: "Test Artist", title: nil, elapsedSecondsAtDownbeat: 4.2))
    }

    // MARK: - Persistence across instances

    func testReloadingFromFile_recoversPreviouslyWrittenEntries() {
        let url = scratchFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let firstStore = DownbeatOffsetStore(fileURL: url)
        firstStore.upsert(
            artist: "Test Artist", title: "Test Track",
            elapsedSecondsAtDownbeat: 4.2, beatsPerPhrase: 32, bpmAtCalibration: 127.0
        )

        let secondStore = DownbeatOffsetStore(fileURL: url)
        let entry = secondStore.lookup(artist: "Test Artist", title: "Test Track")
        XCTAssertEqual(entry?.elapsedSecondsAtDownbeat, 4.2)
        XCTAssertEqual(entry?.beatsPerPhrase, 32)
        XCTAssertEqual(entry?.bpmAtCalibration, 127.0)
    }

    // MARK: - Overwrite

    func testUpsert_overwritesPreviousEntryForSameKey() {
        let url = scratchFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DownbeatOffsetStore(fileURL: url)

        store.upsert(artist: "Test Artist", title: "Test Track", elapsedSecondsAtDownbeat: 4.2)
        store.upsert(artist: "Test Artist", title: "Test Track", elapsedSecondsAtDownbeat: 4.5)

        XCTAssertEqual(store.lookup(artist: "Test Artist", title: "Test Track")?.elapsedSecondsAtDownbeat, 4.5)
    }
}
