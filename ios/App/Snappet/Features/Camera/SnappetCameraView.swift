import SwiftUI
import AVFoundation

/// **The in-app camera** (prompt 190, `docs/ux-research/in-app-camera/wireframes.html` screens 1–4): iPhone-Camera
/// style — torch · resolution · fps chip (tap each half) · countdown · ⌃ settings tray; lenses (.5 / 1× / 3) and
/// pinch-zoom across them; tap to focus, long-press to lock focus + exposure; SLO-MO · VIDEO · PHOTO; a still
/// mid-clip; a hands-free countdown. Stays open across several clips / photos — each is handed up as it finishes
/// (`onVideo` / `onPhoto`) — until Done. Settings are remembered (`CameraSettings`, "Remember my settings").
struct SnappetCameraView: View {
    let onVideo: (URL, Date) -> Void
    let onPhoto: (Data, Date) -> Void
    let onClose: () -> Void

    @State private var camera = CameraController()
    @State private var settings = CameraSettings.load(from: UserDefaults.standard.data(forKey: CameraSettings.storageKey))
    @State private var showTray = false
    @State private var countdownLeft: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var focusMark: FocusMark?
    @State private var captured = 0
    @State private var flash = false
    @State private var pinchBase: Double?
    @State private var previewLayer = PreviewLayerBox()
    @State private var idleTimerWas = false

    private struct FocusMark: Equatable {
        let point: CGPoint
        let locked: Bool
        let id = UUID()
    }

    private var caps: CameraCapabilities { camera.capabilities }

    var body: some View {
        VStack(spacing: 0) {
            topBar.frame(height: 48)
            ZStack {
                preview
                if settings.grid { GridOverlay().allowsHitTesting(false).accessibilityIdentifier("camera.grid") }
                if let mark = focusMark { focusSquare(mark) }
                VStack {
                    Spacer()
                    if !caps.lenses.isEmpty && camera.position == .back && countdownLeft == nil && !showTray { lensBar }
                }
                .padding(.bottom, 10)
                if showTray && !camera.isRecording {
                    VStack { Spacer(); tray }.transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if flash { Color.white.opacity(0.7).allowsHitTesting(false) }
            }
            .clipped()
            bottomBar
        }
        .background(Color.black.ignoresSafeArea())
        .overlay { if let left = countdownLeft { countdownOverlay(left) } }
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .onAppear {
            camera.onMovie = { url, start in captured += 1; onVideo(url, start) }
            camera.onPhoto = { data, at in captured += 1; onPhoto(data, at) }
            camera.start(with: settings)
            settings = CameraLogic.resolve(settings, camera.capabilities)
            camera.apply(settings)
            idleTimerWas = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true   // a propped phone must not lock mid-set
        }
        .onDisappear {
            countdownTask?.cancel()
            camera.stop()
            UIApplication.shared.isIdleTimerDisabled = idleTimerWas
        }
        .animation(.easeOut(duration: 0.2), value: showTray)
        .animation(.easeOut(duration: 0.2), value: camera.isRecording)
    }

    // MARK: - Top

    @ViewBuilder private var topBar: some View {
        if camera.isRecording, let start = camera.recordingStartedAt {
            TimelineView(.periodic(from: start, by: 1)) { ctx in
                Text(CameraLogic.timer(ctx.date.timeIntervalSince(start)))
                    .font(.system(size: 15, weight: .bold)).monospacedDigit()
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityIdentifier("camera.timer")
            }
        } else {
            HStack {
                circleButton(camera.torchOn ? "bolt.fill" : "bolt.slash", on: camera.torchOn, id: "camera.torch") {
                    camera.setTorch(!camera.torchOn)
                }
                .opacity(caps.hasTorch && camera.position == .back ? 1 : 0.3)
                .disabled(!(caps.hasTorch && camera.position == .back))
                Spacer()
                if let chip = CameraLogic.chip(settings) {
                    HStack(spacing: 0) {
                        Button(chip.resolution) { update(CameraLogic.toggleResolution(settings, caps)) }
                            .disabled(settings.mode == .slomo)
                            .accessibilityIdentifier("camera.chip.resolution")
                        Text(" · ").foregroundStyle(.secondary)
                        Button(chip.fps) { update(CameraLogic.cycleFPS(settings, caps)) }
                            .foregroundStyle(Color.yellow)
                            .accessibilityIdentifier("camera.chip.fps")
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.white.opacity(0.14), in: Capsule())
                }
                Spacer()
                Button {
                    var s = settings; s.countdown = CameraLogic.nextCountdown(settings.countdown); update(s)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "timer")
                        if settings.countdown > 0 { Text("\(settings.countdown)s").font(.caption.weight(.bold)) }
                    }
                    .foregroundStyle(settings.countdown > 0 ? Color.yellow : .white)
                    .frame(minWidth: 34, minHeight: 34)
                    .background(.white.opacity(0.14), in: Capsule())
                }
                .accessibilityIdentifier("camera.countdown")
                .accessibilityLabel(settings.countdown > 0 ? "Countdown \(settings.countdown) seconds" : "Countdown off")
                circleButton(showTray ? "chevron.down" : "chevron.up", on: showTray, id: "camera.more") {
                    showTray.toggle()
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func circleButton(_ symbol: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on ? .black : .white)
                .frame(width: 34, height: 34)
                .background(on ? Color.yellow : .white.opacity(0.14), in: Circle())
        }
        .accessibilityIdentifier(id)
    }

    // MARK: - Preview + gestures

    @ViewBuilder private var preview: some View {
        GeometryReader { geo in
            Group {
                if camera.fake {
                    LinearGradient(colors: [Color(white: 0.25), Color(red: 0.16, green: 0.13, blue: 0.1)],
                                   startPoint: .top, endPoint: .bottom)
                } else {
                    CameraPreview(session: camera.session, box: previewLayer)
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { focus(at: $0.location, size: geo.size, lock: false) })
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.6)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onEnded { value in
                        if case .second(true, let drag?) = value {
                            focus(at: drag.location, size: geo.size, lock: true)
                        }
                    })
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        let base = pinchBase ?? camera.zoom
                        pinchBase = base
                        camera.setZoom(base * v.magnification, animated: false)
                    }
                    .onEnded { _ in pinchBase = nil })
        }
        .accessibilityIdentifier("camera.preview")
    }

    private func focus(at location: CGPoint, size: CGSize, lock: Bool) {
        guard countdownLeft == nil else { cancelCountdown(); return }
        if showTray { showTray = false; return }
        let devicePoint = previewLayer.layer.map { CameraController.devicePoint(for: location, in: $0) }
            ?? CGPoint(x: location.y / max(size.height, 1), y: 1 - location.x / max(size.width, 1))
        camera.focus(at: devicePoint, lock: lock)
        let mark = FocusMark(point: location, locked: lock)
        focusMark = mark
        if !lock {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if focusMark == mark { focusMark = nil } }
        }
    }

    private func focusSquare(_ mark: FocusMark) -> some View {
        Rectangle()
            .stroke(Color.yellow, lineWidth: 1.5)
            .frame(width: 72, height: 72)
            .overlay(alignment: .top) {
                if mark.locked {
                    Text("AE/AF LOCK").font(.system(size: 10, weight: .heavy)).foregroundStyle(.black)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.yellow, in: RoundedRectangle(cornerRadius: 3))
                        .offset(y: -20)
                        .accessibilityIdentifier("camera.focusLock")
                }
            }
            .position(mark.point)
            .allowsHitTesting(false)
    }

    private var lensBar: some View {
        let active = CameraLogic.activeLens(zoom: camera.zoom, lenses: caps.lenses)
        return HStack(spacing: 8) {
            ForEach(caps.lenses, id: \.self) { lens in
                let on = lens == active
                Button { camera.setZoom(lens, animated: true) } label: {
                    Text(CameraLogic.lensLabel(lens, selected: on, zoom: camera.zoom))
                        .font(.system(size: on ? 13 : 11, weight: .bold)).monospacedDigit()
                        .foregroundStyle(on ? Color.yellow : .white)
                        .frame(width: on ? 42 : 34, height: on ? 42 : 34)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .accessibilityIdentifier("camera.lens.\(CameraLogic.lensLabel(lens, selected: false, zoom: lens))")
            }
        }
    }

    // MARK: - Settings tray

    private var tray: some View {
        VStack(spacing: 0) {
            if settings.mode == .video {
                trayRow("Resolution") {
                    segmented(CameraResolution.allCases.filter { r in caps.video.contains { $0.resolution == r } },
                              selected: settings.resolution, label: \.label, id: "resolution") { r in
                        var s = settings; s.resolution = r; update(s)
                    }
                }
                trayRow("Frame rate") {
                    segmented(CameraSettings.fpsChoices.filter { caps.video.contains(.init(resolution: settings.resolution, fps: $0)) },
                              selected: settings.fps, label: { "\($0)" }, id: "fps") { f in
                        var s = settings; s.fps = f; update(s)
                    }
                }
            }
            if settings.mode == .slomo && !caps.slomo.isEmpty {
                trayRow("Slo-mo") {
                    segmented(caps.slomo, selected: settings.slomoFPS, label: { "\($0)" }, id: "slomo") { f in
                        var s = settings; s.slomoFPS = f; update(s)
                    }
                }
            }
            if settings.mode.recordsVideo && caps.enhancedStabilization {
                trayRow("Stabilization") {
                    segmented(CameraStabilization.allCases, selected: settings.stabilization, label: \.label,
                              id: "stabilization") { v in
                        var s = settings; s.stabilization = v; update(s)
                    }
                }
            }
            if settings.mode.recordsVideo {
                trayRow("Countdown") {
                    segmented(CameraSettings.countdownChoices, selected: settings.countdown,
                              label: { $0 == 0 ? "Off" : "\($0)s" }, id: "countdown") { c in
                        var s = settings; s.countdown = c; update(s)
                    }
                }
            }
            trayRow("Grid") {
                Toggle("", isOn: Binding(get: { settings.grid }, set: { var s = settings; s.grid = $0; update(s) }))
                    .labelsHidden().accessibilityIdentifier("camera.tray.grid")
            }
            trayRow("Remember my settings") {
                Toggle("", isOn: Binding(get: { settings.remember }, set: { var s = settings; s.remember = $0; update(s) }))
                    .labelsHidden().accessibilityIdentifier("camera.tray.remember")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color(white: 0.07).opacity(0.94), in: UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camera.tray")
    }

    private func trayRow<C: View>(_ title: String, @ViewBuilder control: () -> C) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            control()
        }
        .frame(minHeight: 40)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }

    private func segmented<T: Hashable>(_ options: [T], selected: T, label: @escaping (T) -> String, id: String,
                                        pick: @escaping (T) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                Button { pick(o) } label: {
                    Text(label(o)).font(.caption.weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .foregroundStyle(o == selected ? .white : .secondary)
                        .background(o == selected ? Color(white: 0.3) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("camera.tray.\(id).\(label(o))")
                .accessibilityAddTraits(o == selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        VStack(spacing: 14) {
            HStack(spacing: 22) {
                ForEach(CameraMode.allCases.filter { $0 != .slomo || !caps.slomo.isEmpty }) { m in
                    Button(m.label) {
                        var s = settings; s.mode = m; update(s)
                    }
                    .font(.system(size: 13, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(settings.mode == m ? Color.yellow : Color(white: 0.75))
                    .accessibilityIdentifier("camera.mode.\(m.rawValue)")
                    .accessibilityAddTraits(settings.mode == m ? .isSelected : [])
                }
            }
            .opacity(camera.isRecording || countdownLeft != nil ? 0 : 1)
            .disabled(camera.isRecording)

            HStack {
                leftControl.frame(width: 48, height: 48)
                Spacer()
                shutter
                Spacer()
                Button { camera.flip() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(.white.opacity(0.14), in: Circle())
                }
                .opacity(camera.isRecording || !caps.hasFront ? 0 : 1)
                .disabled(camera.isRecording || !caps.hasFront)
                .accessibilityIdentifier("camera.flip")
            }
            .padding(.horizontal, 32)

            Button("Done") { close() }
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .opacity(camera.isRecording ? 0 : 1)
                .disabled(camera.isRecording)
                .accessibilityIdentifier("camera.done")
        }
        .padding(.top, 14).padding(.bottom, 10)
        .background(Color.black)
    }

    @ViewBuilder private var leftControl: some View {
        if camera.isRecording {
            // A still mid-clip (iPhone's white button while filming).
            Button { snapStill() } label: {
                Circle().fill(.white).frame(width: 26, height: 26)
                    .frame(width: 46, height: 46).background(.white.opacity(0.14), in: Circle())
            }
            .accessibilityIdentifier("camera.still")
        } else if captured > 0 {
            Text("\(captured)")
                .font(.headline).foregroundStyle(.black)
                .frame(width: 42, height: 42)
                .background(Color.yellow, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityIdentifier("camera.captured")
                .accessibilityLabel("\(captured) captured")
        }
    }

    private var shutter: some View {
        Button { shutterTapped() } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                if settings.mode == .photo {
                    Circle().fill(.white).frame(width: 60, height: 60)
                } else if camera.isRecording {
                    RoundedRectangle(cornerRadius: 6).fill(Color.red).frame(width: 28, height: 28)
                } else {
                    Circle().fill(Color.red).frame(width: 60, height: 60)
                }
            }
        }
        .accessibilityIdentifier("camera.shutter")
        .accessibilityLabel(settings.mode == .photo ? "Take photo" : camera.isRecording ? "Stop recording" : "Record")
    }

    private func countdownOverlay(_ left: Int) -> some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(spacing: 10) {
                Text("\(left)").font(.system(size: 150, weight: .ultraLight)).monospacedDigit()
                    .accessibilityIdentifier("camera.countdownOverlay")
                Text("Recording starts in \(left)… get set").font(.headline)
                Text("Tap to cancel").font(.subheadline).foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
            .shadow(radius: 12)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { cancelCountdown() }
    }

    // MARK: - Actions

    private func update(_ new: CameraSettings) {
        let resolved = CameraLogic.resolve(new, caps)
        let hardwareChanged = resolved.mode != settings.mode || resolved.resolution != settings.resolution
            || resolved.fps != settings.fps || resolved.slomoFPS != settings.slomoFPS
            || resolved.stabilization != settings.stabilization
        settings = resolved
        if hardwareChanged { camera.apply(resolved) }
        UserDefaults.standard.set(resolved.encodedForStorage(), forKey: CameraSettings.storageKey)
    }

    private func shutterTapped() {
        if showTray { showTray = false }
        switch settings.mode {
        case .photo:
            camera.capturePhoto()
            withAnimation(.easeOut(duration: 0.08)) { flash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { withAnimation { flash = false } }
        case .video, .slomo:
            if camera.isRecording {
                camera.stopRecording()
                Haptics.tap()
            } else if countdownLeft != nil {
                cancelCountdown()
            } else if settings.countdown > 0 {
                startCountdown(settings.countdown)
            } else {
                camera.startRecording()
                Haptics.tap()
            }
        }
    }

    private func startCountdown(_ seconds: Int) {
        countdownLeft = seconds
        countdownTask = Task { @MainActor in
            for left in stride(from: seconds, to: 0, by: -1) {
                countdownLeft = left
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdownLeft = nil
            camera.startRecording()
            Haptics.tap()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownLeft = nil
    }

    private func snapStill() {
        camera.capturePhoto()
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { withAnimation { flash = false } }
    }

    private func close() {
        cancelCountdown()
        camera.stop()
        onClose()
    }
}

// MARK: - Preview layer

/// Holds the live preview layer so a tap can be converted to the device's focus coordinates.
@MainActor
final class PreviewLayerBox {
    weak var layer: AVCaptureVideoPreviewLayer?
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let box: PreviewLayerBox

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90   // the camera UI is portrait; recordings follow how the phone is held
        }
        box.layer = view.previewLayer
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90),
           connection.videoRotationAngle != 90 {
            connection.videoRotationAngle = 90
        }
    }
}

/// Rule-of-thirds lines.
private struct GridOverlay: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3, y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.6)
        }
    }
}
