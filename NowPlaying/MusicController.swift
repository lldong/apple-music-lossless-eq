import Foundation

struct TrackInfo {
    let title: String
    let artist: String?
    let album: String?
    let isPlaying: Bool
    let position: Double?
    let duration: Double?
}

struct TrackFetchResult {
    let track: TrackInfo?
    let errorMessage: String?
}

struct MusicPlayerInfo {
    let title: String?
    let artist: String?
    let album: String?
    let albumArtist: String?
    let state: String?

    var isPlaying: Bool {
        state == "Playing"
    }

    var hasTrackMetadata: Bool {
        !(title ?? "").isEmpty
    }

    init(userInfo: [AnyHashable: Any]) {
        title = MusicPlayerInfo.string(userInfo["Name"])
        artist = MusicPlayerInfo.string(userInfo["Artist"])
        album = MusicPlayerInfo.string(userInfo["Album"])
        albumArtist = MusicPlayerInfo.string(userInfo["Album Artist"])
        state = MusicPlayerInfo.string(userInfo["Player State"])
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum MusicCommand: String {
    case playPause = "playpause"
    case nextTrack = "next track"
    case previousTrack = "back track"
}

final class MusicController {
    private let playerInfoNotification = Notification.Name("com.apple.Music.playerInfo")

    func observePlayerInfo(_ handler: @escaping (MusicPlayerInfo) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: playerInfoNotification,
                                                            object: nil,
                                                            queue: .main) { notification in
            handler(MusicPlayerInfo(userInfo: notification.userInfo ?? [:]))
        }
    }

    func removePlayerInfoObserver(_ observer: NSObjectProtocol) {
        DistributedNotificationCenter.default().removeObserver(observer)
    }

    func sendCommand(_ command: MusicCommand) {
        let scriptSource = """
        tell application \"Music\"
            if it is running then
                \(command.rawValue)
            end if
        end tell
        """

        guard let script = NSAppleScript(source: scriptSource) else {
            return
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
    }

    func pauseIfPlaying() -> Bool {
        let scriptSource = """
        tell application \"Music\"
            if it is running then
                set stateText to (player state as text)
                if stateText is \"playing\" then
                    pause
                    return \"paused\"
                end if
            end if
        end tell
        return \"\"
        """

        return executeString(scriptSource) == "paused"
    }

    func resumeIfPaused() -> Bool {
        let scriptSource = """
        tell application \"Music\"
            if it is running then
                set stateText to (player state as text)
                if stateText is \"paused\" then
                    play
                    return \"playing\"
                end if
            end if
        end tell
        return \"\"
        """

        return executeString(scriptSource) == "playing"
    }

    func playerPosition() -> Double? {
        let scriptSource = """
        tell application \"Music\"
            if it is running then
                try
                    return (player position as text)
                end try
            end if
        end tell
        return \"\"
        """

        guard let value = executeString(scriptSource), !value.isEmpty else {
            return nil
        }
        return numeric(value)
    }

    func currentTrackArtwork() -> Data? {
        let scriptSource = """
        tell application \"Music\"
            if it is running then
                try
                    return (get data of artwork 1 of current track)
                end try
            end if
        end tell
        """

        guard let script = NSAppleScript(source: scriptSource) else {
            return nil
        }

        var errorInfo: NSDictionary?
        let output = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else {
            return nil
        }

        let data = output.data
        return data.isEmpty ? nil : data
    }

    func currentTrackInfo() -> TrackFetchResult {
        // Note: "st" is a reserved abbreviation in AppleScript and cannot be
        // used as a variable name.
        let scriptSource = """
        tell application \"Music\"
            if it is running then
                set stateText to (player state as text)
                if stateText is \"playing\" or stateText is \"paused\" then
                    set t to current track
                    set trackName to name of t
                    set artistName to \"\"
                    set albumName to \"\"
                    set posText to \"\"
                    set durText to \"\"
                    try
                        set artistName to artist of t
                    end try
                    try
                        set albumName to album of t
                    end try
                    try
                        set posText to (player position as text)
                    end try
                    try
                        set durText to ((duration of t) as text)
                    end try
                    return trackName & \"||\" & artistName & \"||\" & albumName & \"||\" & stateText & \"||\" & posText & \"||\" & durText
                end if
            end if
        end tell
        return ""
        """

        guard let script = NSAppleScript(source: scriptSource) else {
            return TrackFetchResult(track: nil, errorMessage: "Failed to create AppleScript.")
        }

        var errorInfo: NSDictionary?
        let output = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let errorCode = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            if errorCode == -1743 {
                return TrackFetchResult(track: nil,
                                        errorMessage: "Apple Music access denied. Enable it in System Settings > Privacy & Security > Automation.")
            }

            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "AppleScript error."
            return TrackFetchResult(track: nil, errorMessage: message)
        }

        guard let outputString = output.stringValue,
              !outputString.isEmpty else {
            return TrackFetchResult(track: nil, errorMessage: nil)
        }

        let parts = outputString.components(separatedBy: "||")
        guard let title = parts.first, !title.isEmpty else {
            return TrackFetchResult(track: nil, errorMessage: nil)
        }

        let artist = parts.count > 1 ? nonEmpty(parts[1]) : nil
        let album = parts.count > 2 ? nonEmpty(parts[2]) : nil
        let isPlaying = parts.count > 3 && parts[3] == "playing"
        let position = parts.count > 4 ? numeric(parts[4]) : nil
        let duration = parts.count > 5 ? numeric(parts[5]) : nil

        return TrackFetchResult(track: TrackInfo(title: title,
                                                 artist: artist,
                                                 album: album,
                                                 isPlaying: isPlaying,
                                                 position: position,
                                                 duration: duration),
                                errorMessage: nil)
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func executeString(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else {
            return nil
        }

        var errorInfo: NSDictionary?
        let output = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else {
            return nil
        }
        return output.stringValue
    }

    private func numeric(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        return Double(trimmed)
    }
}
