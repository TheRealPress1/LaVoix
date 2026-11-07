@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Safari plays a call's sound in its own "Graphics and Media" process, which ScreenCaptureKit does not attribute to the app (a 76 minute call
/// on 2026-11-06 recorded the other side as digital silence). These pin how that call audio is chosen for a tap, and that it takes the
/// microphone to voice processing like FaceTime, on every route.
final class MeetingWebKitMediaTapTests: XCTestCase {
    private func mic(uid: String = "BuiltInMicrophoneDevice") -> MeetingMicrophoneIdentity {
        MeetingMicrophoneIdentity(captureDeviceID: uid, coreAudioUID: uid, displayName: "Mic")
    }

    private func speakers() -> MeetingOutputRouteSnapshot {
        MeetingOutputRouteSnapshot(deviceExists: true, isBluetooth: false, isBuiltIn: true, isHeadphonesDataSource: false)
    }

    private func decide(_ route: MeetingOutputRouteSnapshot, app: String?, mode: MeetingCaptureMode = .onlineCall) -> MeetingCapturePathDecision {
        MeetingCapturePathDecider.decide(
            mode: mode, microphone: self.mic(), outputRoute: route, preferDirectAEC3: true, applicationBundleIdentifier: app
        )
    }

    // MARK: Registry

    func testSafariIsReadWithATapAndFaceTimeStillIs() {
        XCTAssertTrue(MeetingAppRegistry.callAudioComesFromWebKitMedia(bundleIdentifier: "com.apple.Safari"))
        XCTAssertTrue(MeetingAppRegistry.callAudioIsTapped(bundleIdentifier: "com.apple.Safari"))
        XCTAssertTrue(MeetingAppRegistry.callAudioIsTapped(bundleIdentifier: "com.apple.FaceTime"))
        XCTAssertFalse(MeetingAppRegistry.callAudioComesFromSystemHelper(bundleIdentifier: "com.apple.Safari"), "Safari has no system helper")
    }

    func testTheSafariTapHasAKillSwitchThatNeedsNoNewBuild() {
        let key = MeetingAppRegistry.safariTapDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(MeetingAppRegistry.callAudioIsTapped(bundleIdentifier: "com.apple.Safari"))
        XCTAssertTrue(MeetingAppRegistry.callAudioIsTapped(bundleIdentifier: "com.apple.FaceTime"), "the switch is Safari's only")
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(MeetingAppRegistry.callAudioIsTapped(bundleIdentifier: "com.apple.Safari"), "on by default")
    }

    func testOtherAppsKeepTheirScreenCaptureAudio() {
        for bundle in ["us.zoom.xos", "com.google.Chrome", "com.microsoft.teams2", "company.thebrowser.Browser", nil] {
            XCTAssertFalse(MeetingAppRegistry.callAudioIsTapped(bundleIdentifier: bundle), "\(bundle ?? "nil")")
        }
    }

    // MARK: Capture path

    func testSafariJoinsVoiceProcessingOnSpeakersHeadphonesAndBluetooth() {
        let headphones = MeetingOutputRouteSnapshot(deviceExists: true, isBluetooth: false, isBuiltIn: true, isHeadphonesDataSource: true)
        let bluetooth = MeetingOutputRouteSnapshot(deviceExists: true, isBluetooth: true, isBuiltIn: false, isHeadphonesDataSource: false)
        for (name, route) in [("built-in speakers", self.speakers()), ("headphones", headphones), ("bluetooth", bluetooth)] {
            XCTAssertEqual(self.decide(route, app: "com.apple.Safari"), .voiceProcessing, name)
        }
    }

    func testSafariSpeakerCallNoLongerSelectsTheEchoCancellerThatNeedsTheSilentTrack() {
        // Before: Safari on the built-in speakers chose ScreenCaptureKit + direct AEC3, which uses the (silent) app track as its reference.
        let before = self.decide(self.speakers(), app: "us.zoom.xos")
        XCTAssertEqual(before, .screenCaptureKit(reason: MeetingCapturePathDecider.directAEC3DefaultReason))
        XCTAssertEqual(self.decide(self.speakers(), app: "com.apple.Safari"), .voiceProcessing)
    }

    func testAnInRoomRecordingNeverUsesVoiceProcessingEvenForSafari() {
        guard case .screenCaptureKit = self.decide(self.speakers(), app: "com.apple.Safari", mode: .inRoom) else {
            return XCTFail("in-room capture is microphone-only")
        }
    }

    // MARK: Which processes are tapped

    private typealias Matcher = MeetingCallAudioTap.WebKitMediaMatcher

    func testTheAppItselfAndItsOwnGraphicsAndMediaProcessAreTapped() {
        let gpu = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
        XCTAssertTrue(Matcher.matches(pid: 1027, path: "/Applications/Safari.app/Contents/MacOS/Safari", processName: "Safari", applicationPIDs: [1027], applicationName: "Safari"))
        XCTAssertTrue(Matcher.matches(pid: 1041, path: gpu, processName: "Safari Graphics and Media", applicationPIDs: [1027], applicationName: "Safari"))
    }

    func testAnotherWebKitAppsMediaProcessIsLeftAlone() {
        let gpu = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
        XCTAssertFalse(Matcher.matches(pid: 50709, path: gpu, processName: "Conductor Graphics and Media", applicationPIDs: [1027], applicationName: "Safari"))
        XCTAssertFalse(Matcher.matches(pid: 62510, path: gpu, processName: "myOS Graphics and Media", applicationPIDs: [1027], applicationName: "Safari"))
    }

    func testANameAloneIsNotEnoughAndAnUnknownAppTapsNothingExtra() {
        XCTAssertFalse(Matcher.matches(pid: 9, path: "/usr/bin/other", processName: "Safari Graphics and Media", applicationPIDs: [1027], applicationName: "Safari"))
        let gpu = "/x/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
        XCTAssertFalse(Matcher.matches(pid: 1041, path: gpu, processName: "Safari Graphics and Media", applicationPIDs: [1027], applicationName: nil))
        XCTAssertFalse(Matcher.matches(pid: 1041, path: gpu, processName: nil, applicationPIDs: [1027], applicationName: "Safari"))
    }
}
