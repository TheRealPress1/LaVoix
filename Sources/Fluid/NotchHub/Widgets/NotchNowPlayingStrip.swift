import AppKit
import Combine
import SwiftUI

/// Whether the closed notch shows what is playing. On unless switched off.
enum NotchNowPlayingAmbientSettings {
    private static let key = "LaVoixNotchNowPlayingAmbient"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: self.key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: self.key) }
    }

    /// Whether the strip should be on screen: something is playing, the notch is closed, and nothing else is using the notch.
    nonisolated static func shouldShow(enabled: Bool, playing: Bool, hubOpen: Bool, meetingLive: Bool) -> Bool {
        enabled && playing && !hubOpen && !meetingLive
    }
}

/// The closed notch, widened a little on both sides while something plays: the cover on the left, a live level meter on the right.
/// When the track changes it opens out for a few seconds to name the song and artist, then settles. Clicks pass straight through, and
/// hovering the notch still opens the hub as before.
@MainActor
final class NotchNowPlayingStrip {
    static let shared = NotchNowPlayingStrip()

    private var window: NotchHubWindow?
    private var model: StripModel?
    private var bag = Set<AnyCancellable>()
    private var lastKey: String?
    private var settleTask: Task<Void, Never>?
    private var started = false
    private let audioProvider = CoreAudioProcessActivityProvider()
    /// Whether the app behind the system's reported track is really sending sound out. nil until the first check for a track.
    private var audible: Bool?
    private var audibleKey: String?
    private var checking = false

    /// Whether the strip is on screen right now (other ambient badges sit beyond it).
    var isVisible: Bool { self.window?.isVisible == true }

    static let wing: CGFloat = 60
    static let wide: CGFloat = 170

    func start() {
        guard !self.started else { return }
        self.started = true
        NowPlayingStore.shared.start()
        NowPlayingStore.shared.$track.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &self.bag)
        NotchHubController.shared.model.$isOpen.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &self.bag)
        Timer.publish(every: 5, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }.store(in: &self.bag)
        Timer.publish(every: 1.5, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.checkAudibility() }.store(in: &self.bag)
    }

    /// Browsers (and others) can report a muted or silent tab as "playing". Anything the system reports, as opposed to what
    /// Spotify or Music announce themselves, only counts while that app really has audio going out.
    private func checkAudibility() {
        guard !self.checking, let track = NowPlayingStore.shared.track, track.isPlaying, let pid = track.pid,
              let bundlePath = NSRunningApplication(processIdentifier: pid)?.bundleURL?.resolvingSymlinksInPath().path else { return }
        self.checking = true
        let key = track.key
        Task { [weak self] in
            guard let self else { return }
            let snap = await self.audioProvider.snapshot()
            self.checking = false
            guard snap.queryState == .valid else { return }
            let prefix = bundlePath + "/"
            let now = snap.processes.contains { $0.isOutputRunning && ($0.executablePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.hasPrefix(prefix) } ?? false) }
            guard NowPlayingStore.shared.track?.key == key else { return }
            if self.audible != now || self.audibleKey != key {
                self.audible = now
                self.audibleKey = key
                self.refresh()
            }
        }
    }

    /// Something is really playing: the system says so, and (for anything the system reports) sound is going out.
    var isPlayingAudibly: Bool {
        let track = NowPlayingStore.shared.track
        return track?.isPlaying == true && !(track?.pid != nil && self.audibleKey == track?.key && self.audible == false)
    }

    private func refresh() {
        let track = NowPlayingStore.shared.track
        // The notch is also used for a live meeting and for the dictation overlay; the strip steps aside for both.
        let meetingLive = ((NotchMeetingCardController.shared.engineLiveState()["active"] as? Bool) ?? false) || AppServices.shared.asr.isRunning
        let show = NotchNowPlayingAmbientSettings.shouldShow(enabled: NotchNowPlayingAmbientSettings.isEnabled, playing: self.isPlayingAudibly,
                                                             hubOpen: NotchHubController.shared.model.isOpen, meetingLive: meetingLive)
        guard show, let track, let screen = NotchGeometry.targetScreen() else {
            self.window?.orderOut(nil)
            return
        }
        let notch = NotchGeometry.closedSize(for: screen)
        let width = notch.width + Self.wide * 2
        let frame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - notch.height, width: width, height: notch.height)
        if self.window == nil {
            let w = NotchHubWindow(frame: frame)
            let model = StripModel()
            w.contentView = NSHostingView(rootView: StripView(model: model))
            self.window = w
            self.model = model
        }
        self.window?.setFrame(frame, display: false)
        self.model?.notch = notch
        self.model?.track = track
        let key = "\(track.bundleID ?? "")|\(track.title)"
        if key != self.lastKey {
            self.lastKey = key
            self.model?.expanded = true
            self.settleTask?.cancel()
            self.settleTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !Task.isCancelled { self?.model?.expanded = false }
            }
        }
        self.window?.orderFrontRegardless()
    }
}

@MainActor
final class StripModel: ObservableObject {
    @Published var track: NowPlayingStore.Track?
    @Published var notch = CGSize(width: 190, height: 32)
    @Published var expanded = false
}

private struct StripView: View {
    @ObservedObject var model: StripModel

    var body: some View {
        let wing = self.model.expanded ? NotchNowPlayingStrip.wide : NotchNowPlayingStrip.wing
        HStack(spacing: 0) {
            self.leading.frame(width: wing, alignment: .leading)
            Color.clear.frame(width: self.model.notch.width)
            self.trailing.frame(width: wing, alignment: .trailing)
        }
        .frame(height: self.model.notch.height)
        .background(NotchHubShape(topCornerRadius: 6, bottomCornerRadius: 14).fill(Color.black))
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: self.model.expanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    private var leading: some View {
        HStack(spacing: 8) {
            Group {
                if let art = self.model.track?.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    NowPlayingSourceLogo(source: self.model.track?.site, bundleID: self.model.track?.bundleID, size: 22)
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            if self.model.expanded, let title = self.model.track?.title {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.leading, 10)
    }

    private var trailing: some View {
        HStack(spacing: 8) {
            if self.model.expanded, let artist = self.model.track?.artist, !artist.isEmpty {
                Text(artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.tail)
            }
            LevelBars().frame(width: 16, height: 14)
        }
        .padding(.trailing, 12)
    }
}

/// Four little bars that bounce, standing in for a level meter (the real levels of other apps' audio are not available).
private struct LevelBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(Color.white.opacity(0.85))
                        .frame(width: 2.5, height: 4 + 10 * CGFloat(0.5 + 0.5 * sin(t * (3.2 + Double(i) * 1.3) + Double(i) * 1.7)))
                }
            }
        }
    }
}
