@testable import FluidVoice_Debug
import CoreAudio
import Foundation
import XCTest

final class MeetingCaptureDecisionLogTests: XCTestCase {
    private func facts(path: String = "screenCaptureKit", reason: String? = "DEBUG direct AEC3 selected.") -> MeetingCaptureDecisionLog.Facts {
        MeetingCaptureDecisionLog.Facts(
            mode: .onlineCall,
            applicationBundleIdentifier: "com.apple.Safari",
            applicationProcessID: 1027,
            applicationDisplayID: 3,
            microphoneName: "MacBook Pro Microphone",
            microphoneIsBuiltIn: true,
            outputRoute: MeetingOutputRouteSnapshot(deviceExists: true, isBluetooth: false, isBuiltIn: true, isHeadphonesDataSource: false),
            path: path,
            pathReason: reason,
            directAEC3Enabled: true,
            callAudioSource: "screenCaptureKit",
            captureScope: "window"
        )
    }

    func testTheLineSaysWhatTheRecorderDecidedAndWhatItSaw() {
        let line = MeetingCaptureDecisionLog.line(self.facts())
        for expected in [
            "Meeting capture decisions:", "mode=onlineCall", "app=com.apple.Safari", "appPID=1027", "appDisplayID=3",
            "mic=\"MacBook Pro Microphone\"", "micBuiltIn=yes", "outputExists=yes", "outputBuiltIn=yes", "outputBluetooth=no",
            "outputHeadphones=no", "path=screenCaptureKit", "pathReason=\"DEBUG direct AEC3 selected.\"", "directAEC3=enabled",
            "callAudio=screenCaptureKit", "scope=window",
        ] {
            XCTAssertTrue(line.contains(expected), "missing \(expected) in: \(line)")
        }
    }

    func testVoiceProcessingHasNoReasonAndAnInRoomMeetingHasNoApplication() {
        var voiceProcessing = self.facts(path: "voiceProcessing", reason: nil)
        voiceProcessing.callAudioSource = "tap"
        let line = MeetingCaptureDecisionLog.line(voiceProcessing)
        XCTAssertFalse(line.contains("pathReason"))
        XCTAssertTrue(line.contains("callAudio=tap"))

        var inRoom = self.facts(path: "inRoom", reason: nil)
        inRoom.mode = .inRoom
        inRoom.applicationBundleIdentifier = nil
        inRoom.applicationProcessID = nil
        inRoom.applicationDisplayID = nil
        inRoom.captureScope = nil
        let roomLine = MeetingCaptureDecisionLog.line(inRoom)
        XCTAssertTrue(roomLine.contains("app=none") && roomLine.contains("appPID=none") && roomLine.contains("scope=none"))
    }

    func testAHeadphoneRouteIsReportedFromEitherEvidence() {
        var headphones = self.facts()
        headphones.outputRoute = MeetingOutputRouteSnapshot(deviceExists: true, isBluetooth: false, isBuiltIn: true, isHeadphonesDataSource: true)
        XCTAssertTrue(MeetingCaptureDecisionLog.line(headphones).contains("outputHeadphones=yes"))
        var terminal = self.facts()
        terminal.outputRoute = MeetingOutputRouteSnapshot(
            deviceExists: true, isBluetooth: false, isBuiltIn: false, isHeadphonesDataSource: false, terminalTypes: [kAudioStreamTerminalTypeHeadphones]
        )
        XCTAssertTrue(MeetingCaptureDecisionLog.line(terminal).contains("outputHeadphones=yes"))
    }
}
