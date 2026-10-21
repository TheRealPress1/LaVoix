import SwiftUI

/// Start a FaceTime from the notch: type a name (or just look down the list, the people you are closest to first), then press the video
/// or the phone button. The call starts in FaceTime, which may ask you to confirm. Names and numbers come from myOS and are never kept here.
struct FaceTimeWidgetView: View {
    @ObservedObject var store: FaceTimeStore
    @Environment(\.notchWidgetActive) private var active
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    TextField("", text: self.$query, prompt: Text("Who do you want to FaceTime?").foregroundStyle(.white.opacity(0.45)))
                        .textFieldStyle(.plain).foregroundStyle(.white).tint(.white)
                        .focused(self.$focused)
                        .onSubmit { if let first = self.store.contacts.first { self.store.call(first, audio: false) } }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
                Button { self.store.openFaceTime() } label: {
                    Text("Open FaceTime").font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).frame(height: 30)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
            switch self.store.state {
            case .loading:
                ProgressView().controlSize(.small).tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable:
                Text("myOS isn’t set up on this Mac, so there are no people to call yet.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                if self.store.contacts.isEmpty {
                    Text("No one with a number or email matches.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 6)], spacing: 6) {
                            ForEach(self.store.contacts) { person in
                                FaceTimeRow(person: person, video: { self.store.call(person, audio: false) }, audio: { self.store.call(person, audio: true) })
                            }
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .onAppear { self.store.search(self.query) }
        .onChange(of: self.query) { _, text in if self.active { self.store.search(text) } }
        .onChange(of: self.focused) { _, f in if f { NotchHubController.shared.beginTextEntry() } }
    }
}

private struct FaceTimeRow: View {
    let person: FaceTimeContact
    let video: () -> Void
    let audio: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(self.person.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            self.button("video.fill", help: "FaceTime video", action: self.video)
            self.button("phone.fill", help: "FaceTime audio", action: self.audio)
        }
        .padding(.leading, 10).padding(.trailing, 6).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.black)
                .frame(width: 28, height: 24).background(Capsule().fill(Color(red: 0.2, green: 0.8, blue: 0.4)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
