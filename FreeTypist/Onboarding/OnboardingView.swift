import SwiftUI

struct OnboardingView: View {
    @ObservedObject var onboarding: OnboardingModel
    @ObservedObject var models: ModelRepository

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                if !onboarding.isFirstStep {
                    Button("Back") { onboarding.goBack() }
                }
                Spacer()
                dots
                Spacer()
                Button(onboarding.advanceTitle) { onboarding.advance() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!onboarding.canAdvance && onboarding.step != .accessibility)
            }
        }
        .padding(28)
        .frame(width: 620, height: 540)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(onboarding.visibleSteps, id: \.rawValue) { step in
                Circle()
                    .fill(step == onboarding.step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: step == onboarding.step ? 18 : 7, height: 7)
                    .clipShape(Capsule())
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch onboarding.step {
        case .welcome:
            VStack(alignment: .leading, spacing: 14) {
                Text("Hi there!").font(.system(size: 26, weight: .bold))
                Text("FreeTypist **auto-completes as you type** on your Mac. Completions **happen locally** and never leave this machine.")
                Text("**You stay in the driver's seat**, only taking the completions *you* want.")
                Text("**Let's try it.** Press the ⇥ (Tab) key to complete one word at a time.")
                OnboardingDemoField(accepted: $onboarding.demoAccepted)
                    .frame(height: 60)
                if onboarding.demoAccepted {
                    Label("That's it — that is the whole interaction.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

        case .accessibility:
            VStack(alignment: .leading, spacing: 14) {
                Text("Permissions…").font(.system(size: 26, weight: .bold))
                Text("To show completions, FreeTypist needs permission to use your Mac's Accessibility features.")
                Text("This is how it reads the text around your cursor and inserts a completion you accept. It is the only permission that is required.")
                    .foregroundStyle(.secondary)
                if onboarding.accessibility.isTrusted {
                    Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("Not granted yet — switch FreeTypist on in System Settings, then come back.",
                          systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                }
            }

        case .screenRecording:
            VStack(alignment: .leading, spacing: 14) {
                Text("One optional extra").font(.system(size: 26, weight: .bold))
                Text("Screen Recording lets FreeTypist read what is on screen around the field, so completions fit their surroundings, and sample the colour behind your cursor so they stay readable on dark backgrounds.")
                Text("Screen contents are processed on this Mac and never stored or sent anywhere. macOS may briefly show a purple recording indicator.")
                    .foregroundStyle(.secondary)
                if ScreenCaptureService.hasPermission {
                    Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Grant Screen Recording") { _ = ScreenCaptureService.requestPermission() }
                }
                Text("You can skip this and change it later in Context settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }

        case .model:
            VStack(alignment: .leading, spacing: 14) {
                Text("One more thing…").font(.system(size: 26, weight: .bold))
                Text("FreeTypist needs a language model to show completions. It runs on this Mac, so it has to be downloaded once.")
                if let spec = models.recommendedForThisMac {
                    Text("Recommended for your system: **\(spec.name)**")
                        .foregroundStyle(.secondary)
                }
                ModelPicker(repository: models, coordinator: nil)
            }

        case .download:
            VStack(alignment: .leading, spacing: 14) {
                Text("One more thing…").font(.system(size: 26, weight: .bold))
                Text("Downloading the model. You can carry on to the next step; it continues in the background.")
                Text("Completions will start appearing automatically once the download has finished.")
                ProgressView(value: models.progress)
                    .progressViewStyle(.linear)
                Text("\(Int(models.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

        case .personalize:
            VStack(alignment: .leading, spacing: 12) {
                Text("Get the most out of FreeTypist").font(.system(size: 24, weight: .bold))
                Text("**Tell it how you write** using the instructions below. We have filled in a starting point from your Mac's settings; adjust it however you like. You can always edit this later in Settings.")
                    .font(.callout)

                Toggle(isOn: $onboarding.personalize) {
                    Text("Personalize completions to my writing")
                }
                Text("FreeTypist records what you type in the fields where it suggests, so completions match your own words. The recorded text is encrypted and stays on this Mac. Leave this off if you regularly write something sensitive.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle(isOn: $onboarding.disableSystemSuggestions) {
                    Text("Turn off macOS's built-in text suggestions")
                }
                Text("macOS's own grey suggestions and autocorrect bubble overlap FreeTypist's.")
                    .font(.caption).foregroundStyle(.secondary)

                TextEditor(text: $onboarding.instructions)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }
        }
    }
}
