#!/usr/bin/env python3
"""Volet 3 Extension 2 — détection de structure par le kick, via le canal
basse fréquence de waveColorsInfo (pas besoin de fichier audio).

djay colore sa waveform par bande de fréquence (confirmé par la doc
officielle Algoriddim : rouge=basses, jaune=bas-médiums, vert=haut-médiums,
bleu=aigus — help.algoriddim.com/user-manual/djay-pro-mac/mixing-basics/
waveforms). Le cache `.djayMetadata` stocke une version basse résolution
de ces couleurs (`waveColorsInfo.compressedLowRateWaveColors`, zlib, 6
octets/échantillon = 3 canaux de 2 octets chacun).

Format des 2 octets par canal, découvert le 2026-07-20 : ce sont les 2
octets de poids fort d'un float32 (technique "bfloat16" — tronquer un
float32 à ses 16 bits hauts ; on reconstruit en complétant avec 2 octets
à zéro). Confirmé par le motif observé : les octets pairs (0,2,4) restent
dans une plage étroite (~56-65, cohérent avec l'octet d'exposant d'un
float32 dans la plage "petites valeurs positives"), les octets impairs
(1,3,5) varient sur toute la plage 0-255 (mantisse).

Le premier des 3 canaux (`ch0`, octets 0-1) a un comportement nettement
plus "tout ou rien" que les deux autres — cohérent avec une bande basse/
kick, typiquement présente ou absente en musique électronique plutôt que
graduelle comme les médiums/aigus. Validé visuellement sur "House Of
House" (Apple Music) : montée d'intro, plateau, vrai passage quasi
silencieux (break) au bon endroit, reprise nette (drop), tout aligné
avec les cue points posés manuellement par l'utilisateur.

Cette découverte n'a PAS encore de validation croisée aussi rigoureuse
que le chemin amplitude (Volet 3, `analyze_waveform.py`) — traiter les
labels BREAK/DROP produits ici comme une hypothèse forte, pas un fait
établi, tant qu'on n'a pas comparé à d'autres tracks connues.
"""
import argparse
import glob
import struct
import sys
import zlib

import numpy as np

sys.path.insert(0, ".")
from analyze_waveform import (  # noqa: E402
    DEFAULT_METADATA_DIR,
    beatgrid,
    find_uuid,
    load_metadata,
)

KICK_PRESENT_RATIO = 0.4  # bass channel must be above this fraction of the
                           # track's "loud" baseline to count as kick-present
MIN_SECTION_BARS = 2      # a break/build-up must last at least this many bars


def bass_channel(metadata):
    """Returns (ch0, sample_rate) — the bass-band proxy channel."""
    wci = metadata["waveColorsInfo"]
    raw = zlib.decompress(wci["compressedLowRateWaveColors"])
    arr = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 6)
    padded = np.zeros((len(arr), 4), dtype=np.uint8)
    padded[:, 0] = arr[:, 0]
    padded[:, 1] = arr[:, 1]
    ch0 = padded.view(">f4").flatten()
    return ch0, wci["lowRateSampleRate"]


def total_energy_channel(metadata):
    """Broadband amplitude envelope, for telling 'break' (something else
    still playing) apart from 'track literally silent' (intro/outro)."""
    wic = metadata["waveInfoCompact"]
    raw = zlib.decompress(wic["compressedLowRateWaveSamples"])
    return np.frombuffer(raw, dtype=np.uint8).astype(float), wic["lowRateWaveFinalSampleRate"]


def resample_to(values, src_rate, dst_rate, dst_len):
    src_times = np.arange(len(values)) / src_rate
    dst_times = np.arange(dst_len) / dst_rate
    return np.interp(dst_times, src_times, values)


def label_structure(bass, total, sample_rate, bpm, downbeat, beats_per_phrase=32):
    n = len(bass)
    bar_duration = 4 * 60.0 / bpm
    bar_samples = max(1, int(round(bar_duration * sample_rate)))
    # Bar 0 must start at the real first downbeat, not at raw sample 0 —
    # otherwise every bar timestamp (and everything derived from it: section
    # labels, energy-per-phrase grouping) is off by `downbeat` seconds from
    # the true beatgrid. Bug found 2026-07-20 via a user report of the
    # energy scale lagging a real kick by ~5 beats on a real test track; fixed
    # here and in the Swift port (DjayBridge/DjayLibraryLookup.swift).
    start_idx = max(0, min(n, int(round(downbeat * sample_rate))))

    # Baseline = median bass level among bars that are clearly "loud"
    # overall, so a long intro/outro doesn't drag the baseline down.
    loud_mask = total > np.percentile(total, 50)
    baseline_bass = np.median(bass[loud_mask]) if loud_mask.any() else np.median(bass)
    kick_present = bass > KICK_PRESENT_RATIO * baseline_bass

    near_silence_total = np.percentile(total, 15)

    bars = []
    n_bars = (n - start_idx) // bar_samples
    for i in range(n_bars):
        sl = slice(start_idx + i * bar_samples, start_idx + (i + 1) * bar_samples)
        bars.append({
            "bar": i,
            "t0": downbeat + i * bar_duration,
            "bass": float(bass[sl].mean()),
            "total": float(total[sl].mean()),
            "kick_present": bool(kick_present[sl].mean() > 0.5),
        })

    # Intro / outro: leading/trailing bars below the loud threshold.
    loud_level = np.percentile([b["total"] for b in bars], 55)
    intro_end = 0
    for i, b in enumerate(bars):
        if b["total"] > loud_level and b["kick_present"]:
            intro_end = i
            break
    else:
        intro_end = min(4, len(bars))

    outro_start = len(bars)
    for i in range(len(bars) - 1, intro_end, -1):
        if bars[i]["total"] > loud_level and bars[i]["kick_present"]:
            outro_start = i + 1
            break

    for i in range(intro_end):
        bars[i]["section"] = "intro"
    for i in range(outro_start, len(bars)):
        bars[i]["section"] = "outro"

    i = intro_end
    while i < outro_start:
        if "section" in bars[i]:
            i += 1
            continue
        if not bars[i]["kick_present"] and bars[i]["total"] > near_silence_total:
            j = i
            while j < outro_start and not bars[j]["kick_present"] and bars[j]["total"] > near_silence_total:
                j += 1
            if j - i >= MIN_SECTION_BARS:
                for k in range(i, j):
                    bars[k]["section"] = "break"
                if j < outro_start:
                    bars[j]["section"] = "drop"
            i = j + 1
        else:
            bars[i]["section"] = "groove"
            i += 1

    for b in bars:
        b.setdefault("section", "groove")

    return bars


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("title")
    parser.add_argument("--artist", default=None)
    args = parser.parse_args()

    uuids = find_uuid(args.title)
    for uuid in uuids:
        metadata = load_metadata(uuid)
        if metadata is None or "waveColorsInfo" not in metadata or "waveInfoCompact" not in metadata:
            continue
        info = metadata.get("info", {})
        if args.artist and info.get("Artist", "").lower() != args.artist.lower():
            continue

        bass, bass_sr = bass_channel(metadata)
        total, total_sr = total_energy_channel(metadata)
        bpm, downbeat = beatgrid(metadata)

        # align both channels to the lower of the two sample rates
        target_sr = min(bass_sr, total_sr)
        target_len = int(min(len(bass) / bass_sr, len(total) / total_sr) * target_sr)
        bass_r = resample_to(bass, bass_sr, target_sr, target_len)
        total_r = resample_to(total, total_sr, target_sr, target_len)

        bars = label_structure(bass_r, total_r, target_sr, bpm, downbeat)

        print(f"\n=== {info.get('Artist', '?')} - {info.get('Name', '?')} (uuid={uuid}) ===")
        print(f"BPM={bpm}, downbeat={downbeat:.3f}s\n")
        prev = None
        for b in bars:
            if b["section"] != prev:
                m, s = int(b["t0"] // 60), int(b["t0"] % 60)
                print(f"  {m:02d}:{s:02d}  -> {b['section']}")
                prev = b["section"]


if __name__ == "__main__":
    main()
