import Foundation

// MARK: - Music Zone

struct MusicZone: Identifiable {
    let id: Int
    let name: String
    let emoji: String
    let artist: String
    let spotifyURI: String
    let maxSpeed: Double // upper bound for this zone
}

// MARK: - Spotify Manager

class SpotifyManager: ObservableObject {
    let zones: [MusicZone] = [
        MusicZone(id: 0, name: "Chill",   emoji: "🌊", artist: "Khruangbin",   spotifyURI: "spotify:artist:2mVVjNmdjXZZDvhgQWiakk", maxSpeed: 2.0),
        MusicZone(id: 1, name: "Groove",  emoji: "🕺", artist: "Daft Punk",    spotifyURI: "spotify:artist:4tZwfgrHOc3mvqYlEYSvVi", maxSpeed: 3.5),
        MusicZone(id: 2, name: "Energy",  emoji: "⚡",  artist: "The Prodigy",  spotifyURI: "spotify:artist:4k1ELeJKT1ISyDv8JivPpB", maxSpeed: 5.0),
        MusicZone(id: 3, name: "BEAST",   emoji: "🔥", artist: "Scooter",      spotifyURI: "spotify:artist:0HlxL5hisLf59ETEPM3cUA", maxSpeed: .infinity),
    ]

    @Published var currentZoneIndex: Int = -1
    @Published var currentTrack: String = ""
    @Published var currentArtist: String = ""
    @Published var isEnabled: Bool = true

    private var lastSpeed: Double = 0

    var currentZone: MusicZone? {
        guard currentZoneIndex >= 0 && currentZoneIndex < zones.count else { return nil }
        return zones[currentZoneIndex]
    }

    // Called every ~1 second from the app timer
    func tick(speed: Double, beltRunning: Bool) {
        guard isEnabled && beltRunning && speed > 0 else {
            if currentZoneIndex != -1 {
                stopMusic()
            }
            return
        }

        let target = zoneIndex(for: speed)
        if target != currentZoneIndex {
            switchToZone(target)
        }
    }

    func stopMusic() {
        currentZoneIndex = -1
        currentTrack = ""
        currentArtist = ""
        DispatchQueue.global(qos: .utility).async {
            Self.osascript("tell application \"Spotify\" to pause")
        }
    }

    func skipTrack() {
        DispatchQueue.global(qos: .utility).async {
            Self.osascript("""
            tell application "Spotify" to next track
            """)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.fetchNowPlaying()
        }
    }

    func previousTrack() {
        DispatchQueue.global(qos: .utility).async {
            Self.osascript("""
            tell application "Spotify" to previous track
            """)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.fetchNowPlaying()
        }
    }

    func fetchNowPlaying() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.osascript("""
            tell application "Spotify"
                if player state is playing then
                    return (name of current track) & "|||" & (artist of current track)
                end if
            end tell
            """)
            DispatchQueue.main.async {
                guard let self = self, let result = result, !result.isEmpty else { return }
                let parts = result.components(separatedBy: "|||")
                if parts.count >= 2 {
                    self.currentTrack = parts[0]
                    self.currentArtist = parts[1]
                }
            }
        }
    }

    // MARK: - Private

    private func zoneIndex(for speed: Double) -> Int {
        for (i, zone) in zones.enumerated() {
            if speed <= zone.maxSpeed { return i }
        }
        return zones.count - 1
    }

    private func switchToZone(_ index: Int) {
        currentZoneIndex = index
        let zone = zones[index]

        DispatchQueue.global(qos: .utility).async {
            let uri = zone.spotifyURI
            // open location is more reliable than play track for artist/playlist URIs
            Self.osascript("""
            tell application "Spotify"
                set shuffling to true
                play track "\(uri)"
            end tell
            """)
        }

        // Fetch track info after Spotify has had time to switch
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.fetchNowPlaying()
        }
    }

    @discardableResult
    static func osascript(_ script: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
