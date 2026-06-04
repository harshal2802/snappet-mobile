import SwiftUI

/// The **live heart-rate chart overlay** for the preview (the "moving-playhead line"): the whole
/// session's HR line drawn over the video, with a dot that tracks the video's 0…1 progress and (when
/// enabled) the live BPM number. Draggable to reposition. It's a SwiftUI layer (not baked into the
/// preview composition); export draws the same line + animated dot via Core Animation
/// (`StudioOverlays`), both from `HRChartGeometry`, so preview and export match.
struct StudioHRChartView: View {
    let samples: [HRPoint]
    let config: HROverlayConfig
    let ratio: CGFloat
    let currentTime: Double
    let totalDuration: Double
    let onMove: (CGPoint) -> Void   // normalized centre (0…1, top-left)
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let disp = ClipEditGeometry.displayRect(ratio: ratio, in: geo.size)
            let chartW = max(60, disp.width * config.scale)
            let chartH = chartW * 0.36
            let center = ClipEditGeometry.previewPoint(normalized: config.position, in: disp)
            chart(width: chartW, height: chartH)
                .frame(width: chartW, height: chartH)
                .position(x: center.x + drag.width, y: center.y + drag.height)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .updating($drag) { v, s, _ in s = v.translation }
                        .onEnded { v in
                            let dropped = CGPoint(x: center.x + v.translation.width,
                                                  y: center.y + v.translation.height)
                            onMove(ClipEditGeometry.normalizedPoint(fromPreview: dropped, in: disp))
                        }
                )
        }
        .allowsHitTesting(true)
    }

    private var fraction: Double { totalDuration > 0 ? min(1, max(0, currentTime / totalDuration)) : 0 }

    private var lineColor: Color {
        config.zoneColored
            ? HeartRateZone.forBpm(HRChartGeometry.sampleBPM(samples, atFraction: fraction)).color
            : Color(studioHex: config.colorHex)
    }

    @ViewBuilder private func chart(width: CGFloat, height: CGFloat) -> some View {
        let pts = HRChartGeometry.normalizedPoints(samples)
        let rect = CGRect(x: 6, y: 6, width: width - 12, height: height - 12)
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.35))
            Path { p in
                guard let first = pts.first else { return }
                p.move(to: point(first, in: rect))
                for q in pts.dropFirst() { p.addLine(to: point(q, in: rect)) }
            }
            .stroke(lineColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            // Playhead dot at the current video time.
            if let bpm = HRChartGeometry.sampleBPM(samples, atFraction: fraction), !pts.isEmpty {
                let ny = HRChartGeometry.normalizedY(forBPM: bpm, in: samples)
                let dot = CGPoint(x: rect.minX + fraction * rect.width, y: rect.minY + (1 - ny) * rect.height)
                Circle().fill(.white).frame(width: 9, height: 9).position(dot)
                Circle().fill(lineColor).frame(width: 5, height: 5).position(dot)
                if config.showBPM {
                    Text("♥ \(Int(bpm.rounded()))")
                        .font(.system(size: max(9, height * 0.2), weight: .bold))
                        .foregroundStyle(.white).shadow(color: .black.opacity(0.7), radius: 2)
                        .position(x: rect.midX, y: rect.minY + height * 0.16)
                }
            }
        }
    }

    private func point(_ n: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + n.x * rect.width, y: rect.minY + (1 - n.y) * rect.height)
    }
}

