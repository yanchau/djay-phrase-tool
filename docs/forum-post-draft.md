# [Draft] Forum post for community.algoriddim.com

> Draft only — not yet posted. Target: the Algoriddim community forum, likely the [Suggestions](https://community.algoriddim.com/c/suggestions/16) category or as a reply/reference from the ["Can we have phrase analysis?"](https://community.algoriddim.com/t/can-we-have-phrase-analysis/23688) thread. Review before posting — this is long and detailed on purpose (the user asked for full feature explanations + step-by-step usage), trim if the forum's norms favor shorter posts.

---

**Title:** I built the phrase analysis (+ structure, energy, waveform, cue countdowns) tool this thread has been asking for since 2016 — free, open-source, read-only

Hi all,

Like a lot of people here, I've wanted phrase analysis in djay Pro for years — it's been requested [since 2016](https://community.algoriddim.com/t/can-we-have-phrase-analysis/23688) and djay has never shipped it, on any platform. rekordbox has had it for years (CDJ-only), but djay never got an equivalent.

So I built a companion app for it myself. It's free, open source, and **strictly read-only** — it never writes anything to djay's database, never touches your audio files, and never sends djay any commands. It just reads.

**To be upfront: this isn't a polished commercial product.** It's a solo, spare-time project — I use it myself every time I mix and it genuinely works, but it hasn't been tested across many setups, libraries, or genres beyond mine. Expect some rough edges (see "What it doesn't do" below for the known ones), and treat it as a work in progress rather than a finished release. Bug reports are genuinely welcome, not just a formality.

**A note on genre:** I mix techno, and that shaped some of the design choices below — the structure/energy detection leans on kick presence/absence as the main signal, which is a reliable marker in techno but won't generalize as cleanly to genres with sparser or less kick-driven structure (vocal-heavy house, hip-hop, etc.). The phrase counter and waveform are genre-agnostic and should work for anyone; the automatic structure labels and energy scale are the parts most likely to need retuning outside of techno/house-adjacent styles. Said so upfront so nobody's surprised.

**A moderator's note in advance:** this tool works by reading djay's own on-disk data formats (its live UI via macOS's Accessibility API, its SQLite library database, and its per-track analysis cache), none of which is documented publicly. I'm posting this because I think it's useful to the community, but I fully understand if Algoriddim/moderation would rather this kind of post not live here — happy for it to be removed if so, no hard feelings. The code and the full technical writeup live on GitHub regardless: **https://github.com/yanchau/djay-phrase-tool**.

*Screenshot: [`docs/images/screenshot.png`](../docs/images/screenshot.png) in the repo — drag it directly into the forum's post editor when actually posting (Discourse uploads it and inserts the image for you; a relative repo link like this won't render on the forum itself). Shown in French there since the panel follows your Mac's system language automatically — it'll show in English if your Mac is set to English, no setting to change.*

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

## How to use it

**Option A — Doing it yourself in Terminal (~2 minutes, free, no account needed)**

Nothing assumed here either — every click and every thing to copy is spelled out:

1. **Download the project.** On the [GitHub page](https://github.com/yanchau/djay-phrase-tool), click the green **Code** button near the top, then **Download ZIP**. Once downloaded (usually lands in your Downloads folder), double-click the ZIP file to unzip it — you'll get a folder called `djay-phrase-tool-main`.

2. **Open Terminal.**
   - Press `Cmd` and the `Space` bar at the same time
   - A search box pops up in the middle of the screen — type `Terminal`
   - Press `Enter`
   - A window opens with a plain black or white background and some text — that's it, that's Terminal.

3. **Install the Xcode Command Line Tools** (skip this step if you've already installed them before, for this or any other project):
   - Select this whole line of text (click right before `xcode-select`, hold, drag to the end) and copy it: `Cmd + C`
     ```
     xcode-select --install
     ```
   - Click once inside the Terminal window
   - Paste: `Cmd + V`
   - Press `Enter`
   - A macOS installer window pops up (separate from Terminal) — click **Install**, accept the license, wait for it to finish (a few minutes). This only downloads Apple's own developer tools, nothing from this project.

4. **Grant Accessibility permission.** Click the Apple menu (top-left corner of the screen) → System Settings → Privacy & Security → Accessibility, and turn on the toggle for Terminal (this is what lets the app read djay's on-screen info — it may also prompt you for this automatically the first time you run the app in step 6, in which case just click **Open System Settings** in that prompt instead of navigating there yourself).

5. **Open djay Pro** and load a track on at least one deck.

6. **Go into the downloaded folder and run the app.** Back in the Terminal window:
   - Type `cd ` (the letters c and d, then one space — don't press Enter yet)
   - Open Finder, find the `djay-phrase-tool-main` folder from step 1, then find the `PhraseCounterApp` folder inside it, and drag that `PhraseCounterApp` folder icon straight into the Terminal window — its path appears after `cd ` automatically
   - Press `Enter`
   - Select this line, copy it (`Cmd + C`):
     ```
     swift run PhraseCounterApp
     ```
   - Click inside the Terminal window, paste (`Cmd + V`), press `Enter`
   - The first run takes a minute or two (it's compiling) — you'll see text scrolling, that's normal. Later runs are instant.

   *(Prefer not to type any of this? After step 5, in Finder, just double-click `Launch PhraseCounterApp.command` at the top level of the `djay-phrase-tool-main` folder instead — first double-click needs a right-click → Open → Open to get past a macOS security prompt, then it's a normal double-click every time after, no Terminal typing at all.)*

7. A floating panel appears above djay Pro (it has a close button in the top-right corner). For most tracks, the phrase counter starts immediately. If it says "searching djay's database…" for more than a few seconds (a brand-new track djay hasn't analyzed yet, or a very obscure edge case), tap `⌃⌥1` (deck 1) or `⌃⌥2` (deck 2) right on the first kick to calibrate manually — it'll remember this per track from then on.
8. **Resize it** by dragging any edge or corner — everything scales together, fonts included.
9. To stop: close the panel, or click back in the Terminal window and press `Ctrl + C`.

**Option B — Never used Terminal or written code before? Let an AI assistant set it up for you**

This is genuinely how the tool itself was built — the author doesn't code either. Needs a paid Claude plan or API credits (Claude Code isn't free), but zero coding knowledge. Every step below is spelled out — nothing assumed:

1. **Download the project.** On the [GitHub page](https://github.com/yanchau/djay-phrase-tool), click the green **Code** button near the top, then **Download ZIP**. Once downloaded (usually lands in your Downloads folder), double-click the ZIP file to unzip it — you'll get a folder called `djay-phrase-tool-main`. Inside, you'll see some files ending in `.md` (like `README.md`) — don't double-click those. Double-clicking opens them as plain text with stray `#` and `*` symbols everywhere, which looks broken. They're meant to be read on GitHub instead, where the same files display as normal formatted text with headings and bold — like the [GitHub page](https://github.com/yanchau/djay-phrase-tool) itself, or the beginner guide linked at the end of this section.

2. **Open Terminal.** This is a different app from anything you've probably used before, and that's fine — you'll only type into it, nothing complicated:
   - Press `Cmd` and the `Space` bar at the same time
   - A search box pops up in the middle of the screen — type `Terminal`
   - Press `Enter`
   - A window opens with a plain black or white background and some text — that's it, that's Terminal, working as intended.

3. **Install Claude Code.** This is the one thing you're installing. In the Terminal window:
   - Select this whole line of text (click right before `npm`, hold, drag to the end) and copy it: `Cmd + C`
     ```
     npm install -g @anthropic-ai/claude-code
     ```
   - Click once inside the Terminal window (to make sure it's the active window)
   - Paste: `Cmd + V`
   - Press `Enter`
   - Wait a few seconds until you see the cursor again (a blinking `%` or `$`). If instead you see `command not found: npm`, go install Node.js from [nodejs.org](https://nodejs.org) (the "LTS" button) first, then repeat this step.

4. **Go into the downloaded folder and start Claude Code.** Still in the same Terminal window:
   - Type `cd ` (that's the two letters c and d, then one space — don't press Enter yet)
   - Open Finder, find the `djay-phrase-tool-main` folder from step 1, and drag that folder icon straight into the Terminal window — its full path appears after `cd ` automatically
   - Press `Enter`
   - Type `claude` and press `Enter`
   - The first time only, it'll ask you to pick a color theme (any is fine, press `Enter`) and to log in with your Anthropic account — follow what's on screen.

5. **Ask it to do the rest.** Once you see a `>` waiting for input, type this (or just say it in your own words, any language):
   ```
   Please set this up and run it for me. I've never used a terminal before,
   so explain each step simply and ask before doing anything that needs my
   permission.
   ```
   Press `Enter`. It'll read the project's README, install anything still missing, walk you through granting the one macOS permission it needs (Accessibility — explained in the README's Safety section), and start the app — asking your approval first, in plain language, before anything that changes your Mac.

Full version of this path with troubleshooting: [`GETTING-STARTED-FOR-BEGINNERS.md`](https://github.com/yanchau/djay-phrase-tool/blob/main/docs/GETTING-STARTED-FOR-BEGINNERS.md) — just click, it opens straight in your browser, nicely formatted, nothing to download first.

**Option C — Prebuilt app, no Terminal at all**

Someone asked (fair question) why I don't just ship a signed binary instead of asking people to compile. Short answer: no Apple Developer ID behind this project, so I can't sign/notarize it — "unsigned binary" and "compile from source" both need a one-time Gatekeeper workaround either way, but only the source path lets you read the code before it runs, which matters more than usual for something with Accessibility + database read access. So source-compile stays the default above. That said, if you just want to try it with the least friction:

1. Go to the [Releases page](https://github.com/yanchau/djay-phrase-tool/releases/latest) and download `PhraseCounterApp-macOS.zip` under **Assets**.
2. Double-click the zip to unzip it — you get `PhraseCounterApp.app`.
3. Move it wherever you like (e.g. Applications), then **right-click it → Open → Open** (needed once, since it's unsigned — a normal double-click will refuse to launch it the first time).
4. Grant Accessibility permission when macOS asks (System Settings → Privacy & Security → Accessibility → enable **PhraseCounterApp**).
5. Open djay Pro, load a track — same behavior as above from here.

## What it doesn't do

- It cannot control djay in any way — no autoplay, no triggering cues, nothing. Purely a read-only display.
- The automatic break/drop/transition detection is a heuristic over djay's own *cached, low-resolution* waveform data (a few samples per second, not the real audio) — it's good, not perfect. Your own cue points are shown as a separate, always-accurate source of truth alongside it.
- It was built and tuned on techno, using kick presence/absence as the main structural signal. It'll likely need different thresholds (or a different signal entirely) to be reliable on genres where the kick isn't the dominant structural marker — I haven't tested it outside techno/house-adjacent styles myself, so treat the structure labels and energy scale as unverified if you're mixing something else. Reports from other genres welcome.
- Local-files-only features from the original plan (e.g. full-resolution audio analysis with librosa) turned out to be unnecessary — djay's own cached analysis was enough to make almost everything here work on streamed tracks too.

## Why I'm sharing the technical details too

The GitHub repo includes a full writeup of djay's internal data formats — the binary format used in its SQLite database, the structure of its per-track analysis cache, how the beatgrid/downbeat/cue-point/waveform data is laid out and decoded, what's confirmed vs. still a hypothesis, and a couple of things I tried and couldn't crack (musical key decoding, per-cue custom colors) in case someone else wants to pick those up. My hope is this is useful beyond just this one tool — for anyone else who wants to build something on top of djay's own data, read-only, the way this project does.

Feedback, bug reports, and pull requests all welcome. Thanks for reading!

**GitHub: https://github.com/yanchau/djay-phrase-tool**
