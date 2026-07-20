import Foundation
import SQLite3
import zlib

/// Beatgrid info read directly from djay's own analysis, keyed by
/// artist+title. Lets the phrase counter skip manual downbeat calibration
/// for any track djay has already analyzed (background scan or manual
/// load — see CLAUDE.md "Découvertes — Volet 2").
public struct DjayBeatgridInfo: Equatable {
    public let bpm: Double
    public let downbeatOffsetSeconds: Double
    public let source: String // "local" | "apple-music" | "spotify" | "soundcloud" | "unknown"
    /// True if `downbeatOffsetSeconds` comes from a grid the DJ manually
    /// edited in djay Pro itself (Edit Grid), rather than djay's automatic
    /// beat-tracker analysis. Manual edits are more trustworthy — the
    /// automatic grid is occasionally wrong (e.g. tracks with a pre-kick
    /// intro), which is exactly what a manual edit in djay corrects.
    public let isManualGridEdit: Bool
}

/// A detected level-change moment in a track's precomputed waveform —
/// candidate mix-in/mix-out point. Ported from `volet3/analyze_waveform.py`,
/// validated 2026-07-20 against manually-placed cue points on two tracks
/// (5/5 and 3/3 real boundaries recovered — see CLAUDE.md "Découvertes —
/// Volet 3"). Works on any track djay has analyzed, local or streamed —
/// uses only the cached waveform, never the audio file.
public struct WaveformTransition: Equatable {
    public let time: Double
    /// Phrase-grid-aligned candidates are higher confidence (validated with
    /// zero false positives when aligned) but alignment doesn't hold on
    /// every track — off-grid candidates are NOT dropped, just flagged.
    public let isPhraseAligned: Bool
    public let phraseNumber: Int?
    public let score: Double
}

/// One bar (4 beats) of structure analysis — Extension 2 ("détection de
/// structure par le kick"), ported from `volet3/analyze_structure.py`.
public struct StructureBar: Equatable {
    public enum Section: String, Equatable { case intro, groove, breakSection = "break", drop, outro }

    public let index: Int
    public let startTime: Double
    public let bassEnergy: Double
    public let totalEnergy: Double
    /// Mid/treble band averages for this bar (same raw scale as
    /// `bassEnergy`, i.e. not normalized) — added 2026-07-20 to support
    /// bar-level texture-change detection (`detectBarLevelTransitions`),
    /// alongside the existing bass/total used for section labeling.
    public let midEnergy: Double
    public let trebleEnergy: Double
    public let kickPresent: Bool
    public let section: Section
}

/// One phrase's energy level on a 1-10 scale (Mixed In Key-style),
/// ported from `volet3/analyze_track.py::energy_curve`. Computed by
/// averaging `StructureBar.totalEnergy` over the bars of each phrase,
/// then rescaling the whole track's phrase energies so the 5th/95th
/// percentile span the 1-10 range — a percentile stretch rather than a
/// raw min/max so a single outlier bar can't compress the rest of the
/// scale into 2-3 levels.
public struct PhraseEnergy: Equatable {
    public let phraseNumber: Int
    public let startTime: Double
    public let energyLevel: Int // 1...10
}

/// Combined output of the waveform-based Volet 3 analysis for one track.
public struct DjayStructureInfo: Equatable {
    public let bpm: Double
    public let downbeatOffsetSeconds: Double
    public let transitions: [WaveformTransition]
    public let bars: [StructureBar]
    /// Single 1-10 score for the WHOLE track — Mixed In Key has both this
    /// and the per-phrase `phraseEnergies` (see CLAUDE.md "Découvertes —
    /// échelle d'énergie" for the Mixed In Key research), we only had the
    /// per-phrase one until the user asked for this too (2026-07-20).
    /// Computed as the average of `phraseEnergies`' levels — reuses the
    /// already-validated per-phrase percentile scale rather than
    /// calibrating a second, separate absolute scale from raw bar energy
    /// (which would need a cross-library reference to mean anything, since
    /// a single track's own energy can't be percentile-normalized against
    /// itself).
    public let globalEnergyLevel: Int?
    public let phraseEnergies: [PhraseEnergy]
    /// Raw low-res amplitude envelope (0-255 per sample) and its sample
    /// rate — the same data `bars`/`transitions` are derived from, exposed
    /// directly for a live scrolling waveform view (idea borrowed from
    /// VirtualDJ's "Rhythm Wave" — see CLAUDE.md "Recherche concurrentielle").
    public let waveformSamples: [UInt8]
    public let waveformSampleRate: Double
    /// The 3 decoded frequency-band channels from `waveColorsInfo`
    /// (index 0 = bass, confirmed; 1/2 = presumed mid/treble — see
    /// `decodeColorChannel`), all at `bandSampleRate`. Exposed for a
    /// rekordbox-style 3-band colored waveform view.
    public let bandSamples: [[Double]]
    public let bandSampleRate: Double
    /// Every detected beat's time (seconds), plus the index within it of
    /// the first downbeat (`beatTimes[firstDownbeatIndex] == downbeatOffsetSeconds`).
    /// Exposed so bar numbers can be counted from real beats rather than
    /// assuming a constant tempo — see `structureInfo`'s comment on the
    /// a real test track bar-drift bug (2026-07-20).
    public let beatTimes: [Double]
    public let firstDownbeatIndex: Int
    /// Same length as `beatTimes` — `beatIndexOffset[i]` is the estimated
    /// *true* beat number at `beatTimes[i]`, correcting for gaps where
    /// djay's beat tracker skipped emitting an entry (a quiet passage, a
    /// pad-only breakdown with no clear onset) by rounding each gap to the
    /// nearest whole number of beats it likely represents, instead of
    /// always counting exactly one step per array entry. Use this, not
    /// raw array indices, to count bars — see `structureInfo`'s comment on
    /// the a real test track bar-count bug (2026-07-20).
    public let beatIndexOffset: [Int]
}

/// Read-only lookup against djay's live library database and per-track
/// analysis cache. Never writes to either. Safe to use while djay Pro is
/// running: SQLite's WAL mode supports concurrent read-only connections
/// against a file a writer has open (verified empirically 2026-07-19).
public final class DjayLibraryLookup {
    private let databasePath: String
    private let metadataDir: URL
    private var uuidToMetadataPath: [String: URL] = [:]
    private var indexBuilt = false

    public static var defaultDatabasePath: String {
        NSString(string: "~/Music/djay/djay Media Library.djayMediaLibrary/MediaLibrary.db")
            .expandingTildeInPath
    }

    public static var defaultMetadataDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Group Containers/VJXTL73S8G.com.algoriddim.userdata/" +
                "Library/Application Support/Algoriddim/Metadata"
            )
    }

    public init(
        databasePath: String = DjayLibraryLookup.defaultDatabasePath,
        metadataDir: URL = DjayLibraryLookup.defaultMetadataDir
    ) {
        self.databasePath = databasePath
        self.metadataDir = metadataDir
    }

    /// - Parameter durationHint: the track's duration in seconds, if known
    ///   live (e.g. elapsed+remaining from the Accessibility read). When
    ///   several tracks share the same title+artist (a local file AND an
    ///   Apple Music version of the same song, say — see CLAUDE.md
    ///   "Découvertes — intégration Swift du Volet 3"), this disambiguates
    ///   which one is actually loaded instead of arbitrarily picking the
    ///   first FTS match.
    public func lookup(artist: String, title: String, durationHint: Double? = nil) -> DjayBeatgridInfo? {
        let ranked = rankedCandidates(findCandidateUUIDs(title: title), artist: artist, durationHint: durationHint)
        for uuid in ranked {
            if let result = lookupBeatgrid(uuid: uuid) { return result }
        }
        return nil
    }

    private func artistsMatch(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Orders candidate uuids by: exact artist match first (if any exist),
    /// then by closeness of the cached track duration to `durationHint`
    /// (candidates missing a duration sort last). With no duration hint,
    /// preserves the artist-filtered FTS order (the previous behavior).
    private func rankedCandidates(_ uuids: [String], artist: String, durationHint: Double?) -> [String] {
        let withInfo = uuids.map { uuid -> (uuid: String, artist: String?, duration: Double?) in
            let info = loadMetadataPlist(uuid: uuid)?["info"] as? [String: Any]
            let duration = (info?["Duration"] as? Int).map(Double.init)
            return (uuid, info?["Artist"] as? String, duration)
        }
        let artistMatches = withInfo.filter { artistsMatch($0.artist ?? "", artist) }
        let pool = artistMatches.isEmpty ? withInfo : artistMatches
        guard let durationHint else { return pool.map { $0.uuid } }
        return pool.sorted { a, b in
            let da = a.duration.map { abs($0 - durationHint) } ?? .infinity
            let db = b.duration.map { abs($0 - durationHint) } ?? .infinity
            return da < db
        }.map { $0.uuid }
    }

    // MARK: - SQLite FTS lookup (title -> candidate UUIDs)

    private func findCandidateUUIDs(title: String) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT database2.key FROM database2
        WHERE database2.collection = 'mediaItems'
          AND database2.rowid IN (
            SELECT docid FROM fts_searchIndex WHERE title MATCH ?
          );
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self) // SQLITE_TRANSIENT
        sqlite3_bind_text(stmt, 1, title, -1, transient)

        var uuids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 0) {
                uuids.append(String(cString: cstr))
            }
        }
        return uuids
    }

    // MARK: - Per-track analysis cache lookup (uuid -> beatgrid)

    private func buildIndexIfNeeded() {
        guard !indexBuilt else { return }
        indexBuilt = true
        guard let shards = try? FileManager.default.contentsOfDirectory(
            at: metadataDir, includingPropertiesForKeys: nil
        ) else { return }
        for shard in shards {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: shard, includingPropertiesForKeys: nil
            ) else { continue }
            for file in files where file.pathExtension == "djayMetadata" {
                uuidToMetadataPath[file.deletingPathExtension().lastPathComponent] = file
            }
        }
    }

    /// Loads and parses a track's `.djayMetadata` plist by uuid. Shared by
    /// the beatgrid lookup and the structure-analysis lookup below.
    private func loadMetadataPlist(uuid: String) -> [String: Any]? {
        buildIndexIfNeeded()
        guard let path = uuidToMetadataPath[uuid],
              let data = try? Data(contentsOf: path),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ) as? [String: Any]
        else { return nil }
        return plist
    }

    private func lookupBeatgrid(uuid: String) -> DjayBeatgridInfo? {
        guard let plist = loadMetadataPlist(uuid: uuid),
              let deepBeat = plist["deepBeatTrackerInfo"] as? [String: Any],
              let bpm = deepBeat["bpm"] as? Double,
              let firstDownBeatIndex = deepBeat["firstDownBeatIndex"] as? Int,
              let compressed = deepBeat["compressedBeats"] as? Data,
              let decompressed = Self.zlibDecompress(compressed)
        else { return nil }

        let floatCount = decompressed.count / 4
        guard firstDownBeatIndex >= 0, firstDownBeatIndex < floatCount else { return nil }

        let downbeat = decompressed.withUnsafeBytes { raw -> Double in
            let bits = raw.load(fromByteOffset: firstDownBeatIndex * 4, as: UInt32.self).bigEndian
            return Double(Float(bitPattern: bits))
        }

        let info = plist["info"] as? [String: Any]
        let source: String
        switch info?["source"] as? Int {
        case 1: source = "local"
        case 2: source = "spotify"
        case 4: source = "soundcloud"
        case 7: source = "apple-music"
        default: source = "unknown"
        }

        // A manual grid edit in djay Pro's own "Edit Grid" overrides the
        // automatic downbeat position — prefer it when present. Confirmed
        // against a real edited track (2026-07-19): the automatic and
        // manual positions genuinely differ, and the manual one is the
        // DJ's deliberate correction.
        let manualDownbeat = readManualDownbeatPosition(uuid: uuid)
        let finalDownbeat = manualDownbeat ?? downbeat
        let isManual = manualDownbeat != nil

        return DjayBeatgridInfo(bpm: bpm, downbeatOffsetSeconds: finalDownbeat, source: source, isManualGridEdit: isManual)
    }

    // MARK: - Manual grid-edit lookup (mediaItemUserData, TSAF format)

    /// `mediaItemUserData` blobs use djay's proprietary "TSAF" binary format
    /// (not NSKeyedArchiver, not a standard plist — see CLAUDE.md
    /// "Découvertes — Volet 2"). The grammar for nested objects isn't fully
    /// reverse-engineered, but scalar fields are reliably extractable by
    /// finding the field-name token (tag 0x08 + name + 0x00 terminator) and
    /// reading the 4 bytes immediately before it as a little-endian float32
    /// — validated against known BPM/key values, and here against a real
    /// manually-edited track's `firstDownbeatPosition`.
    private func readManualDownbeatPosition(uuid: String) -> Double? {
        guard let data = readUserDataBlob(uuid: uuid) else { return nil }
        guard let tagOffset = Self.findFieldNameTag(data, name: "firstDownbeatPosition") else { return nil }
        guard tagOffset >= 4 else { return nil }
        let bits = data[(tagOffset - 4)..<tagOffset].withUnsafeBytes { $0.load(as: UInt32.self) }
        let value = Double(Float(bitPattern: bits))
        guard value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func readUserDataBlob(uuid: String) -> Data? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        let sql = "SELECT data FROM database2 WHERE collection = 'mediaItemUserData' AND key = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self) // SQLITE_TRANSIENT
        sqlite3_bind_text(stmt, 1, uuid, -1, transient)

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        let length = sqlite3_column_bytes(stmt, 0)
        return Data(bytes: blob, count: Int(length))
    }

    /// Finds the tag byte (0x08) of a `<tag=0x08><name><0x00>` field-name
    /// token, returning the offset of the tag byte itself.
    private static func findFieldNameTag(_ data: Data, name: String) -> Int? {
        let needle = [UInt8]([0x08] + Array(name.utf8) + [0x00])
        let bytes = [UInt8](data)
        guard bytes.count >= needle.count else { return nil }
        for i in 0...(bytes.count - needle.count) {
            if Array(bytes[i..<(i + needle.count)]) == needle {
                return i
            }
        }
        return nil
    }

    // MARK: - Cue point lookup (mediaItemUserData, TSAF format)

    /// Reads the DJ's own cue points for a track — a ground-truth source
    /// (unlike the algorithmic waveform-based `WaveformTransition`
    /// detection: this is exactly where the DJ chose to mark something,
    /// never a false positive or a missed one). Added 2026-07-20 alongside
    /// the auto-detected transitions, not in place of them.
    public func lookupCuePoints(artist: String, title: String, durationHint: Double? = nil) -> [Double]? {
        let ranked = rankedCandidates(findCandidateUUIDs(title: title), artist: artist, durationHint: durationHint)
        for uuid in ranked {
            if let cues = cuePoints(uuid: uuid), !cues.isEmpty {
                return cues
            }
        }
        return nil
    }

    /// `ADCCuePoint` objects in the TSAF blob (see CLAUDE.md "Piège de
    /// décodage rencontré : cue points dans mediaItemUserData") serialize
    /// the FIRST one in full — class marker, then each field as
    /// (2-byte type tag, payload, `0x08`+name+`0x00`) — but every
    /// subsequent one skips the class name and field names entirely,
    /// using a compact 3-byte back-reference (`0x2b 0x05 <index>`, index
    /// not fixed — varies per track/blob) immediately followed by its
    /// `time` field's (2-byte tag, 4-byte float32 LE) payload. Verified
    /// against two real tracks with known cue counts before writing this
    /// (a single-cue track and a 7-cue track — see CLAUDE.md).
    private func cuePoints(uuid: String) -> [Double]? {
        guard let data = readUserDataBlob(uuid: uuid) else { return nil }
        let bytes = [UInt8](data)
        let classMarker = [UInt8]([0x2b, 0x08] + Array("ADCCuePoint".utf8) + [0x00])
        guard let markerStart = Self.indexOf(bytes, classMarker, from: 0) else { return nil }
        let markerEnd = markerStart + classMarker.count

        var times: [Double] = []
        if let firstTime = Self.readFloat32LE(bytes, at: markerEnd, tagged: true) {
            times.append(firstTime)
        }

        // Determine this blob's per-track back-reference index by scanning
        // forward for the first `2b 05 <index>` immediately followed by the
        // float tag `13 00` — i.e. an actual cue-time back-reference, not
        // some other field that happens to start with the same 2 bytes.
        var searchPos = markerEnd
        var refByte: UInt8?
        while searchPos + 5 <= bytes.count {
            guard let found = Self.indexOf(bytes, [0x2b, 0x05], from: searchPos) else { break }
            if found + 5 <= bytes.count, bytes[found + 3] == 0x13, bytes[found + 4] == 0x00 {
                refByte = bytes[found + 2]
                break
            }
            searchPos = found + 2
        }

        if let refByte {
            let refPattern: [UInt8] = [0x2b, 0x05, refByte, 0x13, 0x00]
            var pos = markerEnd
            while let found = Self.indexOf(bytes, refPattern, from: pos) {
                if let t = Self.readFloat32LE(bytes, at: found + refPattern.count, tagged: false) {
                    times.append(t)
                }
                pos = found + refPattern.count
            }
        }

        return times.filter { $0.isFinite && $0 >= 0 }.sorted()
    }

    /// Reads a little-endian float32. `tagged: true` expects the 2-byte
    /// type tag (`0x13 0x00`) at `offset` with the payload right after;
    /// `tagged: false` expects the payload directly at `offset` (tag
    /// already matched by the caller).
    private static func readFloat32LE(_ bytes: [UInt8], at offset: Int, tagged: Bool) -> Double? {
        let payloadStart = tagged ? offset + 2 : offset
        guard payloadStart + 4 <= bytes.count else { return nil }
        if tagged, (bytes[offset], bytes[offset + 1]) != (0x13, 0x00) { return nil }
        let bits = UInt32(bytes[payloadStart])
            | (UInt32(bytes[payloadStart + 1]) << 8)
            | (UInt32(bytes[payloadStart + 2]) << 16)
            | (UInt32(bytes[payloadStart + 3]) << 24)
        return Double(Float(bitPattern: bits))
    }

    /// Naive byte-pattern search starting at `from` — blobs here are a few
    /// KB, no need for anything smarter.
    private static func indexOf(_ haystack: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, from >= 0, haystack.count >= needle.count else { return nil }
        var i = from
        while i <= haystack.count - needle.count {
            if Array(haystack[i..<(i + needle.count)]) == needle {
                return i
            }
            i += 1
        }
        return nil
    }

    /// Decompresses a zlib stream (the format used by djay's compressedBeats
    /// field) without knowing the exact output size upfront — grows the
    /// output buffer and retries on Z_BUF_ERROR.
    private static func zlibDecompress(_ input: Data) -> Data? {
        var attemptSize = max(input.count * 4, 1024)
        for _ in 0..<5 {
            var output = [UInt8](repeating: 0, count: attemptSize)
            var destLen = uLongf(attemptSize)
            let result = input.withUnsafeBytes { inBuf -> Int32 in
                uncompress(&output, &destLen, inBuf.bindMemory(to: UInt8.self).baseAddress, uLong(input.count))
            }
            if result == Z_OK {
                return Data(output.prefix(Int(destLen)))
            }
            if result == Z_BUF_ERROR {
                attemptSize *= 4
                continue
            }
            return nil
        }
        return nil
    }

    // MARK: - Volet 3: structure analysis from the cached waveform

    /// Constants match `volet3/analyze_waveform.py` / `analyze_structure.py`
    /// exactly — validated there (2026-07-20) against manually-placed cue
    /// points on real tracks. Keep in sync if either side changes.
    private enum StructureConstants {
        static let smoothWindowS = 2.0
        static let changeWindowS = 20.0
        static let minDistanceS = 20.0
        static let scoreThreshold = 0.35
        /// Threshold for the spectral-balance ("texture") signal, added
        /// 2026-07-20 — deliberately lower than `scoreThreshold` since a
        /// texture-only change (hats/vocals entering without a loudness
        /// jump) tends to be a smaller swing than a broadband amplitude
        /// change. First estimate, not yet empirically validated against a
        /// real track the way `scoreThreshold` was.
        static let textureScoreThreshold = 0.15
        static let phraseSnapToleranceS = 3.0
        static let kickPresentRatio = 0.4
        static let minSectionBars = 2
        /// Bar-level ("short") texture-change detection — added 2026-07-20
        /// after the 20s-window signals missed a real ~2-bar change on
        /// a real test track (diluted away by comparing 20s-before vs 20s-after
        /// averages). Compares each bar's mid+treble share to the average
        /// of the `barLevelWindowBars` bars just before/after it instead —
        /// short enough to resolve a change lasting only a couple of bars.
        /// None of these three constants are empirically validated yet
        /// (unlike `scoreThreshold`, tuned against real tracks in Volet 3).
        static let barLevelWindowBars = 4
        static let barLevelScoreThreshold = 0.12
        static let barLevelMinDistanceBars = 4
    }

    /// See `lookup(artist:title:durationHint:)` for what `durationHint` does.
    public func lookupStructure(
        artist: String, title: String, durationHint: Double? = nil, beatsPerPhrase: Int = 32
    ) -> DjayStructureInfo? {
        let ranked = rankedCandidates(findCandidateUUIDs(title: title), artist: artist, durationHint: durationHint)
        for uuid in ranked {
            if let info = structureInfo(uuid: uuid, beatsPerPhrase: beatsPerPhrase) {
                return info
            }
        }
        return nil
    }

    private func structureInfo(uuid: String, beatsPerPhrase: Int) -> DjayStructureInfo? {
        guard let plist = loadMetadataPlist(uuid: uuid),
              let deepBeat = plist["deepBeatTrackerInfo"] as? [String: Any],
              let bpm = deepBeat["bpm"] as? Double,
              let firstDownBeatIndex = deepBeat["firstDownBeatIndex"] as? Int,
              let beatsCompressed = deepBeat["compressedBeats"] as? Data,
              let beatsData = Self.zlibDecompress(beatsCompressed)
        else { return nil }

        let beatFloatCount = beatsData.count / 4
        guard firstDownBeatIndex >= 0, firstDownBeatIndex < beatFloatCount else { return nil }
        // Every detected beat, not just the first downbeat — used
        // (2026-07-20) to count bars by actual beat, not by an assumed
        // constant tempo. `deepBeat["bpm"]` is one summary number for the
        // whole track; on a real test track the user found the bar number we
        // computed from it (`downbeat + i * 4*60/bpm`) drifting by a
        // growing, non-constant amount over the track (1 bar off at bar 17,
        // 2 at bar 31, 0 at bar 33, 6 at bar 93) — the signature of real
        // micro-variation in tempo that a single constant BPM can't
        // capture, not a rounding bug (which would stay ≤1 bar and not
        // grow). Counting actual beats from `firstDownBeatIndex` sidesteps
        // the assumption entirely.
        let beatTimes: [Double] = beatsData.withUnsafeBytes { raw in
            (0..<beatFloatCount).map { i in
                let bits = raw.load(fromByteOffset: i * 4, as: UInt32.self).bigEndian
                return Double(Float(bitPattern: bits))
            }
        }
        let downbeat = beatTimes[firstDownBeatIndex]

        // Raw beat-counting alone (above) still gave the exact same wrong
        // bar numbers as the constant-tempo formula it replaced — the
        // user's diagnosis: djay's beat tracker doesn't emit an entry for
        // every real beat, it skips ones it has no confidence in (a quiet
        // passage, a pad-only breakdown with no clear onset), so counting
        // array entries silently undercounts across any such gap. Detected
        // here by comparing each consecutive gap to the track's median
        // beat interval (robust to a handful of gaps, unlike a mean) and
        // rounding the gap to the nearest whole number of beats it likely
        // represents, instead of always assuming exactly one.
        let rawIntervals = zip(beatTimes, beatTimes.dropFirst()).map { $1 - $0 }
        let referenceInterval = rawIntervals.isEmpty ? 0 : Self.percentile(rawIntervals, 50)
        var beatIndexOffset = [Int](repeating: 0, count: beatTimes.count)
        if referenceInterval > 0 {
            for i in 1..<beatTimes.count {
                let gap = beatTimes[i] - beatTimes[i - 1]
                let steps = max(1, Int((gap / referenceInterval).rounded()))
                beatIndexOffset[i] = beatIndexOffset[i - 1] + steps
            }
        } else if !beatTimes.isEmpty {
            beatIndexOffset = Array(0..<beatTimes.count)
        }

        var ampBytes: [UInt8] = []
        var ampRate: Double = 0
        if let wic = plist["waveInfoCompact"] as? [String: Any],
           let ampCompressed = wic["compressedLowRateWaveSamples"] as? Data,
           let ampData = Self.zlibDecompress(ampCompressed),
           let sampleRate = wic["lowRateWaveFinalSampleRate"] as? Double {
            ampBytes = [UInt8](ampData)
            ampRate = sampleRate
        }

        var bars: [StructureBar] = []
        var bandSamples: [[Double]] = []
        var bandSampleRate: Double = 0
        if !ampBytes.isEmpty,
           let wci = plist["waveColorsInfo"] as? [String: Any],
           let colorsCompressed = wci["compressedLowRateWaveColors"] as? Data,
           let colorsData = Self.zlibDecompress(colorsCompressed),
           let bassRate = wci["lowRateSampleRate"] as? Double {
            let total = ampBytes.map { Double($0) }
            bandSamples = (0..<3).map { Self.decodeColorChannel(colorsData, channel: $0) }
            bandSampleRate = bassRate
            bars = Self.labelStructure(
                bass: bandSamples[0], bassRate: bassRate, total: total, totalRate: ampRate, bpm: bpm, downbeat: downbeat,
                mid: bandSamples[1], treble: bandSamples[2]
            )
        }

        // Spectral balance (mid+treble share of total band energy, each
        // channel independently normalized by its own track-wide max first
        // so the 3 differently-scaled channels combine meaningfully) — a
        // second detection signal alongside broadband loudness. Needed
        // because a texture change (hats/vocals entering, a filter sweep)
        // can leave total loudness almost flat while still being a real,
        // audible transition — the user found exactly this case missed on
        // a real test track between bars 31-33 (2026-07-20).
        var spectralBalance: [Double] = []
        if bandSamples.count == 3 {
            let bassMax = bandSamples[0].max() ?? 1
            let midMax = bandSamples[1].max() ?? 1
            let trebleMax = bandSamples[2].max() ?? 1
            let n = min(bandSamples[0].count, bandSamples[1].count, bandSamples[2].count)
            spectralBalance = (0..<n).map { i in
                let b = max(bandSamples[0][i] / max(bassMax, 1e-6), 0)
                let m = max(bandSamples[1][i] / max(midMax, 1e-6), 0)
                let tr = max(bandSamples[2][i] / max(trebleMax, 1e-6), 0)
                return (m + tr) / max(b + m + tr, 1e-6)
            }
        }

        var transitions: [WaveformTransition] = []
        if !ampBytes.isEmpty {
            let samples = ampBytes.map { Double($0) }
            transitions = Self.detectTransitions(
                samples: samples, sampleRate: ampRate,
                spectralBalance: spectralBalance.isEmpty ? nil : spectralBalance,
                spectralSampleRate: bandSampleRate,
                bpm: bpm, downbeat: downbeat, beatsPerPhrase: beatsPerPhrase
            )
        }

        // Bar-level ("short") transitions merged in alongside the 20s-window
        // ones above — a separate detector at a different time scale, not a
        // replacement (see `detectBarLevelTransitions`). Candidates within
        // 2s of an already-found sustained transition are dropped as the
        // same event rather than reported twice.
        if !bars.isEmpty {
            let barLevel = Self.detectBarLevelTransitions(bars: bars, bpm: bpm, downbeat: downbeat, beatsPerPhrase: beatsPerPhrase)
            let dedupToleranceS = 2.0
            let extra = barLevel.filter { candidate in
                !transitions.contains { abs($0.time - candidate.time) < dedupToleranceS }
            }
            transitions = (transitions + extra).sorted { $0.time < $1.time }
        }

        // Refine each candidate to the exact bar boundary it belongs on —
        // added 2026-07-20 after the user found "mesure 16" reported for a
        // kick entrance landing exactly on bar 17 by ear and on djay's own
        // waveform. Two earlier attempts at this both failed for
        // instructive reasons (kept here, not just in CLAUDE.md, because
        // the next person touching this needs to not repeat them):
        //  1. Comparing BAR-AVERAGED bass/total between consecutive bars.
        //     Verified directly against this track's real data: the kick
        //     actually starts a fraction of a bar (~0.1-0.3s) *before* the
        //     bar-17 boundary — close enough that at djay's cached ~2Hz
        //     color-channel resolution it's indistinguishable from "right
        //     at the boundary" by ear/eye, but far enough that averaging
        //     over all of bar 16 already pulls that bar's average up,
        //     making the 15→16 jump look bigger than 16→17 — systematically
        //     one bar early whenever the true onset lands in a bar's tail.
        //  2. Using the single sharpest RAW sample-to-sample jump in the
        //     finer (~8Hz) total-amplitude channel instead. Also verified
        //     directly: that channel is dominated by the four-on-the-floor
        //     kick's own beat-to-beat spikes (amplitude swings 60→10→60...
        //     every single beat, section or no section), so the single
        //     biggest raw delta near a real transition is essentially
        //     random noise from a nearby beat, not the transition itself.
        // What actually works: smooth the total-amplitude channel over a
        // short (half-bar) window — long enough to average out the
        // beat-to-beat kick spikes, short enough to keep the section-level
        // ramp — then find where that smoothed signal crosses the midpoint
        // between the local plateau levels just before and after the
        // search window, and round THAT crossing time to the nearest bar
        // boundary (round, not floor: the true crossing lands slightly
        // before the perceptual boundary about as often as slightly after).
        if !bars.isEmpty, !ampBytes.isEmpty {
            let samples = ampBytes.map { Double($0) }
            let phraseDuration = Double(beatsPerPhrase) * 60.0 / bpm
            transitions = transitions.map { t in
                let refined = Self.refineTransitionTime(
                    t.time, bars: bars, bpm: bpm, downbeat: downbeat, samples: samples, sampleRate: ampRate
                )
                let phraseIndex = ((refined - downbeat) / phraseDuration).rounded()
                let phraseTime = downbeat + phraseIndex * phraseDuration
                let aligned = abs(refined - phraseTime) <= StructureConstants.phraseSnapToleranceS && phraseTime >= 0
                return WaveformTransition(
                    time: refined,
                    isPhraseAligned: aligned,
                    phraseNumber: aligned ? Int(phraseIndex) + 1 : nil,
                    score: t.score
                )
            }
        }

        let phraseEnergies = Self.energyCurve(bars: bars, beatsPerPhrase: beatsPerPhrase)
        let globalEnergyLevel: Int? = phraseEnergies.isEmpty ? nil :
            Int((Double(phraseEnergies.map { $0.energyLevel }.reduce(0, +)) / Double(phraseEnergies.count)).rounded())

        return DjayStructureInfo(
            bpm: bpm, downbeatOffsetSeconds: downbeat, transitions: transitions, bars: bars,
            globalEnergyLevel: globalEnergyLevel, phraseEnergies: phraseEnergies,
            waveformSamples: ampBytes, waveformSampleRate: ampRate,
            bandSamples: bandSamples, bandSampleRate: bandSampleRate,
            beatTimes: beatTimes, firstDownbeatIndex: firstDownBeatIndex, beatIndexOffset: beatIndexOffset
        )
    }

    /// Ported from `analyze_track.py::energy_curve`, then extended
    /// (2026-07-20) to weigh in the bass channel, not just the broadband
    /// envelope: research into how Mixed In Key / MIR practice build energy
    /// curves confirmed percentile normalization as the standard approach
    /// (already what this did), but also that techno's perceived energy is
    /// dominated by sub-bass/bass (~48-52% of spectral energy at peak-time —
    /// see CLAUDE.md "Découvertes — échelle d'énergie"), which the
    /// broadband-only version ignored. `totalEnergy` and `bassEnergy` are on
    /// different raw scales (whole-track amplitude bytes vs. decoded bfloat16
    /// bass channel), so each is percentile-normalized to 0-1 independently
    /// *before* combining 50/50 — a raw weighted sum would let whichever
    /// channel happens to have the larger raw magnitude dominate regardless
    /// of the intended weight.
    static func energyCurve(bars: [StructureBar], beatsPerPhrase: Int) -> [PhraseEnergy] {
        guard !bars.isEmpty else { return [] }
        let barsPerPhrase = max(1, beatsPerPhrase / 4)

        var phraseNumbers: [Int] = []
        var phraseStarts: [Double] = []
        var phraseTotal: [Double] = []
        var phraseBass: [Double] = []
        var i = 0
        var phraseNumber = 1
        while i < bars.count {
            let chunk = bars[i..<min(i + barsPerPhrase, bars.count)]
            phraseNumbers.append(phraseNumber)
            phraseStarts.append(chunk.first!.startTime)
            phraseTotal.append(chunk.map { $0.totalEnergy }.reduce(0, +) / Double(chunk.count))
            phraseBass.append(chunk.map { $0.bassEnergy }.reduce(0, +) / Double(chunk.count))
            phraseNumber += 1
            i += barsPerPhrase
        }

        func percentileNormalized(_ values: [Double]) -> [Double] {
            let lo = percentile(values, 5)
            let hi = percentile(values, 95)
            return values.map { min(1, max(0, ($0 - lo) / max(hi - lo, 1e-9))) }
        }

        let totalNorm = percentileNormalized(phraseTotal)
        let bassNorm = percentileNormalized(phraseBass)
        let combined = zip(totalNorm, bassNorm).map { 0.5 * $0 + 0.5 * $1 }

        return (0..<phraseNumbers.count).map { idx in
            let level = Int(min(10, max(1, (1 + 9 * combined[idx]).rounded())))
            return PhraseEnergy(phraseNumber: phraseNumbers[idx], startTime: phraseStarts[idx], energyLevel: level)
        }
    }

    /// Decodes one of the 3 frequency-band channels from `waveColorsInfo`'s
    /// low-rate color data (6 bytes/sample = 3 channels of 2 bytes each —
    /// see CLAUDE.md "Décodage de waveColorsInfo"). Channel 0 is confirmed
    /// bass (most "on/off"-like, used for kick detection since 2026-07-20's
    /// structure detector); channels 1/2 are presumed mid/treble by
    /// elimination but not independently confirmed — used starting
    /// 2026-07-20 for the 3-band colored waveform (rekordbox-style, see
    /// CLAUDE.md "Découvertes — waveform 3 bandes"). Each channel is a
    /// "bfloat16": the 2 high bytes of a float32, reconstructed by padding
    /// with 2 zero low bytes.
    private static func decodeColorChannel(_ colorsData: Data, channel: Int) -> [Double] {
        let bytes = [UInt8](colorsData)
        let recordSize = 6
        let n = bytes.count / recordSize
        let offset = channel * 2
        var result: [Double] = []
        result.reserveCapacity(n)
        for i in 0..<n {
            let base = i * recordSize + offset
            let bits = (UInt32(bytes[base]) << 24) | (UInt32(bytes[base + 1]) << 16)
            result.append(Double(Float(bitPattern: bits)))
        }
        return result
    }

    /// Simple moving-average smoothing, matching numpy's `convolve(..., mode="same")`
    /// for a boxcar kernel: output[i] is centered on input[i] (with edge
    /// truncation instead of zero-padding, which only affects the first/last
    /// `window/2` samples — negligible for our multi-minute-long tracks).
    private static func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard window > 1 else { return values }
        let n = values.count
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + values[i] }
        var result = [Double](repeating: 0, count: n)
        let half = window / 2
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n, i - half + window)
            result[i] = (prefix[hi] - prefix[lo]) / Double(hi - lo)
        }
        return result
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let rank = (p / 100.0) * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = Int(rank.rounded(.up))
        if lo == hi { return sorted[lo] }
        let frac = rank - Double(lo)
        return sorted[lo] * (1 - frac) + sorted[hi] * frac
    }

    /// Sustained-change score for one 1D signal: at each point, the
    /// relative gap between the mean of the ~20s before it and the ~20s
    /// after (see `analyze_waveform.py` docstring) — shared by both the
    /// broadband-loudness and spectral-balance detection passes below.
    private static func changeScoreSignal(_ samples: [Double], sampleRate: Double) -> [Double] {
        let n = samples.count
        guard n > 0, sampleRate > 0 else { return [] }
        let smoothWindow = max(1, Int((StructureConstants.smoothWindowS * sampleRate).rounded()))
        let smoothed = movingAverage(samples, window: smoothWindow)
        let half = Int((StructureConstants.changeWindowS * sampleRate).rounded())
        guard half > 0, n > half * 2 else { return [] }
        var changeScore = [Double](repeating: 0, count: n)
        for i in half..<(n - half) {
            let before = smoothed[(i - half)..<i].reduce(0, +) / Double(half)
            let after = smoothed[i..<(i + half)].reduce(0, +) / Double(half)
            changeScore[i] = abs(after - before) / max(before, 1.0)
        }
        return changeScore
    }

    /// Local maxima of a change-score signal above `threshold`, as
    /// (time in seconds, score) pairs — greedy non-max suppression by
    /// score happens later, once candidates from multiple signals (of
    /// possibly different sample rates) are merged in the time domain.
    private static func changeScorePeaks(
        _ changeScore: [Double], sampleRate: Double, threshold: Double
    ) -> [(time: Double, score: Double)] {
        let n = changeScore.count
        let half = Int((StructureConstants.changeWindowS * sampleRate).rounded())
        guard half > 0, n > half * 2 else { return [] }
        var peaks: [(time: Double, score: Double)] = []
        for i in half..<(n - half) {
            guard changeScore[i] >= threshold else { continue }
            let prev = i > 0 ? changeScore[i - 1] : -.infinity
            let next = i < n - 1 ? changeScore[i + 1] : -.infinity
            if changeScore[i] > prev && changeScore[i] >= next {
                peaks.append((Double(i) / sampleRate, changeScore[i]))
            }
        }
        return peaks
    }

    /// Ported from `analyze_waveform.py::detect_transitions`, then extended
    /// (2026-07-20) with a second detection pass over `spectralBalance` —
    /// the mid+treble share of total band energy (see `structureInfo`).
    /// Needed because a real transition can leave broadband loudness nearly
    /// flat while still audibly changing texture (hats/vocals entering, a
    /// filter sweep) — reported missed by the user on a real test track between
    /// bars 31-33. Candidates from both signals are merged by time and
    /// jointly non-max-suppressed, so a moment strong in either (or both)
    /// signals survives, but the same moment isn't reported twice. Each
    /// transition is then classified as phrase-grid aligned or not (both
    /// are returned — off-grid candidates are lower confidence, not
    /// dropped; see CLAUDE.md for why filtering them outright caused false
    /// negatives on a real track).
    static func detectTransitions(
        samples: [Double], sampleRate: Double,
        spectralBalance: [Double]? = nil, spectralSampleRate: Double = 0,
        bpm: Double, downbeat: Double, beatsPerPhrase: Int
    ) -> [WaveformTransition] {
        guard !samples.isEmpty, sampleRate > 0, bpm > 0 else { return [] }

        var candidates = changeScorePeaks(
            changeScoreSignal(samples, sampleRate: sampleRate),
            sampleRate: sampleRate, threshold: StructureConstants.scoreThreshold
        )
        if let spectralBalance, spectralSampleRate > 0 {
            candidates += changeScorePeaks(
                changeScoreSignal(spectralBalance, sampleRate: spectralSampleRate),
                sampleRate: spectralSampleRate, threshold: StructureConstants.textureScoreThreshold
            )
        }

        // Greedy non-max suppression by score, enforcing minimum distance —
        // a simplified stand-in for scipy.signal.find_peaks(distance:,
        // prominence:) that's adequate here because both change-score
        // signals are already smoothed, derived signals (see
        // analyze_waveform.py docstring).
        var accepted: [(time: Double, score: Double)] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            if accepted.allSatisfy({ abs($0.time - candidate.time) >= StructureConstants.minDistanceS }) {
                accepted.append(candidate)
            }
        }
        accepted.sort { $0.time < $1.time }

        let phraseDuration = Double(beatsPerPhrase) * 60.0 / bpm
        return accepted.map { c in
            let phraseIndex = ((c.time - downbeat) / phraseDuration).rounded()
            let phraseTime = downbeat + phraseIndex * phraseDuration
            let aligned = abs(c.time - phraseTime) <= StructureConstants.phraseSnapToleranceS && phraseTime >= 0
            return WaveformTransition(
                time: c.time,
                isPhraseAligned: aligned,
                phraseNumber: aligned ? Int(phraseIndex) + 1 : nil,
                score: c.score
            )
        }
    }

    /// Bar-level texture-change detection (added 2026-07-20 — see
    /// `StructureConstants.barLevelWindowBars`). Independent of
    /// `detectTransitions`'s 20s-window signals: compares each bar's
    /// mid+treble share of total band energy to the average of the few
    /// bars just before/after it, so a change lasting only a couple of
    /// bars isn't diluted away the way it would be in a 40-second window.
    /// Every result is necessarily phrase-unaligned-or-not per the normal
    /// classification (bar-granularity, not phrase-granularity, is the
    /// point — a real texture change need not land on a 16/32-beat
    /// boundary any more than the 20s-window transitions do).
    static func detectBarLevelTransitions(
        bars: [StructureBar], bpm: Double, downbeat: Double, beatsPerPhrase: Int
    ) -> [WaveformTransition] {
        let w = StructureConstants.barLevelWindowBars
        guard bars.count > w * 2, bpm > 0 else { return [] }

        let balance = bars.map { bar -> Double in
            let total = bar.bassEnergy + bar.midEnergy + bar.trebleEnergy
            return total > 1e-9 ? (bar.midEnergy + bar.trebleEnergy) / total : 0
        }

        // Every bar above threshold is a candidate — greedy non-max
        // suppression by score (below) picks the strongest bar within any
        // cluster of consecutive qualifying bars, so no separate local-
        // maximum pass is needed at this small a scale.
        var candidates: [(time: Double, score: Double)] = []
        for i in w..<(bars.count - w) {
            let before = balance[(i - w)..<i].reduce(0, +) / Double(w)
            let after = balance[i..<(i + w)].reduce(0, +) / Double(w)
            let score = abs(after - before)
            guard score >= StructureConstants.barLevelScoreThreshold else { continue }
            candidates.append((bars[i].startTime, score))
        }

        let minDistanceS = Double(StructureConstants.barLevelMinDistanceBars) * 4.0 * 60.0 / bpm
        var accepted: [(time: Double, score: Double)] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            if accepted.allSatisfy({ abs($0.time - candidate.time) >= minDistanceS }) {
                accepted.append(candidate)
            }
        }
        accepted.sort { $0.time < $1.time }

        let phraseDuration = Double(beatsPerPhrase) * 60.0 / bpm
        return accepted.map { c in
            let phraseIndex = ((c.time - downbeat) / phraseDuration).rounded()
            let phraseTime = downbeat + phraseIndex * phraseDuration
            let aligned = abs(c.time - phraseTime) <= StructureConstants.phraseSnapToleranceS && phraseTime >= 0
            return WaveformTransition(
                time: c.time,
                isPhraseAligned: aligned,
                phraseNumber: aligned ? Int(phraseIndex) + 1 : nil,
                score: c.score
            )
        }
    }

    /// Refines an approximate transition time to the nearest true bar
    /// boundary — see `structureInfo`'s comment on the a real test track
    /// bar-precision fix (2026-07-20) for why bar-average jumps and raw
    /// single-sample jumps both failed. Smooths the raw total-amplitude
    /// channel over half a bar (long enough to average out the
    /// four-on-the-floor kick's own beat-to-beat spikes, short enough to
    /// keep a real section-level ramp), locates where that smoothed signal
    /// crosses the midpoint between the plateau levels just outside a
    /// small search window around the approximate candidate, and rounds
    /// that crossing time to the nearest bar boundary. `searchBars` default
    /// of 1 (not wider) is deliberate and verified against real data: a
    /// wider window (tried 3) spans two closely-spaced real transitions on
    /// this same track (a break at bar 31, the return at bar 33, only 2
    /// bars apart) and produces unstable, oscillating results depending on
    /// which nearby bar the input candidate happened to land on — ±1
    /// resolved every test point (bars 17/31/33/93) correctly and stably.
    private static func refineTransitionTime(
        _ time: Double, bars: [StructureBar], bpm: Double, downbeat: Double,
        samples: [Double], sampleRate: Double, searchBars: Int = 1
    ) -> Double {
        guard bars.count > 1, sampleRate > 0, samples.count > 2, bpm > 0 else { return time }
        let barDuration = 4.0 * 60.0 / bpm

        var nearestIdx = 0
        var nearestDist = Double.infinity
        for (i, bar) in bars.enumerated() {
            let d = abs(bar.startTime - time)
            if d < nearestDist { nearestDist = d; nearestIdx = i }
        }
        let lo = max(0, nearestIdx - searchBars)
        let hi = min(bars.count - 1, nearestIdx + searchBars)
        guard lo < hi else { return time }

        let windowStart = bars[lo].startTime
        let windowEnd = bars[hi].startTime + barDuration
        let loIdx = max(1, Int(windowStart * sampleRate))
        let hiIdx = min(samples.count - 1, Int(windowEnd * sampleRate))
        guard loIdx < hiIdx else { return time }

        let smoothWindow = max(1, Int((barDuration / 2.0 * sampleRate).rounded()))
        let smoothed = movingAverage(samples, window: smoothWindow)

        let before = smoothed[loIdx]
        let after = smoothed[hiIdx]
        guard abs(after - before) > 1e-6 else { return time }
        let midpoint = (before + after) / 2.0
        let rising = after > before

        var crossingIdx = loIdx
        for i in loIdx..<hiIdx {
            let crossed = rising ? smoothed[i] >= midpoint : smoothed[i] <= midpoint
            if crossed { crossingIdx = i; break }
            crossingIdx = i + 1
        }
        let crossingTime = Double(crossingIdx) / sampleRate

        let roundedBarIndex = ((crossingTime - downbeat) / barDuration).rounded()
        return downbeat + roundedBarIndex * barDuration
    }

    /// Ported from `analyze_structure.py::label_structure` — **and then
    /// fixed (2026-07-20)** for a bug present in that original Python
    /// reference too: the bar grid was built from raw sample index 0, never
    /// actually using the `downbeat` it was passed. Since bar 0 didn't start
    /// at the real first downbeat, every bar's timestamp (and therefore
    /// every section badge and the energy-per-phrase grouping, both derived
    /// from these bars) was off by `downbeat` seconds from the true
    /// beatgrid — reported by the user as the energy level on a real test track
    /// lagging the real kick by ~5 beats. Fixed by starting the bar loop at
    /// the sample index nearest `downbeat` and computing each bar's start
    /// from the beatgrid (`downbeat + i * barDuration`) instead of from the
    /// raw sample index.
    static func labelStructure(
        bass: [Double], bassRate: Double, total: [Double], totalRate: Double, bpm: Double, downbeat: Double,
        mid: [Double] = [], treble: [Double] = []
    ) -> [StructureBar] {
        guard !bass.isEmpty, !total.isEmpty, bassRate > 0, totalRate > 0, bpm > 0 else { return [] }

        // Resample all channels onto a common (the lowest) rate, via linear
        // interpolation — matches numpy.interp in the Python original. Mid/
        // treble share `bass`'s rate (same source array, `waveColorsInfo`).
        let targetRate = min(bassRate, totalRate)
        let targetLen = Int((min(Double(bass.count) / bassRate, Double(total.count) / totalRate) * targetRate))
        guard targetLen > 1 else { return [] }
        let bassR = resample(bass, srcRate: bassRate, dstRate: targetRate, dstLen: targetLen)
        let totalR = resample(total, srcRate: totalRate, dstRate: targetRate, dstLen: targetLen)
        let midR = mid.isEmpty ? [Double](repeating: 0, count: targetLen) : resample(mid, srcRate: bassRate, dstRate: targetRate, dstLen: targetLen)
        let trebleR = treble.isEmpty ? [Double](repeating: 0, count: targetLen) : resample(treble, srcRate: bassRate, dstRate: targetRate, dstLen: targetLen)

        let barDuration = 4.0 * 60.0 / bpm
        let barSamples = max(1, Int((barDuration * targetRate).rounded()))
        let startIdx = max(0, min(targetLen, Int((downbeat * targetRate).rounded())))
        let nBars = (targetLen - startIdx) / barSamples
        guard nBars > 0 else { return [] }

        var barBass = [Double](repeating: 0, count: nBars)
        var barTotal = [Double](repeating: 0, count: nBars)
        var barMid = [Double](repeating: 0, count: nBars)
        var barTreble = [Double](repeating: 0, count: nBars)
        var barStart = [Double](repeating: 0, count: nBars)
        for i in 0..<nBars {
            let lo = startIdx + i * barSamples
            let hi = min(targetLen, lo + barSamples)
            barBass[i] = bassR[lo..<hi].reduce(0, +) / Double(hi - lo)
            barTotal[i] = totalR[lo..<hi].reduce(0, +) / Double(hi - lo)
            barMid[i] = midR[lo..<hi].reduce(0, +) / Double(hi - lo)
            barTreble[i] = trebleR[lo..<hi].reduce(0, +) / Double(hi - lo)
            barStart[i] = downbeat + Double(i) * barDuration
        }

        let loudMask = barTotal.map { $0 > percentile(barTotal, 50) }
        let loudBass = zip(barBass, loudMask).filter { $0.1 }.map { $0.0 }
        let baselineBass = loudBass.isEmpty ? percentile(barBass, 50) : percentile(loudBass, 50)
        let kickPresent = barBass.map { $0 > StructureConstants.kickPresentRatio * baselineBass }
        let nearSilenceTotal = percentile(barTotal, 15)
        let loudLevel = percentile(barTotal, 55)

        var sections = [StructureBar.Section?](repeating: nil, count: nBars)

        var introEnd = min(4, nBars)
        for i in 0..<nBars where barTotal[i] > loudLevel && kickPresent[i] {
            introEnd = i
            break
        }
        for i in 0..<introEnd { sections[i] = .intro }

        var outroStart = nBars
        if nBars > introEnd {
            outroStart = nBars
            for i in stride(from: nBars - 1, through: introEnd, by: -1)
            where barTotal[i] > loudLevel && kickPresent[i] {
                outroStart = i + 1
                break
            }
        }
        for i in outroStart..<nBars { sections[i] = .outro }

        var i = introEnd
        while i < outroStart {
            if sections[i] != nil { i += 1; continue }
            if !kickPresent[i] && barTotal[i] > nearSilenceTotal {
                var j = i
                while j < outroStart, sections[j] == nil, !kickPresent[j], barTotal[j] > nearSilenceTotal {
                    j += 1
                }
                if j - i >= StructureConstants.minSectionBars {
                    for k in i..<j { sections[k] = .breakSection }
                    if j < outroStart { sections[j] = .drop }
                }
                i = j + 1
            } else {
                sections[i] = .groove
                i += 1
            }
        }

        return (0..<nBars).map { i in
            StructureBar(
                index: i, startTime: barStart[i], bassEnergy: barBass[i], totalEnergy: barTotal[i],
                midEnergy: barMid[i], trebleEnergy: barTreble[i],
                kickPresent: kickPresent[i], section: sections[i] ?? .groove
            )
        }
    }

    private static func resample(_ values: [Double], srcRate: Double, dstRate: Double, dstLen: Int) -> [Double] {
        guard values.count > 1 else { return [Double](repeating: values.first ?? 0, count: dstLen) }
        var result = [Double](repeating: 0, count: dstLen)
        let lastSrcIndex = Double(values.count - 1)
        for i in 0..<dstLen {
            let dstTime = Double(i) / dstRate
            var srcPos = dstTime * srcRate
            srcPos = min(max(srcPos, 0), lastSrcIndex)
            let lo = Int(srcPos.rounded(.down))
            let hi = min(values.count - 1, lo + 1)
            let frac = srcPos - Double(lo)
            result[i] = values[lo] * (1 - frac) + values[hi] * frac
        }
        return result
    }
}
