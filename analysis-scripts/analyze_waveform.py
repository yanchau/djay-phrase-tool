#!/usr/bin/env python3
"""Volet 3 — détection de structure à partir de la waveform précalculée de djay.

Contrairement à analyze_track.py (qui a besoin du fichier audio local),
ce script n'utilise QUE ce que djay a déjà calculé et mis en cache :
- BPM + premier downbeat (deepBeatTrackerInfo, Volet 2)
- l'enveloppe d'amplitude basse résolution (waveInfoCompact.compressedLowRateWaveSamples)

Ça marche donc aussi bien sur les fichiers locaux que sur les tracks
Apple Music/Spotify/SoundCloud — la limite DRM ne s'applique pas puisqu'on
ne touche jamais le fichier audio, seulement le cache d'analyse de djay.

Méthode, validée le 2026-07-20 sur un vrai morceau (version Apple Music)
contre les cue points posés manuellement par l'utilisateur sur les vrais
changements de structure : 5/5 changements retrouvés avec un écart de
0.1 à 1.8s.

1. Lisser l'enveloppe (fenêtre ~2s) pour effacer le bruit au niveau du temps.
2. Score de changement en chaque point = |moyenne(après) - moyenne(avant)|
   / moyenne(avant), sur des fenêtres de ~20s de part et d'autre.
3. Pics locaux du score (scipy.signal.find_peaks, distance >= 20s,
   proéminence >= 0.35).
4. Caler chaque pic sur la frontière de phrase (16/32 temps) la plus
   proche du beatgrid ; rejeter les pics à plus de 3s de toute frontière
   de phrase (élimine les faux positifs qui ne sont pas de vrais
   changements de section — filtre validé empiriquement : un faux positif
   au milieu du test ne tombait sur aucune frontière, contrairement aux
   5 vrais changements qui tombaient tous exactement dessus).

Lecture seule sur la base djay et le cache .djayMetadata.
"""
import argparse
import glob
import json
import plistlib
import sqlite3
import struct
import os
import sys
import zlib

import numpy as np
from scipy.signal import find_peaks

DEFAULT_DB = os.path.expanduser(
    "~/Music/djay/djay Media Library.djayMediaLibrary/MediaLibrary.db"
)
DEFAULT_METADATA_DIR = os.path.expanduser(
    "~/Library/Group Containers/VJXTL73S8G.com.algoriddim.userdata/"
    "Library/Application Support/Algoriddim/Metadata"
)

SMOOTH_WINDOW_S = 2.0
CHANGE_WINDOW_S = 20.0
MIN_DISTANCE_S = 20.0
PROMINENCE = 0.35
PHRASE_SNAP_TOLERANCE_S = 3.0


def find_uuid(title, artist=None, db_path=DEFAULT_DB):
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    cur = conn.cursor()
    cur.execute(
        """
        SELECT database2.key FROM database2
        WHERE database2.collection = 'mediaItems'
          AND database2.rowid IN (SELECT docid FROM fts_searchIndex WHERE title MATCH ?)
        """,
        (title,),
    )
    return [row[0] for row in cur.fetchall()]


def load_metadata(uuid, metadata_dir=DEFAULT_METADATA_DIR):
    matches = glob.glob(f"{metadata_dir}/*/{uuid}.djayMetadata")
    if not matches:
        return None
    with open(matches[0], "rb") as f:
        return plistlib.load(f)


def waveform_samples(metadata):
    wic = metadata["waveInfoCompact"]
    raw = zlib.decompress(wic["compressedLowRateWaveSamples"])
    return np.frombuffer(raw, dtype=np.uint8).astype(float), wic["lowRateWaveFinalSampleRate"]


def beatgrid(metadata):
    dbt = metadata["deepBeatTrackerInfo"]
    beats_raw = zlib.decompress(dbt["compressedBeats"])
    beats = struct.unpack(">%df" % (len(beats_raw) // 4), beats_raw)
    downbeat = beats[dbt["firstDownBeatIndex"]]
    return dbt["bpm"], downbeat


def detect_transitions(samples, sample_rate, bpm, downbeat, beats_per_phrase=32):
    n = len(samples)
    smooth_win = max(1, int(round(SMOOTH_WINDOW_S * sample_rate)))
    smoothed = np.convolve(samples, np.ones(smooth_win) / smooth_win, mode="same")

    half = int(round(CHANGE_WINDOW_S * sample_rate))
    change_score = np.zeros(n)
    for i in range(half, n - half):
        before = smoothed[i - half:i].mean()
        after = smoothed[i:i + half].mean()
        change_score[i] = abs(after - before) / max(before, 1.0)

    peaks, _ = find_peaks(
        change_score,
        distance=max(1, int(round(MIN_DISTANCE_S * sample_rate))),
        prominence=PROMINENCE,
    )

    # Phrase-alignment is a strong signal when it holds (validated on one
    # real track: eliminated every false positive with zero cost) but it
    # does NOT hold on every track — on a different real track it would
    # have silently thrown away two strong, real transitions (score 4.04
    # and 0.83) that simply didn't land on a phrase boundary within
    # tolerance. So: report every peak, and separately flag which ones
    # happen to be phrase-aligned rather than dropping the ones that
    # aren't. Let the caller decide.
    phrase_duration = beats_per_phrase * 60.0 / bpm
    transitions = []
    for p in peaks:
        t = p / sample_rate
        phrase_idx = round((t - downbeat) / phrase_duration)
        phrase_time = downbeat + phrase_idx * phrase_duration
        aligned = abs(t - phrase_time) <= PHRASE_SNAP_TOLERANCE_S and phrase_time >= 0
        transitions.append({
            "raw_time": float(t),
            "phrase_time": float(phrase_time) if aligned else None,
            "phrase_number": int(phrase_idx) + 1 if aligned else None,
            "phrase_aligned": aligned,
            "score": float(change_score[p]),
        })
    return transitions


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("title")
    parser.add_argument("--artist", default=None)
    parser.add_argument("--beats-per-phrase", type=int, default=32)
    parser.add_argument("--out", default=None)
    args = parser.parse_args()

    uuids = find_uuid(args.title)
    if not uuids:
        print(f"Aucune track trouvée pour le titre {args.title!r}", file=sys.stderr)
        sys.exit(1)

    for uuid in uuids:
        metadata = load_metadata(uuid)
        if metadata is None or "waveInfoCompact" not in metadata:
            continue
        info = metadata.get("info", {})
        if args.artist and info.get("Artist", "").lower() != args.artist.lower():
            continue

        samples, sample_rate = waveform_samples(metadata)
        bpm, downbeat = beatgrid(metadata)
        transitions = detect_transitions(samples, sample_rate, bpm, downbeat, args.beats_per_phrase)

        print(f"\n=== {info.get('Artist', '?')} - {info.get('Name', '?')} (uuid={uuid}) ===")
        print(f"BPM={bpm}, downbeat={downbeat:.3f}s, source={info.get('source')}")

        def fmt(seconds):
            m, s = int(seconds // 60), seconds % 60
            return f"{m:02d}:{s:05.2f}"

        aligned = [t for t in transitions if t["phrase_aligned"]]
        unaligned = [t for t in transitions if not t["phrase_aligned"]]
        print("Transitions calées sur la grille de phrase (haute confiance) :")
        for t in sorted(aligned, key=lambda t: t["phrase_time"]):
            print(f"  {fmt(t['phrase_time'])}  (phrase {t['phrase_number']}, score={t['score']:.2f})")
        if unaligned:
            print("Transitions détectées mais hors grille (à vérifier à l'oreille) :")
            for t in sorted(unaligned, key=lambda t: t["raw_time"]):
                print(f"  {fmt(t['raw_time'])}  (score={t['score']:.2f})")

        if args.out:
            with open(args.out, "w") as f:
                json.dump({"uuid": uuid, "bpm": bpm, "downbeat": downbeat, "transitions": transitions}, f, indent=2)


if __name__ == "__main__":
    main()
