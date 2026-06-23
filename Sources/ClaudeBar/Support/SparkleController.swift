import Foundation
import Security
#if canImport(Sparkle)
import Sparkle
#endif

/// Wraps Sparkle so the rest of the app stays oblivious to it.
///
/// Updates only run from a **Developer ID-signed `.app`** — i.e. a `make dist`
/// release. Local `make run` / `swift run` builds (Apple Development or ad-hoc
/// signed) get the no-op `DisabledUpdater`, so dev builds never try to update
/// themselves and `isAvailable` stays false (which hides the UI). The on/off
/// switch persists to `UserDefaults` and drives both automatic checks and
/// downloads.
@MainActor
final class SparkleController {
    static let shared = SparkleController()

    private static let defaultsKey = "autoUpdateEnabled"
    private var updater: UpdaterProviding

    private init() {
        updater = DisabledUpdater()

        #if canImport(Sparkle)
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app", Self.isDeveloperIDSigned(bundleURL) else {
            Log.info("auto-update: disabled (not a Developer ID-signed .app)")
            return
        }

        let enabled = UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = enabled
        controller.updater.automaticallyDownloadsUpdates = enabled
        controller.startUpdater()
        updater = controller
        Log.info("auto-update: enabled via Sparkle (autoUpdate=\(enabled))")
        #endif
    }

    /// True only when Sparkle is live (a signed release build). Gates the
    /// "Check for Updates…" menu item and the settings toggle.
    var isAvailable: Bool { updater.isAvailable }

    /// Master switch for automatic update checks + downloads. Persisted, and
    /// applied to the running updater immediately.
    var autoUpdateEnabled: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            updater.automaticallyChecksForUpdates = newValue
            updater.automaticallyDownloadsUpdates = newValue
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
        }
    }

    func checkForUpdates() {
        guard updater.isAvailable else { return }
        updater.checkForUpdates(nil)
    }

    /// Sparkle requires a Developer ID signature to install updates, so don't
    /// even start it otherwise — avoids a dev build trying to self-update.
    private static func isDeveloperIDSigned(_ bundleURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let code = staticCode else { return false }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any],
              let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first,
              let summary = SecCertificateCopySubjectSummary(leaf) as String?
        else { return false }
        return summary.hasPrefix("Developer ID Application:")
    }
}

/// Lets the app compile and run with updates simply switched off on builds
/// where Sparkle can't operate (unsigned, or a hypothetical Sparkle-less build).
private protocol UpdaterProviding: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var isAvailable: Bool { get }
    func checkForUpdates(_ sender: Any?)
}

private final class DisabledUpdater: UpdaterProviding {
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    let isAvailable = false
    func checkForUpdates(_ sender: Any?) {}
}

#if canImport(Sparkle)
extension SPUStandardUpdaterController: UpdaterProviding {
    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }
    var isAvailable: Bool { true }
    // checkForUpdates(_:) is already provided by SPUStandardUpdaterController.
}
#endif
