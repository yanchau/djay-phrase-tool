# djay-phrase-tool

A read-only companion tool for [Algoriddim djay Pro](https://www.algoriddim.com/djay-pro-mac) on macOS that adds **live phrase analysis** — a feature DJs have been [asking for since 2016](https://community.algoriddim.com/t/can-we-have-phrase-analysis/23688) and djay has never shipped.

**Just want to install and run it? → Jump to [Setup](#setup).**

It shows, per deck, in real time: which beat/bar/phrase you're in, a countdown to the next phrase boundary, a live scrolling waveform, detected track structure (intro/groove/break/drop/outro), a Mixed In Key-style energy scale, and countdowns to your own cue points and to detected mix-out points — all without ever writing to djay's database or touching your audio files.

It's built from three layers, each usable independently:

1. **Live phrase counter** — reads djay Pro's UI in real time via the macOS Accessibility API and computes phrase position from it.
2. **Library reader** — reads djay's own analysis cache (BPM, beatgrid, cue points, waveform) directly, so the phrase counter needs zero manual calibration for any track djay has already analyzed.
3. **Structure & energy detection** — turns djay's cached waveform data into intro/build/drop/break/outro labels and an energy curve, entirely from data djay already computed (no audio file access needed — this works on streamed Apple Music/Spotify/SoundCloud tracks too, not just local files).

## Why this exists

djay Pro doesn't expose a phrase/structure view anywhere in its UI, on any platform, despite rekordbox (Pioneer) having shipped one for years. This project reverse-engineers djay's own on-disk data — its live accessibility tree, its SQLite library database, and its per-track analysis cache — to build the feature externally, without modifying djay or its data in any way.

Read [`docs/TECHNICAL.md`](docs/TECHNICAL.md) for the full reverse-engineering writeup: the binary formats, the extraction techniques, what's confirmed vs. still a hypothesis, and what didn't work.

## Screenshot

*(A floating HUD panel — one block per deck: phrase number in large type, bar/beat position, countdown to the next phrase boundary, a live scrolling waveform colored by frequency band, a full-track structure overview, an energy scale, and countdowns to the next detected structural change, your own cue points, and suggested mix-out points.)*

## Safety

**Strictly read-only.** This tool never writes to djay's database, never modifies your audio files, and never sends djay any commands. It only *reads*:

- djay Pro's live accessibility tree (the same UI text macOS's Accessibility Inspector or VoiceOver can already read from any app)
- djay's own SQLite library database, in read-only mode, while djay is running (SQLite's WAL mode is designed for exactly this and was verified safe empirically)
- djay's per-track `.djayMetadata` analysis cache files

If you're uneasy about the SQLite access specifically, quit djay Pro first — reading the database only requires djay to have analyzed a track at some point in the past, not to be running right now (with the one exception that the *live* phrase counter needs djay open, since it reads the UI).

## Project layout

```
PhraseCounterApp/       Swift package — the live HUD app (built on a fork of
                         kyleawayan/djay-pro-bridge, see Credits)
analysis-scripts/       Python reference implementations for the structure/
                         energy detection, and the original binary-format
                         exploration scripts
docs/TECHNICAL.md        Full technical writeup — binary formats, extraction
                         methodology, validation, open questions
```

## Setup

Requires macOS with Xcode Command Line Tools — a full Xcode install is not needed to build and run the app, only to run its test suite. No paid account or subscription of any kind is needed for the steps below.

1. **Open Terminal**: press `Cmd + Space`, type `Terminal`, press `Enter`. A plain window with text will open — this is normal.
2. **Install the Xcode Command Line Tools** (skip if you've already installed them before): copy the line below (select it, `Cmd+C`), click inside the Terminal window, paste it (`Cmd+V`), then press `Enter`:
   ```bash
   xcode-select --install
   ```
   A macOS installer window will pop up — click through its prompts to install. This only downloads Apple's own command-line developer tools, nothing from this project.
3. Grant Accessibility permission to whatever terminal app you'll run this from (System Settings → Privacy & Security → Accessibility).
4. Open djay Pro and load a track on at least one deck.
5. Build and run — either:
   - copy, paste (`Cmd+V`), and run these two lines in Terminal, one at a time (press `Enter` after each):
     ```bash
     cd PhraseCounterApp
     ```
     ```bash
     swift run PhraseCounterApp
     ```
   - or, simpler: just double-click **`Launch PhraseCounterApp.command`** at the repo root — no copying or typing at all (first double-click may show a macOS security prompt — right-click it → Open → Open once instead, then double-click works normally after that).
6. A floating panel appears, staying above djay Pro. For a track djay has already analyzed, the phrase counter starts automatically — no calibration needed. For a track djay hasn't analyzed yet (or if its automatic beatgrid is wrong), press `⌃⌥1` (deck 1) or `⌃⌥2` (deck 2) on the first kick to calibrate manually; djay Pro's own "Edit Grid" corrections are also read and take priority automatically when present.

The panel is resizable (drag any edge/corner, everything in it scales together) and has a close button (×) in its top-right corner. Its text follows your Mac's system language — French if your system is set to French, English otherwise (this is about the panel's *own* text; djay Pro's UI itself can be in whatever language you already have it in, read separately — see [`docs/TECHNICAL.md`](docs/TECHNICAL.md#reading-djays-live-ui-accessibility-api)).

**Prefer not to touch Terminal at all, or got stuck above?** [`docs/GETTING-STARTED-FOR-BEGINNERS.md`](docs/GETTING-STARTED-FOR-BEGINNERS.md) walks through the same setup using Claude Code, an AI assistant that runs the commands for you and explains each step — optional, and it requires a paid Claude plan or API credits, so it's offered as an alternative here, not a requirement.

## What's read-only vs. what's stored locally

The *only* thing this tool ever writes is your own manual calibrations (if you use `⌃⌥1`/`⌃⌥2`), saved to `~/djay-phrase-tool/data/downbeat-offsets.json` — never inside djay's own data. Nothing about your library ever leaves your machine.

## Known limitations

- djay's Accessibility tree is view-dependent — some fields (elapsed/remaining time in particular) briefly become unavailable when djay's own UI changes panels (e.g. expanding the library browser). The app caches the last known value to ride out most of these, but loading a *brand new* track while the library panel is already expanded has no prior value to fall back on; collapsing and re-expanding the library panel once resolves it.
- djay only exposes BPM to one decimal place in its UI, which limits the precision of anything derived from the *live* BPM reading over long time spans (this is why a "continuous phase offset between two synced decks" feature was tried and removed — it would have shown drift that doesn't actually exist in djay's own audio engine, which stays phase-locked internally at full precision).
- The automatic structure/transition detection (break/drop/intro/outro boundaries) is a heuristic over djay's own *cached, low-resolution* waveform (~2–11 samples/second, not the real audio) — validated to high precision on some tracks, with real false positives/negatives on others. Your own cue points (read directly, ground truth) are shown alongside it, not as a replacement.
- Two things were investigated and explicitly abandoned after real effort — documented in `docs/TECHNICAL.md` in case someone wants to pick them back up: decoding the musical key from djay's analysis blob (found a plausible field, couldn't find a consistent mapping across test tracks), and decoding per-cue-point custom colors (found the field that appears/disappears with custom colors, couldn't decode its value format).

## Credits

- Built on top of [kyleawayan/djay-pro-bridge](https://github.com/kyleawayan/djay-pro-bridge) (MIT), which did the original Accessibility API groundwork for reading djay Pro's live deck state.
- The competitive-research section of `docs/TECHNICAL.md` also references [parabolala/djtools](https://github.com/parabolala/djtools) and [xsaardo/Djay-Pro-2-Export-Tools](https://github.com/xsaardo/Djay-Pro-2-Export-Tools), earlier projects that explored djay Pro 2's older database format.

## License

MIT — see [`PhraseCounterApp/LICENSE`](PhraseCounterApp/LICENSE).
