import SwiftUI

/// The `/look` bar above a reply box: ONE line, as tall as the emoji strip, so the conversation keeps its height. It opens the moment the box holds "/look", and as you
/// type it shows the place Return would take (its name and address); a tap on it puts that address in the box, and the arrow beside it shows the next suggestion (up to
/// five). Shared by the Messages and WhatsApp tabs, so the two cannot drift apart.
struct NotchPlaceResults: View {
    let state: NotchPlaceLookup.State
    var selected = 0
    /// The address of the suggestion is being asked for (a tap that has to wait for it).
    var resolving = false
    var staticLayout = false
    let onPick: (PlaceCandidate) -> Void
    var onNext: () -> Void = {}

    var body: some View {
        switch self.state {
        case .idle:
            EmptyView()
        case .typing:
            self.note("Type a place: it searches as you type", symbol: "magnifyingglass")
        case let .searching(query):
            self.note("Looking for “\(query)”…", symbol: "magnifyingglass")
        case let .notFound(query):
            self.note("No place found for “\(query)”. Try the name and the city.", symbol: "mappin.slash")
        case let .failed(message):
            self.note(message, symbol: "exclamationmark.triangle")
        case let .found(_, places):
            if !places.isEmpty { self.match(places, index: min(max(self.selected, 0), places.count - 1)) }
        }
    }

    private func note(_ text: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            Text(text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }

    private func match(_ places: [PlaceCandidate], index: Int) -> some View {
        let place = places[index]
        return HStack(spacing: 6) {
            Button { self.onPick(place) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.circle.fill").font(.system(size: 16)).foregroundStyle(.white.opacity(0.7))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(place.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                        Text(place.detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    // What Return does (or a small spinner while the address is being asked for).
                    if self.resolving {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else {
                        Image(systemName: "return").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if places.count > 1 {
                Button(action: self.onNext) {
                    HStack(spacing: 3) {
                        Text("\(index + 1)/\(places.count)").font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Next place")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(height: 36)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }
}
