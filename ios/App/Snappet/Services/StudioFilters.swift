import CoreImage

/// Maps a `StudioFilter` (+ 0…1 intensity) to a configured `CIFilter` — the colour treatment the
/// `StudioFilterCompositor` applies per frame (S2). Pure **Core Image**, no AVFoundation / device, so
/// the mapping is unit-tested on the simulator (apply to a sample `CIImage`, assert a valid output).
/// `.none` returns `nil` (no-op). Intensity blends where the filter exposes a parameter.
enum StudioFilters {

    static func ciFilter(for filter: StudioFilter, intensity: Double) -> CIFilter? {
        let i = max(0, min(1, intensity))
        switch filter {
        case .none:
            return nil
        case .mono:
            return CIFilter(name: "CIPhotoEffectMono")
        case .noir:
            return CIFilter(name: "CIPhotoEffectNoir")
        case .fade:
            return CIFilter(name: "CIPhotoEffectFade")
        case .vivid:
            let f = CIFilter(name: "CIColorControls")
            f?.setValue(1 + 0.6 * i, forKey: kCIInputSaturationKey)
            f?.setValue(0.04 * i, forKey: kCIInputBrightnessKey)
            f?.setValue(1 + 0.10 * i, forKey: kCIInputContrastKey)
            return f
        case .warm:
            // Lift red, ease blue (a simple, reliable warm tint — avoids CITemperatureAndTint's
            // dual-neutral subtlety).
            let f = CIFilter(name: "CIColorMatrix")
            f?.setValue(CIVector(x: 1 + 0.15 * i, y: 0, z: 0, w: 0), forKey: "inputRVector")
            f?.setValue(CIVector(x: 0, y: 0, z: 1 - 0.12 * i, w: 0), forKey: "inputBVector")
            return f
        case .cool:
            let f = CIFilter(name: "CIColorMatrix")
            f?.setValue(CIVector(x: 1 - 0.12 * i, y: 0, z: 0, w: 0), forKey: "inputRVector")
            f?.setValue(CIVector(x: 0, y: 0, z: 1 + 0.15 * i, w: 0), forKey: "inputBVector")
            return f
        }
    }

    /// Apply the filter to `image`, returning the filtered output (or `image` unchanged for `.none`
    /// or a failed filter). The filter's output is cropped back to the input extent so downstream
    /// composition keeps the frame's bounds.
    static func apply(_ filter: StudioFilter, intensity: Double, to image: CIImage) -> CIImage {
        guard let f = ciFilter(for: filter, intensity: intensity) else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        guard let out = f.outputImage else { return image }
        return out.cropped(to: image.extent)
    }

    /// Apply a manual colour **Adjust** (brightness/contrast/saturation via `CIColorControls`) to
    /// `image`. A neutral adjust (or nil) returns the image unchanged. Pure Core Image (unit-tested).
    static func applyAdjust(_ adjust: ClipAdjust?, to image: CIImage) -> CIImage {
        guard let adjust, !adjust.isNeutral, let f = CIFilter(name: "CIColorControls") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(max(-1, min(1, adjust.brightness)), forKey: kCIInputBrightnessKey)
        f.setValue(max(0, min(2, adjust.contrast)), forKey: kCIInputContrastKey)
        f.setValue(max(0, min(2, adjust.saturation)), forKey: kCIInputSaturationKey)
        guard let out = f.outputImage else { return image }
        return out.cropped(to: image.extent)
    }

    /// Scale `image` to **fill** a `canvas`-sized frame (cover, centred, cropped to the canvas) — the
    /// frame layout the filter compositor hands back at `renderSize`. Pure Core Image (unit-tested).
    static func aspectFill(_ image: CIImage, to canvas: CGSize) -> CIImage {
        let src = image.extent
        guard src.width > 0, src.height > 0, canvas.width > 0, canvas.height > 0 else { return image }
        let scale = max(canvas.width / src.width, canvas.height / src.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (canvas.width - scaled.extent.width) / 2 - scaled.extent.minX
        let dy = (canvas.height - scaled.extent.height) / 2 - scaled.extent.minY
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .cropped(to: CGRect(origin: .zero, size: canvas))
    }
}
