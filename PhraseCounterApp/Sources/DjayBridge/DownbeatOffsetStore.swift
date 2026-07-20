import Foundation

/// A calibrated downbeat, cached by artist+title so the same track doesn't
/// need re-calibrating on every reload. `source` is reserved for a future
/// Volet 2 integration that reads the offset from djay's own database
/// instead of manual calibration — kept loose enough not to paint into a
/// corner, but Volet 2 itself is not implemented here.
public struct DownbeatOffsetEntry: Codable, Equatable {
    /// Absolute position in seconds into the track's audio content where the
    /// first downbeat falls (e.g. 4.2). Invariant across reloads because
    /// djay's Elapsed Time reports true position in the track, not time
    /// since playback started.
    public var elapsedSecondsAtDownbeat: Double
    public var beatsPerPhrase: Int?
    public var bpmAtCalibration: Double?
    public var source: String
    public var updatedAt: Date

    public init(
        elapsedSecondsAtDownbeat: Double,
        beatsPerPhrase: Int? = nil,
        bpmAtCalibration: Double? = nil,
        source: String = "manual",
        updatedAt: Date = Date()
    ) {
        self.elapsedSecondsAtDownbeat = elapsedSecondsAtDownbeat
        self.beatsPerPhrase = beatsPerPhrase
        self.bpmAtCalibration = bpmAtCalibration
        self.source = source
        self.updatedAt = updatedAt
    }
}

/// Local JSON cache of calibrated downbeats, keyed by normalized "artist|title".
/// Read-only source of truth lives on disk under ~/djay-phrase-tool/data/ —
/// outside the djay-pro-bridge git clone, so DJ library metadata never risks
/// being committed.
public final class DownbeatOffsetStore {
    private let lock = NSLock()
    private let fileURL: URL
    private var cache: [String: DownbeatOffsetEntry]

    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("djay-phrase-tool/data/downbeat-offsets.json")
    }

    public init(fileURL: URL = DownbeatOffsetStore.defaultFileURL) {
        self.fileURL = fileURL
        self.cache = Self.load(from: fileURL)
    }

    public static func normalizedKey(artist: String?, title: String?) -> String? {
        guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let a = (artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(a)|\(t)"
    }

    public func lookup(artist: String?, title: String?) -> DownbeatOffsetEntry? {
        guard let key = Self.normalizedKey(artist: artist, title: title) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    @discardableResult
    public func upsert(
        artist: String?,
        title: String?,
        elapsedSecondsAtDownbeat: Double,
        beatsPerPhrase: Int? = nil,
        bpmAtCalibration: Double? = nil,
        source: String = "manual"
    ) -> Bool {
        guard let key = Self.normalizedKey(artist: artist, title: title) else { return false }
        lock.lock()
        defer { lock.unlock() }
        cache[key] = DownbeatOffsetEntry(
            elapsedSecondsAtDownbeat: elapsedSecondsAtDownbeat,
            beatsPerPhrase: beatsPerPhrase,
            bpmAtCalibration: bpmAtCalibration,
            source: source,
            updatedAt: Date()
        )
        save()
        return true
    }

    private static func load(from url: URL) -> [String: DownbeatOffsetEntry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: DownbeatOffsetEntry].self, from: data)) ?? [:]
    }

    private func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
