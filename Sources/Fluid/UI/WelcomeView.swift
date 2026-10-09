import AppKit
import AVFoundation
import Combine
import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var appServices: AppServices
    @Binding var selectedSidebarItem: SidebarItem?
    let accessibilityEnabled: Bool
    let openAccessibilitySettings: () -> Void
    let openFluidIntelligenceDemo: () -> Void
    let openShortcutSettings: () -> Void

    var body: some View {
        DashboardView(
            asr: self.appServices.asr,
            selectedSidebarItem: self.$selectedSidebarItem,
            accessibilityEnabled: self.accessibilityEnabled,
            openAccessibilitySettings: self.openAccessibilitySettings,
            openFluidIntelligenceDemo: self.openFluidIntelligenceDemo,
            openShortcutSettings: self.openShortcutSettings
        )
        .task {
            await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
            await AudioStartupGate.shared.waitUntilOpen()
            guard !Task.isCancelled else { return }
            self.appServices.asr.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            await self.appServices.asr.checkIfModelsExistAsync()
        }
    }
}
