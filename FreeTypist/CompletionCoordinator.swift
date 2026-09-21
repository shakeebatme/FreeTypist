import AppKit
import ApplicationServices

/// Owns the live loop: watch typing, build a suggestion, show it, and insert it
/// when the user presses Tab.
@MainActor
final class CompletionCoordinator: ObservableObject {
    @Published private(set) var statusMessage = "Starting…"
    @Published private(set) var modelStatus: ModelStatus = .noModelSelected
    @Published private(set) var isTapActive = false
    /// Mirrors of the stored tally, so the settings row can observe them. The
    /// tally itself is the record; these exist because SwiftUI watches
    /// published properties and not a struct behind them.
    @Published private(set) var acceptedCount = 0
    @Published private(set) var acceptedWords = 0
    @Published private(set) var countingSince = Date()
    @Published private(set) var lastSuggestionText = ""
    /// How long recent model passes took. Published so the settings row follows
    /// it; a model pass runs at most a couple of times a second, well under the
    /// fast pass that `announce` had to be careful about.
    @Published private(set) var latency = LatencyStats()
    /// What the reader last saw in another app. Reading on demand is
    /// useless here: clicking a button in our own window steals the focus
    /// we would be trying to inspect.
    @Published private(set) var lastContextDescription = "No text field seen yet."

    private let reader: FocusedTextReader
    private let heuristic = HeuristicProvider()
    private let model: (any ModelBackend)?
    let models = ModelRepository()
    let screenContext = ScreenContextProvider()
    let personalization = PersonalizationStore()
    let shortcuts = ShortcutStore()

    /// Set when Escape pauses suggestions, so a second press reaches the app.
    private var pausedUntil: Date?

    /// What the user has been writing in the current field. Flushed to the
    /// encrypted store when they move on — never mid-keystroke.
    private struct EditingSession {
        let app: String
        var text: String
        var acceptedCompletion = false
        /// Everything we inserted here. Kept so the store can tell the user's
        /// own words from ours: accepted text still counts as their writing,
        /// but it must not be counted as their *vocabulary*, which drives a
        /// logit bias toward generating those same words again.
        var insertedText = ""
    }
    private var session: EditingSession?
    private var personalizationSnapshot = PersonalizationStore.Snapshot(recentPhrasing: [], vocabulary: [:])
    private let inserter: TextInsertionService
    private let overlay: SuggestionOverlayController
    private let preferences: Preferences
    private let tap = KeyEventTap()
    private let hotKeys = HotKeyMonitor()
    private let changes = AXChangeObserver()
    /// Lent to `TextInsertionService` so it can wait to be told an insertion
    /// landed rather than re-reading the field on a timer.
    var changeObserver: AXChangeObserver { changes }

    private var currentSuggestion: Suggestion?
    private var currentElement: AXUIElement?

    /// Other continuations for the caret currently showing, and which of them
    /// is on screen. Empty until the user asks: the model is not run three
    /// times for a suggestion nobody wanted to look past.
    private var candidates: [Suggestion] = []
    private var candidateIndex = 0
    /// The request that produced the suggestion showing, kept so the others can
    /// be asked for against exactly the same context. Rebuilding it later would
    /// re-read the screen and the clipboard, which by then describe a different
    /// moment.
    private var candidateRequest: CompletionRequest?
    private var candidateTask: Task<Void, Never>?
    /// How many to offer in all, the one on screen included.
    private let candidateCount = 3
    /// Editing state we have already answered for.
    private var currentSignature = ""
    /// True when the caret was last seen scrolled out of its field's viewport.
    /// The suggestion is still the right one — none of the text changed — but
    /// nothing is on screen to accept, so Tab belongs to the app until the caret
    /// comes back.
    private var caretOutOfView = false

    private var fastTask: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var repositionTask: Task<Void, Never>?
    /// Token for the scroll monitor, so it can be taken down at shutdown.
    private var scrollMonitor: Any?
    /// Handles for the block-based notification registrations, with the centre
    /// each belongs to. `removeObserver(self)` does nothing for one of these —
    /// the block *is* the observer — so the token is the only way back.
    private var observerTokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    private let ownBundleID = Bundle.main.bundleIdentifier

    /// Counts that outlive the session. Loaded once here rather than at each
    /// read: this is touched on every acceptance.
    private var statistics = Statistics.load(from: .standard)

    /// Long enough to coalesce a burst of keystrokes, short enough to feel
    /// immediate. Also absorbs the duplicate AX notifications: Safari posts two
    /// `AXValueChanged` per keystroke and a trailing `AXSelectedTextChanged`.
    private let fastDebounce = Duration.milliseconds(90)
    /// The model costs real time, so only ask once typing actually pauses.
    private let modelDebounce = Duration.milliseconds(450)
    /// How long to wait after the last window-moved notification before drawing
    /// the ghost text again. A drag posts these continuously and each redraw
    /// costs a round trip into the app for fresh caret bounds, so the overlay
    /// stays down until the window settles.
    private let repositionDebounce = Duration.milliseconds(120)
    /// A backstop, not the main loop. The key tap catches typing and
    /// `AXChangeObserver` catches everything else the focused app is willing to
    /// report; this only has to cover what neither can — Accessibility
    /// permission changing, and apps that post no notifications at all.
    private let pollInterval = Duration.milliseconds(2_000)

    init(
        reader: FocusedTextReader,
        inserter: TextInsertionService,
        overlay: SuggestionOverlayController,
        preferences: Preferences
    ) {
        self.reader = reader
        self.inserter = inserter
        self.overlay = overlay
        self.preferences = preferences
        self.model = ModelBackendFactory.make()
    }

    // MARK: - Lifecycle

    func start() {
        Log.core.notice("coordinator.start enabled=\(self.preferences.isEnabled, privacy: .public)")
        publishStatistics()
        AX.configureMessagingTimeout()

        // Ask on first run. Besides showing the dialog, this registers FreeTypist
        // in the Accessibility list so the user only has to flip the switch
        // instead of hunting for the bundle with the + button.
        if !AXIsProcessTrusted() {
            Log.core.notice("not trusted at launch; prompting")
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }

        // Only ask for Screen Recording if a feature that needs it is switched
        // on. Prompting for it unprompted would be rude given what it grants.
        if preferences.screenshotContext || preferences.screenshotAppearance,
           !ScreenCaptureService.hasPermission {
            Log.core.notice("screen capture enabled but not permitted; prompting")
            _ = ScreenCaptureService.requestPermission()
        }
        Log.core.notice("screen capture permitted=\(ScreenCaptureService.hasPermission, privacy: .public)")
        tap.onKeyDown = { [weak self] stroke in
            self?.handle(stroke) ?? .pass
        }
        // A hot key has already swallowed its key by the time this runs, so
        // unlike the tap there is no disposition to return. `wantedHotKeys` is
        // what keeps that honest.
        hotKeys.onAction = { [weak self] action in
            _ = self?.perform(action)
        }
        // Debounced on purpose: these arrive several times per keystroke.
        changes.onChange = { [weak self] in self?.scheduleFastPass() }
        changes.onDisplacement = { [weak self] kind in self?.handleDisplacement(kind) }
        changes.start()
        observeDisplacement()
        syncPermissionState()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.shutdownBlocking()
        }

        startPolling()
        refreshPersonalization(for: nil)
        Task { await self.loadModel() }
    }

    /// True while an accepted suggestion is being written. Insertion hops to a
    /// Task — Accessibility writes must never run inside the tap callback, or
    /// the system disables a tap whose callback runs long — so there is a real
    /// window during which `currentSuggestion` is nil but the user is still
    /// pressing Tab.
    private var isAccepting = false

    /// Until when a Tab with no suggestion should still be swallowed.
    ///
    /// Accepting the last word of a suggestion leaves nothing to accept while
    /// the next one is generated — `fastDebounce` + `modelDebounce` + inference,
    /// around 550–730 ms measured. A Tab landing in that gap reaches the app,
    /// and in a browser form that moves focus to the next field and loses the
    /// caret. The window is short and only opens straight after an accept, so
    /// Tab still works for navigation and indentation the rest of the time.
    private var acceptGraceUntil: Date?
    private let acceptGrace: TimeInterval = 0.9
    private var graceResyncTimer: Timer?

    /// Apps that keep refusing insertions, and until when to leave them alone.
    ///
    /// Swallowing Tab is a promise to put something in its place. An app that
    /// will not take an insertion — a web editor behind an unhelpful
    /// Accessibility layer, a canvas that ignores synthesized keys — turns that
    /// promise into a broken Tab key, which is far worse than a missing
    /// suggestion. After a few refusals in a row, stop suggesting there and hand
    /// the key back. `forceActivate` clears it for anyone who wants to retry.
    private var insertionFailures: [String: Int] = [:]
    private var insertionRefusedUntil: [String: Date] = [:]
    private let insertionFailureLimit = 3
    private let insertionStandDown: TimeInterval = 600

    /// The app owning the field we last read, so an insertion result can be
    /// attributed even after focus has moved on.
    private var currentBundleID: String?

    /// Guards against running teardown twice. Two paths deliberately lead here
    /// — `applicationWillTerminate` and the `willTerminateNotification`
    /// observer — because for a `MenuBarExtra`-only app the delegate hook has
    /// been seen not to fire at all. Whichever arrives first does the work.
    private var hasShutDown = false

    /// Called while the app is terminating. Blocks briefly on purpose: the
    /// alternative is aborting inside ggml's exit handler.
    ///
    /// Both callers run on the main thread, so the main-actor work is done
    /// *synchronously* here rather than hopped to with `Task { @MainActor }`.
    /// Hopping deadlocks: the semaphore below blocks the main thread, so a task
    /// queued on the main actor can never run, the wait times out having freed
    /// nothing, and `exit()` then aborts inside `ggml_metal_rsets_free`. That
    /// was a real crash on every quit with a model loaded, and it logged twice
    /// two seconds apart — one timeout per registration — which is how it was
    /// found.
    ///
    /// Blocking is safe only because the awaited work belongs to `LlamaBackend`,
    /// a separate actor that runs on the cooperative pool.
    nonisolated func shutdownBlocking() {
        MainActor.assumeIsolated {
            guard !hasShutDown else { return }
            hasShutDown = true

            Log.core.notice("shutdown: releasing model before exit")
            repositionTask?.cancel()
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
            for (center, token) in observerTokens { center.removeObserver(token) }
            observerTokens.removeAll()
            changes.stop()
            flushSession()

            guard let backend = model as? LlamaBackend else { return }
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await backend.shutdown()
                done.signal()
            }
            if done.wait(timeout: .now() + 3) == .timedOut {
                Log.core.error("shutdown: model teardown timed out")
            }
        }
    }

    /// Clears the tally. Offered because a count kept across launches is one
    /// the user may well want to start again — after trying a different model,
    /// or simply to see what a week looks like.
    func resetStatistics() {
        statistics.reset()
        statistics.save(to: .standard)
        publishStatistics()
    }

    private func publishStatistics() {
        acceptedCount = statistics.accepted
        acceptedWords = statistics.words
        countingSince = statistics.since
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            syncPermissionState()
        } else {
            tap.stop()
            hotKeys.stop()
            isTapActive = false
            clearSuggestion()
            announce("Suggestions are off.")
        }
    }

    /// Points the engine at whichever model is on disk, then warms it so the
    /// first keystroke does not pay for Metal pipeline setup.
    func loadModel() async {
        guard let model = model as? LlamaBackend else {
            modelStatus = .noModelSelected
            return
        }
        guard let path = models.loadableModelPath else {
            modelStatus = .noModelSelected
            Log.core.notice("no model on disk")
            return
        }

        modelStatus = .loading
        // The window describes an engine, and this is about to be a different
        // one. Carrying the old numbers over would misreport the swap as a
        // regression, or hide one.
        latency.reset()
        await model.load(path: path)
        modelStatus = await model.status()
        Log.core.notice("model status=\(String(describing: self.modelStatus), privacy: .public)")

        if modelStatus.isReady {
            await model.warmUp()
            Log.core.notice("model warmed")
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: self?.pollInterval ?? .milliseconds(650))
            }
        }
    }

    /// Catches everything the key tap cannot see: the user clicking into a
    /// different field, switching apps, or granting permission while we run.
    private func tick() {
        syncPermissionState()
        // Also catches a rebinding made in Settings since the last pass.
        syncHotKeys()
        guard preferences.isEnabled, isTapActive else { return }
        runFastPass()
    }

    /// Publishes a status line only when it actually changes.
    ///
    /// A `@Published` assignment is not free — it wakes every SwiftUI view
    /// observing this object — and the fast pass runs up to eleven times a
    /// second while typing and every two seconds when nothing is happening at
    /// all. Nearly all of those assignments wrote the value that was already
    /// there: standing down in an app republished the same sentence every poll
    /// for ten minutes, and waiting for permission did it indefinitely.
    private func announce(_ message: String) {
        guard statusMessage != message else { return }
        statusMessage = message
    }

    private func syncPermissionState() {
        let trusted = AXIsProcessTrusted()

        guard preferences.isEnabled else { return }

        if trusted {
            if !tap.isRunning {
                let started = tap.start()
                Log.core.notice("tap.start trusted=true started=\(started, privacy: .public)")
                if started {
                    announce("Watching for typing.")
                } else {
                    announce("Accessibility is on but the key tap was refused.")
                }
            }
        } else {
            if tap.isRunning { tap.stop() }
            clearSuggestion()
            announce("Waiting for Accessibility permission.")
        }
        isTapActive = tap.isRunning
    }

    // MARK: - Hot keys

    /// Which shortcuts should be registered as Carbon hot keys right now.
    ///
    /// This exists because a hot key is unconditional. Once registered it
    /// swallows its key, and Carbon offers no way to hand one back the way the
    /// tap does by returning `.pass`. So a key is only registered while
    /// `perform` is certain to act on it, and the guards below have to track
    /// the ones in `perform` — otherwise bare Tab would stop indenting and stop
    /// moving between fields in every app on the Mac.
    private var wantedHotKeys: [ShortcutAction: Shortcut] {
        guard preferences.isEnabled else { return [:] }

        var wanted: [ShortcutAction: Shortcut] = [:]

        // These already consume their key unconditionally in the tap, so
        // registering them takes nothing new away from anyone. Bare bindings are
        // left to the tap alone: a hot key on an unmodified key would claim it
        // system-wide, and these three are never in a position to give it back.
        for action in [ShortcutAction.forceActivate, .toggleCurrentApp, .toggleGlobally] {
            if let shortcut = shortcuts.shortcut(for: action), shortcut.hasModifiers {
                wanted[action] = shortcut
            }
        }

        // An app that has refused insertions, or a caret scrolled out of sight,
        // means the accept keys are not ours — `perform` hands them back in both
        // cases, so they must not be registered.
        if !insertionRefused(in: currentBundleID), !caretOutOfView {
            let haveSomethingToAccept = isAccepting || currentSuggestion != nil
            if haveSomethingToAccept || withinAcceptGrace,
               let shortcut = shortcuts.shortcut(for: .nextWord) {
                wanted[.nextWord] = shortcut
            }
            // No grace for the whole-suggestion key, matching `perform`: with
            // nothing on screen the backtick has to type a backtick.
            if haveSomethingToAccept, let shortcut = shortcuts.shortcut(for: .fullCompletion) {
                wanted[.fullCompletion] = shortcut
            }
            // Only while a suggestion is actually showing, for the same reason:
            // registered, the chord is taken from the app underneath, and
            // Option-Down moves the caret in most editors.
            if currentSuggestion != nil, let shortcut = shortcuts.shortcut(for: .nextAlternative) {
                wanted[.nextAlternative] = shortcut
            }
        }
        return wanted
    }

    private func syncHotKeys() {
        hotKeys.sync(wantedHotKeys)
        scheduleGraceResync()
    }

    /// The accept grace is the only thing here that closes on a clock rather
    /// than on an event, so without this nothing would come along to give Tab
    /// back when it lapses.
    private func scheduleGraceResync() {
        graceResyncTimer?.invalidate()
        graceResyncTimer = nil
        guard currentSuggestion == nil, !isAccepting, let until = acceptGraceUntil else { return }
        let delay = max(until.timeIntervalSinceNow, 0) + 0.05
        graceResyncTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.syncHotKeys() }
        }
    }

    // MARK: - Key handling

    private func handle(_ stroke: KeyStroke) -> KeyDisposition {
        guard preferences.isEnabled else { return .pass }

        if stroke.keyCode == Shortcut.escape {
            return handleEscape()
        }

        if let action = shortcuts.action(for: stroke), perform(action) {
            return .consume
        }

        // Command/Control/Option chords are app shortcuts, not typing, so they
        // leave the suggestion alone. Without this, Shift-Command-4 (and every
        // other shortcut) wipes the suggestion before it can be used or captured.
        if stroke.isCommandLike {
            return .pass
        }

        // Any real keystroke makes the visible suggestion stale, and means the
        // user is typing rather than working through a suggestion.
        acceptGraceUntil = nil
        clearSuggestion()
        scheduleFastPass()
        return .pass
    }

    /// Escape only changes meaning *while a suggestion is showing*. Once it has
    /// cleared one, a second press must reach the app — otherwise Escape appears
    /// broken everywhere, which is far worse than a suggestion lingering.
    private func handleEscape() -> KeyDisposition {
        guard currentSuggestion != nil, !caretOutOfView else { return .pass }

        clearSuggestion()
        if preferences.escapeBehaviour == .pauseBriefly {
            pausedUntil = Date().addingTimeInterval(5)
        }
        return .consume
    }

    /// Returns true when the action applied and the key should be swallowed.
    private func perform(_ action: ShortcutAction) -> Bool {
        switch action {
        case .nextWord:
            // Insertion is asynchronous, so there is a window with no
            // suggestion while one is being written, and another while the next
            // one is generated. Swallow Tab in both rather than letting it
            // through: in a browser form a stray Tab moves focus to the next
            // field and the caret is gone.
            // Give Tab back to an app that has proved it will not take text.
            if insertionRefused(in: currentBundleID) { return false }
            // Nothing is on screen while the caret is scrolled out of sight.
            // Swallowing Tab there would write text the user cannot see into a
            // place they are not looking.
            if caretOutOfView { return false }
            if isAccepting { return true }
            guard currentSuggestion != nil else { return withinAcceptGrace }
            accept(.nextWord)
            return true

        case .fullCompletion:
            if insertionRefused(in: currentBundleID) { return false }
            if caretOutOfView { return false }
            if isAccepting { return true }
            // No grace here on purpose: with no suggestion the backtick must
            // type a backtick.
            guard currentSuggestion != nil else { return false }
            accept(.whole)
            return true

        case .nextAlternative:
            // Nothing on screen to replace.
            guard currentSuggestion != nil, !caretOutOfView else { return false }
            cycleAlternative()
            return true

        case .forceActivate:
            // An explicit ask is also a request to retry an app we had given up
            // on, otherwise a stand-down could only be waited out.
            if let app = currentBundleID {
                insertionRefusedUntil[app] = nil
                insertionFailures[app] = nil
            }
            pausedUntil = nil
            currentSignature = ""
            scheduleFastPass()
            return true

        case .toggleCurrentApp:
            guard let front = NSWorkspace.shared.frontmostApplication,
                  let app = front.bundleIdentifier,
                  app != ownBundleID else { return false }
            let name = front.localizedName ?? app
            if preferences.suggestsIn(app) {
                preferences.exclude(app, name: name, for: .tenMinutes)
                announce("\(name) excluded for 10 minutes.")
            } else {
                preferences.include(app)
                announce("\(name) is no longer excluded.")
            }
            clearSuggestion()
            return true

        case .toggleGlobally:
            let enabled = !preferences.isEnabled
            preferences.isEnabled = enabled
            setEnabled(enabled)
            return true
        }
    }

    enum AcceptMode {
        case nextWord
        case whole
    }

    private func accept(_ mode: AcceptMode) {
        guard let suggestion = currentSuggestion else { return }
        let element = currentElement

        let toInsert: Suggestion
        let remainder: String
        // A correction rewrites one word; splitting it would be meaningless.
        if mode == .whole || suggestion.isCorrection {
            toInsert = suggestion
            remainder = ""
        } else {
            let (head, tail) = Suggestion.splitFirstWord(
                suggestion.text,
                includeTrailingSpace: preferences.includeTrailingSpace,
                includeTrailingPunctuation: preferences.includeTrailingPunctuation
            )
            if head.isEmpty || tail.trimmingCharacters(in: .whitespaces).isEmpty {
                toInsert = suggestion
                remainder = ""
            } else {
                toInsert = Suggestion(
                    text: head,
                    replacing: suggestion.replacing,
                    source: suggestion.source
                )
                remainder = tail
            }
        }

        // Clear first so a fast double-Tab cannot insert twice.
        clearSuggestion()
        currentSignature = ""
        isAccepting = true
        // Arm the grace here rather than when the suggestion runs out. Every
        // step between this point and the next presented suggestion is a window
        // in which Tab has nothing to accept, and a Tab that reaches a browser
        // form moves focus and loses the caret.
        acceptGraceUntil = Date().addingTimeInterval(acceptGrace)
        syncHotKeys()

        let app = currentBundleID

        // Never do Accessibility writes inside the tap callback: the system
        // disables a tap whose callback runs long.
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isAccepting = false
                self.syncHotKeys()
            }

            let outcome = self.inserter.apply(toInsert, to: element)
            // Synthesized keystrokes are posted, not applied: the field does not
            // change until the target app gets round to them. Reading it now
            // would re-anchor the rest of the suggestion against the text as it
            // was, at the caret where it was.
            let inserted = outcome.isDeferred
                ? await self.inserter.awaitInsertion(of: toInsert, in: element)
                : outcome.succeeded

            // Counted here rather than at the key press, because until this
            // point nothing is known about whether the text arrived. These are
            // the user's own statistics, and `acceptedCompletion` is one of the
            // three gates on writing this field's text to the encrypted store —
            // the condition they set was that a completion was accepted here,
            // and an insertion the app refused does not meet it.
            if inserted {
                self.statistics.record(
                    words: toInsert.text.split(whereSeparator: \.isWhitespace).count
                )
                // Written through on each acceptance rather than at quit. A
                // menu-bar app is killed far more often than it is quit
                // politely, and a tally that only survives a clean exit is not
                // one anybody would trust.
                self.statistics.save(to: .standard)
                self.publishStatistics()
                if self.session?.app == app {
                    self.session?.acceptedCompletion = true
                    self.session?.insertedText += " " + toInsert.text
                }
            }

            // An app that answers "no" often enough gets Tab back.
            if self.noteInsertion(succeeded: inserted, in: app) { return }

            self.announce(inserted
                ? "Inserted \u{201C}\(toInsert.text.prefix(28))\u{201D}"
                : "This app refused the insertion.")

            // Re-anchor the rest at the new caret rather than asking the model
            // again: it is instant and keeps the wording stable across taps.
            if inserted, !remainder.isEmpty, let now = self.reader.readFocusedText() {
                self.currentSignature = now.signature
                self.present(
                    Suggestion(text: remainder, source: suggestion.source),
                    in: now
                )
                return
            }

            // The text never showed up: put the suggestion back instead of
            // waiting on a fresh generation. Without this a failed insertion
            // leaves nothing to accept, and the next Tab goes to the app.
            //
            // Re-presenting is the safer half of the bet. If the keystrokes were
            // merely slower than the settle window and land afterwards, the next
            // poll sees the change and replaces this; assuming success when the
            // text is absent leaves the user with nothing at all.
            if !inserted, let now = self.reader.readFocusedText() {
                self.currentSignature = now.signature
                self.present(suggestion, in: now)
                return
            }

            // The suggestion is used up. Re-arm from here rather than relying on
            // the window opened at the start of the accept: the next suggestion
            // is only now being generated, and that is the gap Tab must not fall
            // into.
            self.acceptGraceUntil = Date().addingTimeInterval(self.acceptGrace)
            self.syncHotKeys()
            self.scheduleFastPass()
        }
    }

    // MARK: - Alternatives

    /// Puts the next candidate on screen, asking the model for them the first
    /// time.
    private func cycleAlternative() {
        guard !candidates.isEmpty else {
            fetchAlternatives()
            return
        }
        candidateIndex = (candidateIndex + 1) % candidates.count
        showCandidate()
    }

    /// Asks for the whole ranked list, the one already showing included.
    ///
    /// The list is asked for as a list rather than as "the others" because the
    /// backend has to know which openings to avoid, and that means knowing what
    /// the first answer was. Its first entry should therefore be what is
    /// already on screen, and if it is not — a different model, a changed
    /// bias — the list is still right and simply starts where it starts.
    private func fetchAlternatives() {
        guard candidateTask == nil, let model, let request = candidateRequest else { return }
        let signature = currentSignature

        announce("Looking for other suggestions…")
        candidateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.candidateTask = nil }

            let texts = await model.completions(request, count: self.candidateCount)
            // The caret has to still be where it was. Anything else and these
            // continue a sentence that has moved on.
            guard !Task.isCancelled, self.currentSignature == signature,
                  let now = self.reader.readFocusedText(), now.signature == signature else { return }
            guard texts.count > 1 else {
                self.announce("No other suggestion here.")
                return
            }

            self.candidates = texts.map { Suggestion(text: $0, source: .model) }
            self.candidateIndex = 1
            self.showCandidate()
        }
    }

    private func showCandidate() {
        guard candidates.indices.contains(candidateIndex),
              let context = reader.readFocusedText(),
              context.signature == currentSignature else { return }
        announce("Suggestion \(candidateIndex + 1) of \(candidates.count)")
        present(candidates[candidateIndex], in: context)
    }

    /// Called wherever the suggestion stops being the one these belong to.
    private func dropAlternatives() {
        candidateTask?.cancel()
        candidateTask = nil
        candidates = []
        candidateIndex = 0
        candidateRequest = nil
    }

    // MARK: - Suggestion pipeline

    private func scheduleFastPass() {
        // Deliberately does *not* cancel `modelTask`. This is called for every
        // AX change notification, and apps post trailing ones after typing
        // stops — Safari sends `AXSelectedTextChanged` about 100 ms late.
        // Cancelling here killed the model pass that the previous fast pass had
        // just scheduled, and no later pass rescheduled it, because by then the
        // signature was unchanged and `runFastPass` returns early above the
        // point where the model is asked. The result was no suggestion at all.
        // The model pass is cancelled where the text actually changes instead.
        fastTask?.cancel()
        fastTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.fastDebounce)
            guard !Task.isCancelled else { return }
            self.runFastPass()
        }
    }

    private func runFastPass() {
        guard preferences.isEnabled, AXIsProcessTrusted() else { return }
        // An accept in flight re-anchors the suggestion itself once the text has
        // landed. A poll arriving first reads a field mid-change and clears it.
        guard !isAccepting else { return }
        if let pausedUntil, pausedUntil > Date() { return }
        // Generating uses the GPU; honour the user's wish to conserve power.
        if preferences.pauseInLowPower, ProcessInfo.processInfo.isLowPowerModeEnabled { return }

        // Something is collecting a password. `FocusedTextReader` refuses to
        // read anything while that is true, so this exists to say why and to
        // put down what is already in hand.
        //
        // The grace has to go first, and before `clearSuggestion`, which syncs
        // the hot keys off the back of it. Left armed it keeps swallowing Tab
        // for up to another 0.9 s — into a password dialog, where Tab is how
        // you reach the next field. The signature goes for the reason
        // `handleDisplacement` clears it: the user will come back to this same
        // text, and an unchanged signature would return above the point where
        // anything is suggested.
        if let paused = SecureInput.explanation() {
            acceptGraceUntil = nil
            currentSignature = ""
            clearSuggestion()
            announce(paused)
            return
        }

        guard let context = reader.readFocusedText() else {
            Log.core.debug("fastPass: no readable focused text field")
            currentSignature = ""
            clearSuggestion()
            // An app that cannot support completion at all is worth saying out
            // loud: silence here is indistinguishable from the app being broken.
            if let limitation = reader.lastLimitation?.limitation {
                announce(limitation.summary)
            } else if isTapActive {
                announce("Watching for typing.")
            }
            return
        }

        if isTapActive { announce("Watching for typing.") }

        guard context.bundleIdentifier != ownBundleID,
              preferences.suggestsIn(context.bundleIdentifier) else {
            clearSuggestion()
            return
        }

        track(context)
        currentBundleID = context.bundleIdentifier

        // This app has already shown it will not take insertions; a suggestion
        // here could not be accepted, and Tab belongs to the app.
        if insertionRefused(in: context.bundleIdentifier) {
            clearSuggestion()
            announce(standDownMessage(for: context.bundleIdentifier))
            return
        }

        let signature = context.signature
        guard signature != currentSignature else { return }
        currentSignature = signature
        record(context)
        // The text really did change, so anything still being generated is for
        // text that no longer exists.
        modelTask?.cancel()
        currentElement = context.element
        // Focus can move inside one app without a notification we saw, so point
        // the field registrations at whatever we just actually read.
        changes.refocus(on: context.element)

        // Terminals need their own treatment: the "text before the cursor" is
        // the whole screen buffer, and a suggestion accepted into a command line
        // would run.
        var before = context.textBeforeCursor
        if TerminalContext.isTerminal(context.bundleIdentifier) {
            guard preferences.terminalSuggestions else {
                clearSuggestion()
                return
            }
            before = TerminalContext.inputLine(from: before)
            guard TerminalContext.looksLikePrompt(before) else {
                clearSuggestion()
                return
            }
        }

        // A greeting waiting for a name is a lookup, not a prediction, and the
        // model is measurably bad at it: given a prompt naming Christine three
        // times over, "Hi C" came back as "," — the C read as an initial — and
        // "Hi " as a whole opening paragraph. The name is in the quoted
        // original and in the To: field the screen scan read, so it is looked
        // up and the model pass is skipped rather than left to overwrite it.
        if let greeting = Correspondent.greetingCompletion(
            for: before,
            in: [context.textAfterCursor, screenContext.cached(for: context).ocrText]
        ) {
            Log.core.debug("greeting completion (\(greeting.text.count) chars)")
            present(Suggestion(text: greeting.text, replacing: greeting.replacing, source: .heuristic),
                    in: context)
            return
        }

        let word = WordBoundary.currentWord(in: before)
        let typo = preferences.suppressOnTypo && WordBoundary.isMisspelled(word)
        let app = context.bundleIdentifier

        if let suggestion = heuristic.suggestSync(
            before: before,
            after: context.textAfterCursor,
            showFixes: preferences.showSuggestedFixes(in: app),
            emoji: preferences.emojiSuggestions(in: app)
        ), !(typo && !suggestion.isCorrection) {
            Log.core.debug("heuristic hit (\(suggestion.text.count) chars), caret=\(context.caretRect != nil, privacy: .public)")
            present(suggestion, in: context)
            // A replacement is an offer to rewrite the word just typed, not a
            // guess at what comes next. The model pass answers that different
            // question for the same caret and presents unconditionally when it
            // lands, so whatever arrives last wins: ":rocket" showed 🚀 and then
            // lost it to a continuation a few hundred milliseconds later.
            //
            // Spelling fixes were already safe by accident — a misspelled word
            // sets `typo`, and the guard below skips the model for it. A
            // shortcode is spelled correctly as far as the checker is concerned,
            // so nothing stopped it. Return on the replacement itself rather
            // than on being a typo, which is the same reason the greeting lookup
            // above returns instead of falling through.
            if suggestion.isCorrection { return }
        } else {
            Log.core.debug("no heuristic match")
            clearSuggestion()
        }

        // Never extend a word that already contains a typo: the completion would
        // build on a mistake. The fix for it is still offered above.
        guard !typo else { return }

        // Mid-line suggestions compete with text the user already wrote, so they
        // are opt-in.
        if preferences.midLineCompletions(in: app) || Self.isAtLineEnd(context.textAfterCursor) {
            // In a terminal "after the cursor" is the rest of the screen buffer,
            // not the rest of a sentence, so it is not context the way it is in
            // a reply. `before` is already narrowed to the input line above.
            let after = TerminalContext.isTerminal(context.bundleIdentifier)
                ? ""
                : context.textAfterCursor
            scheduleModelPass(before: before,
                              after: after,
                              appName: context.appName,
                              bundleID: app,
                              signature: signature)
        }
    }

    private func scheduleModelPass(
        before: String,
        after: String,
        appName: String?,
        bundleID: String?,
        signature: String
    ) {
        let maxWords = preferences.maxWords(in: bundleID)
        modelTask?.cancel()
        // The text has moved on, so anything gathered for the old caret is
        // about a sentence that no longer exists.
        dropAlternatives()
        guard preferences.useModel, let model, modelStatus.isReady else { return }
        // Mirrors `CompletionRequest.hasEnoughContext`, which is the backend's
        // own floor: a bare "Hi " is under it, and is exactly when a name is
        // wanted.
        guard before.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
            || Correspondent.isGreeting(before) else { return }

        modelTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.modelDebounce)
            guard !Task.isCancelled else { return }

            // Screen context rides the same debounce as the model: both are too
            // expensive for a keystroke, and neither is useful until typing
            // pauses. Results are cached, so this is usually a no-op.
            var screen = ScreenContextProvider.Context()
            if self.preferences.screenshotContext || self.preferences.screenshotAppearance,
               let focus = self.reader.readFocusedText(), focus.signature == signature {
                screen = await self.screenContext.refresh(
                    for: focus,
                    wantsOCR: self.preferences.screenshotContext,
                    wantsBackdrop: self.preferences.screenshotAppearance
                )
            }
            guard !Task.isCancelled else { return }

            let request = CompletionRequest(
                before: before,
                after: after,
                ocrText: screen.ocrText,
                clipboard: self.preferences.clipboardContext ? ClipboardContext.current() : nil,
                appName: appName,
                instructions: UserInstructions.current,
                recentPhrasing: self.personalizationSnapshot.recentPhrasing,
                vocabulary: self.personalizationSnapshot.vocabulary,
                needsLeadingSpace: WordBoundary.caretEndsCompleteWord(before),
                maxWords: maxWords,
                wordChoiceStrength: self.preferences.wordChoiceStrength
            )
            Log.core.notice("personalization phrasing=\(self.personalizationSnapshot.recentPhrasing.count, privacy: .public) vocab=\(self.personalizationSnapshot.vocabulary.count, privacy: .public) bias=\(String(format: "%.2f", self.preferences.wordChoiceStrength), privacy: .public)")
            let started = Date()
            self.candidateRequest = request
            let text = await model.complete(request)
            // Timed here rather than inside the backend, so the number stays
            // true of whatever engine is behind the protocol. A cancelled pass
            // is not recorded: it was abandoned partway and would report as
            // fast, dragging the window down exactly when the user is typing
            // quickly enough to cancel things.
            if !Task.isCancelled {
                self.latency.record(Int(Date().timeIntervalSince(started) * 1000))
            }

            Log.core.debug("model returned \(text?.count ?? 0) chars")
            guard !Task.isCancelled, let text, !text.isEmpty else { return }
            // The caret may have moved while the model was thinking.
            guard let now = self.reader.readFocusedText(), now.signature == signature else { return }
            self.present(Suggestion(text: text, source: .model), in: now)
        }
    }

    /// The caret counts as line-end when nothing but whitespace follows it.
    static func isAtLineEnd(_ after: String) -> Bool {
        guard let next = after.first else { return true }
        return next.isNewline || next.isWhitespace
    }

    /// Records how an insertion went. Returns true when this app has just been
    /// stood down, in which case the caller must not re-present anything.
    @discardableResult
    private func noteInsertion(succeeded: Bool, in app: String?) -> Bool {
        guard let app else { return false }
        guard !succeeded else {
            insertionFailures[app] = nil
            return false
        }

        let failures = (insertionFailures[app] ?? 0) + 1
        insertionFailures[app] = failures
        guard failures >= insertionFailureLimit else { return false }

        insertionFailures[app] = nil
        insertionRefusedUntil[app] = Date().addingTimeInterval(insertionStandDown)
        acceptGraceUntil = nil
        clearSuggestion()
        announce(standDownMessage(for: app))
        Log.core.notice("standing down in \(app, privacy: .public) after \(failures, privacy: .public) refused insertions")
        return true
    }

    private func insertionRefused(in app: String?) -> Bool {
        guard let app, let until = insertionRefusedUntil[app] else { return false }
        guard Date() < until else {
            insertionRefusedUntil[app] = nil
            return false
        }
        return true
    }

    private func standDownMessage(for app: String?) -> String {
        let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? app ?? "This app"
        return "\(name) will not accept insertions. Tab is yours there for 10 minutes."
    }

    private var withinAcceptGrace: Bool {
        guard let until = acceptGraceUntil else { return false }
        guard Date() < until else {
            acceptGraceUntil = nil
            return false
        }
        return true
    }

    private func present(_ suggestion: Suggestion, in context: FocusedTextContext) {
        // Deliberately does *not* cancel the grace. Presenting a suggestion is
        // no guarantee it survives — a poll that finds nothing to suggest clears
        // it again — and a Tab arriving in that sliver used to reach the app.
        // Only a real keystroke, handled in `handle`, ends the grace early.
        currentSuggestion = suggestion
        // Drawing it settles the question the scroll asked: the caret is in view.
        caretOutOfView = false
        if lastSuggestionText != suggestion.text { lastSuggestionText = suggestion.text }
        overlay.show(
            suggestion,
            at: context.caretRect,
            font: context.caretFont,
            textColor: context.caretTextColor,
            ghostColor: screenContext.cached(for: context).backdrop?.ghostColor,
            strikeRect: strikeRect(for: suggestion, in: context),
            // The same question `runFastPass` asks before it bothers the model
            // at all, asked again here because it decides something different:
            // there, whether to suggest; here, whether ghost text at the caret
            // would be drawn on top of the user's own words.
            atLineEnd: Self.isAtLineEnd(context.textAfterCursor),
            // Computed here rather than passed in, so every path that presents
            // gets it — including the redraw after a scroll, where the counter
            // has to come back with the suggestion it belongs to.
            badge: SuggestionOverlayController.positionBadge(
                index: candidateIndex, total: candidates.count
            )
        )
        syncHotKeys()
    }

    /// Screen rect of the word a correction replaces, so it can be struck
    /// through where it actually sits.
    private func strikeRect(for suggestion: Suggestion, in context: FocusedTextContext) -> CGRect? {
        guard suggestion.isCorrection else { return nil }
        return reader.rect(replacing: suggestion.replacing, in: context)
    }

    private func clearSuggestion() {
        repositionTask?.cancel()
        dropAlternatives()
        currentSuggestion = nil
        caretOutOfView = false
        overlay.hide()
        syncHotKeys()
    }

    // MARK: - Keeping the overlay attached to the caret

    /// Ghost text is drawn in our own window sitting on top of someone else's
    /// text, so it is only ever correct while that text is where we last saw it.
    /// None of these events change the field's contents, which means the
    /// completion pass would skip them entirely: `runFastPass` returns early on
    /// an unchanged signature, and the signature is text and caret index only.
    /// Without this the suggestion stayed on screen — over the desktop, over
    /// another app, over Mission Control — long after the field had gone.
    private func observeDisplacement() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            // Also the closest thing to a public signal that Mission Control or
            // Exposé has come up: the Dock takes over as the active app, which
            // deactivates whatever was holding the caret.
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            // `[weak self]` belongs on *this* closure. Put on the inner one it
            // reads as a weak capture and is not one: the inner closure is built
            // afresh each time the outer runs, so the outer has to hold `self`
            // to form the reference at all — strongly, having no capture list of
            // its own. Verified by watching for a `deinit` that never came.
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleDisplacement(.lost) }
            }
            observerTokens.append((workspace, token))
        }
        // Screens rearranged, resolution changed, a display plugged in: every
        // cached rect is in the old coordinate space.
        let screens = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDisplacement(.moved) }
        }
        observerTokens.append((.default, screens))
        // Scrolling is the displacement nothing else here can see. Accessibility
        // posts no notification for it, and the text and caret index are both
        // untouched, so `runFastPass` returns early — while on screen the line
        // the ghost text belongs to slides out from under it and the suggestion
        // stays behind, pinned to the pixels it was drawn on.
        //
        // A passive monitor rather than another event type on the tap: the
        // system disables a tap whose callback runs long, a scroll delivers
        // events by the hundred, and nothing here wants to alter a scroll — only
        // to know one happened.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScroll() }
        }
    }

    /// Scroll events arrive in bursts, so the common case — nothing showing —
    /// has to cost nothing.
    private func handleScroll() {
        guard currentSuggestion != nil || overlay.isVisible else { return }
        // Handled exactly like a window drag: down immediately, back once the
        // scrolling settles, wherever the caret rect says it belongs then.
        // Following the caret event by event would mean an Accessibility round
        // trip into an app that is already busy scrolling, and the ghost text
        // would still trail the line it is meant to sit on by a frame or two.
        handleDisplacement(.moved)
    }

    /// Takes the overlay down straight away, then either restores it where the
    /// caret has ended up or drops the suggestion for good.
    private func handleDisplacement(_ kind: AXChangeObserver.Displacement) {
        repositionTask?.cancel()
        overlay.hide()

        guard kind == .moved else {
            // The field is gone, so is any reason to keep what was written for
            // it. Clearing the signature too, because the user may well come
            // back to this exact text and would otherwise be met with silence:
            // the next pass would see nothing new and return before suggesting.
            currentSignature = ""
            clearSuggestion()
            return
        }

        repositionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.repositionDebounce)
            guard !Task.isCancelled else { return }
            self.repositionOverlay()
        }
    }

    /// Redraws whatever is already in hand at the caret's new position.
    ///
    /// Deliberately not a trip through `runFastPass`: the text has not changed,
    /// so asking the model again would burn a generation to arrive at the same
    /// words, and the unchanged-signature guard would return before redrawing
    /// anything at all.
    private func repositionOverlay() {
        guard preferences.isEnabled, AXIsProcessTrusted(), !isAccepting else { return }
        guard let context = reader.readFocusedText(),
              context.bundleIdentifier != ownBundleID,
              preferences.suggestsIn(context.bundleIdentifier),
              context.signature == currentSignature else {
            // The move took the caret with it — a different field, or none. Let
            // the next pass start from scratch rather than redraw against
            // geometry we can no longer vouch for.
            currentSignature = ""
            clearSuggestion()
            return
        }
        // The caret scrolled out of the viewport. The rect the app just handed
        // back is for a line that is no longer in view, so drawing against it
        // would put the suggestion over a toolbar, or over whatever the scroll
        // brought into its place. The suggestion and the signature are both kept
        // — the text has not changed, so scrolling back brings it straight back
        // with no second trip to the model.
        guard reader.caretIsVisible(in: context) else {
            caretOutOfView = true
            overlay.hide()
            syncHotKeys()
            return
        }
        guard let suggestion = currentSuggestion else { return }
        present(suggestion, in: context)
    }

    // MARK: - Diagnostics for the settings window

    /// Accumulates the current field's text and flushes the previous field when
    /// focus moves to a different app.
    private func track(_ context: FocusedTextContext) {
        guard let app = context.bundleIdentifier else { return }

        if let existing = session, existing.app != app {
            flushSession()
        }
        if session?.app != app {
            session = EditingSession(app: app, text: context.textBeforeCursor)
        } else {
            session?.text = context.textBeforeCursor
        }
    }

    /// Writes the finished session to the store, if policy allows it.
    ///
    /// Three gates, all of which must pass: recording is switched on, the app is
    /// not excluded, and either the user accepted a completion here or they have
    /// opted into recording regardless.
    func flushSession() {
        guard let finished = session else { return }
        session = nil

        guard preferences.mayRecord(finished.app) else { return }
        guard preferences.recordWithoutAcceptance || finished.acceptedCompletion else { return }

        let text = finished.text
        let app = finished.app
        let ours = finished.insertedText
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 12 else { return }

        Task { [personalization] in
            await personalization.record(text: text, app: app, ourOwnText: ours)
        }
        refreshPersonalization(for: app)
    }

    private func refreshPersonalization(for app: String?) {
        guard preferences.recordWriting else {
            personalizationSnapshot = PersonalizationStore.Snapshot(recentPhrasing: [], vocabulary: [:])
            return
        }
        Task { @MainActor [weak self, personalization] in
            let snapshot = await personalization.snapshot(app: app)
            self?.personalizationSnapshot = snapshot
        }
    }

    /// Called below the unchanged-signature guard, not above it. Above, it ran
    /// on every poll — rebuilding and republishing the same sentence every two
    /// seconds with nothing on screen to show it to.
    private func record(_ context: FocusedTextContext) {
        let app = context.bundleIdentifier ?? "unknown app"
        let tail = context.textBeforeCursor.suffix(28)
        let caret = context.caretRect == nil ? "no caret geometry" : "caret located"
        let description = "\(app) — \u{201C}…\(tail)\u{201D} (\(caret))"
        guard description != lastContextDescription else { return }
        lastContextDescription = description
    }

    /// True when nothing is standing in the way of a suggestion.
    var isReady: Bool {
        AXIsProcessTrusted() && preferences.isEnabled && isTapActive
            && reader.lastLimitation == nil && !SecureInput.isActive
    }

    /// A one-line answer to "why am I not seeing suggestions?".
    var diagnosis: String {
        if !AXIsProcessTrusted() {
            return "Accessibility permission is missing for the copy of FreeTypist that is running."
        }
        if !preferences.isEnabled {
            return "Suggestions are switched off."
        }
        if !isTapActive {
            return "Permission is granted but the keyboard tap was refused. Quit and reopen FreeTypist."
        }
        // Ahead of the limitation, which is about the app in front; this is
        // about the whole session and outranks it.
        if let paused = SecureInput.diagnosis() {
            return paused
        }
        if let limitation = reader.lastLimitation?.limitation {
            return limitation.detail
        }
        if insertionRefused(in: currentBundleID) {
            return standDownMessage(for: currentBundleID)
        }
        return "Ready. Type in another app and pause briefly."
    }

}
