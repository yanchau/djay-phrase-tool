#!/usr/bin/env python3
"""Volet 3 — énergie et structure par le kick, pour fichiers locaux.

Découpe le morceau en mesures (4 temps) alignées sur le beatgrid du
Volet 2 (BPM + premier downbeat lus depuis la base djay), calcule par
mesure : énergie basse (40-100 Hz, le kick), énergie totale, centre de
gravité spectral (brightness/densité), densité d'onsets. Agrège en
phrases (16 ou 32 temps) pour une courbe d'énergie 1-10, puis applique
les règles de CLAUDE.md (Extension 2) pour étiqueter intro/build-up/
drop/break/outro/groove.

Lecture seule sur le fichier audio et sur la base djay (copie ou originale
en lecture seule via SQLite — jamais d'écriture).
"""
import argparse
import json
import sys

import librosa
import numpy as np

BASS_LOW_HZ = 40
BASS_HIGH_HZ = 100
N_FFT = 4096
HOP_LENGTH = 1024


def compute_frame_features(path):
    y, sr = librosa.load(path, sr=44100, mono=True)
    duration = len(y) / sr

    S = np.abs(librosa.stft(y, n_fft=N_FFT, hop_length=HOP_LENGTH))
    freqs = librosa.fft_frequencies(sr=sr, n_fft=N_FFT)
    frame_times = librosa.frames_to_time(np.arange(S.shape[1]), sr=sr, hop_length=HOP_LENGTH)

    bass_mask = (freqs >= BASS_LOW_HZ) & (freqs <= BASS_HIGH_HZ)
    bass_energy = S[bass_mask, :].sum(axis=0)
    total_energy = S.sum(axis=0)
    centroid = librosa.feature.spectral_centroid(S=S, sr=sr)[0]
    onset_env = librosa.onset.onset_strength(y=y, sr=sr, hop_length=HOP_LENGTH)
    # onset_env has its own frame count (same hop_length, but librosa may pad
    # differently) — resample onto frame_times by nearest index.
    onset_frame_times = librosa.frames_to_time(np.arange(len(onset_env)), sr=sr, hop_length=HOP_LENGTH)

    return {
        "duration": duration,
        "frame_times": frame_times,
        "bass_energy": bass_energy,
        "total_energy": total_energy,
        "centroid": centroid,
        "onset_env": onset_env,
        "onset_frame_times": onset_frame_times,
    }


def bars_from_beatgrid(features, bpm, downbeat, duration):
    beat_duration = 60.0 / bpm
    bar_duration = beat_duration * 4
    frame_times = features["frame_times"]
    n_bars = max(0, int((duration - downbeat) // bar_duration))

    bars = []
    for i in range(n_bars):
        t0 = downbeat + i * bar_duration
        t1 = t0 + bar_duration
        idx = (frame_times >= t0) & (frame_times < t1)
        if not idx.any():
            continue
        onset_idx = (features["onset_frame_times"] >= t0) & (features["onset_frame_times"] < t1)
        bars.append({
            "bar": i,
            "t0": float(t0),
            "t1": float(t1),
            "bass_energy": float(features["bass_energy"][idx].mean()),
            "total_energy": float(features["total_energy"][idx].mean()),
            "centroid": float(features["centroid"][idx].mean()),
            "onset_density": float(features["onset_env"][onset_idx].mean()) if onset_idx.any() else 0.0,
        })
    return bars, bar_duration


def label_structure(bars):
    """Extension 2 rules from CLAUDE.md, applied to the per-bar feature series."""
    if not bars:
        return bars

    bass_vals = np.array([b["bass_energy"] for b in bars])
    total_vals = np.array([b["total_energy"] for b in bars])
    centroid_vals = np.array([b["centroid"] for b in bars])

    # Baseline = median bass energy across bars that aren't near-silent overall,
    # so a quiet intro/outro doesn't drag the baseline down and hide breaks.
    loud_enough = total_vals > np.percentile(total_vals, 20)
    baseline_bass = np.median(bass_vals[loud_enough]) if loud_enough.any() else np.median(bass_vals)
    kick_present = bass_vals > 0.35 * baseline_bass

    n = len(bars)

    # --- Intro: leading bars before the first big density jump ---
    total_smoothed = np.convolve(total_vals, np.ones(4) / 4, mode="same")
    intro_end = 0
    track_ramp_level = np.percentile(total_vals, 60)
    for i in range(1, n):
        if total_smoothed[i] > track_ramp_level and kick_present[i]:
            intro_end = i
            break
    else:
        intro_end = min(8, n)

    # --- Outro: trailing bars, symmetric logic from the end ---
    outro_start = n
    for i in range(n - 1, intro_end, -1):
        if total_smoothed[i] > track_ramp_level and kick_present[i]:
            outro_start = i + 1
            break

    labels = [None] * n
    for i in range(intro_end):
        labels[i] = "intro"
    for i in range(outro_start, n):
        labels[i] = "outro"

    # --- Breaks: contiguous kick-absent runs (>=2 bars) in the middle section,
    # with total energy still above near-silence (something else is playing) ---
    i = intro_end
    near_silence = np.percentile(total_vals, 10)
    while i < outro_start:
        if labels[i] is None and not kick_present[i] and total_vals[i] > near_silence:
            j = i
            while j < outro_start and not kick_present[j] and total_vals[j] > near_silence:
                j += 1
            run_len = j - i
            if run_len >= 2:
                # Rising centroid/energy across the run -> build-up; flat/falling -> break.
                if run_len >= 2 and centroid_vals[j - 1] > centroid_vals[i] * 1.15 and total_vals[j - 1] > total_vals[i] * 1.1:
                    for k in range(i, j):
                        labels[k] = "build-up"
                else:
                    for k in range(i, j):
                        labels[k] = "break"
                # Bar right after a break/build-up, kick back: drop.
                if j < outro_start and kick_present[j]:
                    labels[j] = "drop"
            i = j + 1
        else:
            i += 1

    for i in range(n):
        if labels[i] is None:
            labels[i] = "groove"

    for bar, label, kp in zip(bars, labels, kick_present):
        bar["section"] = label
        bar["kick_present"] = bool(kp)

    return bars


def energy_curve(bars, beats_per_phrase, bar_duration):
    bars_per_phrase = beats_per_phrase // 4
    phrases = []
    for i in range(0, len(bars), bars_per_phrase):
        chunk = bars[i:i + bars_per_phrase]
        if not chunk:
            continue
        phrases.append({
            "phrase": i // bars_per_phrase + 1,
            "t0": chunk[0]["t0"],
            "total_energy": float(np.mean([b["total_energy"] for b in chunk])),
            "sections": sorted(set(b["section"] for b in chunk)),
        })

    all_energy = np.array([p["total_energy"] for p in phrases])
    lo, hi = np.percentile(all_energy, 5), np.percentile(all_energy, 95)
    for p in phrases:
        scaled = 1 + 9 * (p["total_energy"] - lo) / max(hi - lo, 1e-9)
        p["energy_1_10"] = int(round(min(10, max(1, scaled))))

    return phrases


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audio_path")
    parser.add_argument("--bpm", type=float, required=True)
    parser.add_argument("--downbeat", type=float, required=True)
    parser.add_argument("--beats-per-phrase", type=int, default=32)
    parser.add_argument("--out", default=None, help="write JSON report to this path")
    args = parser.parse_args()

    print(f"Chargement et analyse spectrale de {args.audio_path}...", file=sys.stderr)
    features = compute_frame_features(args.audio_path)
    bars, bar_duration = bars_from_beatgrid(features, args.bpm, args.downbeat, features["duration"])
    bars = label_structure(bars)
    phrases = energy_curve(bars, args.beats_per_phrase, bar_duration)

    print(f"\n{len(bars)} mesures analysées, durée {features['duration']:.1f}s, BPM {args.bpm}\n")
    print("Timeline par phrase :")
    for p in phrases:
        bar_chart = "#" * p["energy_1_10"]
        t0 = p["t0"]
        mins, secs = int(t0 // 60), int(t0 % 60)
        print(f"  Phrase {p['phrase']:3d} [{mins:02d}:{secs:02d}] energie={p['energy_1_10']:2d} {bar_chart:<10s} {'/'.join(p['sections'])}")

    if args.out:
        report = {
            "audio_path": args.audio_path,
            "bpm": args.bpm,
            "downbeat": args.downbeat,
            "duration": features["duration"],
            "bars": bars,
            "phrases": phrases,
        }
        with open(args.out, "w") as f:
            json.dump(report, f, indent=2)
        print(f"\nRapport JSON écrit dans {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
