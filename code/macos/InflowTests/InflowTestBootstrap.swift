import AppKit
import XCTest

/// XCTest instantiates the test bundle's NSPrincipalClass before running tests.
/// Direct `xcrun xctest` runs have no app icon of their own; use the enclosing
/// Inflow.app's compiled icon, just like app-hosted tests and normal launches.
@objc(InflowTestBootstrap)
final class InflowTestBootstrap: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { Self.configureApplicationIcon() }
        } else {
            DispatchQueue.main.sync { Self.configureApplicationIcon() }
        }
    }

    static var hostApplicationBundle: Bundle? {
        var url = Bundle(for: InflowTestBootstrap.self).bundleURL
        while url.path != "/" {
            if url.pathExtension == "app" { return Bundle(url: url) }
            url.deleteLastPathComponent()
        }
        return nil
    }

    @MainActor
    private static func configureApplicationIcon() {
        guard let bundle = hostApplicationBundle,
              let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              let url = bundle.url(forResource: (name as NSString).deletingPathExtension,
                                   withExtension: "icns"),
              let icon = NSImage(contentsOf: url)
        else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}
