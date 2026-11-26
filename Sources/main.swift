// Lensy — select any area of the screen, read the text and translate it, on-device.

import AppKit

#if TESTING
MainActor.assumeIsolated { runTests() }
#else
MainActor.assumeIsolated {
    if !AppDelegate.e2e { Migration.fromLens() }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
#endif
