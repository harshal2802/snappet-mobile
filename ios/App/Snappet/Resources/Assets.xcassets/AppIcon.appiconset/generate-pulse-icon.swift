import AppKit
import UniformTypeIdentifiers

// Renders the Snappet "Pulse" app icon — the same `waveform.path.ecg` brand mark the app shows in its
// loading view (#77) — in the three iOS 18 appearance slots: light (coral, opaque, App-Store-compliant),
// dark (coral mark on near-black), and tinted (grayscale; iOS applies the user's tint). 1024×1024.
//   swift generate-pulse-icon.swift .

func c(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let size = 1024
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

/// Draw the brand symbol, tinted, centred at `fraction` of the canvas.
func drawMark(into cg: CGContext, color: NSColor, fraction: CGFloat) {
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.42, weight: .semibold)
    guard let base = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil),
          let sym = base.withSymbolConfiguration(config) else { return }
    sym.isTemplate = true
    // Tint the template glyph (draw, then composite the colour sourceAtop).
    let tinted = NSImage(size: sym.size)
    tinted.lockFocus()
    sym.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    color.set()
    NSRect(origin: .zero, size: sym.size).fill(using: .sourceAtop)
    tinted.unlockFocus()

    let target = CGFloat(size) * fraction
    let aspect = sym.size.width / sym.size.height
    let w = aspect >= 1 ? target : target * aspect
    let h = aspect >= 1 ? target / aspect : target
    let rect = NSRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h)

    let ctx = NSGraphicsContext(cgContext: cg, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    tinted.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!

enum Variant { case light, dark, tinted }
func render(_ variant: Variant, filename: String) {
    // Light must be opaque (App Store); dark/tinted carry alpha.
    let alphaInfo: CGImageAlphaInfo = variant == .light ? .noneSkipLast : .premultipliedLast
    guard let cg = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                             bytesPerRow: 0, space: cs, bitmapInfo: alphaInfo.rawValue) else { return }
    let full = CGRect(x: 0, y: 0, width: size, height: size)

    switch variant {
    case .light:
        // Coral diagonal gradient + a soft top sheen, then a white mark.
        let ns = NSGraphicsContext(cgContext: cg, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        NSGradient(colors: [c(0xFF7A6B), c(0xF2761E)])!.draw(in: NSBezierPath(rect: full), angle: -45)
        NSGradient(colors: [NSColor(white: 1, alpha: 0.16), NSColor(white: 1, alpha: 0)])!
            .draw(in: NSBezierPath(rect: full), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        drawMark(into: cg, color: .white, fraction: 0.62)
    case .dark:
        cg.setFillColor(c(0x1E1E22).cgColor); cg.fill(full)
        drawMark(into: cg, color: c(0xFF7A6B), fraction: 0.62)
    case .tinted:
        // Grayscale on transparent: iOS composites the user's tint over the luminance.
        drawMark(into: cg, color: NSColor(white: 0.92, alpha: 1), fraction: 0.62)
    }

    guard let img = cg.makeImage() else { return }
    let url = URL(fileURLWithPath: "\(outDir)/\(filename)")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(filename)")
}

render(.light, filename: "AppIcon.png")
render(.dark, filename: "AppIcon-Dark.png")
render(.tinted, filename: "AppIcon-Tinted.png")
