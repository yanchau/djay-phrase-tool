import SwiftUI
import DjayBridge

/// Full-track waveform overview, 3-band stacked-layer style (see
/// `RhythmWaveView`/`WaveformBandStyle`), with a marker for the current
/// playback position. Replaces an earlier version colored flatly by
/// section (intro/groove/break/drop/outro) — dropped 2026-07-20 after the
/// user compared our Rhythm Wave to real rekordbox screenshots from the
/// Algoriddim forum thread requesting a 3-band waveform mode and preferred
/// rekordbox's whole-track overview strip over a flat section-color band:
/// the frequency-layered look already lets a DJ read kicks/breaks/drops
/// directly, the same information the section badge above states in words.
struct StructureTimelineView: View {
    let info: DjayStructureInfo
    let elapsed: Double?
    var scale: CGFloat = 1.0

    private var totalDuration: Double {
        // Approximate track duration as the end of the last bar plus one
        // bar's worth — bars don't carry their own length, so infer it
        // from spacing between the last two bars (falls back to a small
        // constant if there's only one).
        guard let last = info.bars.last else { return 1 }
        guard info.bars.count > 1 else { return last.startTime + 4 }
        let barLen = last.startTime - info.bars[info.bars.count - 2].startTime
        return last.startTime + max(barLen, 1)
    }

    // Same fix as `RhythmWaveView`: this Canvas redraws every time
    // `elapsed` ticks (~60Hz, just to move the position marker) or the
    // window resizes, but the waveform columns themselves only depend on
    // `info` — recomputing `max()` over thousands of samples on every one
    // of those redraws was wasted, measurable work.
    @State private var maxTotal: Double = 1
    @State private var bandMax: [Double] = [1, 1, 1]

    private func recomputeMaxes() {
        maxTotal = Double(info.waveformSamples.max() ?? 1)
        bandMax = info.bandSamples.count == 3 ? info.bandSamples.map { $0.max() ?? 1 } : [1, 1, 1]
    }

    var body: some View {
        Canvas { context, size in
            guard totalDuration > 0,
                  info.waveformSampleRate > 0,
                  !info.waveformSamples.isEmpty
            else { return }

            let samples = info.waveformSamples
            let sr = info.waveformSampleRate

            let hasBands = info.bandSamples.count == 3 && info.bandSampleRate > 0

            let columnCount = 220
            let columnWidth = size.width / CGFloat(columnCount)
            for i in 0..<columnCount {
                let t = (Double(i) / Double(columnCount)) * totalDuration
                let idx = Int(t * sr)
                guard idx >= 0, idx < samples.count else { continue }
                let loudness = Double(samples[idx]) / max(maxTotal, 1)
                let x = CGFloat(i) * columnWidth
                let w = max(columnWidth - 0.3, 1)

                func drawLayer(_ value: Double, cap: Double, color: Color) {
                    let h = max(CGFloat(min(value, 1) * cap) * size.height, 1)
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: w, height: h)
                    context.fill(Path(rect), with: .color(color))
                }

                if hasBands {
                    let bandIdx = Int(t * info.bandSampleRate)
                    if bandIdx >= 0, bandIdx < info.bandSamples[0].count {
                        let bass = max(info.bandSamples[0][bandIdx] / max(bandMax[0], 1e-6), 0)
                        let mid = max(info.bandSamples[1][bandIdx] / max(bandMax[1], 1e-6), 0)
                        let treble = max(info.bandSamples[2][bandIdx] / max(bandMax[2], 1e-6), 0)
                        drawLayer(bass, cap: WaveformBandStyle.bassCap, color: WaveformBandStyle.bassColor)
                        drawLayer(mid, cap: WaveformBandStyle.midCap, color: WaveformBandStyle.midColor)
                        drawLayer(treble, cap: WaveformBandStyle.trebleCap, color: WaveformBandStyle.trebleColor)
                        continue
                    }
                }
                drawLayer(loudness, cap: WaveformBandStyle.bassCap, color: .blue.opacity(0.75))
            }

            if let elapsed, totalDuration > 0 {
                let x = CGFloat(min(max(elapsed / totalDuration, 0), 1)) * size.width
                let markerWidth = 1.5 * scale
                let marker = Path(CGRect(x: x - markerWidth / 2, y: 0, width: markerWidth, height: size.height))
                context.fill(marker, with: .color(.white))
            }
        }
        .frame(height: 36 * scale)
        .background(Color.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 4 * scale))
        .onAppear(perform: recomputeMaxes)
        .onChange(of: info) { _ in recomputeMaxes() }
    }
}
