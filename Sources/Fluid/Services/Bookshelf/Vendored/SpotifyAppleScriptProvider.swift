// Vendored unchanged (apart from `nonisolated` markers, the dropped module import and the playback commands, which myOS does not use) from bookshelf's mac/BookshelfListen at dd62626, so myOS
// reads players and credits listening exactly the way Bookshelf's own Mac app does. Re-sync from there; do not improve it here.
import AppKit
import Foundation

nonisolated enum SpotifyAppleScriptProvider {
    static func read(
        applicationDetector: any PlayerApplicationDetecting = SystemPlayerApplicationDetector(),
        executor: any AppleScriptExecuting = SystemAppleScriptExecutor()
    ) -> PlaybackReadResult {
        let provider = MusicPlayerKind.spotify
        guard applicationDetector.isRunning(
            bundleIdentifier: provider.applicationBundleIdentifier
        ) else {
            return .success(PlaybackSnapshot(state: .notRunning, provider: provider))
        }

        switch executor.execute(appleScript) {
        case .failure(code: -1743, message: _):
            return .permissionDenied(provider: provider)
        case .failure(let code, _):
            return .scriptFailure(code: code, provider: provider)
        case .success(let output, _):
            let snapshot = SpotifyScriptParser.parse(output ?? "")
            if (snapshot.state == .playing || snapshot.state == .paused),
               snapshot.track == nil {
                return .metadataUnavailable(state: snapshot.state, provider: provider)
            }
            guard snapshot.state != .unavailable else {
                return .scriptFailure(code: nil, provider: provider)
            }
            return .success(snapshot)
        }
    }

    private static let appleScript = #"""
tell application "Spotify"
  set playerState to player state as string
  if playerState is "stopped" then return playerState

  try
    set currentSpotifyTrack to current track
  on error
    return playerState
  end try

  try
    set identityBefore to spotify url of currentSpotifyTrack
  on error
    set identityBefore to ""
  end try
  try
    set trackName to name of currentSpotifyTrack
    set trackArtist to artist of currentSpotifyTrack
    set trackAlbum to album of currentSpotifyTrack
  on error
    return playerState
  end try

  try
    set albumArtistValue to album artist of currentSpotifyTrack
  on error
    set albumArtistValue to trackArtist
  end try

  try
    set durationValue to duration of currentSpotifyTrack as string
  on error
    set durationValue to ""
  end try

  try
    set positionValue to player position
    set positionValue to (round (positionValue * 1000)) as string
  on error
    set positionValue to ""
  end try

  try
    set urlValue to spotify url of currentSpotifyTrack
  on error
    set urlValue to ""
  end try

  try
    set trackNumberValue to track number of currentSpotifyTrack as string
  on error
    set trackNumberValue to ""
  end try

  try
    set artworkValue to artwork url of currentSpotifyTrack
  on error
    set artworkValue to ""
  end try

  try
    set currentSpotifyTrackAfter to current track
    set identityAfter to spotify url of currentSpotifyTrackAfter
  on error
    set identityAfter to ""
  end try

  return playerState & tab & trackName & tab & trackArtist & tab & trackAlbum & tab & albumArtistValue & tab & durationValue & tab & positionValue & tab & urlValue & tab & trackNumberValue & tab & artworkValue & tab & identityBefore & tab & identityAfter
end tell
"""#
}
