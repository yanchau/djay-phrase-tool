# Technical writeup: reverse-engineering djay Pro's data

This document covers what was found while building `djay-phrase-tool`: djay Pro's on-disk data formats, how they were decoded, what's confirmed vs. still a hypothesis, and what was tried and abandoned. It exists so someone else doesn't have to re-derive any of this from scratch — every extraction technique here was validated against real data before being relied on.

Everything described was learned through black-box reverse-engineering (reading djay's own files with a hex editor and a debugger, never disassembling djay's binary or bypassing any protection). All of it is **read-only** — nothing here writes to djay's database or files.

macOS version at the time of writing: djay Pro 5.6.7 on macOS 14.4.1. Formats may change in future djay versions.

## Contents

- [Locations](#locations)
- [Track identification](#track-identification)
- [The `database2` SQLite schema and the TSAF binary format](#the-database2-sqlite-schema-and-the-tsaf-binary-format)
- [The `.djayMetadata` cache (plain plist)](#the-djaymetadata-cache-plain-plist)
- [Beatgrid & downbeat extraction](#beatgrid--downbeat-extraction)
- [Cue points](#cue-points)
- [Waveform & frequency-band data](#waveform--frequency-band-data)
- [Structure & energy detection](#structure--energy-detection)
- [Reading djay's live UI (Accessibility API)](#reading-djays-live-ui-accessibility-api)
- [Open questions / abandoned attempts](#open-questions--abandoned-attempts)

## Locations

- Main database: `~/Music/djay/djay Media Library.djayMediaLibrary/MediaLibrary.db` — SQLite in WAL mode (so `-shm`/`-wal` sidecar files exist while djay is running).
- Per-track analysis cache: `~/Library/Group Containers/VJXTL73S8G.com.algoriddim.userdata/Library/Application Support/Algoriddim/Metadata/<2-char-shard>/<uuid>.djayMetadata` — one file per track, sharded into ~256 subdirectories (the sharding rule wasn't reverse-engineered; in practice, either index the subdirectories once at startup or search by content).

The database contains far more tracks than what's visible in djay's own library view: djay scans every folder it has access to in the background and silently adds discovered tracks. On one real library, **3,679 tracks were found in the database**, all with complete BPM/beatgrid analysis (3,193 local files, 467 Apple Music, 5 Spotify, 1 SoundCloud) — confirming djay analyzes Spotify and SoundCloud tracks too, not just local files and Apple Music.

**Reading the SQLite database while djay Pro is running is safe** — WAL mode is designed for concurrent readers, verified empirically over an extended session. No need to quit djay or copy the database first for this use case.

## Track identification

A library entry is identified by the triplet **(artist, title, duration)** — not a file path. Consequences:

- Several identical local files (same triplet) share one database entry, and therefore share cue points: whichever copy is loaded into djay *first* determines the cues that "belong" to that artist/title/duration going forward.
- A local file and a streamed version (e.g. Apple Music) of the *same* song do **not** necessarily share a database entry — they can get separate UUIDs with independent analysis and cues.
- Editing metadata (ID3 tags, artist/title) with an **external** tool (Serato, Kid3, a bulk tag editor) can leave "ghost" duplicate entries behind — confirmed independently by another user's forensic investigation on the Algoriddim community forum ([Duplicate ghost files](https://community.algoriddim.com/t/duplicate-ghost-files/42759/21)). Editing directly inside djay does not cause this. Bulk edits across many files are more likely to trigger it than isolated ones.

## The `database2` SQLite schema and the TSAF binary format

The main table is a key-value store: `database2(rowid, collection, key, data, metadata)`. `key` is a 32-character hex UUID identifying a track; `data` is a binary blob. A single track has one row per *collection* it appears in, all under the same UUID. The collections that matter here:

| Collection | What it holds |
|---|---|
| `mediaItemAnalyzedData` | BPM, key index (see [Open questions](#open-questions--abandoned-attempts)), play count, rating |
| `mediaItemUserData` | Cue points, loop regions, manual beatgrid corrections |
| `mediaItemTitleIDs`, `mediaItems`, `localMediaItemLocations`, `globalMediaItemLocations` | Title/artist text, file location, streaming-service identity |

A full-text index, `fts_searchIndex` (SQLite FTS4, columns: title/artist/genre/album/…), maps directly to `database2.key` — `SELECT rowid FROM fts_searchIndex WHERE fts_searchIndex MATCH 'query'`, then look up `database2` by that same `rowid`/`key`.

### The TSAF binary format

`database2.data` blobs are **not** `NSKeyedArchiver` and not a standard plist — they're a proprietary binary format, tagged `TSAF` in the first 4 bytes (a 20-byte header total, then the payload). Reverse-engineered structure:

- **Class markers**: `0x2b 0x08 <class-name-ASCII> 0x00` (e.g. `ADCCuePoint`, `ADCLoopRegion`, `ADCMediaItemUserData`).
- **Field-name tokens**: `0x08 <field-name-ASCII> 0x00`.
- **Scalar fields are encoded VALUE-then-NAME**, not name-then-value: a 2-byte type tag, a fixed-width payload, *then* the field-name token. Concretely:
  - float32 (little-endian): tag `0x13 0x00`, 4-byte payload.
  - int32 (little-endian): tag `0x0b`, 4-byte payload (only 1 byte of tag observed here vs. 2 for float — not fully systematized).
  - string: tag `0x08`, ASCII bytes, `0x00` terminator.
  - "null/unset" markers use a distinct single-byte tag (`0x2d`, `0x2e` observed) with no payload — a field can be entirely *absent* from the byte stream rather than present-with-a-default, which matters when scanning for a field's presence as a signal (see [Cue points](#cue-points)).
- **Repeated objects of the same class use a compact 3-byte back-reference** instead of re-spelling the class name and every field name: `0x2b 0x05 <index>`, where `<index>` is a single byte **assigned per-blob** — it is *not* a fixed constant across tracks (observed `0x0f`, `0x10`, `0x0e`, `0x16` for the same `ADCCuePoint` class in different blobs). After this 3-byte reference, that object's own fields follow using the same *scalar field* compact-reference scheme (`0x05 <field-index>`, no name repeated) rather than the full name.
- Complex/collection-typed fields (a `Set` of cue points, an array, etc.) don't carry an inline scalar value — only their field name is announced (`cuePoints`, `loopRegions`, …), and the actual member objects appear later in the byte stream as their own class markers.

**Practical extraction technique validated repeatedly**: to read a scalar field once you know its name, search the blob for the field-name token (`0x08 <name> 0x00`) and read the 4 bytes immediately *before* the tag as the value (works because of the value-before-name ordering above). This is how the BPM, key index, and manual-beatgrid-correction fields below were all extracted, with no need to fully parse the format's grammar.

## The `.djayMetadata` cache (plain plist)

Unlike the SQLite blobs, these per-track files are **standard Apple binary plists** — `plutil`/`plistlib` read them directly, no custom parsing needed. Filename is `<uuid>.djayMetadata`, same UUID as in `database2`.

Top-level keys of interest:

- `deepBeatTrackerInfo` — BPM, beatgrid, tempo confidence (see below).
- `waveInfoCompact` — the low-resolution amplitude envelope (see [Waveform](#waveform--frequency-band-data)).
- `waveColorsInfo` — per-frequency-band envelope data (same section).
- `keyInfo` — `keyIndex`/`keyConfidence` (musical key; see [Open questions](#open-questions--abandoned-attempts)).
- `info` — `Name`, `Artist`, `Duration`, `source` (1 = local file, 2 = Spotify, 4 = SoundCloud, 7 = Apple Music — confirmed against 600 sampled tracks), and for streamed tracks a `persistentID` (e.g. `apple-music:library:track:i.XXXXXXXX`).

## Beatgrid & downbeat extraction

Inside `deepBeatTrackerInfo`:

- `bpm` (and `analyzedBPM`/`straightBPM`, generally identical) — the analyzed tempo.
- `compressedBeats` — every detected beat's timestamp, zlib-compressed, decompressing to an array of **big-endian** float32 (note: big-endian here, unlike everything else in this document, which is little-endian).
- `firstDownBeatIndex` — the index *into that decompressed array* of the actual first downbeat.
- `straightGrid` (bool) — whether djay is using a constant-tempo grid for this track, vs. a variable-tempo one (djay's own UI distinguishes "Straight beatgrid" and "Dynamic beatgrid" + manually-placeable "Anchor Points" for tracks with real tempo changes — see [Algoriddim's own beatgrid documentation](https://help.algoriddim.com/user-manual/djay-pro-mac/dj-tools/beatgrids-bpm-sync/beatgrids)). `compressedBPMChangeTimes`/`compressedPrevalentBPMs` exist alongside for variable-tempo tracks.
- `bpmConfidence` — djay's own confidence score for the analysis.

**Downbeat offset in seconds** = `beats[firstDownBeatIndex]` after decompressing `compressedBeats`.

**Bar/beat counting**: for a track using a straight (constant-tempo) grid, `barNumber(t) = floor((t − downbeat) / (4 × 60 / bpm)) + 1` works. For anything more precise (or a dynamic-grid track), **count real detected beats** from `compressedBeats` instead of dividing by a constant tempo — the array already reflects any true tempo variation. One caveat found in practice: djay's beat tracker doesn't emit an array entry for *every* beat if it has low confidence in a quiet/ambiguous passage, which under-counts a naive "index difference" approach — detect this by comparing each gap between consecutive beat timestamps to the track's *median* gap, and round each gap to the nearest whole number of beats it likely represents instead of always assuming exactly one.

### Manual grid corrections

If a DJ used djay's own "Edit Grid" feature, the correction is **not** in `deepBeatTrackerInfo` — it's a separate object (`ADCBeatGridEdits`, field `firstDownbeatPosition`) inside `mediaItemUserData` (the TSAF-format collection, not the plist). Extract with the field-name-search technique described above. This should take priority over the automatic analysis when present, since it's a DJ's deliberate correction (djay's automatic grid is occasionally wrong — e.g. on tracks with a rhythmically-ambiguous intro before the first clear kick).

## Cue points

`ADCCuePoint` objects live in `mediaItemUserData`'s `cuePoints` set. Each has `time`, `endTime` (float32 seconds; `endTime = -1.0` means "not a loop-like cue, just a point"), and `number` (an integer, absent/null for at least one cue in every track tested — see below).

Extraction, validated on tracks with 1 and with 7 real cue points:

1. Find the `ADCCuePoint` class marker.
2. The *first* cue point spells every field by name — read its `time` via the "4 bytes before the field-name token" technique.
3. Determine this blob's compact class-reference byte: scan forward from the class marker for the first `0x2b 0x05 <index>` immediately followed by the float tag `0x13 0x00` (this specifically identifies a cue-time back-reference, as opposed to some other field that happens to start the same way).
4. Scan the rest of the blob for that exact 3-byte pattern; each occurrence is immediately followed by another `time` value.

All decoded cue times shared the same fractional-part quantization artifact (e.g. `.00030517578125`), which is a useful sanity check that you're decoding real data and not noise.

### Custom cue colors — investigated, not solved

djay lets a DJ assign one of 8 colors per cue point (confirmed **not** a fixed order by slot — colors are freely reassignable). The default color order when inserting cues in sequence is: **red, orange, blue, yellow, green, magenta, sky blue, violet**.

A field was found that is *absent* when a cue uses its default color and *present* (extra bytes appear in the blob) when a DJ manually overrides it — confirmed by diffing a track's blob before/after recoloring a cue. In one clean test, this field's value for a manually-set **green** cue was `4`, which matches "green" being index 4 (0-based) in the default-order list above — encouraging, but:

- The same approach on a cue manually changed to **blue** did not show the expected field on a different (messier, had an unexplained duplicate/ghost cue entry) test track.
- A field named `colorIndex` also exists, but at the *track* level (inside `ADCMediaItemUserData` directly, appearing once per blob, not per cue) — likely an unrelated whole-track color tag, not per-cue color; it did not change value when a cue's color was edited.
- A recolor-to-orange test showed the field's byte layout doesn't follow the simple `[2-byte tag][4-byte payload]` pattern established for every other field in this document — value not decoded.

**Abandoned without a working decode.** If picking this back up: work on a track with *zero* prior cue points (a duplicate/ghost cue point from an earlier deleted-and-recreated cue muddied at least one test here), change exactly one cue's color at a time, and diff the *entire* binary blob before/after rather than assuming the change is confined to one already-identified field.

## Waveform & frequency-band data

`waveInfoCompact.compressedLowRateWaveSamples` — zlib-compressed, decompresses to **one unsigned byte per sample**, roughly 8–11 samples/second across the whole track (confirmed via `lowRateWaveFinalSampleRate`). This is real amplitude data (verified: values track the track's actual loudness/rhythm), and — importantly — it exists for **streamed tracks too** (Apple Music/Spotify/SoundCloud), not just local files, since it's djay's own cached analysis rather than something derived from the (DRM-protected, inaccessible) audio file itself. This is what makes structure/energy detection possible without ever touching an audio file.

`waveColorsInfo.compressedLowRateWaveColors` — zlib-compressed, 6 bytes per sample = **3 channels of 2 bytes each**, at a separate (lower, ~2 Hz observed) sample rate (`lowRateSampleRate`). Each 2-byte channel value is a **bfloat16**: the top 16 bits of an IEEE754 float32, reconstructed by zero-padding the low 2 bytes before interpreting as float32.

djay's own documentation on waveform coloring ([help.algoriddim.com — Waveforms](https://help.algoriddim.com/user-manual/djay-pro-mac/mixing-basics/waveforms)) states the full-resolution color scheme is **red = bass, yellow = low-mid, green = high-mid, blue = treble** — 4 bands. Only 3 channels were found at this *low-resolution* cache tier; channel 0 was confirmed (by its distinctive on/off, high-variance behavior matching a kick drum) to be the bass band. Channels 1/2 are presumed mid/treble by elimination, not independently confirmed. A higher-resolution tier (`waveInfoCompact`'s "normal rate", ~172 Hz, 2 bytes/sample) exists in the cache but wasn't decoded.

## Structure & energy detection

Two independent detectors, both operating purely on the cached waveform data above (no audio file needed):

**Bar-level section labeling** (intro / groove / break / drop / outro): resample the bass and total-amplitude channels onto a common bar grid (anchored to the real downbeat — an earlier version anchored bar 0 to raw sample index 0 instead, which is wrong for any track whose first downbeat isn't at exactly t=0, and produced a bar-count-off-by-N bug caught via a user report). Per bar: is total amplitude above a percentile-based "loud" threshold, and is bass amplitude above a percentile-based "kick present" threshold relative to a baseline computed from the track's own loud bars (so a long intro/outro doesn't drag the baseline down)? Leading/trailing quiet-or-loud runs become intro/outro; a sustained kick-absent-but-not-silent run becomes a break, with the bar right after becoming a drop.

**Transition detection** (arbitrary structural change points, phrase-aligned or not): a change-score signal — at each point, the relative gap between the mean of the ~20 seconds before it and the ~20 seconds after — run over the amplitude channel. Local maxima above a threshold, greedy non-max-suppression by minimum distance. **Validated against manually-placed cue points** (placed while actually listening to the track, which turned out to matter — cues placed by eye against the waveform alone, without listening, did not validate cleanly) on two tracks: 5/5 and 3/3 real structural boundaries recovered, generally within 1–2 seconds.

A second, shorter-window (~4 bars instead of 20 seconds) pass over the *spectral balance* (mid+treble share of total band energy) catches texture changes that don't move overall loudness (hats/vocals entering, a filter opening) — the 20-second window dilutes anything shorter than several bars into invisibility regardless of threshold.

Candidates are classified as phrase-grid-aligned or not (within ~3 seconds of a 16/32-beat boundary) but **not filtered by alignment** — an earlier version rejected off-grid candidates outright, which turned out to lose real transitions on some tracks (grid alignment isn't universal across all production styles/eras).

**Energy scale** (1–10, Mixed In Key-style): group bars into phrases, average `totalEnergy` and `bassEnergy` per phrase (each independently normalized 0–1 by its own track-wide range before combining, since the two are on different raw scales), rescale the whole track's per-phrase values so the 5th/95th percentile span 1–10 (a percentile stretch, not raw min/max, so one outlier bar can't compress the rest of the range).

## Reading djay's live UI (Accessibility API)

The live phrase counter (not covered in depth here — see [kyleawayan/djay-pro-bridge](https://github.com/kyleawayan/djay-pro-bridge)'s own README for the base Accessibility API technique) reads djay's UI tree directly, the same mechanism VoiceOver uses. Two practical gotchas found while building on top of it:

- **Localization**: djay's Accessibility labels are localized — a French system shows "Titre"/"Artiste"/"Clé" and "Platine N" instead of "Title"/"Artist"/"Key" and "Deck N" (but "Elapsed time"/"Remaining time"/"Play / Pause" stay in English even under French localization — inconsistent). Match both language variants rather than assuming English.
- **View-dependent visibility**: some fields (elapsed/remaining time specifically) become temporarily unavailable when djay's own UI changes panel state (e.g. expanding the library browser), even though the track is still playing normally. Treat a `nil` reading here as "temporarily unknown," not "stopped" — cache the last known value and keep extrapolating from it rather than resetting state.
- **Tempo math**: djay's displayed BPM is already pitch-adjusted (moving the pitch fader changes the displayed number) — but elapsed-time extrapolation happens in the track's own pitch-adjusted "content seconds," so recovering the *base* tempo for beat-duration math requires `displayedBPM / (1 + pitchPercent/100)`, not the displayed BPM directly (using it directly caused two synced decks at different pitch percentages to drift apart over a track).

## Open questions / abandoned attempts

- **Musical key.** `keySignatureIndex` (TSAF blob) and `keyInfo.keyIndex` (`.djayMetadata`) agree with each other, and a "0–11 major, 12–23 minor, chromatic order" hypothesis matched 2 of 4 manually-verified tracks (checked live against djay's own key display) — but was contradicted by the other 2, and no other simple mapping (e.g. circle-of-fifths) fit all 4. Abandoned; the correct table would need to be built one verified value at a time, up to 24 entries.
- **Per-cue custom colors.** See [above](#custom-cue-colors--investigated-not-solved).
- **`waveColorsInfo` channels 1/2** — presumed mid/treble, not independently confirmed against a reference.
- **Higher-resolution waveform tier** (`waveInfoCompact`'s "normal rate", ~172 Hz) — exists, not decoded; would improve structure-detection precision if decoded, since the low-resolution tier's ~2–11 Hz sampling is the limiting factor behind most of the false positives/negatives observed in transition detection.
