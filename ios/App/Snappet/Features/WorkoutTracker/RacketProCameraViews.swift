import SwiftUI
import UIKit

// MARK: - Racket pro camera, before recording (prompt 255, issue #448 part 2)
//
// Boards ProCamera, ProCameraZoom, ProCameraFocus, ProCameraLock, ProCameraQuality, ProCameraOptions, ProCameraLooks,
// ProCameraDenied: Apple Camera's layout and gestures (not its icons or artwork). Thin renderers over the pure
// `RacketProCamera.swift`; the camera itself is `Services/RacketRecorder.swift`, the level `Services/RacketLevelMeter`.
// The live picture is the owning cover's one persistent preview (`racketPersistentPreview`), drawn at this screen's slot.

/// The camera's amber (the boards' selected lens, mode and focus square), from the design system's amber.
private let cameraAmber = SnappetColor.perfModerate

struct RacketProCameraView: View {
    let recorder: RacketRecorder
    let sport: RacketSport
    var unit: RacketUnit = .game
    /// The mode strip; empty ⇒ no strip.
    var modes: [RacketRecordingMode] = [.byUnit, .everything]
    @Binding var mode: RacketRecordingMode
    let accessDenied: Bool
    /// Who serves first (a match); nil ⇒ no row.
    var firstServer: Binding<RacketServe.Side?>? = nil
    /// Who serves first for us (doubles); nil ⇒ no row.
    var ourFirstServer: Binding<RacketDoublesServe.Player?>? = nil
    var sides: (us: String, them: String) = ("You", "Them")
    var partnerName: String = "Partner"
    @Binding var show: RacketRecordingShow
    @Binding var useWatch: Bool
    let watchAvailable: Bool
    /// The newest video of this match, for the thumbnail; nil ⇒ an empty frame.
    var thumbnailID: String? = nil
    /// The thumbnail opens Your videos; nil ⇒ no thumbnail.
    var onVideos: (() -> Void)? = nil
    let onShutter: () -> Void
    let onClose: () -> Void
    let onPlayWithoutVideo: () -> Void
    /// While recording (prompt 256): the recording chrome in place of the ready chrome. nil ⇒ before recording.
    var live: RacketCameraLive? = nil
    /// Extra controls at the top of Options (the break's pause, +1 min, auto-start).
    var optionsExtra: AnyView? = nil
    /// UI tests only: stand-in buttons drawn above everything in this view's own stack (outside it, the preview's UIKit
    /// gesture layer takes their taps).
    var testOverlay: AnyView? = nil

    @AppStorage(RacketFraming.storageKey) private var framingData = Data()
    @AppStorage(RacketRecordingDefaults.storageKey) private var defaultsData = Data()
    @State private var level: RacketLevelMeter?
    @State private var free: Int64?
    @State private var battery: Int?
    @State private var dialOpen = false
    @State private var dialTouch = 0
    @State private var dragStartZoom: Double?
    /// When a drag across the lenses ended: the button under the finger must not also jump to its lens.
    @State private var lensDragEndedAt: Date?
    @State private var pinchStartZoom: Double?
    /// The focus square's place on screen, and a counter so each tap restarts its fade.
    @State private var focusAt: CGPoint?
    @State private var focusTouch = 0
    @State private var biasStart: Double?
    @State private var lockCaption = false
    @State private var showQuality = false
    @State private var showOptions = false
    @State private var showLooks = false
    @State private var looksTouch = 0
    @State private var thumbnail: UIImage?

    private var caps: RacketCameraCapabilities { recorder.capabilities }
    private var setup: RacketCameraSetup { recorder.setup }
    private var framing: RacketFraming { RacketFraming.load(framingData) }
    private var freeBytes: Int64 { free ?? 64_000_000_000 }
    private var pill: RacketCameraStatus.Pill {
        RacketCameraStatus.pill(roomSec: RacketQualityEstimate(format: setup.format, freeBytes: freeBytes, codec: recorder.codec).roomSec,
                                batteryPercent: battery)
    }

    var body: some View {
        if accessDenied {
            RacketCameraDeniedView(onClose: onClose, onPlayWithoutVideo: onPlayWithoutVideo)
        } else {
            camera
        }
    }

    /// Sideways when the screen is wider than tall (ProCameraLandscape); which way from the window scene.
    private func orientation(_ box: CGSize) -> RacketCameraOrientation {
        guard box.width > box.height else { return .portrait }
        let o = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation
        return o == .landscapeLeft ? .landscapeLeft : .landscapeRight
    }

    private var camera: some View {
        GeometryReader { g in
            let box = g.size
            let o = orientation(box)
            let aspect = o.shownAspect(portraitAspect: recorder.previewAspect.map(Double.init)).map { CGFloat($0) }
            let video = RacketVideoOrientation.aspectFit(aspect: aspect, in: box)
            ZStack(alignment: .topLeading) {
                if live?.showsPicture ?? true {
                    // The cover's one live preview is drawn here (behind), with the look on it; the fake draws a court.
                    Color.clear.racketPreviewSlot()
                    if recorder.fake {
                        RacketFakeCourtScene()
                            .modifier(RacketLookPreviewEffect(preview: RacketLookPreview(live == nil ? setup.look : .original)))
                            .scaleEffect(max(1, setup.zoom), anchor: .center)
                            .frame(width: video.width, height: video.height)
                            .clipped()
                            .offset(x: video.minX, y: video.minY)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    if live == nil { framingOverlays(video) }
                    gestureLayer(box, aspect: aspect, orientation: o)
                    if let p = focusAt { focusOverlay(p, box: box) }
                } else {
                    Color.black
                }
                if let live { liveMiddle(live) }
                if o.isLandscape { landscapeControls } else if let live { liveControls(live) } else { controls }
                if let testOverlay {
                    // A background makes the strip take its own taps (bare buttons over the preview lose them to the
                    // UIKit gesture layer).
                    testOverlay.fixedSize().background(Color.black.opacity(0.35)).padding(.top, safeTop + 50).padding(.leading, 4)
                }
            }
            .frame(width: box.width, height: box.height)
        }
        .ignoresSafeArea()
        // No background here: the live picture is drawn behind this view by the owning cover, which is black itself.
        .onAppear(perform: appear)
        .onDisappear { level?.stop() }
        .task {
            // The pill's space and battery, refreshed while the camera shows.
            while !Task.isCancelled {
                free = RacketRecorder.storage()?.free ?? free
                battery = RacketRecorder.batteryPercent()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .task(id: thumbnailID) {
            guard let id = thumbnailID else { thumbnail = nil; return }
            thumbnail = await RacketVideoLibrary.shared.poster(id)
        }
        .task(id: focusTouch) {
            // The square and the sun fade after a few seconds (the AE/AF LOCK badge stays).
            guard focusAt != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { focusAt = nil }
        }
        .task(id: dialTouch) {
            guard dialOpen else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, dragStartZoom == nil, pinchStartZoom == nil else { return }
            withAnimation(.easeOut(duration: 0.25)) { dialOpen = false }
        }
        .task(id: looksTouch) {
            guard showLooks else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { showLooks = false }
        }
        .sheet(isPresented: $showQuality) {
            RacketCameraQualityPage(recorder: recorder, freeBytes: freeBytes, onDone: { showQuality = false })
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showOptions) {
            RacketCameraOptionsSheet(
                framing: Binding(get: { framing }, set: { framingData = $0.encoded }),
                firstServer: firstServer, ourFirstServer: ourFirstServer, sides: sides, partnerName: partnerName,
                show: $show, useWatch: $useWatch, watchAvailable: watchAvailable, extra: optionsExtra,
                onDone: { showOptions = false },
                onLooks: {
                    showOptions = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { openLooks() }
                },
                onCompareQuality: {
                    showOptions = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showQuality = true }
                })
                .presentationDetents([.fraction(0.6), .large])
                .presentationBackground(Color(white: 0.07))
                .presentationDragIndicator(.visible)
        }
        .onChange(of: framing.level) { _, on in on ? level?.start() : level?.stop() }
    }

    private func appear() {
        #if DEBUG
        // UI tests: the headless simulator doesn't turn the app with the device (prompt 253's hook).
        if UserDefaults.standard.bool(forKey: "uiTestRacketLandscape") {
            // After the cover has finished presenting (a request mid-transition is dropped).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { e in
                    RacketRecorder.trace("landscape request failed \(e.localizedDescription)")
                }
            }
        }
        #endif
        if level == nil { level = RacketLevelMeter(fake: recorder.fake) }
        if framing.level { level?.start() }
        free = RacketRecorder.storage()?.free
        battery = RacketRecorder.batteryPercent()
    }

    // MARK: Framing (grid, level, court guide): over the preview only, never recorded

    @ViewBuilder private func framingOverlays(_ video: CGRect) -> some View {
        Group {
            if framing.grid { RacketCameraGrid().accessibilityIdentifier("racket.camera.grid") }
            if framing.level { RacketLevelLine(tilt: level?.tilt) }
            if framing.courtGuide { RacketCourtGuide(sport: sport, videoAspect: nil) }
        }
        .frame(width: video.width, height: video.height)
        .offset(x: video.minX, y: video.minY)
        .allowsHitTesting(false)
    }

    // MARK: Gestures on the preview: tap = focus (always), touch and hold = AE/AF lock, pinch = zoom

    private func gestureLayer(_ box: CGSize, aspect: CGFloat?, orientation o: RacketCameraOrientation) -> some View {
        RacketCameraGestureLayer(
            onTap: { p in
                if setup.locked {
                    // "Tap anywhere to unlock".
                    recorder.unlock()
                    withAnimation(.easeOut(duration: 0.2)) { focusAt = nil; lockCaption = false }
                    Haptics.tap()
                    return
                }
                focus(at: p, box: box, aspect: aspect, o: o, lock: false)
            },
            onHold: { p in
                focus(at: p, box: box, aspect: aspect, o: o, lock: true)
                Haptics.success()
            },
            onPinch: { scale, ended in
                if pinchStartZoom == nil { pinchStartZoom = setup.zoom }
                recorder.setZoom(RacketZoomDial.pinched(from: pinchStartZoom ?? 1, scale: scale, caps), ramp: false)
                dialOpen = true
                if ended { pinchStartZoom = nil; dialTouch += 1 }
            })
            .frame(width: box.width, height: box.height)
            .accessibilityElement()
            .accessibilityLabel("Camera preview")
            .accessibilityValue(setup.locked ? "Focus and exposure locked" : "Auto focus")
            .accessibilityHint("Tap to focus and set the exposure there. Touch and hold to lock them.")
            .accessibilityIdentifier("racket.camera.preview")
            .accessibilityAction(named: "Focus on the centre") {
                focus(at: CGPoint(x: box.width / 2, y: box.height / 2), box: box, aspect: aspect, o: o, lock: false)
            }
            .accessibilityAction(named: setup.locked ? "Unlock focus and exposure" : "Lock focus and exposure") {
                if setup.locked { recorder.unlock(); focusAt = nil; lockCaption = false }
                else { focus(at: focusAt ?? CGPoint(x: box.width / 2, y: box.height / 2), box: box, aspect: aspect, o: o, lock: true) }
            }
            .accessibilityZoomAction { action in
                recorder.setZoom(RacketZoomDial.stepped(setup.zoom, up: action.direction == .zoomIn, caps), ramp: true)
            }
    }

    private func focus(at p: CGPoint, box: CGSize, aspect: CGFloat?, o: RacketCameraOrientation, lock: Bool) {
        let device = RacketFocusPoint.devicePoint(tap: p, in: box, videoAspect: aspect, orientation: o)
        recorder.focus(at: device, lock: lock)
        let shown = RacketFocusPoint.viewPoint(device: device, in: box, videoAspect: aspect, orientation: o)
        withAnimation(.easeOut(duration: 0.15)) {
            focusAt = shown
            lockCaption = lock
        }
        focusTouch += 1
        if lock {
            Task {
                try? await Task.sleep(for: .seconds(4))
                withAnimation { lockCaption = false }
            }
        }
    }

    private func focusOverlay(_ p: CGPoint, box: CGSize) -> some View {
        let side: CGFloat = 76
        let sliderLength: CGFloat = 120
        let onRight = p.x + side / 2 + 40 < box.width
        let sliderX = onRight ? p.x + side / 2 + 18 : p.x - side / 2 - 18
        let knob = RacketExposureBias.knobOffset(setup.exposureBias, length: Double(sliderLength))
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(cameraAmber, lineWidth: 1.5)
                .frame(width: side, height: side)
                .position(p)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel(setup.locked ? "Focus locked" : "Focus")
                .accessibilityIdentifier("racket.camera.focus")
            // The sun slider: drag up to brighten, down to darken.
            ZStack {
                Rectangle().fill(cameraAmber).frame(width: 1.5, height: sliderLength)
                ZStack {
                    Circle().fill(Color.black).frame(width: 24, height: 24)
                    Circle().strokeBorder(cameraAmber, lineWidth: 1.5).frame(width: 24, height: 24)
                    Image(systemName: "sun.max.fill").font(.system(size: 11)).foregroundStyle(cameraAmber)
                }
                .offset(y: knob)
            }
            .frame(width: 44, height: sliderLength + 24)
            .contentShape(Rectangle())
            .position(x: sliderX, y: p.y)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if biasStart == nil { biasStart = setup.exposureBias }
                    recorder.setExposureBias(RacketExposureBias.dragged(from: biasStart ?? 0, dy: v.translation.height))
                    focusTouch += 1
                }
                .onEnded { _ in biasStart = nil })
            .accessibilityElement()
            .accessibilityLabel("Brightness")
            .accessibilityValue(RacketExposureBias.label(setup.exposureBias))
            .accessibilityIdentifier("racket.camera.exposure")
            .accessibilityAdjustableAction { d in
                recorder.setExposureBias(RacketExposureBias.stepped(setup.exposureBias, up: d == .increment))
                focusTouch += 1
            }
        }
        .frame(width: box.width, height: box.height, alignment: .topLeading)
        .transition(.opacity)
    }

    // MARK: Chrome

    private var controls: some View {
        VStack(spacing: 0) {
            topBar
            if showLooks {
                Text("Preview only. The video saves as filmed.")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 12)
                    .accessibilityIdentifier("racket.camera.looksCaption")
            }
            Spacer(minLength: 0)
            if lockCaption {
                Text("Stays fixed when players move. Tap anywhere to unlock.")
                    .font(.system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 90)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("racket.camera.lockCaption")
            }
            if dialOpen, caps.maxZoom > caps.minZoom, !showLooks {
                Text("Pinch works too")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.bottom, 10)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("racket.camera.pinchHint")
            }
            bottomPanel
        }
        .foregroundStyle(Color.white)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("racket.camera.close")
            HStack(spacing: 6) {
                Circle().fill(pillColor).frame(width: 9, height: 9)
                Text(pill.text).font(.system(size: 14, weight: .semibold)).foregroundStyle(pillColor)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(pill.text)
            .accessibilityIdentifier("racket.camera.status")
            Spacer(minLength: 4)
            if setup.locked {
                Text("AE/AF LOCK").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.black)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(cameraAmber, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityIdentifier("racket.camera.lockBadge")
                Spacer(minLength: 4)
            }
            Button { showQuality = true } label: {
                Text(setup.format.label).font(.system(size: 15, weight: .bold))
                    .frame(minWidth: 44, minHeight: 44).padding(.horizontal, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(recorder.isCapturing)
            .accessibilityLabel("Video quality \(setup.format.label)")
            .accessibilityIdentifier("racket.camera.quality")
        }
        .padding(.leading, 4).padding(.trailing, 12)
        .padding(.top, safeTop)
        .background(Color.black.opacity(0.55))
    }

    private var safeTop: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.safeAreaInsets.top ?? 44
    }
    private var safeBottom: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.safeAreaInsets.bottom ?? 20
    }

    private var pillColor: Color {
        switch pill.tone {
        case .ready: return SnappetColor.perfFresh
        case .low: return SnappetColor.perfModerate
        case .full: return SnappetColor.perfHard
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: 14) {
            if showLooks {
                looksStrip
            } else {
                if dialOpen, caps.maxZoom > caps.minZoom { dial }
                lensRow
            }
            if !modes.isEmpty { modeStrip }
            HStack {
                thumbnailButton.frame(width: 72, alignment: .leading)
                Spacer()
                shutter
                Spacer()
                Button { showOptions = true } label: {
                    Text("Options").font(.system(size: 13, weight: .semibold))
                        .frame(width: 60, height: 60)
                        .background(Color.white.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .frame(width: 72, alignment: .trailing)
                .accessibilityIdentifier("racket.camera.options")
            }
            .padding(.horizontal, 24)
        }
        .padding(.top, 12)
        .padding(.bottom, max(12, safeBottom))
        .background(Color.black.opacity(0.55))
    }

    // MARK: Lenses and the dial

    private var lensRow: some View {
        let selected = RacketZoomDial.selectedLens(for: setup.zoom, caps)
        return HStack(spacing: 10) {
            ForEach(Array(caps.lenses.enumerated()), id: \.offset) { i, lens in
                let on = i == selected
                let text = RacketZoomDial.buttonText(lens: lens, selected: on, zoom: setup.zoom)
                Button {
                    // A drag across the lenses ends with a touch-up on a button (UIKit's generous touch-up area):
                    // that is the end of the drag, not a tap.
                    if dragStartZoom != nil { return }
                    if let t = lensDragEndedAt, Date().timeIntervalSince(t) < 0.4 { return }
                    recorder.setZoom(lens, ramp: true)
                    Haptics.tap()
                } label: {
                    Text(text)
                        .font(.system(size: on ? 13 : 12, weight: .bold)).monospacedDigit()
                        .foregroundStyle(on ? cameraAmber : Color.white)
                        .frame(width: on ? 40 : 34, height: on ? 40 : 34)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zoom \(on ? text : RacketZoomDial.label(lens))")
                .accessibilityIdentifier("racket.camera.lens.\(RacketZoomDial.number(lens))")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .background(Color.white.opacity(0.06), in: Capsule())
        // Drag across the lens buttons opens the dial and zooms (right zooms in).
        .simultaneousGesture(DragGesture(minimumDistance: 8)
            .onChanged { v in
                if dragStartZoom == nil { dragStartZoom = setup.zoom; withAnimation(.easeOut(duration: 0.2)) { dialOpen = true } }
                recorder.setZoom(RacketZoomDial.dragged(from: dragStartZoom ?? 1, dx: v.translation.width, caps), ramp: false)
            }
            .onEnded { _ in dragStartZoom = nil; lensDragEndedAt = Date(); dialTouch += 1 })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("racket.camera.lenses")
    }

    private var dial: some View {
        GeometryReader { g in
            let w = g.size.width
            let ticks = RacketZoomDial.ticks(caps)
            let at = RacketZoomDial.position(of: setup.zoom, caps) * w
            ZStack(alignment: .topLeading) {
                ForEach(Array(ticks.enumerated()), id: \.offset) { _, t in
                    let x = t.position * w
                    if let label = t.label {
                        Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white.opacity(0.8))
                            .fixedSize()
                            .position(x: x, y: 8)
                    }
                    Rectangle().fill(Color.white.opacity(t.label == nil ? 0.55 : 0.95))
                        .frame(width: t.label == nil ? 1 : 2, height: t.label == nil ? 8 : 16)
                        .position(x: x, y: t.label == nil ? 38 : 34)
                }
                Rectangle().fill(cameraAmber).frame(width: 2, height: 40).position(x: at, y: 28)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    recorder.setZoom(RacketZoomDial.zoom(atPosition: v.location.x / max(1, w), caps), ramp: false)
                    dialTouch += 1
                })
        }
        .frame(height: 50)
        .padding(.horizontal, 26)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 10)
        .accessibilityElement()
        .accessibilityLabel("Zoom")
        .accessibilityValue(RacketZoomDial.label(setup.zoom))
        .accessibilityIdentifier("racket.camera.dial")
        .accessibilityAdjustableAction { d in
            recorder.setZoom(RacketZoomDial.stepped(setup.zoom, up: d == .increment, caps), ramp: true)
            dialTouch += 1
        }
        .transition(.opacity)
    }

    // MARK: Mode strip, thumbnail, shutter

    private var modeStrip: some View {
        HStack(spacing: 26) {
            ForEach(modes, id: \.self) { m in
                let on = m == mode
                Button { mode = m; Haptics.tap() } label: {
                    Text(RacketCameraModeStrip.label(m, unit: unit))
                        .font(.system(size: 14, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(on ? cameraAmber : Color.white)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("racket.camera.mode.\(m.rawValue)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("racket.camera.modes")
    }

    @ViewBuilder private var thumbnailButton: some View {
        if let onVideos {
            Button(action: onVideos) {
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Image(systemName: "film.stack").font(.system(size: 18)).foregroundStyle(Color.white.opacity(0.75))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.white.opacity(0.08))
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Your videos")
            .accessibilityIdentifier("racket.camera.videos")
        } else {
            Color.clear.frame(width: 52, height: 52)
        }
    }

    private var shutter: some View {
        let enabled = pill.tone != .full
        return Button {
            showLooks = false
            Haptics.tap()
            onShutter()
        } label: {
            ZStack {
                Circle().strokeBorder(Color.white, lineWidth: 5).frame(width: 78, height: 78)
                Circle().fill(SnappetColor.perfHard).frame(width: 62, height: 62)
            }
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("Start recording")
        .accessibilityHint(enabled ? "" : "Not enough space on this phone to record.")
        .accessibilityIdentifier("racket.camera.shutter")
    }

    // MARK: Looks (preview only)

    private func openLooks() {
        withAnimation(.easeOut(duration: 0.2)) { showLooks = true; dialOpen = false }
        looksTouch += 1
    }

    private var looksStrip: some View {
        HStack(spacing: 8) {
            ForEach(RacketLook.allCases, id: \.self) { l in
                let on = l == setup.look
                Button {
                    recorder.setLook(l)
                    looksTouch += 1
                    Haptics.tap()
                } label: {
                    VStack(spacing: 6) {
                        RacketFakeCourtScene()
                            .modifier(RacketLookPreviewEffect(preview: RacketLookPreview(l)))
                            .frame(width: 60, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(on ? SnappetColor.brand : Color.white.opacity(0.25), lineWidth: on ? 2 : 1))
                        Text(l.label).font(.system(size: 13, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? SnappetColor.brand : Color.white)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(l.label) look")
                .accessibilityIdentifier("racket.camera.look.\(l.rawValue)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("racket.camera.looks")
        .transition(.opacity)
    }

    // MARK: While recording (prompt 256: ProCameraRecording → ProCameraSpace)

    @ViewBuilder private func liveMiddle(_ live: RacketCameraLive) -> some View {
        if let card = live.card {
            cardView(card).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let dim = live.dim {
            VStack(spacing: 6) {
                Text(dim.score).font(.system(size: 64, weight: .light)).monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityIdentifier(live.dimScoreID)
                Text(dim.caption).font(.system(size: 14)).foregroundStyle(SnappetColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier(live.dimCaptionID)
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let middle = live.middle {
            ScrollView { middle.padding(.horizontal, 16) }
                .padding(.top, safeTop + 64)
                .padding(.bottom, 230)
                .foregroundStyle(Color.white)
        }
    }

    private func liveControls(_ live: RacketCameraLive) -> some View {
        VStack(spacing: 0) {
            liveTopBar(live)
            if let b = live.banner, live.card == nil { bannerView(b).padding(.horizontal, 12).padding(.top, 10) }
            if let notice = live.notice {
                Text(notice).font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 12)
                    .accessibilityIdentifier("racket.camera.notice")
            }
            Spacer(minLength: 0)
            if lockCaption {
                Text("Stays fixed when players move. Tap anywhere to unlock.")
                    .font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.bottom, 16)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("racket.camera.lockCaption")
            }
            if live.card == nil { liveBottom(live) }
        }
        .foregroundStyle(Color.white)
    }

    private func toneColor(_ t: RacketCameraLive.Tone) -> Color {
        switch t {
        case .plain: return Color.white
        case .amber: return cameraAmber
        case .red: return SnappetColor.perfHard
        }
    }

    private func liveTopBar(_ live: RacketCameraLive) -> some View {
        HStack(spacing: 8) {
            Text(live.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(toneColor(live.titleTone))
                .lineLimit(1).minimumScaleFactor(0.75)
                .accessibilityIdentifier(live.titleID)
            Spacer(minLength: 4)
            if let c = live.centre { centreView(c) }
            Spacer(minLength: 4)
            if setup.locked {
                // AE/AF lock holds through the recording; the badge says so.
                Text("AE/AF").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.black)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(cameraAmber, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityLabel("AE/AF LOCK")
                    .accessibilityIdentifier("racket.camera.lockBadge")
            }
            qualityButton(locked: live.qualityLocked)
        }
        .padding(.horizontal, 14)
        .padding(.top, safeTop)
        .frame(minHeight: 44 + safeTop)
        .background(Color.black.opacity(0.55))
    }

    @ViewBuilder private func centreView(_ c: RacketCameraLive.Centre) -> some View {
        switch c {
        case .timer(let text, let a11y, let id):
            Text(text).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(Color.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(SnappetColor.perfHard, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(a11y)
                .accessibilityValue(text)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier(id)
        case .amber(let text, let id):
            Text(text).font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(cameraAmber)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityIdentifier(id)
        case .stopped(let text, let id):
            Text(text).font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(SnappetColor.perfHard)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityIdentifier(id)
        }
    }

    private func qualityButton(locked: Bool) -> some View {
        Button { showQuality = true } label: {
            Text(setup.format.label).font(.system(size: 15, weight: .bold))
                .foregroundStyle(locked ? Color.white.opacity(0.4) : Color.white)
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked || recorder.isCapturing)
        .accessibilityLabel("Video quality \(setup.format.label)")
        .accessibilityHint(locked ? "Locked while recording" : "")
        .accessibilityIdentifier("racket.camera.quality")
    }

    private func bannerView(_ b: RacketCameraLive.Banner) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(b.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(toneColor(b.tone))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(b.id)
            if let line = b.line {
                Text(line).font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(b.id).line")
            }
            if b.primary != nil || b.secondary != nil {
                HStack(spacing: 8) {
                    if let p = b.primary { bannerButton(p, primary: true) }
                    if let s = b.secondary { bannerButton(s, primary: false) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(toneColor(b.tone).opacity(0.8)))
        .accessibilityElement(children: .contain)
        .onAppear { AccessibilityNotification.Announcement(b.title).post() }
    }

    private func bannerButton(_ a: RacketCameraLive.Action, primary: Bool) -> some View {
        Button(action: a.action) {
            Text(a.label ?? a.title).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(primary ? Color.black : Color.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(primary ? SnappetColor.brand : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!a.enabled)
        .opacity(a.enabled ? 1 : 0.5)
        .accessibilityIdentifier(a.id)
    }

    private func cardView(_ c: RacketCameraLive.Card) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(c.title).font(.system(size: 18, weight: .bold)).foregroundStyle(SnappetColor.perfHard)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("racket.camera.stopTitle")
            Text(c.line).font(.system(size: 14)).foregroundStyle(SnappetColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("racket.camera.stopLine")
            if let p = c.primary {
                Button(action: p.action) { Text(p.label ?? p.title).frame(maxWidth: .infinity, minHeight: 30) }
                    .buttonStyle(SnappetWidePrimaryStyle())
                    .disabled(!p.enabled)
                    .accessibilityIdentifier(p.id)
            }
            if let sec = c.secondary {
                RacketWideButton(sec.title, id: sec.id, primary: false, action: sec.action)
            }
        }
        .padding(16)
        .background(Color(white: 0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(SnappetColor.hairline))
        .padding(.horizontal, 24)
        .foregroundStyle(Color.white)
        .onAppear { AccessibilityNotification.Announcement(c.title).post() }
    }

    private func liveBottom(_ live: RacketCameraLive) -> some View {
        VStack(spacing: 14) {
            // The boards drop the lenses while a banner (warm, interrupted, low space) asks for attention; pinch still zooms.
            if live.showsLenses, live.showsPicture, live.banner == nil {
                if dialOpen, caps.maxZoom > caps.minZoom { dial }
                lensRow
            }
            if let a = live.above {
                Button(action: a.action) {
                    Text(a.title).font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SnappetColor.hairline))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .accessibilityIdentifier(a.id)
            }
            liveStrip(live)
            HStack {
                Group {
                    if live.thumbnailAndOptions { thumbnailButton } else if let l = live.left { circleButton(l, light: false) }
                    else { Color.clear.frame(width: 52, height: 52) }
                }
                .frame(width: 72, alignment: .leading)
                Spacer()
                liveShutter(live)
                Spacer()
                Group {
                    if live.thumbnailAndOptions { optionsButton } else if let r = live.right { circleButton(r, light: true) }
                    else { Color.clear.frame(width: 52, height: 52) }
                }
                .frame(width: 72, alignment: .trailing)
            }
            .padding(.horizontal, 24)
        }
        .padding(.top, 12)
        .padding(.bottom, max(12, safeBottom))
        .background(live.showsPicture ? Color.black.opacity(0.55) : Color.clear)
    }

    @ViewBuilder private func liveStrip(_ live: RacketCameraLive) -> some View {
        if let views = live.views {
            HStack(spacing: 30) {
                ForEach(RacketRecordingShow.allCases, id: \.self) { v in
                    let on = views.wrappedValue == v
                    Button { views.wrappedValue = v; Haptics.tap() } label: {
                        Text(v.label.uppercased()).font(.system(size: 14, weight: .semibold)).tracking(0.6)
                            .foregroundStyle(on ? cameraAmber : Color.white)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(v.label)
                    .accessibilityIdentifier("\(live.viewIDPrefix).\(v.rawValue)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(live.viewIDPrefix)
        } else if !live.stripActions.isEmpty {
            HStack(spacing: 26) {
                ForEach(Array(live.stripActions.enumerated()), id: \.offset) { _, a in
                    Button(action: { a.action(); Haptics.tap() }) {
                        Text(a.title).font(.system(size: 14, weight: .semibold)).tracking(0.4)
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!a.enabled)
                    .accessibilityLabel(a.label ?? a.title)
                    .accessibilityIdentifier(a.id)
                }
            }
        }
    }

    private func circleButton(_ a: RacketCameraLive.Action, light: Bool) -> some View {
        Button(action: { a.action(); Haptics.tap() }) {
            Text(a.title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(light ? Color.black : Color.white)
                .frame(width: 54, height: 54)
                .background(light ? Color.white.opacity(0.92) : Color.white.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!a.enabled)
        .opacity(a.enabled ? 1 : 0.45)
        .accessibilityLabel(a.label ?? a.title)
        .accessibilityIdentifier(a.id)
    }

    private var optionsButton: some View {
        Button { showOptions = true } label: {
            Text("Options").font(.system(size: 13, weight: .semibold))
                .frame(width: 60, height: 60)
                .background(Color.white.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("racket.camera.options")
    }

    private func liveShutter(_ live: RacketCameraLive) -> some View {
        let a = live.shutter
        return Button(action: { Haptics.tap(); a.action() }) {
            ZStack {
                Circle().strokeBorder(Color.white, lineWidth: 5).frame(width: 78, height: 78)
                if live.shutterStops {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SnappetColor.perfHard).frame(width: 32, height: 32)
                } else {
                    Circle().fill(SnappetColor.perfHard).frame(width: 62, height: 62)
                }
            }
            .opacity(a.enabled ? 1 : 0.4)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!a.enabled)
        .accessibilityLabel(a.label ?? a.title)
        .accessibilityIdentifier(a.id)
    }

    // MARK: Sideways (ProCameraLandscape): status and quality on the left, the controls down the right edge

    private var landscapeControls: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                if let live {
                    qualityButton(locked: live.qualityLocked)
                    Spacer(minLength: 0)
                    if let c = live.centre { centreView(c) }
                    Text(live.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(toneColor(live.titleTone))
                        .lineLimit(2).minimumScaleFactor(0.7)
                        .accessibilityIdentifier(live.titleID)
                    if let views = live.views {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(RacketRecordingShow.allCases, id: \.self) { v in
                                Button { views.wrappedValue = v } label: {
                                    Text(v.label.uppercased()).font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(views.wrappedValue == v ? cameraAmber : Color.white)
                                        .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("\(live.viewIDPrefix).\(v.rawValue)")
                                .accessibilityAddTraits(views.wrappedValue == v ? .isSelected : [])
                            }
                        }
                    }
                } else {
                    Button { showQuality = true } label: {
                        Text(setup.format.label).font(.system(size: 15, weight: .bold))
                            .frame(minWidth: 44, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Video quality \(setup.format.label)")
                    .accessibilityIdentifier("racket.camera.quality")
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Circle().fill(pillColor).frame(width: 9, height: 9)
                        Text(pill.text.components(separatedBy: " · ").first ?? pill.text)
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(pillColor)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(pill.text)
                    .accessibilityIdentifier("racket.camera.status")
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("racket.camera.close")
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .frame(width: 120, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(Color.black.opacity(0.55))
            Spacer(minLength: 0)
            if let b = live?.banner, live?.card == nil {
                bannerView(b).frame(maxWidth: 380).padding(.top, 12).frame(maxHeight: .infinity, alignment: .top)
                Spacer(minLength: 0)
            }
            if live?.showsPicture ?? true, live?.showsLenses ?? true {
                VStack(spacing: 8) {
                    ForEach(Array(caps.lenses.enumerated().reversed()), id: \.offset) { i, lens in
                        let on = i == RacketZoomDial.selectedLens(for: setup.zoom, caps)
                        let text = RacketZoomDial.buttonText(lens: lens, selected: on, zoom: setup.zoom)
                        Button { recorder.setZoom(lens, ramp: true) } label: {
                            Text(text).font(.system(size: 12, weight: .bold)).monospacedDigit()
                                .foregroundStyle(on ? cameraAmber : Color.white)
                                .frame(width: 38, height: 38)
                                .background(Color.black.opacity(0.55), in: Circle())
                                .frame(width: 44, height: 44).contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Zoom \(on ? text : RacketZoomDial.label(lens))")
                        .accessibilityIdentifier("racket.camera.lens.\(RacketZoomDial.number(lens))")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.trailing, 8)
            }
            VStack {
                if let live {
                    if live.thumbnailAndOptions { optionsButton } else if let r = live.right { circleButton(r, light: true) }
                    Spacer(minLength: 0)
                    liveShutter(live)
                    Spacer(minLength: 0)
                    if live.thumbnailAndOptions { thumbnailButton } else if let l = live.left { circleButton(l, light: false) }
                } else {
                    optionsButton
                    Spacer(minLength: 0)
                    shutter
                    Spacer(minLength: 0)
                    thumbnailButton
                }
            }
            .padding(.vertical, 16)
            .frame(width: 100)
            .frame(maxHeight: .infinity)
            .background(Color.black.opacity(0.55))
        }
        .foregroundStyle(Color.white)
    }
}

// MARK: - The look on the live preview

/// The compositor's colour effects for a look (`RacketLookPreview`): preview only, never recorded. Always the same
/// modifiers (neutral for Original), so changing the look never rebuilds the preview view under it.
struct RacketLookPreviewEffect: ViewModifier {
    let preview: RacketLookPreview
    func body(content: Content) -> some View {
        content
            .saturation(preview.saturation)
            .contrast(preview.contrast)
            .brightness(preview.brightness)
            .colorMultiply(Color(red: preview.red, green: preview.green, blue: preview.blue))
    }
}

// MARK: - Overlays

/// Thirds.
struct RacketCameraGrid: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3, y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.45), lineWidth: 0.75)
        }
    }
}

/// The level: a line across the middle that turns with the horizon, green when the phone is square.
struct RacketLevelLine: View {
    let tilt: Double?
    var body: some View {
        let level = RacketLevel.isLevel(tilt)
        Rectangle()
            .fill(level ? SnappetColor.perfFresh : Color.white.opacity(0.85))
            .frame(width: 110, height: 2)
            .rotationEffect(.degrees(-(tilt ?? 0)))
            .opacity(tilt == nil ? 0 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement()
            .accessibilityLabel(level ? "Level" : "Not level")
            .accessibilityIdentifier("racket.camera.level")
    }
}

/// The fake camera's picture (simulator, UI tests): a code-drawn court so the screen, the zoom and the looks can be
/// seen. Not a recording, not footage.
struct RacketFakeCourtScene: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                Color(red: 0.12, green: 0.13, blue: 0.16)
                ForEach([0.09, 0.91], id: \.self) { x in
                    Circle().fill(Color(white: 0.4)).frame(width: w * 0.05, height: w * 0.05)
                        .position(x: w * x, y: h * 0.25)
                    Capsule().fill(Color(white: 0.3)).frame(width: w * 0.08, height: h * 0.34)
                        .position(x: w * x, y: h * 0.45)
                }
                Rectangle().fill(Color(red: 0.15, green: 0.39, blue: 0.66))
                    .frame(width: w * 0.8, height: h * 0.1).position(x: w * 0.5, y: h * 0.57)
                ForEach([0.16, 0.84], id: \.self) { x in
                    Rectangle().fill(Color(red: 0.15, green: 0.39, blue: 0.66)).frame(width: 3, height: h * 0.3)
                        .position(x: w * x, y: h * 0.77)
                }
                Rectangle().fill(Color.white).frame(width: 3, height: h * 0.12).position(x: w * 0.5, y: h * 0.48)
                Circle().fill(Color(red: 1, green: 0.62, blue: 0.4)).frame(width: 9, height: 9)
                    .position(x: w * 0.35, y: h * 0.34)
            }
        }
    }
}

/// UIKit's tap, touch-and-hold and pinch, with the touch point: SwiftUI's long press gives no location, and the tap
/// must wait for the hold to fail (a touch held still is a lock, not a focus).
struct RacketCameraGestureLayer: UIViewRepresentable {
    let onTap: (CGPoint) -> Void
    let onHold: (CGPoint) -> Void
    let onPinch: (Double, Bool) -> Void

    final class Coordinator: NSObject {
        var parent: RacketCameraGestureLayer
        init(_ p: RacketCameraGestureLayer) { parent = p }
        @objc func tap(_ r: UITapGestureRecognizer) { parent.onTap(r.location(in: r.view)) }
        @objc func hold(_ r: UILongPressGestureRecognizer) {
            if r.state == .began { parent.onHold(r.location(in: r.view)) }
        }
        @objc func pinch(_ r: UIPinchGestureRecognizer) {
            switch r.state {
            case .began, .changed: parent.onPinch(Double(r.scale), false)
            case .ended, .cancelled, .failed: parent.onPinch(Double(r.scale), true)
            default: break
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.6
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: hold)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        [hold, tap, pinch].forEach(v.addGestureRecognizer)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }
}

// MARK: - Video quality (ProCameraQuality)

struct RacketCameraQualityPage: View {
    let recorder: RacketRecorder
    let freeBytes: Int64
    let onDone: () -> Void

    @AppStorage(RacketRecordingDefaults.storageKey) private var defaultsData = Data()
    @State private var chosen: RacketCameraFormat?
    @State private var everyMatch = false

    private var current: RacketCameraFormat { chosen ?? recorder.setup.format }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(recorder.capabilities.formats, id: \.self) { f in row(f) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Estimates for this phone").font(.system(size: 15, weight: .semibold))
                        Text(RacketQualityEstimate.footnote(freeBytes: freeBytes))
                            .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("racket.camera.qualityFootnote")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SnappetColor.hairline))
                    Button { everyMatch.toggle(); Haptics.tap() } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Use for every match").font(.system(size: 15, weight: .semibold))
                                Text("Off: this match only").font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                            }
                            Spacer()
                            RacketCheckbox(on: everyMatch)
                        }
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SnappetColor.hairline))
                    .accessibilityIdentifier("racket.camera.everyMatch")
                    .accessibilityAddTraits(everyMatch ? .isSelected : [])
                    Text("Rally finding works the same at every quality.")
                        .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                        .accessibilityIdentifier("racket.camera.qualityRallyLine")
                }
                .padding(16)
            }
            .background(Color.black)
            .navigationTitle("Video quality")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back", action: onDone).accessibilityIdentifier("racket.camera.qualityBack")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { apply(); onDone() }.accessibilityIdentifier("racket.camera.qualityDone")
                }
            }
        }
        .preferredColorScheme(.dark)
        // Off each time the page opens ("Off: this match only"); on, Done also saves the pick as the default.
    }

    private func apply() {
        recorder.setFormat(current)
        if everyMatch {
            var d = RacketRecordingDefaults.load(from: defaultsData)
            d.quality = current.quality
            d.fps = current.fps
            defaultsData = d.encoded ?? defaultsData
        }
    }

    private func row(_ f: RacketCameraFormat) -> some View {
        let on = f == current
        let estimate = RacketQualityEstimate(format: f, freeBytes: freeBytes, codec: recorder.codec)
        return Button { chosen = f; Haptics.tap() } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(f.rowTitle).font(.system(size: 16, weight: .bold))
                    Spacer(minLength: 8)
                    Text(estimate.line).font(SnappetType.detail.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                        .accessibilityIdentifier("racket.camera.qualityLine.\(f.key)")
                }
                if let note = f.heatNote {
                    Text(note).font(.system(size: 13, weight: .semibold)).foregroundStyle(SnappetColor.perfModerate)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(on ? SnappetColor.brand.opacity(0.18) : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(on ? SnappetColor.brand : SnappetColor.hairline, lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("racket.camera.quality.\(f.key)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The boards' square checkbox.
struct RacketCheckbox: View {
    let on: Bool
    var enabled = true
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(on ? SnappetColor.brand : Color.white.opacity(enabled ? 1 : 0.85))
                .frame(width: 24, height: 24)
            if on {
                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.black)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Options (ProCameraOptions)

struct RacketCameraOptionsSheet: View {
    @Binding var framing: RacketFraming
    var firstServer: Binding<RacketServe.Side?>?
    var ourFirstServer: Binding<RacketDoublesServe.Player?>?
    let sides: (us: String, them: String)
    let partnerName: String
    @Binding var show: RacketRecordingShow
    @Binding var useWatch: Bool
    let watchAvailable: Bool
    var extra: AnyView? = nil
    let onDone: () -> Void
    let onLooks: () -> Void
    let onCompareQuality: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Options").font(.system(size: 17, weight: .bold))
                    Spacer()
                    Button("Done", action: onDone).font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SnappetColor.brand)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("racket.camera.optionsDone")
                }
                if let extra { extra }
                label("Framing")
                HStack(spacing: 8) {
                    toggleChip("Grid", on: framing.grid, id: "grid") { framing.grid.toggle() }
                    toggleChip("Level", on: framing.level, id: "level") { framing.level.toggle() }
                    toggleChip("Court guide", on: framing.courtGuide, id: "courtGuide") { framing.courtGuide.toggle() }
                }
                if let firstServer {
                    label("Who serves first? Optional")
                    RacketChips(options: ["us", "them", "skip"],
                                label: { $0 == "us" ? sides.us : $0 == "them" ? sides.them : "Skip" },
                                selection: Binding(get: { firstServer.wrappedValue?.rawValue ?? "skip" },
                                                   set: { firstServer.wrappedValue = RacketServe.Side(rawValue: $0) }),
                                idPrefix: "racket.camera.serve")
                }
                if let ourFirstServer {
                    label("Who serves first for us? Optional")
                    RacketChips(options: ["you", "partner", "skip"],
                                label: { $0 == "you" ? "You" : $0 == "partner" ? partnerName : "Skip" },
                                selection: Binding(get: { ourFirstServer.wrappedValue?.rawValue ?? "skip" },
                                                   set: { ourFirstServer.wrappedValue = RacketDoublesServe.Player(rawValue: $0) }),
                                idPrefix: "racket.camera.ourServe")
                }
                label("While playing, show")
                RacketChips(options: RacketRecordingShow.allCases, label: { $0.label }, selection: $show,
                            idPrefix: "racket.camera.show", idFor: { $0.rawValue })
                Button { if watchAvailable { useWatch.toggle(); Haptics.tap() } } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start and score from your Watch").font(.system(size: 15, weight: .semibold))
                            Text(watchAvailable ? (useWatch ? "Watch linked" : "Off for this match") : "No Apple Watch linked")
                                .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                        }
                        Spacer()
                        RacketCheckbox(on: watchAvailable && useWatch, enabled: watchAvailable)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!watchAvailable)
                .accessibilityIdentifier("racket.camera.options.watch")
                .accessibilityAddTraits(watchAvailable && useWatch ? .isSelected : [])
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live tracking").font(.system(size: 15, weight: .semibold))
                        Text(RacketFeatureState.notAvailableYet.label).font(SnappetType.detail)
                            .foregroundStyle(SnappetColor.textSecondary)
                    }
                    Spacer()
                    RacketCheckbox(on: false, enabled: false)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityRemoveTraits(.isSelected)
                .accessibilityValue("Off")
                .accessibilityIdentifier("racket.camera.options.tracking")
                .disabled(true)
                HStack {
                    Button("Looks", action: onLooks).accessibilityIdentifier("racket.camera.options.looks")
                    Spacer()
                    Button("Compare quality", action: onCompareQuality)
                        .accessibilityIdentifier("racket.camera.options.compareQuality")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SnappetColor.brand)
                .frame(minHeight: 44)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 14, weight: .semibold)).foregroundStyle(SnappetColor.textSecondary)
    }

    private func toggleChip(_ title: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button { action(); Haptics.tap() } label: {
            Text(title).font(.system(size: 14, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? SnappetColor.brand : SnappetColor.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(on ? SnappetColor.brand.opacity(0.14) : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(on ? SnappetColor.brand : SnappetColor.hairline, lineWidth: 1.2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("racket.camera.framing.\(id)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - No access (ProCameraDenied)

struct RacketCameraDeniedView: View {
    let onClose: () -> Void
    let onPlayWithoutVideo: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.white)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("racket.camera.close")
            .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 12) {
                Text("Snappet can’t use the camera").font(.system(size: 19, weight: .bold))
                    .accessibilityIdentifier("racket.camera.denied")
                Text("Recording needs the camera, and saving needs Photos. Nothing else on your phone is read.")
                    .font(.system(size: 15)).foregroundStyle(SnappetColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: { Text("Open Settings").frame(maxWidth: .infinity, minHeight: 30) }
                    .buttonStyle(SnappetWidePrimaryStyle())
                    .accessibilityIdentifier("racket.camera.openSettings")
                RacketWideButton("Play without video", id: "racket.camera.playWithoutVideo", primary: false,
                                 action: onPlayWithoutVideo)
            }
            .padding(16)
            .background(Color(white: 0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(SnappetColor.hairline))
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(Color.white)
    }
}
