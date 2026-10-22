import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// **Share → Snappet** (prompt 201): a photo or screenshot holding a Snappet QR code (a climb, a routine, a lineup,
/// a workout link) opens the app on it. The code is read on-device (`QRImageDecoder`, downscaled for the extension's
/// memory limit) and picked by `SnappetCodeImport`. iOS gives share extensions no API to open their app, so it's
/// opened through the app object on the responder chain; when that doesn't work, the link waits in the App-Group
/// action inbox and runs the next time Snappet opens.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareCodeView(model: model, done: { [weak self] in self?.finish() }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await read() }
    }

    private func read() async {
        guard let data = await imageData() else { return model.state = .failed(.noCode) }
        let payloads = await QRImageDecoder.payloads(in: data, maxPixelSize: 3000)
        switch SnappetCodeImport.pick(payloads, decode: { _ -> String? in nil }) {
        case .value: break   // unreachable: the share sheet has no kind of its own
        case .otherLink(let link):
            let what = SnappetCodeImport.describe(link)
            model.state = .opening(what)
            if let url = URL(string: link), await openApp(url) {
                finish()
            } else {
                AppActionInbox.enqueue(.openLink(link))
                model.state = .saved(what)
            }
        case .failure(let why):
            model.state = .failed(why)
        }
    }

    /// The first shared image's bytes (a file URL, raw data or a `UIImage`, whichever the source app hands over).
    private func imageData() async -> Data? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) })
        else { return nil }
        return await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                done.resume(returning: data)
            }
        }
    }

    /// `UIApplication.open` is unavailable to extensions at compile time, but the extension's app object is on the
    /// responder chain and still answers it. Calls back with whether iOS opened the URL.
    private func openApp(_ url: URL) async -> Bool {
        var responder: UIResponder? = self
        while let r = responder, !(r is UIApplication) { responder = r.next }
        guard let app = responder else { return false }
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        guard app.responds(to: selector) else { return false }
        typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
        let open = unsafeBitCast(app.method(for: selector), to: Open.self)
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            open(app, selector, url as NSURL, NSDictionary(), { ok in done.resume(returning: ok) })
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@MainActor @Observable
final class ShareModel {
    enum State: Equatable {
        case reading
        case opening(String)
        case saved(String)
        case failed(SnappetCodeImport.Failure)
    }
    var state: State = .reading
}

/// The share sheet's card: reading → opening (gone in a moment) · saved for the next open · why it didn't work.
struct ShareCodeView: View {
    let model: ShareModel
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 72, height: 72)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text(title).font(.title3.weight(.bold)).multilineTextAlignment(.center)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.state == .reading || isOpening {
                ProgressView()
            } else {
                Button(action: done) {
                    Text("Done").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(Color(red: 1, green: 0.35, blue: 0.24))
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private var isOpening: Bool { if case .opening = model.state { true } else { false } }

    private var symbol: String {
        switch model.state {
        case .reading: "qrcode.viewfinder"
        case .opening, .saved: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        if case .failed = model.state { return .orange }
        return Color(red: 1, green: 0.35, blue: 0.24)
    }

    private var title: String {
        switch model.state {
        case .reading: "Reading the code…"
        case .opening: "Opening Snappet…"
        case .saved: "Saved for Snappet"
        case .failed(.noCode): "No QR code found"
        case .failed(.notSnappet): "Not a Snappet code"
        }
    }

    private var detail: String {
        switch model.state {
        case .reading: "Looking for a Snappet QR code in this photo. Nothing leaves your phone."
        case .opening(let what): "Found \(what)."
        case .saved(let what): "Found \(what). Open Snappet and it'll be waiting for you."
        case .failed(let why): why.message
        }
    }
}
