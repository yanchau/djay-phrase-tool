#!/bin/bash
# Double-click launcher for PhraseCounterApp.
#
# Why this exists: `swift run` needs to be run from inside the
# PhraseCounterApp/ package directory, in a terminal — not something a
# non-technical user should have to type by hand every time. Double-clicking
# this file (or right-click → Open, the first time — see below) does that
# for you.
#
# First-run note (macOS Gatekeeper): if double-clicking does nothing or
# shows a security warning, right-click this file → Open → Open, once.
# After that first approval, double-click works normally.
set -e
cd "$(dirname "$0")/PhraseCounterApp"

echo "djay-phrase-tool — PhraseCounterApp"
echo "===================================="
echo
echo "Make sure djay Pro is already open with a track loaded before continuing."
echo "(First launch compiles the app and can take a minute or two.)"
echo

swift run PhraseCounterApp
