import AppKit

// Renders Snappet "S" monogram app-icon candidates: full-bleed gradient + white rounded S.
// 1024x1024, opaque (no alpha) PNG — App Store compliant. Xcode applies the corner mask.

struct Palette { let name: String; let top: NSColor; let bottom: NSColor }

func c(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
}

let palettes = [
    Palette(name: "A-orange-pink", top: c(255, 149, 43),  bottom: c(245, 39, 122)),  // amber → magenta-pink
    Palette(name: "B-coral-magenta", top: c(255, 94, 87), bottom: c(214, 31, 145)),  // coral → magenta
    Palette(name: "C-sunset", top: c(255, 178, 36),       bottom: c(255, 61, 92)),   // gold → warm red
    Palette(name: "D-violet-pink", top: c(124, 58, 237),  bottom: c(255, 45, 120)),  // violet → pink
]

let size = 1024
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/snappet-icons"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Rounded, black-weight S
func roundedFont(_ pt: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: pt, weight: .black)
    if let d = base.fontDescriptor.withDesign(.rounded) {
        return NSFont(descriptor: d, size: pt) ?? base
    }
    return base
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!

for p in palettes {
    // RGB, no alpha (noneSkipLast) → opaque output, App Store compliant.
    guard let cg = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }

    let ctx = NSGraphicsContext(cgContext: cg, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let full = NSRect(x: 0, y: 0, width: size, height: size)

    // Diagonal gradient background (top-left light → bottom-right deep)
    let grad = NSGradient(colors: [p.top, p.bottom])!
    grad.draw(in: NSBezierPath(rect: full), angle: -45)

    // Subtle top sheen for depth
    let sheen = NSGradient(colors: [NSColor(white: 1, alpha: 0.18), NSColor(white: 1, alpha: 0)])!
    sheen.draw(in: NSBezierPath(rect: full), angle: -90)

    // The "S"
    let font = roundedFont(700)
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.18)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .paragraphStyle: para,
        .shadow: shadow,
    ]
    let s = NSAttributedString(string: "S", attributes: attrs)
    let bounds = s.boundingRect(with: NSSize(width: size, height: size),
                                options: [.usesLineFragmentOrigin, .usesFontLeading])
    // Optical centering
    let x = (CGFloat(size) - bounds.width) / 2 - bounds.minX
    let y = (CGFloat(size) - bounds.height) / 2 - bounds.minY - 8
    s.draw(at: NSPoint(x: x, y: y))

    NSGraphicsContext.restoreGraphicsState()

    guard let img = cg.makeImage() else { continue }
    let path = "\(outDir)/snappet-\(p.name).png"
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { continue }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path)")
}
