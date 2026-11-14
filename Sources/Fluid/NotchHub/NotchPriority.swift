import Foundation

/// Who may be on screen at the closed notch when several things want it at once. The list is the priority, highest first: anything lower steps aside while something
/// higher is on screen, and comes back when it leaves, instead of drawing over it (the music strip used to be drawn over a meeting's "Writing notes…" card).
///
///   1. the open hub
///   2. dictation (you are speaking)
///   3. a meeting card, in ANY phase: starting, call detected, recording, writing notes, failed, discarded
///   4. a message, Look or alert card
///   5. the music strip
///   6. the System Fix badge
enum NotchPriority {
    enum Occupant: Int, CaseIterable, Comparable {
        case hub, dictation, meeting, banner, music, badge

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// The occupants that are on screen (or about to be) right now, from the things that can be asked directly.
    static func present(hubOpen: Bool, dictating: Bool, meeting: Bool, banner: Bool) -> Set<Occupant> {
        var found = Set<Occupant>()
        if hubOpen { found.insert(.hub) }
        if dictating { found.insert(.dictation) }
        if meeting { found.insert(.meeting) }
        if banner { found.insert(.banner) }
        return found
    }

    /// Whether `who` may be on screen: nothing ranked above it is.
    static func mayShow(_ who: Occupant, hubOpen: Bool, dictating: Bool, meeting: Bool, banner: Bool) -> Bool {
        !self.present(hubOpen: hubOpen, dictating: dictating, meeting: meeting, banner: banner).contains { $0 < who }
    }
}
