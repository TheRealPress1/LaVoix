import AppKit
import Combine
import SwiftUI

/// What the meeting card is showing.
@MainActor
final class NotchMeetingModel: ObservableObject {
    enum Phase: Equatable {
        case recording
        case processing
        case ended
        case failed(String)
    }

    @Published var phase: Phase = .recording
    @Published var startedAt = Date()
    /// Set once the meeting is over, so the card can show a fixed length.
    @Published var endedAt: Date?
    /// The most recent words heard, already trimmed to fit the card.
    @Published var caption = ""
    @Published var sourceName = ""

    var duration: TimeInterval { max(0, (self.endedAt ?? Date()).timeIntervalSince(self.startedAt)) }
}

/// Drops out of the notch while a meeting is recording: a live dot, the running time, the latest captions and a
/// stop button. When the meeting ends it turns into a "write notes" button.
struct NotchMeetingCardView: View {
    @ObservedObject var model: NotchMeetingModel
    let notchHeight: CGFloat
    var onStop: () -> Void = {}
    var onWriteNotes: () -> Void = {}
    var onShowCaptions: () -> Void = {}
    var onDismiss: () -> Void = {}

    var body: some View {
        let size = NotchGeometry.meetingCardSize(notchHeight: self.notchHeight)
        ZStack(alignment: .top) {
            NotchHubShape(topCornerRadius: 10, bottomCornerRadius: 28)
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                .overlay(alignment: .top) {
                    self.content
                        .padding(.top, self.notchHeight + 4)
                        .padding(.horizontal, 26)
                        .frame(width: size.width, height: size.height, alignment: .top)
                }
        }
        .frame(width: size.width + NotchGeometry.meetingCardPadding * 2, height: size.height + NotchGeometry.meetingCardPadding, alignment: .top)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var content: some View {
        switch self.model.phase {
        case .recording:
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    RecordingDot()
                    Text("Recording").font(.system(size: 13, weight: .semibold))
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(Self.clock(self.model.duration))
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 8)
                    Button(action: self.onStop) {
                        Text("Stop")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(Capsule().fill(Color.white))
                    }
                    .buttonStyle(.plain)
                }
                Button(action: self.onShowCaptions) {
                    Text(self.model.caption.isEmpty ? "Listening…" : self.model.caption)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(self.model.caption.isEmpty ? 0.4 : 0.8))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        case .processing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Transcribing the meeting…").font(.system(size: 13, weight: .medium))
                Spacer()
                Text(Self.clock(self.model.duration))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.top, 10)
        case .ended:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Meeting ended").font(.system(size: 13, weight: .semibold))
                    Text(Self.clock(self.model.duration) + (self.model.sourceName.isEmpty ? "" : " · " + self.model.sourceName))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: self.onWriteNotes) {
                    Text("Write notes")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
                Button(action: self.onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
        case let .failed(message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 15)).foregroundStyle(.orange)
                Text(message).font(.system(size: 12)).lineLimit(2).foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 8)
                Button(action: self.onWriteNotes) {
                    Text("Open").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 12).padding(.vertical, 5).background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct RecordingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 9, height: 9)
            .opacity(self.dim ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { self.dim = true }
            }
    }
}

/// A small non-activating panel under the notch, kept separate from the hub window so it only covers its own
/// area and never blocks clicks elsewhere. Hidden while the hub itself is open.
@MainActor
final class NotchMeetingCardController {
    static let shared = NotchMeetingCardController()

    let model = NotchMeetingModel()

    private weak var coordinator: MeetingSessionCoordinator?
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var dismissTask: Task<Void, Never>?
    private var wantsVisible = false
    private var hubObserver: AnyCancellable?

    private init() {}

    /// True while the card is on screen, so notification cards stay out of its way.
    var isShowing: Bool { self.shouldShow }

    func attach(coordinator: MeetingSessionCoordinator) {
        guard self.coordinator !== coordinator else { return }
        self.coordinator = coordinator
        self.cancellables.removeAll()
        coordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.apply(state: state) }
            .store(in: &self.cancellables)
        coordinator.$liveTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in self?.updateCaption(snapshot) }
            .store(in: &self.cancellables)
    }

    /// The hub started or stopped; show or remove the card to match.
    func hubStateChanged() {
        if NotchHubController.shared.isRunning {
            self.hubObserver = NotchHubController.shared.model.$isOpen
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.syncPanel() }
        } else {
            self.hubObserver = nil
        }
        self.syncPanel()
    }

    // MARK: - State

    private func apply(state: MeetingCoordinatorState) {
        self.dismissTask?.cancel()
        switch state {
        case .recording, .recordingDegraded:
            if let session = self.coordinator?.activeSession { self.model.startedAt = session.startedAt }
            self.model.endedAt = nil
            self.model.sourceName = self.coordinator?.sourceDisplayName ?? ""
            self.model.phase = .recording
            self.wantsVisible = true
        case .stopping, .processing:
            self.model.endedAt = self.coordinator?.activeSession?.endedAt ?? Date()
            self.model.phase = .processing
            self.wantsVisible = true
        case .completed:
            if let session = self.coordinator?.latestCompletedSession {
                self.model.startedAt = session.startedAt
                self.model.endedAt = session.endedAt ?? Date()
            }
            self.model.phase = .ended
            self.wantsVisible = true
            self.scheduleDismiss(after: 60)
        case .interrupted:
            self.model.phase = .failed("Recording was interrupted. Your audio is saved.")
            self.wantsVisible = true
            self.scheduleDismiss(after: 25)
        case let .failed(_, failure):
            self.model.phase = .failed(failure.message)
            self.wantsVisible = true
            self.scheduleDismiss(after: 25)
        case .idle, .preparing:
            self.wantsVisible = false
            self.model.caption = ""
        }
        self.syncPanel()
    }

    private func updateCaption(_ snapshot: MeetingLiveTranscriptSnapshot) {
        let rows = MeetingLiveBubbleComposer.rows(for: snapshot)
        guard let last = rows.last else { self.model.caption = ""; return }
        // Two lines fit about 110 characters; keep the tail so the newest words are the ones visible.
        let text = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model.caption = text.count > 110 ? "…" + text.suffix(108) : text
    }

    private func scheduleDismiss(after seconds: Double) {
        self.dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    // MARK: - Actions

    func stop() {
        guard let coordinator else { return }
        Task { _ = try? await coordinator.stopAndTranscribe() }
    }

    func writeNotes() {
        self.dismiss()
        MenuBarManager.current?.openMeetingsFromUI()
    }

    func showCaptions() {
        MeetingRecordingPillController.shared.expand()
    }

    func dismiss() {
        self.dismissTask?.cancel()
        self.wantsVisible = false
        self.syncPanel()
    }

    // MARK: - Panel

    private var shouldShow: Bool {
        self.wantsVisible && NotchHubController.shared.isRunning && !NotchHubController.shared.model.isOpen
    }

    private func syncPanel() {
        guard self.shouldShow, let screen = NotchGeometry.targetScreen() else {
            self.panel?.orderOut(nil)
            return
        }
        let frame = NotchGeometry.meetingCardFrame(for: screen)
        let panel = self.panel ?? self.makePanel(frame: frame, notchHeight: NotchGeometry.closedSize(for: screen).height)
        self.panel = panel
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel(frame: NSRect, notchHeight: CGFloat) -> NSPanel {
        let panel = NotchHubWindow(frame: frame)
        panel.ignoresMouseEvents = false
        let view = NotchMeetingCardView(
            model: self.model,
            notchHeight: notchHeight,
            onStop: { [weak self] in self?.stop() },
            onWriteNotes: { [weak self] in self?.writeNotes() },
            onShowCaptions: { [weak self] in self?.showCaptions() },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }

    // MARK: - Debug

    func debugPresent(_ phase: NotchMeetingModel.Phase) {
        self.dismissTask?.cancel()
        self.model.phase = phase
        self.model.startedAt = Date().addingTimeInterval(-754)
        self.model.endedAt = phase == .recording ? nil : Date()
        self.model.caption = "…so let's move the launch to the 14th and I'll send the revised plan tonight."
        self.model.sourceName = "Zoom"
        self.wantsVisible = true
        self.syncPanel()
    }

    func debugReport(_ label: String) -> String {
        guard let panel else { return "[\(label)] meeting card: no panel" }
        let f = panel.frame
        return "[\(label)] meeting card: visible=\(panel.isVisible) frame=(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))) phase=\(self.model.phase)"
    }
}
