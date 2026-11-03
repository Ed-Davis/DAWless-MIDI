import SwiftUI
import AppKit
import ImageIO

/// Takes a picture of the window for the README.
///
/// Launch with `--screenshot <folder>` (GitHub Actions does this). The app
/// fills itself with made-up devices, photographs its own window, saves PNGs
/// and quits. Nothing is saved to your setup and no MIDI is sent.
enum Screenshot {
    static let outputDirectory: URL? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--screenshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }()

    static var isActive: Bool { outputDirectory != nil }

    /// Frames of tagged parts of the window, top-left origin.
    static var frames: [String: CGRect] = [:]

    @MainActor
    static func run(model: AppModel) async {
        guard let dir = outputDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Never hang the build.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            log("timed out")
            NSApp.terminate(nil)
        }

        model.loadDemo()
        await pause(1.0)

        guard let window = NSApp.windows.first(where: { $0.title == "DAWless MIDI" && $0.isVisible })
                ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else {
            log("window not found")
            NSApp.terminate(nil)
            return
        }
        window.setContentSize(NSSize(width: 1400, height: 860))
        window.center()
        window.makeKeyAndOrderFront(nil)
        await pause(2.0)

        if let shot = windowShot(window) {
            save(shot.image, "main-window", dir)
            if let rect = frames["patchbay"] {
                let inWindow = rect.offsetBy(dx: 0, dy: shot.contentTop).insetBy(dx: -2, dy: -2)
                save(crop(shot.image, viewSize: shot.frameSize, rect: inWindow), "patchbay", dir)
            }
        }

        FileManager.default.createFile(atPath: dir.appendingPathComponent(".done").path, contents: nil)
        log("finished")
        NSApp.terminate(nil)
    }

    // MARK: - Helpers (as in MIDI Flicker's help screenshots)

    struct WindowShot {
        let image: CGImage
        let frameSize: CGSize
        let contentTop: CGFloat
    }

    @MainActor
    private static func windowShot(_ window: NSWindow) -> WindowShot? {
        guard let frameView = window.contentView?.superview, let content = window.contentView else { return nil }
        let size = frameView.bounds.size
        let contentFrame = content.convert(content.bounds, to: frameView)
        let contentTop = frameView.isFlipped ? contentFrame.minY : size.height - contentFrame.maxY
        if let image = systemCapture(window), looksReal(image) {
            return WindowShot(image: image, frameSize: size, contentTop: contentTop)
        }
        log("system window capture unavailable; drawing the window instead")
        guard let image = snapshot(frameView) else { return nil }
        return WindowShot(image: image, frameSize: size, contentTop: contentTop)
    }

    @MainActor
    private static func systemCapture(_ window: NSWindow) -> CGImage? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dawless-shot-\(window.windowNumber).png")
        try? FileManager.default.removeItem(at: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning && Date() < deadline { usleep(50_000) }
            if process.isRunning { process.terminate(); return nil }
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image
    }

    /// Without screen recording permission macOS hands back a blank picture.
    private static func looksReal(_ image: CGImage) -> Bool {
        guard image.width > 100, image.height > 100,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let bpp = image.bitsPerPixel / 8, row = image.bytesPerRow
        guard bpp >= 3 else { return false }
        var colours = Set<UInt32>()
        for yi in 0..<40 {
            for xi in 0..<40 {
                let x = image.width * (xi * 2 + 1) / 80, y = image.height * (yi * 2 + 1) / 80
                let p = y * row + x * bpp
                colours.insert(UInt32(bytes[p]) << 16 | UInt32(bytes[p + 1]) << 8 | UInt32(bytes[p + 2]))
            }
        }
        return colours.count > 60
    }

    @MainActor
    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @MainActor
    private static func snapshot(_ view: NSView) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }

    private static func crop(_ image: CGImage, viewSize: CGSize, rect: CGRect) -> CGImage? {
        guard viewSize.width > 0 else { return nil }
        let scale = CGFloat(image.width) / viewSize.width
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixels.isEmpty else { return nil }
        return image.cropping(to: pixels)
    }

    private static func save(_ image: CGImage?, _ name: String, _ dir: URL) {
        guard let image else { log("nothing captured for \(name)"); return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = dir.appendingPathComponent("\(name).png")
        do {
            try data.write(to: url)
            log("saved \(url.lastPathComponent) (\(image.width)×\(image.height))")
        } catch {
            log("couldn't save \(name): \(error.localizedDescription)")
        }
    }

    private static func log(_ message: String) {
        print("[screenshot] \(message)")
        fflush(stdout)
    }
}

private struct ScreenshotAnchorKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Tags part of the window so the screenshot can crop it out.
    func screenshotAnchor(_ name: String) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: ScreenshotAnchorKey.self, value: [name: geo.frame(in: .global)])
        })
    }

    /// Collects the tagged frames (on the window's root view).
    func collectScreenshotAnchors() -> some View {
        onPreferenceChange(ScreenshotAnchorKey.self) { frames in
            Screenshot.frames.merge(frames) { $1 }
        }
    }
}
