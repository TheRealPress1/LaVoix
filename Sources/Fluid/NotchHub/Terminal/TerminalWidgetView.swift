import SwiftUI

/// The notch's Terminal tab: locked until Touch ID, then the scrollback and one input line. Hidden from Accessibility as a whole, so nothing outside can read it.
struct TerminalWidgetView: View {
    @ObservedObject var store: TerminalStore
    /// A still preview draws a plain list instead of a scroll view and no live input.
    var staticLayout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            self.header
            if self.store.isUnlocked { self.terminal } else { self.lockedBody }
        }
        .foregroundStyle(.white)
        .accessibilityHidden(true)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { if !self.staticLayout { self.store.setSize(width: proxy.size.width) } }
                    .onChange(of: proxy.size.width) { _, width in if !self.staticLayout { self.store.setSize(width: width) } }
            }
        )
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)
            if self.store.isUnlocked {
                Circle().fill(self.statusColor).frame(width: 6, height: 6)
                Text(self.statusText).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            if self.store.isUnlocked {
                if self.store.isBusy {
                    self.headerButton("Stop", systemImage: "stop.fill") { self.store.interrupt() }
                    if self.store.canForceStop { self.headerButton("Force stop", systemImage: "xmark.octagon.fill") { self.store.forceStop() } }
                }
                if case .running = self.store.sessionState {} else { self.headerButton("New session", systemImage: "plus") { self.store.newSession() } }
                self.headerButton("Lock", systemImage: "lock.fill") { self.store.lock() }
            }
        }
    }

    private func headerButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).font(.system(size: 11)).labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.6))
    }

    private var statusColor: Color {
        switch self.store.sessionState {
        case .running: self.store.isBusy ? Color.orange : Color.green
        case .none: Color.gray
        case .ended: Color.gray
        case .failed: Color.red
        }
    }

    private var statusText: String {
        switch self.store.sessionState {
        case .running: self.store.isBusy ? "running" : "ready"
        case .none: "no session"
        case let .ended(code): "session ended (exit \(code))"
        case .failed: "could not start"
        }
    }

    // MARK: - locked

    private var lockedBody: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 24)).foregroundStyle(.white.opacity(0.35))
            Text("The terminal is locked").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            Button {
                Task { await self.store.unlock() }
            } label: {
                Label("Unlock with Touch ID", systemImage: "touchid")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .disabled(self.store.isUnlocking || self.staticLayout)
            if let notice = self.store.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - unlocked

    private var terminal: some View {
        VStack(alignment: .leading, spacing: 6) {
            if self.staticLayout {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(self.store.rendered.suffix(9))) { line in self.row(line) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(self.store.rendered) { line in self.row(line) }
                            Color.clear.frame(height: 1).id("end")
                        }
                    }
                    .onChange(of: self.store.scrollTick) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            if self.store.needsFullTerminal {
                Text("This program needs a full terminal. Stop it with Ctrl-C, and run it in the Terminal app.")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            if case let .failed(message) = self.store.sessionState {
                Text(message).font(.system(size: 11)).foregroundStyle(.orange)
            }
            if let notice = self.store.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.orange)
            }
            self.inputRow
        }
    }

    private func row(_ line: RenderedLine) -> some View {
        Text(line.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inputRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("›").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).padding(.top, 4)
            if self.staticLayout {
                Text(" ").font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            } else {
                TerminalInputField(store: self.store).frame(height: 28)
            }
        }
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
    }
}
