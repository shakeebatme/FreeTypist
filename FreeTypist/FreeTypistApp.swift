import SwiftUI

@main
struct FreeTypistApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                model: model,
                preferences: model.preferences,
                coordinator: model.coordinator
            )
        } label: {
            // Both symbols verified to exist; a missing one renders blank.
            Image(systemName: model.preferences.isEnabled
                  ? "character.cursor.ibeam"
                  : "pause.circle.fill")
        }
        .menuBarExtraStyle(.menu)
        .onChange(of: model.launchStamp, initial: true) { _, _ in
            let coordinator = model.coordinator
            delegate.onTerminate = { coordinator.shutdownBlocking() }
        }

    }
}
