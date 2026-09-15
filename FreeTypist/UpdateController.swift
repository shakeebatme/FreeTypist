import AppKit
import Combine
import Sparkle

/// Sparkle, wrapped so the rest of the app never imports it.
///
/// The updater is only started when the bundle carries an EdDSA public key.
/// Without one — every local build until `scripts/generate-update-keys.sh` has
/// run, and any fork that has not set up its own key — Sparkle refuses at
/// launch with an alert the user can do nothing about, and a *Check for
/// Updates* item would be offering a download nothing can verify. So the whole
/// feature stays folded away instead.
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    /// False in a build with no signing key. The UI hides itself when false.
    let isConfigured: Bool

    /// Sparkle drops this while a check is already in flight.
    @Published private(set) var canCheckForUpdates = false

    /// `nil` until the first check of this install.
    @Published private(set) var lastCheck: Date?

    @Published var automaticallyChecks: Bool {
        didSet { updater?.automaticallyChecksForUpdates = automaticallyChecks }
    }

    @Published var automaticallyDownloads: Bool {
        didSet { updater?.automaticallyDownloadsUpdates = automaticallyDownloads }
    }

    private let controller: SPUStandardUpdaterController?
    private var updater: SPUUpdater? { controller?.updater }
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let configured = !(key ?? "").isEmpty
        isConfigured = configured

        // `startingUpdater: true` also schedules the background check, which is
        // what prompts the user for permission on a later launch. Sparkle owns
        // that answer and stores it in its own defaults; Preferences stays out.
        let controller = configured
            ? SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
              )
            : nil
        self.controller = controller
        automaticallyChecks = controller?.updater.automaticallyChecksForUpdates ?? false
        automaticallyDownloads = controller?.updater.automaticallyDownloadsUpdates ?? false
        lastCheck = controller?.updater.lastUpdateCheckDate

        guard let updater = controller?.updater else { return }
        // `canCheckForUpdates` goes false for the duration of a check and true
        // again when it finishes, which is also the moment the check date moves.
        updater.publisher(for: \.canCheckForUpdates)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.canCheckForUpdates = value
                    self.lastCheck = updater.lastUpdateCheckDate
                }
            }
            .store(in: &cancellables)
    }

    /// Brings the shared instance into existence, and with it Sparkle's
    /// scheduled background check.
    ///
    /// Worth doing explicitly at launch: every other reference to
    /// `UpdateController.shared` is inside a view, and `MenuBarExtra` does not
    /// build its content until the menu is opened. Left to that, the app would
    /// only ever check for updates once you had gone looking for the menu.
    static func start() {
        _ = shared
    }

    /// The menu item and the Settings button both land here.
    func checkForUpdates() {
        guard let controller else { return }
        // FreeTypist is an accessory app: it has no windows of its own, so
        // Sparkle's alert opens behind whatever the user was typing in unless
        // the app is brought forward first.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
