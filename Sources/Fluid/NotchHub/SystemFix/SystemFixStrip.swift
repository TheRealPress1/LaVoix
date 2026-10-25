import AppKit
import Combine
import SwiftUI

/// A small badge beside the closed notch while the System agent works or has a proposal waiting, so closing the notch
/// doesn't hide that something is going on. Clicks pass through; hovering the notch opens the hub as usual.
@MainActor
final class SystemFixStrip {
    static let shared = SystemFixStrip()

    private var window: NotchHubWindow?
    private var model: SystemFixStripModel?
    private var bag = Set<AnyCancellable>()
    private var started = false

    static let width: CGFloat = 36

    func start() {
        guard !self.started else { return }
        self.started = true
        SystemFixAgent.shared.$phase.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &self.bag)
        NotchHubController.shared.model.$isOpen.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &self.bag)
        // The music strip comes and goes on its own; keep clear of it.
        Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }.store(in: &self.bag)
    }

    private func refresh() {
        let state = SystemFixStripModel.State(SystemFixAgent.shared.phase)
        guard state != .hidden, !NotchHubController.shared.model.isOpen, let screen = NotchGeometry.targetScreen() else {
            self.window?.orderOut(nil)
            return
        }
        let notch = NotchGeometry.closedSize(for: screen)
        // Right of the notch; beyond the Now Playing wing when that is showing.
        let offset = NotchNowPlayingStrip.shared.isVisible ? NotchNowPlayingStrip.wing : 0
        let frame = NSRect(x: screen.frame.midX + notch.width / 2 + offset, y: screen.frame.maxY - notch.height, width: Self.width, height: notch.height)
        if self.window == nil {
            let w = NotchHubWindow(frame: frame)
            let model = SystemFixStripModel()
            w.contentView = NSHostingView(rootView: SystemFixStripView(model: model))
            self.window = w
            self.model = model
        }
        self.window?.setFrame(frame, display: false)
        self.model?.state = state
        self.window?.orderFrontRegardless()
    }
}

@MainActor
final class SystemFixStripModel: ObservableObject {
    enum State: Equatable {
        case hidden, working, ready, done, failed

        init(_ phase: SystemFixAgent.Phase) {
            switch phase {
            case .idle: self = .hidden
            case .investigating, .applying: self = .working
            case .proposal: self = .ready
            case .finished: self = .done
            case .failed: self = .failed
            }
        }
    }

    @Published var state: State = .hidden
}

private struct SystemFixStripView: View {
    @ObservedObject var model: SystemFixStripModel

    var body: some View {
        ZStack {
            UnevenRoundedRectangle(bottomTrailingRadius: 12, topTrailingRadius: 4).fill(Color.black)
            self.icon
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var icon: some View {
        switch self.model.state {
        case .hidden:
            EmptyView()
        case .working:
            // The wand with a slow pulse, so it reads as "busy" without being a spinner in a 32 pt space.
            TimelineView(.animation(minimumInterval: 0.05)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.orange.opacity(0.55 + 0.45 * (0.5 + 0.5 * sin(t * 4))))
            }
        case .ready:
            // Waiting for you: a steady wand with a dot.
            Image(systemName: "wand.and.stars")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.orange)
                .overlay(alignment: .topTrailing) { Circle().fill(Color.orange).frame(width: 6, height: 6).offset(x: 4, y: -3) }
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Color.red.opacity(0.85))
        }
    }
}
