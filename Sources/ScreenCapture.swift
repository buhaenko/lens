// Grabs a screen rectangle in-process with ScreenCaptureKit.

import AppKit
import ScreenCaptureKit

/// Captures a rect given in global Cocoa coordinates (bottom-left origin) at the display's native resolution.
func captureScreen(_ r: NSRect) async -> CGImage? {
    guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(r) }) ?? NSScreen.main,
          let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == number }) else { return nil }
        let own = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: own)
        let config = SCStreamConfiguration()
        let f = screen.frame, scale = screen.backingScaleFactor
        // display-local, top-left origin, in points
        let local = CGRect(x: r.minX - f.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
        config.sourceRect = local
        config.width = max(1, Int(local.width * scale))
        config.height = max(1, Int(local.height * scale))
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    } catch {
        NSLog("Lensy: capture failed: %@", error.localizedDescription)
        return nil
    }
}
