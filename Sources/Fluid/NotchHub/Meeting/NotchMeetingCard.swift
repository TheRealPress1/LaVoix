import AppKit
import Combine
import SwiftUI

/// What the meeting card is showing.
@MainActor
final class NotchMeetingModel: ObservableObject {
    enum Phase: Equatable {
        /// A calendar meeting is starting; offer to record or join.
        case starting
        /// A call was detected (Zoom, Teams, Meet…); one click on the card starts recording.
        case detected
        case recording
        case processing
        case ended
        case failed(String)

        /// The slim one-row card.
        var isCompact: Bool { self == .starting || self == .detected }
    }

    @Published var phase: Phase = .recording
    @Published var startedAt = Date()
    /// Set once the meeting is over, so the card can show a fixed length.
    @Published var endedAt: Date?
    /// The most recent words heard, already trimmed to fit the card.
    @Published var caption = ""
    @Published var sourceName = ""
    @Published var event: CalendarStore.Event?
    /// The detected call: its app icon, name, and what the card says while starting or after a failed start.
    @Published var detectedIcon: NSImage?
    @Published var detectedName = ""
    @Published var detectedStarting = false
    @Published var detectedError: String?
    /// Progress of the automatic notes once the meeting is over.
    @Published var notes: MeetingAutoAnalysis.Status = .idle

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
    var onRecordEvent: () -> Void = {}
    var onJoin: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onDetectedTap: () -> Void = {}
    var onDetectedNeverAgain: () -> Void = {}
    var onDetectedHover: (Bool) -> Void = { _ in }

    var body: some View {
        let size = NotchGeometry.meetingCardSize(notchHeight: self.notchHeight, compact: self.model.phase.isCompact)
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
        case .starting:
            HStack(spacing: 10) {
                Circle().fill(self.model.event?.color ?? .blue).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(self.model.event?.title ?? "Meeting").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let event = self.model.event {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Self.countdown(to: event.start, now: context.date))
                                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
                Spacer(minLength: 8)
                if self.model.event?.joinURL != nil {
                    Button(action: self.onJoin) {
                        Text("Join").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 14).padding(.vertical, 5).background(Capsule().fill(Color.white))
                    }
                    .buttonStyle(.plain)
                }
                Button(action: self.onRecordEvent) {
                    // A plain red record dot, like a camera's record light.
                    ZStack {
                        Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5).frame(width: 20, height: 20)
                        Circle().fill(Color(red: 1, green: 0.27, blue: 0.23)).frame(width: 11, height: 11)
                    }
                }
                .buttonStyle(.plain)
                .help("Record this meeting")
                Button(action: self.onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        case .detected:
            HStack(spacing: 10) {
                Button(action: self.onDetectedTap) {
                    HStack(spacing: 10) {
                        if let icon = self.model.detectedIcon {
                            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                                .frame(width: 26, height: 26)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(self.model.detectedName.isEmpty ? "Meeting detected" : self.model.detectedName)
                                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            if let error = self.model.detectedError {
                                Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
                            } else {
                                Text(self.model.detectedStarting ? "Starting…" : "Click to record")
                                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                            }
                        }
                        Spacer(minLength: 8)
                        if self.model.detectedStarting {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            ZStack {
                                Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5).frame(width: 20, height: 20)
                                Circle().fill(Color(red: 1, green: 0.27, blue: 0.23)).frame(width: 11, height: 11)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(self.model.detectedStarting)
                .help("Record this meeting")
                Button(action: self.onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .disabled(self.model.detectedStarting)
                .contextMenu { Button("Don’t show again", action: self.onDetectedNeverAgain) }
            }
            .padding(.top, 4)
            .onHover { self.onDetectedHover($0) }
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
                if case .writing = self.model.notes {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 16))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(self.endedTitle).font(.system(size: 13, weight: .semibold))
                    Text(self.endedSubtitle)
                        .font(.system(size: 11)).foregroundStyle(self.endedSubtitleIsError ? Color.orange : .white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 8)
                if case .writing = self.model.notes {
                    EmptyView()
                } else {
                    Button(action: self.onWriteNotes) {
                        Text(self.endedButton)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Capsule().fill(Color.white))
                    }
                    .buttonStyle(.plain)
                }
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

    private var endedTitle: String {
        switch self.model.notes {
        case .writing: return "Writing notes…"
        case .ready: return "Notes ready"
        default: return "Meeting ended"
        }
    }

    private var endedSubtitle: String {
        if case let .failed(message) = self.model.notes { return message }
        if case let .writing(progress) = self.model.notes, progress != "Writing notes…" { return progress }
        return Self.clock(self.model.duration) + (self.model.sourceName.isEmpty ? "" : " · " + self.model.sourceName)
    }

    private var endedSubtitleIsError: Bool {
        if case .failed = self.model.notes { return true }
        return false
    }

    private var endedButton: String {
        if case .ready = self.model.notes { return "Open" }
        return "Write notes"
    }

    /// "Starts in 1:45", "Starting now", "Started 2 min ago".
    static func countdown(to start: Date, now: Date) -> String {
        let seconds = Int(start.timeIntervalSince(now).rounded(.up))
        if seconds > 0 { return "Starts in " + String(format: "%d:%02d", seconds / 60, seconds % 60) }
        if seconds > -30 { return "Starting now" }
        return "Started \(max(1, -seconds / 60)) min ago"
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

    /// True while the card is on screen.
    var isShowing: Bool { self.shouldShow }

    /// Only a live recording (or its transcription) keeps message cards away. A "meeting starting" or "meeting ended"
    /// card is just a prompt, so a new message replaces it instead of being swallowed.
    var blocksBanners: Bool {
        guard self.shouldShow else { return false }
        return self.model.phase == .recording || self.model.phase == .processing
    }

    /// True while the "meeting detected" card is the thing on screen.
    var isShowingDetected: Bool { self.shouldShow && self.model.phase == .detected }

    /// Takes away a prompt-style card (starting, ended, failed) to make room for a message card.
    func dismissPrompt() {
        guard self.wantsVisible, !self.blocksBanners else { return }
        if self.model.phase == .detected {
            // A message replaces the detection prompt; the detector treats that as the prompt timing out.
            MeetingDetectionPromptController.shared.notchCardReplaced()
            return
        }
        self.dismiss()
    }

    func attach(coordinator: MeetingSessionCoordinator) {
        guard self.coordinator !== coordinator else { return }
        self.coordinator = coordinator
        self.cancellables.removeAll()
        coordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.apply(state: state) }
            .store(in: &self.cancellables)
        MeetingAutoAnalysis.shared.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.analysisChanged(status) }
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

    func apply(state: MeetingCoordinatorState) {
        // `idle` is re-published often. It must not wipe, or cancel the timer of, a "meeting starting" prompt that is on
        // screen: cancelling the timer here left that card up for good, covering the notch and blocking message cards.
        switch state {
        case .idle, .preparing:
            if self.model.phase.isCompact, self.wantsVisible { return }
        default: break
        }
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
            if let session = self.coordinator?.latestCompletedSession { MeetingAutoAnalysis.shared.start(session: session) }
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

    private func analysisChanged(_ status: MeetingAutoAnalysis.Status) {
        self.model.notes = status
        guard self.model.phase == .ended else { return }
        switch status {
        case .writing: self.dismissTask?.cancel()
        case .ready, .failed: self.scheduleDismiss(after: 60)
        case .idle: break
        }
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

    /// Offers to record a calendar meeting that is starting, unless a recording or its follow-up is already showing.
    func presentStarting(_ event: CalendarStore.Event) {
        if let state = self.coordinator?.state {
            switch state {
            case .idle, .completed, .interrupted, .failed: break
            default: return
            }
        }
        self.dismissTask?.cancel()
        self.model.event = event
        self.model.phase = .starting
        self.wantsVisible = true
        self.syncPanel()
        self.scheduleDismiss(after: max(0, event.start.timeIntervalSinceNow) + self.startingDismissSeconds)
    }

    // MARK: - Detected call

    /// Shows the "meeting detected" card. Returns false when the notch can't show it, so the caller falls back to the
    /// floating prompt. Timing belongs to `MeetingDetectionPromptController`, so no dismiss timer runs here.
    func presentDetected(icon: NSImage?, name: String) -> Bool {
        guard NotchHubController.shared.isRunning, NotchGeometry.targetScreen() != nil else { return false }
        if let state = self.coordinator?.state {
            switch state {
            case .idle, .completed, .interrupted, .failed: break
            default: return false
            }
        }
        self.dismissTask?.cancel()
        self.model.detectedIcon = icon
        self.model.detectedName = name
        self.model.detectedStarting = false
        self.model.detectedError = nil
        self.model.phase = .detected
        self.wantsVisible = true
        self.syncPanel()
        return true
    }

    func updateDetected(starting: Bool, error: String?) {
        guard self.model.phase == .detected else { return }
        self.model.detectedStarting = starting
        self.model.detectedError = error
    }

    /// Takes the detected card away, but leaves a recording card that has since replaced it alone.
    func withdrawDetected() {
        guard self.model.phase == .detected else { return }
        self.wantsVisible = false
        self.syncPanel()
    }

    /// How long the "meeting starting" prompt stays up. Tests shorten it.
    var startingDismissSeconds: Double = 90

    /// Starts recording for a calendar event: an online call when it has a call link, otherwise in the room.
    func record(_ event: CalendarStore.Event) {
        guard let coordinator else { return }
        Task {
            do {
                let configuration = try await coordinator.defaultConfiguration(
                    mode: event.joinURL != nil ? .onlineCall : .inRoom, title: event.title
                )
                _ = try await coordinator.startRecording(configuration: configuration)
            } catch {
                self.dismissTask?.cancel()
                self.model.phase = .failed(error.localizedDescription)
                self.wantsVisible = true
                self.syncPanel()
                self.scheduleDismiss(after: 25)
            }
        }
    }

    func joinEventCall() {
        if let url = self.model.event?.joinURL { NSWorkspace.shared.open(url) }
        self.dismiss()
    }

    func showCaptions() {
        MeetingRecordingPillController.shared.expand()
    }

    func dismiss() {
        if self.model.phase == .detected, self.wantsVisible, MeetingDetectionPromptController.shared.request != nil {
            MeetingDetectionPromptController.shared.dismissTapped()
            return
        }
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
        let frame = NotchGeometry.meetingCardFrame(for: screen, compact: self.model.phase.isCompact)
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
            onRecordEvent: { [weak self] in if let event = self?.model.event { self?.record(event) } },
            onJoin: { [weak self] in self?.joinEventCall() },
            onDismiss: { [weak self] in self?.dismiss() },
            onDetectedTap: { MeetingDetectionPromptController.shared.startTapped() },
            onDetectedNeverAgain: { MeetingDetectionPromptController.shared.dontShowAgainTapped() },
            onDetectedHover: { MeetingDetectionPromptController.shared.notchCardHover($0) }
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
        self.model.detectedName = "Zoom"
        self.wantsVisible = true
        self.syncPanel()
    }

    func debugReport(_ label: String) -> String {
        guard let panel else { return "[\(label)] meeting card: no panel" }
        let f = panel.frame
        return "[\(label)] meeting card: visible=\(panel.isVisible) frame=(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))) phase=\(self.model.phase)"
    }
}
