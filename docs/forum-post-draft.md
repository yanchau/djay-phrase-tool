# [Draft] Forum post for community.algoriddim.com

> Draft only — not yet posted. Target: the Algoriddim community forum, likely the [Suggestions](https://community.algoriddim.com/c/suggestions/16) category or as a reply/reference from the ["Can we have phrase analysis?"](https://community.algoriddim.com/t/can-we-have-phrase-analysis/23688) thread. Review before posting — this is long and detailed on purpose (the user asked for full feature explanations + step-by-step usage), trim if the forum's norms favor shorter posts.

---

**Title:** I built the phrase analysis (+ structure, energy, waveform, cue countdowns) tool this thread has been asking for since 2016 — free, open-source, read-only

Hi all,

Like a lot of people here, I've wanted phrase analysis in djay Pro for years — it's been requested [since 2016](https://community.algoriddim.com/t/can-we-have-phrase-analysis/23688) and djay has never shipped it, on any platform. rekordbox has had it for years (CDJ-only), but djay never got an equivalent.

So I built a companion app for it myself. It's free, open source, and **strictly read-only** — it never writes anything to djay's database, never touches your audio files, and never sends djay any commands. It just reads.

**A note on genre:** I mix techno, and that shaped some of the design choices below — the structure/energy detection leans on kick presence/absence as the main signal, which is a reliable marker in techno but won't generalize as cleanly to genres with sparser or less kick-driven structure (vocal-heavy house, hip-hop, etc.). The phrase counter and waveform are genre-agnostic and should work for anyone; the automatic structure labels and energy scale are the parts most likely to need retuning outside of techno/house-adjacent styles. Said so upfront so nobody's surprised.

**A moderator's note in advance:** this tool works by reading djay's own on-disk data formats (its live UI via macOS's Accessibility API, its SQLite library database, and its per-track analysis cache), none of which is documented publicly. I'm posting this because I think it's useful to the community, but I fully understand if Algoriddim/moderation would rather this kind of post not live here — happy for it to be removed if so, no hard feelings. The code and the full technical writeup live on GitHub regardless: **[link]**.

## What it does

It's a small floating panel that sits on top of djay Pro (macOS only) and shows, live, per deck:

- **Phrase counter** — which beat you're on, which bar within the phrase, which phrase number, and a countdown to the next phrase boundary (16 or 32 beats, your choice per deck). This is the core feature — everything else builds on it.
- **Automatic calibration** — [downbeat correction is a recurring ask here too](https://community.algoriddim.com/t/downbeat-adjustment-from-the-current-position/38905); for any track djay has already analyzed (which in practice is almost every track in your library, since djay analyzes in the background even before you load a track), the phrase counter starts immediately with no setup. It reads djay's own beatgrid analysis, and if you've corrected the grid yourself in djay ("Edit Grid"), that correction is read and takes priority automatically. A manual calibration shortcut (tap on the first kick) exists as a fallback for anything djay's automatic analysis gets wrong, and is remembered per track.
- **Live scrolling waveform** — a ~16-second window centered on your current position, colored by frequency band (bass/mid/treble, stacked-layer style similar to rekordbox's 3-band waveform mode, which is [also a popular open request](https://community.algoriddim.com/t/3-band-waveform-mode/42714) here that djay doesn't have). Works on streamed tracks (Apple Music/Spotify/SoundCloud) too, not just local files — it's built from djay's own cached waveform analysis, not the audio file itself, so DRM isn't a blocker.
- **Full-track structure overview** — the same 3-band coloring, zoomed out to the whole track, with a position marker — the kind of at-a-glance overview [asked for here](https://community.algoriddim.com/t/waveform-preview-in-library/27328).
- **Automatic structure detection** — intro / groove / break / drop / outro labels, detected from the kick pattern (presence/absence of bass energy) — the song breakdown [requested here](https://community.algoriddim.com/t/better-waveforms/17071). Not perfect (see Limitations below) but genuinely useful as an at-a-glance guide.
- **Energy scale (1–10)** — Mixed In Key-style, [something people have otherwise had to go outside djay for](https://community.algoriddim.com/t/mixed-in-key-djay-pro-is-it-worth-it-for-energy-tagging/40191), both a per-phrase level that moves with playback and a single whole-track score, derived from the same structure analysis.
- **Countdown to your own cue points** — [another long-requested feature](https://community.algoriddim.com/t/beat-countdown-to-next-cue-point/28162), this reads the actual cue points you've placed in djay (ground truth, not a guess), with a countdown and bar number to the next one.
- **Suggested mix-out points** — a countdown to the next detected break or the start of the outro, answering [another open request here](https://community.algoriddim.com/t/automix-ai-break-point-recognition-for-mix-out-points/42723) about djay's Automix not finding good mix-out points (this doesn't touch Automix, but gives you the same information to act on manually).
- **"Launch in sync" helper** — when one deck is paused and the other is playing, shows exactly which bar number the playing deck will be at when you should press play on the paused one, so you don't have to do the countdown math in your head.
- **Follows your Mac's language** — the panel's own text is in French or English depending on your system language. Separately, it correctly reads djay Pro's UI regardless of which language *djay itself* is set to (confirmed with djay running in French, where several of its accessibility labels are translated).

## How to use it (step by step)

1. **Requirements**: macOS, djay Pro, Xcode Command Line Tools (`xcode-select --install` in Terminal — the full Xcode app isn't required). No paid account or subscription needed for any of this.
2. **Download**: clone or download the repo: **[GitHub link]**.
3. **Grant permission**: the first time you run it, macOS will ask for Accessibility permission for your terminal app (Terminal, iTerm2, etc.) — this is what lets it read djay's UI. Grant it in System Settings → Privacy & Security → Accessibility if it doesn't prompt automatically.
4. **Open djay Pro** and load a track on at least one deck.
5. **Run it** — either:
   ```
   cd PhraseCounterApp
   swift run PhraseCounterApp
   ```
   or just double-click `Launch PhraseCounterApp.command` at the repo root (first double-click may need a right-click → Open → Open to get past a macOS security prompt, then it's a normal double-click every time after).
6. A floating panel appears above djay Pro (it has a close button in the top-right corner). For most tracks, the phrase counter starts immediately. If it says "searching djay's database…" for more than a few seconds (a brand-new track djay hasn't analyzed yet, or a very obscure edge case), tap `⌃⌥1` (deck 1) or `⌃⌥2` (deck 2) right on the first kick to calibrate manually — it'll remember this per track from then on.
7. **Resize it** by dragging any edge or corner — everything scales together, fonts included.
8. To stop: close the panel, or `Ctrl+C` in the terminal.

*Prefer not to touch Terminal at all, or got stuck above? [**GETTING-STARTED-FOR-BEGINNERS.md**](getting-started-link) walks through the same setup using Claude Code, an AI assistant that runs the commands for you — optional, and it requires a paid Claude plan or API credits, so it's offered here as an alternative, not a requirement.*

## What it doesn't do

- It cannot control djay in any way — no autoplay, no triggering cues, nothing. Purely a read-only display.
- The automatic break/drop/transition detection is a heuristic over djay's own *cached, low-resolution* waveform data (a few samples per second, not the real audio) — it's good, not perfect. Your own cue points are shown as a separate, always-accurate source of truth alongside it.
- It was built and tuned on techno, using kick presence/absence as the main structural signal. It'll likely need different thresholds (or a different signal entirely) to be reliable on genres where the kick isn't the dominant structural marker — I haven't tested it outside techno/house-adjacent styles myself, so treat the structure labels and energy scale as unverified if you're mixing something else. Reports from other genres welcome.
- Local-files-only features from the original plan (e.g. full-resolution audio analysis with librosa) turned out to be unnecessary — djay's own cached analysis was enough to make almost everything here work on streamed tracks too.

## Why I'm sharing the technical details too

The GitHub repo includes a full writeup of djay's internal data formats — the binary format used in its SQLite database, the structure of its per-track analysis cache, how the beatgrid/downbeat/cue-point/waveform data is laid out and decoded, what's confirmed vs. still a hypothesis, and a couple of things I tried and couldn't crack (musical key decoding, per-cue custom colors) in case someone else wants to pick those up. My hope is this is useful beyond just this one tool — for anyone else who wants to build something on top of djay's own data, read-only, the way this project does.

Feedback, bug reports, and pull requests all welcome. Thanks for reading!

**GitHub: [link]**
