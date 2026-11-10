import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct CapturedShot: Identifiable {
    let id = UUID()
    let image: CGImage
    let date = Date()
    let isRegion: Bool

    var thumbnail: NSImage { NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplay
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Screen Recording permission is missing. Open QuizSnapper → Permissions."
        case .noDisplay: return "Couldn't find the display under the cursor."
        case .failed(let msg): return "Screen capture failed: \(msg)"
        }
    }
}

enum ScreenCapturer {
    /// The NSScreen that currently contains the mouse pointer.
    static var screenUnderMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Captures the full display under the mouse at native resolution, excluding QuizSnapper's own windows.
    static func captureScreen(_ screenOverride: NSScreen? = nil) async throws -> CGImage {
        // Displays can be briefly unavailable while they reconfigure (lid closing, monitor unplugged).
        guard let screen = screenOverride ?? screenUnderMouse else { throw CaptureError.noDisplay }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            // Only blame permissions when macOS says access is missing.
            throw CGPreflightScreenCaptureAccess() ? CaptureError.failed(error.localizedDescription) : CaptureError.permissionDenied
        }
        guard let id = displayID(of: screen),
              let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first
        else { throw CaptureError.noDisplay }

        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        config.capturesAudio = false
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CaptureError.failed(error.localizedDescription)
        }
    }
}

// MARK: - Encoding

enum ImageEncoder {
    /// Providers reject images above ~5 MB base64 (≈3.75 MB raw). Stay comfortably below.
    static let maxBytes = 3_600_000
    /// Claude caps each side at 2000 px once a request has more than 20 images.
    static let manyImagesMaxDimension = 2000

    /// Encodes every image for one request, applying the provider limits.
    static func encodeAll(_ images: [CGImage], settings: AppSettings) -> [EncodedImage] {
        var maxDim = max(settings.imageMaxDimension, 256)
        if images.count > 20 { maxDim = min(maxDim, manyImagesMaxDimension) }
        return images.compactMap { encode($0, settings: settings, maxDimension: maxDim) }
    }

    /// Downscales to `maxDimension` on the longest side and encodes as JPEG/PNG. If the result is too big,
    /// falls back to JPEG and keeps shrinking until it fits.
    static func encode(_ image: CGImage, settings: AppSettings, maxDimension: Int? = nil) -> EncodedImage? {
        var dim = CGFloat(maxDimension ?? max(settings.imageMaxDimension, 256))
        var usePNG = settings.imageFormat == .png
        var quality = settings.jpegQuality
        for _ in 0..<8 {
            guard let scaled = downscale(image, maxDimension: dim),
                  let data = write(scaled, png: usePNG, quality: quality) else { return nil }
            if data.count <= maxBytes {
                return EncodedImage(data: data, mediaType: usePNG ? "image/png" : "image/jpeg")
            }
            if usePNG { usePNG = false } else { quality = max(0.5, quality - 0.1); dim *= 0.8 }
        }
        return nil
    }

    private static func downscale(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = min(1, maxDimension / max(w, h))
        guard scale < 1 else { return image }
        let tw = max(1, Int((w * scale).rounded())), th = max(1, Int((h * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage()
    }

    private static func write(_ image: CGImage, png: Bool, quality: Double) -> Data? {
        let data = NSMutableData()
        let type: UTType = png ? .png : .jpeg
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if !png { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
