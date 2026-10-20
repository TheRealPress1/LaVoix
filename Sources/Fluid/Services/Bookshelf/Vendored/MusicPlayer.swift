// Vendored unchanged (apart from `nonisolated` markers and the dropped module import) from bookshelf's mac/BookshelfListen at dd62626, so myOS
// reads players and credits listening exactly the way Bookshelf's own Mac app does. Re-sync from there; do not improve it here.
import Foundation

/// The desktop player Bookshelf observes locally. The Mac app never receives
/// audio; it asks the selected app for metadata and playhead position through
/// macOS Automation, and pauses, resumes, or changes songs only after an
/// explicit user action. It never moves the playhead itself, so going back is
/// whatever the selected player's own Previous command does.
nonisolated public enum MusicPlayerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case spotify
    case appleMusic = "apple_music"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .spotify: "Spotify"
        case .appleMusic: "Apple Music"
        }
    }

    public var applicationName: String {
        switch self {
        case .spotify: "Spotify"
        case .appleMusic: "Music"
        }
    }

    /// The other supported player. There are exactly two, and the widget
    /// follows whichever one is actually playing, so "the one I am not
    /// watching" is a question it asks on every idle poll.
    public var counterpart: MusicPlayerKind {
        switch self {
        case .spotify: .appleMusic
        case .appleMusic: .spotify
        }
    }
}
