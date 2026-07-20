import SwiftUI
import DjayBridge

/// Live scrolling waveform centered on the current playback position — past
/// audio on the left, future on the right, a fixed marker in the center.
/// Idea borrowed from VirtualDJ's "Rhythm Wave" (see CLAUDE.md "Recherche
/// concurrentielle"). Built from djay's cached low-res amplitude envelope
/// (~10 samples/second — coarser than a real per-sample audio waveform, but
/// enough to see the pulse/energy shape around a beat, and needs no audio
/// file access so it works on Apple Music tracks too).
///
/// Colored per-bar since 2026-07-20 as 3 nested layers (bass/mid/treble —
/// `DjayStructureInfo.bandSamples`), answering a feature request seen on the
/// Algoriddim forum for a rekordbox-style 3-band waveform (djay itself
/// doesn't have one — see CLAUDE.md "Découvertes — waveform 3 bandes").
/// Matched to actual rekordbox screenshots from that forum thread (not
/// djay's own "Spectral" style, which is per-column solid-hue stripes):
/// rekordbox draws a stacked mountain-range histogram, blue (bass) as the
/// widest outer envelope, orange (mid) narrower on top, white/cream
/// (treble) narrowest at the core — not a single blended hue per bar. Each
/// layer's height is that instant's own band value (normalized 0-1 by that
/// channel's track-wide max) capped by a fixed per-layer visual ceiling so
/// the nesting stays consistent regardless of which band happens to be
/// momentarily loudest.
struct RhythmWaveView: View {
    let info: DjayStructureInfo
    let elapsed: Double?
    var scale: CGFloat = 1.0
    var windowSeconds: Double = 16

    // `samples.max()`/`bandSamples.map { $0.max() }` are O(n) over
    // potentially thousands of points — cheap once, but this Canvas
    // redraws on every elapsed tick (~60Hz) AND on every frame of a live
    // window resize, so recomputing them inline every single draw was
    // real, avoidable cost. Found 2026-07-20 chasing residual resize
    // jitter after the earlier window-fighting-itself bug was fixed —
    // cached here, refreshed only when `info` itself actually changes
    // (a new track), not every redraw.
    @State private var maxTotal: Double = 1
    @State private var bandMax: [Double] = [1, 1, 1]

    private func recomputeMaxes() {
        maxTotal = Double(info.waveformSamples.max() ?? 1)
        bandMax = info.bandSamples.count == 3 ? info.bandSamples.map { $0.max() ?? 1 } : [1, 1, 1]
    }

    var body: some View {
        Canvas { context, size in
            guard let elapsed,
                  info.waveformSampleRate > 0,
                  !info.waveformSamples.isEmpty
            else { return }

            let samples = info.waveformSamples
            let sr = info.waveformSampleRate
            let startTime = elapsed - windowSeconds / 2

            let hasBands = info.bandSamples.count == 3 && info.bandSampleRate > 0

            let barCount = 120
            let barWidth = size.width / CGFloat(barCount)
            for i in 0..<barCount {
                let t = startTime + (Double(i) / Double(barCount)) * windowSeconds
                guard t >= 0 else { continue }
                let idx = Int(t * sr)
                guard idx >= 0, idx < samples.count else { continue }
                let loudness = Double(samples[idx]) / max(maxTotal, 1)
                let x = CGFloat(i) * barWidth
                let w = max(barWidth - 0.5, 1)

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
                    } else {
                        drawLayer(loudness, cap: WaveformBandStyle.bassCap, color: .blue.opacity(0.75))
                    }
                } else {
                    drawLayer(loudness, cap: WaveformBandStyle.bassCap, color: .blue.opacity(0.75))
                }
            }

            let centerX = size.width / 2
            var marker = Path()
            marker.move(to: CGPoint(x: centerX, y: 0))
            marker.addLine(to: CGPoint(x: centerX, y: size.height))
            context.stroke(marker, with: .color(.white), lineWidth: 1.5 * scale)
        }
        .frame(height: 36 * scale)
        .background(Color.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 4 * scale))
        .onAppear(perform: recomputeMaxes)
        .onChange(of: info) { _ in recomputeMaxes() }
    }
}
