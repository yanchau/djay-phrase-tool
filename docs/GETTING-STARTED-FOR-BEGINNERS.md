# Never used Terminal before? Start here.

This guide is for DJs who want to run this tool but have never opened a terminal or written code. You won't need to — an AI coding assistant called **Claude Code** will do the technical steps for you, live, on your own Mac. This is exactly how this tool itself was built: the author doesn't code either.

**Important — this only works if Claude can actually run commands on your Mac.** Pasting or uploading this project's files into a normal chat conversation (claude.ai in your browser, the Claude phone app, ChatGPT, etc.) will **not** work — those can read and comment on code, but they can't build the app, grant permissions, or start it running on your machine. You specifically need **Claude Code**, set up as described below, which runs *in your Terminal* with the ability to act on your computer.

You will need an Anthropic account (the company that makes Claude) with either a paid Claude plan or API credits — Claude Code is not free to use.

## Step 1 — Download this project

On this GitHub page, click the green **Code** button near the top, then **Download ZIP**. Once it's downloaded, double-click the ZIP file to unzip it — you'll get a folder named something like `djay-phrase-tool-main`. Move that folder somewhere you'll remember, e.g. directly in your home folder.

*(If you're comfortable with git, `git clone` works too — the AI can also do this step for you if you ask it to, once you've completed Step 2 and Step 3 below from any folder.)*

## Step 2 — Open Terminal

- Press `Cmd + Space` to open Spotlight
- Type `Terminal`
- Press `Enter`

A plain window with text will open. This is normal — this is where you'll type a couple of short commands, and where Claude will later work for you.

## Step 3 — Install Claude Code

Copy this line, paste it into the Terminal window (Cmd+V), and press Enter:

```
npm install -g @anthropic-ai/claude-code
```

If you get a message saying `npm: command not found`, you need Node.js first — download and install it from [nodejs.org](https://nodejs.org) (the "LTS" version), then try the command above again.

Once it finishes (a few seconds), check it worked:

```
claude --version
```

You should see a version number printed back.

## Step 4 — Point Claude at the downloaded folder

Still in Terminal, navigate into the folder you downloaded in Step 1. If you moved it to your home folder and it's named `djay-phrase-tool-main`, that's:

```
cd ~/djay-phrase-tool-main
```

(Tip: typing `cd ` — with a space after it — and then dragging the folder from Finder straight into the Terminal window also works, and avoids typos.)

Then start Claude Code in that folder:

```
claude
```

The first time you run it, it'll ask you to pick a color theme and log in with your Anthropic account — follow the on-screen prompts.

## Step 5 — Ask it to set everything up

Once you see a prompt (a `>` you can type into), just ask in plain English (or French, or whatever you're comfortable with):

```
Please set this up and run it for me. I've never used a terminal before,
so explain each step simply and ask before doing anything that needs my
permission.
```

Claude Code will read this project's `README.md` and figure out the rest: installing the Xcode Command Line Tools if needed, building the app, and walking you through granting the one macOS permission it needs (Accessibility, so it can read djay Pro's screen — see the **Safety** section in the main [README](../README.md) for exactly why and what that does and doesn't allow).

**It will ask your permission before doing anything that changes your system** (installing software, granting permissions) — that's normal and by design, just read each prompt and approve the ones that make sense.

## Step 6 — Use it

Once it's running, open djay Pro, load a track, and the floating panel described in the main README should appear. Ask Claude Code directly in that same Terminal window if anything looks wrong or doesn't start — it can see any error messages and fix most setup issues itself.

## Later, to run it again

You won't need to repeat all these steps every time. Simplest option: in the project folder, double-click **`Launch PhraseCounterApp.command`** — no Terminal, no Claude Code needed once everything's set up (first double-click may show a macOS security prompt — right-click it → Open → Open once instead, then double-click works normally after that).

If you'd rather go through Claude Code again (e.g. something's not working and you want it to help):

1. Open Terminal (`Cmd+Space`, type `Terminal`, `Enter`)
2. `cd ~/djay-phrase-tool-main` (or wherever you put the folder)
3. `claude`
4. Ask it to run the app again

## A note on genre

This tool was built and tuned for techno. The phrase counter and live waveform work for any genre, but the automatic structure/energy detection leans on kick presence as its main signal — see the **Known limitations** section in the main README before relying on it outside techno/house-adjacent styles.
