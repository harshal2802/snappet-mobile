import SwiftUI
import UIKit

/// Share a festival lineup — or your starred-set plan — with a friend who has Snappet (festival prompt
/// 05, wireframe frame 12). A segmented **My Code / Scan** sheet, the `RoutineShareView` shape:
///
///   • **My Code** carries a plan/lineup toggle. A small subject (a day plan) renders a pure
///     black-on-white QR that carries the whole thing *in the code* (`snappet://festival/v1/<blob>`) —
///     scannable in a field with no signal; a whole festival, too dense to scan, automatically falls
///     back to an **install-link QR** (`SharedLineup.scannableForm`) plus a `ShareLink` for AirDrop.
///   • **Scan** opens the shared camera scanner to receive a code someone else is showing — the host
///     routes the decoded value to the import-confirm preview.
///
/// All the payload-vs-link math is the pure `SharedLineup`; this view renders it.
struct FestivalShareView: View {
    let pack: FestivalPack
    let lineupName: String
    let starredSetIDs: Set<UUID>
    /// Where the sheet opens: from the schedule's ⋯ "Share my plan" vs "Share this lineup" vs "Scan".
    var start: Start = .plan
    /// Called with a lineup/plan scanned in the "Scan" tab — the host routes it to import-confirm.
    let onScan: (SharedLineup) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode
    @State private var subject: Subject

    enum Start { case plan, lineup, scan }

    init(pack: FestivalPack, lineupName: String, starredSetIDs: Set<UUID>,
         start: Start = .plan, onScan: @escaping (SharedLineup) -> Void) {
        self.pack = pack
        self.lineupName = lineupName
        self.starredSetIDs = starredSetIDs
        self.start = start
        self.onScan = onScan
        _mode = State(initialValue: start == .scan ? .scan : .myCode)
        _subject = State(initialValue: start == .lineup ? .lineup : .plan)
    }

    private enum Mode: String, CaseIterable, Identifiable {
        case myCode, scan
        var id: String { rawValue }
        var label: String { self == .myCode ? "My Code" : "Scan" }
    }

    private enum Subject: String, CaseIterable, Identifiable {
        case plan, lineup
        var id: String { rawValue }
        var label: String { self == .plan ? "My plan" : "Whole lineup" }
    }

    private var planTitle: String { "My \(lineupName) plan" }

    /// The value to render: the chosen subject, resolved through the payload-vs-link cliff.
    private var shared: SharedLineup {
        switch subject {
        case .plan:  return SharedLineup.plan(from: pack, starredSetIDs: starredSetIDs, title: planTitle)
                        .scannableForm()
        case .lineup: return SharedLineup.lineup(from: pack, title: lineupName).scannableForm()
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .accessibilityIdentifier("festival.share.modePicker")

                switch mode {
                case .myCode: myCode
                case .scan:
                    SnappetScannerView(
                        prompt: "Point at a friend's Snappet lineup QR code.",
                        foreignHint: "That isn't a Snappet lineup code.",
                        decode: { SharedLineup(decoding: $0) },
                        onScan: { decoded in onScan(decoded); dismiss() })
                        .accessibilityIdentifier("festival.scanner")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 16)
            .navigationTitle("Share lineup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .presentationDetents([.large])
        }
    }

    @ViewBuilder private var myCode: some View {
        VStack(spacing: 14) {
            Picker("Subject", selection: $subject) {
                ForEach(Subject.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .accessibilityIdentifier("festival.share.subjectPicker")

            if subject == .plan && starredSetIDs.isEmpty {
                ContentUnavailableView {
                    Label("No plan yet", systemImage: "star")
                } description: {
                    Text("Star the sets you want to catch, then share your plan as a code.")
                }
            } else {
                codeCard
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder private var codeCard: some View {
        let shared = shared
        VStack(spacing: 14) {
            Text(subject == .plan ? planTitle : lineupName)
                .font(.headline).multilineTextAlignment(.center)

            if let image = QRCodeImage.make(for: shared.encoded) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 260)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("QR code for \(subject == .plan ? planTitle : lineupName)")
                    .accessibilityIdentifier("festival.share.qr")
            }

            // Honest about which form the code is: in-the-code (offline) vs an install link (fetch).
            switch shared.content {
            case .payload:
                Label("The lineup is in the code — scanning works with no signal.",
                      systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("festival.share.formNote")
            case .installLink:
                Label("Too big for a code — this shares an install link your friend fetches once.",
                      systemImage: "arrow.down.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("festival.share.formNote")
            }

            if let url = shared.url {
                ShareLink(item: url, subject: Text(subject == .plan ? planTitle : lineupName),
                          message: Text("A festival lineup from Snappet")) {
                    Label("Share link", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(SnappetColor.festival)
                .accessibilityIdentifier("festival.share.link")
            }
        }
    }
}
