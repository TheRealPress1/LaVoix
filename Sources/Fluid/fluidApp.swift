//
//  fluidApp.swift
//  fluid
//
//  Created by Barathwaj Anandan on 7/30/25.
//

import AppKit
import ApplicationServices
import SwiftUI

@main
struct FluidApp: App {
    @StateObject private var menuBarManager = MenuBarManager()
    @ObservedObject private var settings = SettingsStore.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        LocalCleanupSelfTest.runIfRequested()
        EvalRunner.runIfRequested()
        EngineSocketAutotest.runIfRequested()
        WritingRecoveryAutotest.runIfRequested()
        MeetingCaptureTargetAutotest.runIfRequested()
        MeetingTranscriptAttachTool.runIfRequested()
        NotchHubDebug.renderIfRequested()
        NotchHubDebug.autotestIfRequested()
        NotchHubDebug.nowPlayingProbeIfRequested()
        NotchHubDebug.meetingCardAutotestIfRequested()
        NotchHubDebug.autoNotesAutotestIfRequested()
        NotchHubDebug.contactsExportAutotestIfRequested()
        NotchHubDebug.messagesExportAutotestIfRequested()
        NotchHubDebug.peopleAutotestIfRequested()
        NotchHubDebug.clipboardAutotestIfRequested()
        NotchHubDebug.messagesAutotestIfRequested()
        NotchHubDebug.calendarAutotestIfRequested()
        NotchHubDebug.nowPlayingHistoryAutotestIfRequested()
        NotchHubDebug.typingTestIfRequested()
        NotchHubDebug.lagTestIfRequested()
        NotchHubDebug.downloaderAutotestIfRequested()
        NotchHubDebug.downloaderE2EIfRequested()
        NotificationProbe.runIfRequested()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            #if DEBUG
            if MeetingExternalReferenceTrialAGate.autorunEnabled(environment: ProcessInfo.processInfo.environment)
                || MeetingSCKPairedDiagnosticGate.autorunEnabled()
                || MeetingStage05EvidenceAutorun.requested()
                || ProcessInfo.processInfo.environment["FLUIDVOICE_MIC_PHASE1"] != nil
                || ProcessInfo.processInfo.environment["FLUIDVOICE_VPIO_ACOUSTIC"] == "1"
            {
                Color.clear
            } else {
                self.applicationContent
            }
            #else
            self.applicationContent
            #endif
        }
        .defaultSize(width: 1000, height: 700)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    self.menuBarManager.openPreferencesFromUI()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Find") {
                    NotificationCenter.default.post(name: .sidebarSearchFocusRequested, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }

    private var applicationContent: some View {
        AdaptiveAppTheme(accent: self.settings.accentColor) {
            ContentView()
                .environmentObject(self.menuBarManager)
                // Resolve the singleton only when the normal application content branch is built.
                // The DEBUG C2 autorun branch returns Color.clear before this view is evaluated.
                .environmentObject(AppServices.shared)
        }
    }
}
