import Combine
import Contacts
import Foundation
import MapKit

/// `/look <place>` typed in a notch reply box (Messages or WhatsApp): the place is found with Apple Maps and its street address goes into the box, ready
/// to send. The words after /look are the only thing that leaves this Mac (to Apple's map search); nothing from the chat is read or sent, and nothing is
/// sent to the chat until you press send yourself.
enum NotchPlaceCommand {
    static let word = "/look"

    /// True for "/look" and "/look <anything>" in any case, with spaces before it allowed. "/looking" is not a command.
    static func isCommand(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.hasPrefix(self.word) else { return false }
        return t.count == self.word.count || t[t.index(t.startIndex, offsetBy: self.word.count)].isWhitespace
    }

    /// The place asked for: what follows "/look", on one line, at most 120 characters; nil when nothing follows it.
    static func query(in text: String) -> String? {
        guard self.isCommand(text) else { return nil }
        let rest = text.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(self.word.count)
        let query = rest.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return query.isEmpty ? nil : String(query.prefix(120))
    }
}

/// One place Apple Maps suggested: its name, the line under it, and (once known) the address as it goes into the message.
struct PlaceCandidate: Identifiable, Equatable {
    let id: Int
    let name: String
    /// What is shown under the name: its address as Maps gave it while you type, tidied; the full address when that is already known.
    let detail: String
    /// The address for the message. A suggestion made while you type has none until Apple Maps has been asked for the place itself.
    var address: String?
    var completion: MKLocalSearchCompletion?
}

enum PlaceSuggestion {
    /// Maps' line under a suggestion, tidied: double spaces collapsed, and the Mac's own country left off.
    static func detail(_ subtitle: String) -> String {
        var line = subtitle.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if let region = Locale.current.region?.identifier, let home = Locale.current.localizedString(forRegionCode: region), !home.isEmpty, line.hasSuffix(", \(home)") {
            line = String(line.dropLast(home.count + 2))
        }
        return line
    }

    /// "Search Nearby" suggestions are searches, not places.
    static func isPlace(_ completion: MKLocalSearchCompletion) -> Bool {
        let detail = completion.subtitle.trimmingCharacters(in: .whitespaces).lowercased()
        return !completion.title.isEmpty && detail != "search nearby"
    }
}

enum PlaceAddress {
    /// The address on one line, laid out the way that country writes it ("2890 N Fulton Dr NE, Atlanta GA 30305", "12 Rue Cler, 75007 Paris"). The country is left out
    /// when it is the Mac's own.
    static func line(_ address: CNPostalAddress) -> String {
        let formatter = CNPostalAddressFormatter()
        formatter.style = .mailingAddress
        var lines = formatter.string(from: address).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.count > 1, !address.country.isEmpty, lines.last == address.country, address.isoCountryCode.uppercased() == (Locale.current.region?.identifier ?? "").uppercased() {
            lines.removeLast()
        }
        // The US layout has no comma before the state ("Atlanta GA 30305"); people write "Atlanta, GA 30305".
        return lines.joined(separator: ", ").replacingOccurrences(of: #"(\S) ([A-Z]{2} \d{5}(?:-\d{4})?)$"#, with: "$1, $2", options: .regularExpression)
    }

    /// What goes in the box for a map item: its address, or its name when Apple Maps has no street for it (a park, a city).
    static func text(for item: MKMapItem) -> String {
        if let postal = item.placemark.postalAddress {
            let line = Self.line(postal)
            if !line.isEmpty { return line }
        }
        return item.name ?? ""
    }
}

/// The typing-ahead lookup behind `/look`: from the moment the box holds "/look" it is on, and each letter after it asks Apple Maps' autocomplete (made for typing:
/// about 0.2 s, and it copes with half-typed names) for up to five places. The one showing is looked up in the background, so Return or a tap fills the box at once.
@MainActor
final class NotchPlaceLookup: ObservableObject {
    enum State: Equatable {
        case idle
        /// "/look" with nothing after it yet: the bar is open and waiting.
        case typing
        case searching(String)
        case found(query: String, [PlaceCandidate])
        case notFound(String)
        case failed(String)
    }

    @Published private(set) var state: State
    /// Which suggestion is showing (the one Return takes); the arrow beside it moves to the next.
    @Published private(set) var selected = 0
    /// The address of the suggestion being looked up, when a tap or Return has to wait for it.
    @Published private(set) var resolving = false
    /// Set when Return was pressed before any suggestion had come: the view takes it the moment it is there.
    @Published private(set) var ready: PlaceCandidate?

    /// The search for the letters typed so far. Each ask has its own completer, so a slow answer to earlier letters can never be taken for the answer to the letters in the box.
    private var ask: Ask?
    private var askedQuery: String?
    private var pickWhenFound = false
    private var generation = 0
    private var resolved: [String: String] = [:]
    private var resolvingKeys = Set<String>()

    /// A preview can start in any state; the real thing starts idle.
    init(state: State = .idle) {
        self.state = state
    }

    /// Matches for the preview stills: a public school and two others of the same name, nothing of anyone's.
    static let samplePlaces = [
        PlaceCandidate(id: 0, name: "Atlanta International School", detail: "2890 N Fulton Dr NE, Atlanta, GA 30305", address: "2890 N Fulton Dr NE, Atlanta, GA 30305"),
        PlaceCandidate(id: 1, name: "Atlanta Montessori International School - Cliff Valley", detail: "1970 Cliff Valley Way NE, Atlanta, GA 30329", address: "1970 Cliff Valley Way NE, Atlanta, GA 30329"),
        PlaceCandidate(id: 2, name: "Atlanta Montessori International School - Druid Hills", detail: "1215 S Ponce de Leon Ave NE, Atlanta, GA 30306", address: "1215 S Ponce de Leon Ave NE, Atlanta, GA 30306"),
    ]

    /// The suggestion showing, once there are some.
    var current: PlaceCandidate? {
        guard case let .found(_, list) = self.state, !list.isEmpty else { return nil }
        return list[min(max(self.selected, 0), list.count - 1)]
    }

    /// Shows the next suggestion, and the first again after the last.
    func next() {
        guard case let .found(_, list) = self.state, list.count > 1 else { return }
        self.selected = (self.selected + 1) % list.count
        self.prefetch(self.current)
    }

    /// The box changed (called on every letter). "/look" opens the bar, each letter after it asks again, anything else closes it.
    func draftChanged(to text: String) {
        guard NotchPlaceCommand.isCommand(text) else {
            if self.state != .idle || self.askedQuery != nil { self.clear() }
            return
        }
        guard let query = NotchPlaceCommand.query(in: text), query.count >= 2 else {
            // "/look" and one letter: the bar is open and waiting.
            self.stopAsking()
            self.askedQuery = nil
            self.pickWhenFound = false
            self.generation += 1
            if self.state != .typing { self.selected = 0; self.state = .typing }
            return
        }
        if query == self.askedQuery { return }
        self.askedQuery = query
        self.pickWhenFound = false
        self.generation += 1
        // The suggestions already showing stay until the new ones arrive, so the bar does not flicker while you type.
        if self.current == nil { self.state = .searching(query) }
        self.ask?.cancel()
        let asked = Ask(fragment: query)
        asked.onResults = { [weak self] fragment, completions in MainActor.assumeIsolated { self?.received(completions, for: fragment) } }
        asked.onFailure = { [weak self] fragment in MainActor.assumeIsolated { self?.askFailed(for: fragment) } }
        self.ask = asked
        asked.start()
        self.armTimeout(for: self.generation)
    }

    /// Return was pressed in the box: the suggestion showing, or nil and it is taken the moment one arrives (`ready`).
    func returnPressed() -> PlaceCandidate? {
        if let shown = self.current { return shown }
        if self.askedQuery != nil { self.pickWhenFound = true }
        return nil
    }

    func clear() {
        self.stopAsking()
        self.askedQuery = nil
        self.pickWhenFound = false
        self.generation += 1
        self.selected = 0
        self.resolving = false
        self.ready = nil
        self.state = .idle
    }

    /// The address that goes in the box for this suggestion: asked of Apple Maps once (usually already done in the background by then).
    func address(for place: PlaceCandidate) async -> String? {
        if let known = place.address { return known }
        let key = Self.key(place)
        if let hit = self.resolved[key] { return hit }
        guard let completion = place.completion else { return nil }
        self.resolving = true
        defer { self.resolving = false }
        let found = await Self.resolve(completion)
        let address = found ?? (place.detail.isEmpty ? place.name : place.detail)
        self.resolved[key] = address
        return address
    }

    // MARK: - Inside

    private static func key(_ place: PlaceCandidate) -> String { "\(place.name)|\(place.detail)" }

    private func prefetch(_ place: PlaceCandidate?) {
        guard let place, place.address == nil, place.completion != nil else { return }
        let key = Self.key(place)
        guard self.resolved[key] == nil, self.resolvingKeys.insert(key).inserted, let completion = place.completion else { return }
        Task { [weak self] in
            let found = await Self.resolve(completion)
            guard let self else { return }
            self.resolvingKeys.remove(key)
            if let found { self.resolved[key] = found }
        }
    }

    nonisolated static func resolve(_ completion: MKLocalSearchCompletion) async -> String? {
        let request = MKLocalSearch.Request(completion: completion)
        guard let response = try? await MKLocalSearch(request: request).start(), let item = response.mapItems.first else { return nil }
        let text = PlaceAddress.text(for: item)
        return text.isEmpty ? nil : text
    }

    private func stopAsking() {
        self.ask?.cancel()
        self.ask = nil
    }

    private func received(_ completions: [MKLocalSearchCompletion], for fragment: String) {
        guard let query = self.askedQuery, query == fragment else { return }
        var seen = Set<String>()
        var list: [PlaceCandidate] = []
        for completion in completions where PlaceSuggestion.isPlace(completion) {
            let detail = PlaceSuggestion.detail(completion.subtitle)
            guard seen.insert("\(completion.title.lowercased())|\(detail.lowercased())").inserted else { continue }
            list.append(PlaceCandidate(id: list.count, name: completion.title, detail: detail, address: nil, completion: completion))
            if list.count == 5 { break }
        }
        if list.isEmpty {
            // Autocomplete knows nothing for these letters: one ordinary search, in case it is a street address or a name it can find whole.
            let mine = self.generation
            Task { [weak self] in
                let outcome = await Self.find(query)
                guard let self, mine == self.generation else { return }
                self.show(outcome, for: query)
            }
            return
        }
        self.show(.found(query: query, list), for: query)
    }

    private func show(_ outcome: State, for query: String) {
        self.selected = 0
        self.state = outcome
        if case .found = outcome {
            self.prefetch(self.current)
            if self.pickWhenFound { self.pickWhenFound = false; self.ready = self.current }
        } else {
            self.pickWhenFound = false
        }
    }

    private func askFailed(for fragment: String) {
        guard self.askedQuery == fragment, self.current == nil else { return }
        self.state = .failed("Couldn't reach Apple Maps.")
    }

    /// An ask that is never answered ends in words after 15 seconds, not a bar that waits for ever.
    private func armTimeout(for mine: Int) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, mine == self.generation, case .searching = self.state else { return }
            self.state = .failed("Apple Maps didn't answer in time.")
        }
    }

    /// One ordinary Apple Maps search (the fallback when autocomplete has nothing).
    nonisolated static func find(_ query: String) async -> State {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        do {
            let response = try await MKLocalSearch(request: request).start()
            var seen = Set<String>()
            var found: [PlaceCandidate] = []
            for item in response.mapItems {
                let address = PlaceAddress.text(for: item)
                guard !address.isEmpty, seen.insert(address.lowercased()).inserted else { continue }
                found.append(PlaceCandidate(id: found.count, name: item.name ?? address, detail: address, address: address))
                if found.count == 3 { break }
            }
            return found.isEmpty ? .notFound(query) : .found(query: query, found)
        } catch let error as MKError where error.code == .placemarkNotFound {
            return .notFound(query)
        } catch is CancellationError {
            return .idle
        } catch {
            return .failed("Couldn't reach Apple Maps.")
        }
    }

    /// One question to Apple Maps' autocomplete: the letters typed, its own completer, and whatever it answers (MapKit wants an NSObject delegate).
    private final class Ask: NSObject, MKLocalSearchCompleterDelegate {
        let fragment: String
        private let completer = MKLocalSearchCompleter()
        var onResults: ((String, [MKLocalSearchCompletion]) -> Void)?
        var onFailure: ((String) -> Void)?

        init(fragment: String) {
            self.fragment = fragment
            super.init()
            self.completer.resultTypes = [.pointOfInterest, .address]
            self.completer.delegate = self
        }

        func start() { self.completer.queryFragment = self.fragment }

        /// Nothing it says after this reaches anyone.
        func cancel() {
            self.completer.delegate = nil
            self.completer.queryFragment = ""
            self.onResults = nil
            self.onFailure = nil
        }

        func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) { self.onResults?(self.fragment, completer.results) }
        func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { self.onFailure?(self.fragment) }
    }
}
