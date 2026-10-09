import AVFoundation
import SwiftUI

/// LaVoix onboarding: a landing screen, then one setup screen with the three things the app needs
/// (microphone, accessibility, voice engine). The voice engine is fixed to English Parakeet and
/// downloads automatically; everything else can be changed later in Settings.
struct LaVoixOnboardingView: View {
    @EnvironmentObject private var appServices: AppServices
    @ObservedObject private var settings = SettingsStore.shared

    let accessibilityEnabled: Bool
    let openAccessibilitySettings: () -> Void
    let finishOnboarding: () -> Void

    @State private var showsSetup = false
    @State private var isPreparingEngine = false
    @State private var engineErrorMessage: String?

    private var asr: ASRService {
        self.appServices.asr
    }

    private static let engineModel = SettingsStore.SpeechModel.parakeetTDTv2

    private var isMicrophoneReady: Bool {
        self.asr.micStatus == .authorized
    }

    private var isEngineReady: Bool {
        self.asr.isAsrReady && self.settings.selectedSpeechModel == Self.engineModel
    }

    private var isSetupComplete: Bool {
        self.isMicrophoneReady && self.accessibilityEnabled && self.isEngineReady
    }

    var body: some View {
        Group {
            if self.showsSetup {
                self.setupScreen
            } else {
                self.landingScreen
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            FluidOnboardingLandingBackdrop()
        }
        .background {
            FluidOnboardingWindowTransparency()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.asr.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    // MARK: - Landing

    private var landingScreen: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            FluidOnboardingCompactAppIconMark(size: 220)

            Text("your voice is your instrument.")
                .font(LaVoixFonts.tagline(size: 46))
                .foregroundStyle(Color.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .padding(.top, 36)

            FluidOnboardingArrowButton {
                self.showsSetup = true
                self.prepareEngineIfNeeded()
            }
            .padding(.top, 56)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Setup

    private var setupScreen: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            FluidOnboardingCompactAppIconMark(size: 120)

            Text("three quick things.")
                .font(LaVoixFonts.tagline(size: 40))
                .foregroundStyle(Color.white.opacity(0.92))
                .padding(.top, 24)

            VStack(spacing: 12) {
                self.setupRow(
                    title: "microphone",
                    isReady: self.isMicrophoneReady,
                    actionTitle: self.asr.micStatus == .notDetermined ? "allow" : "open settings",
                    action: self.handleMicrophoneAction
                )

                self.setupRow(
                    title: "accessibility",
                    isReady: self.accessibilityEnabled,
                    actionTitle: "open settings",
                    action: self.openAccessibilitySettings
                )

                self.setupRow(
                    title: "voice engine",
                    detail: self.engineDetail,
                    isReady: self.isEngineReady,
                    isBusy: self.isPreparingEngine,
                    actionTitle: self.engineErrorMessage == nil ? nil : "retry",
                    action: self.prepareEngineIfNeeded
                )
            }
            .frame(width: 460)
            .padding(.top, 36)

            FluidOnboardingArrowButton(isEnabled: self.isSetupComplete) {
                self.complete()
            }
            .padding(.top, 44)

            Spacer(minLength: 0)
        }
    }

    private var engineDetail: String? {
        if let message = self.engineErrorMessage {
            return message
        }
        if self.isEngineReady {
            return nil
        }
        if self.isPreparingEngine {
            return self.asr.isLoadingModel && !self.asr.isDownloadingModel ? "loading…" : "downloading…"
        }
        return nil
    }

    private func setupRow(
        title: String,
        detail: String? = nil,
        isReady: Bool,
        isBusy: Bool = false,
        actionTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.fluidSystem(size: 17, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.92))
                if let detail {
                    Text(detail)
                        .font(.fluidSystem(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(2)
                }
            }

            Spacer()

            if isReady {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white)
            } else if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
            } else if let actionTitle {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.fluidSystem(size: 14, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 60)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    // MARK: - Actions

    private func handleMicrophoneAction() {
        if self.asr.micStatus == .notDetermined {
            self.asr.requestMicAccess()
        } else {
            self.asr.openSystemSettingsForMic()
        }
    }

    private func prepareEngineIfNeeded() {
        guard !self.isPreparingEngine, !self.isEngineReady else { return }
        guard let route = VoiceEngineLanguageCatalog.routes(forLanguageID: "en").first(where: { $0.model == Self.engineModel }) else {
            self.engineErrorMessage = "voice engine unavailable"
            return
        }

        let previousModel = self.settings.selectedSpeechModel
        VoiceEngineLanguageCatalog.apply(route, to: self.settings)
        if previousModel != self.settings.selectedSpeechModel {
            self.asr.resetTranscriptionProvider()
        }

        self.engineErrorMessage = nil
        self.isPreparingEngine = true
        Task { @MainActor in
            defer { self.isPreparingEngine = false }
            do {
                try await self.asr.ensureAsrReady(source: .onboarding)
            } catch is CancellationError {
                return
            } catch {
                self.engineErrorMessage = error.localizedDescription
            }
            await self.asr.checkIfModelsExistAsync()
        }
    }

    private func complete() {
        guard self.isSetupComplete else { return }
        self.settings.onboardingAISkipped = true
        self.settings.onboardingPlaygroundSkipped = true
        self.settings.setDictationPromptSelection(.off)
        self.finishOnboarding()
    }
}
