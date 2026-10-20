// Vendored unchanged (apart from `nonisolated` markers, the dropped module import and the playback commands, which myOS does not use) from bookshelf's mac/BookshelfListen at dd62626, so myOS
// reads players and credits listening exactly the way Bookshelf's own Mac app does. Re-sync from there; do not improve it here.
import AppKit
import Foundation

nonisolated enum AppleMusicAppleScriptProvider {
    static func read(
        applicationDetector: any PlayerApplicationDetecting = SystemPlayerApplicationDetector(),
        executor: any AppleScriptExecuting = SystemAppleScriptExecutor()
    ) -> PlaybackReadResult {
        let provider = MusicPlayerKind.appleMusic
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
            let snapshot = AppleMusicScriptParser.parse(output ?? "")
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

    static func artworkData(
        executor: any AppleScriptExecuting = SystemAppleScriptExecutor()
    ) -> Data? {
        guard case .success(_, let data) = executor.execute(artworkAppleScript) else {
            return nil
        }
        return data
    }

    /// Music reports durations and player position in seconds, unlike Spotify's
    /// millisecond duration. Normalize both values in the script so the rest of
    /// the app and API share one unit. A persistent (or database) library ID is
    /// read on both sides of the metadata; artwork remains a separate local-only
    /// read because Apple Event image blobs do not belong in the capture API.
    private static let appleScript = #"""
tell application "Music"
  set playerState to player state as string
  if playerState is "stopped" then return playerState

  try
    set currentMusicTrack to current track
  on error
    return playerState
  end try

  set identityBefore to ""
  try
    set persistentIdValue to persistent ID of currentMusicTrack
    if persistentIdValue is not missing value then
      set persistentIdText to persistentIdValue as string
      if persistentIdText is not "" and persistentIdText is not "missing value" then set identityBefore to "persistent:" & persistentIdText
    end if
  end try
  if identityBefore is "" then
    try
      set databaseIdValue to database ID of currentMusicTrack
      if databaseIdValue is not missing value then
        set databaseIdText to databaseIdValue as string
        if databaseIdText is not "" and databaseIdText is not "missing value" then set identityBefore to "database:" & databaseIdText
      end if
    end try
  end if

  try
    set trackName to name of currentMusicTrack
    set trackArtist to artist of currentMusicTrack
    set trackAlbum to album of currentMusicTrack
  on error
    return playerState
  end try

  try
    set albumArtistValue to album artist of currentMusicTrack
  on error
    set albumArtistValue to trackArtist
  end try

  try
    set durationValue to (round ((duration of currentMusicTrack) * 1000)) as string
  on error
    set durationValue to ""
  end try

  try
    set positionValue to (round ((player position) * 1000)) as string
  on error
    set positionValue to ""
  end try

  try
    set trackNumberValue to track number of currentMusicTrack as string
  on error
    set trackNumberValue to ""
  end try

  set identityAfter to ""
  try
    set currentMusicTrackAfter to current track
    try
      set persistentIdValueAfter to persistent ID of currentMusicTrackAfter
      if persistentIdValueAfter is not missing value then
        set persistentIdTextAfter to persistentIdValueAfter as string
        if persistentIdTextAfter is not "" and persistentIdTextAfter is not "missing value" then set identityAfter to "persistent:" & persistentIdTextAfter
      end if
    end try
    if identityAfter is "" then
      try
        set databaseIdValueAfter to database ID of currentMusicTrackAfter
        if databaseIdValueAfter is not missing value then
          set databaseIdTextAfter to databaseIdValueAfter as string
          if databaseIdTextAfter is not "" and databaseIdTextAfter is not "missing value" then set identityAfter to "database:" & databaseIdTextAfter
        end if
      end try
    end if
  end try

  return playerState & tab & trackName & tab & trackArtist & tab & trackAlbum & tab & albumArtistValue & tab & durationValue & tab & positionValue & tab & "" & tab & trackNumberValue & tab & "" & tab & identityBefore & tab & identityAfter
end tell
"""#

    private static let artworkAppleScript = #"""
tell application "Music"
  try
    set currentMusicTrack to current track
    if (count of artworks of currentMusicTrack) is 0 then return missing value
    return data of artwork 1 of currentMusicTrack
  on error
    return missing value
  end try
end tell
"""#
}
