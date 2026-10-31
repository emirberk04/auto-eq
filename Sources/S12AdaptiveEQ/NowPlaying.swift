import EQCore
import Foundation
import os

/// Music.app's public "playerInfo" distributed notification: posted on every track or play-state
/// change, no permission or private API needed. Only used to name tracks and key the cache;
/// the audio path never depends on it.
@MainActor
final class NowPlaying {
    struct Track: Sendable, Equatable {
        var title: String
        var artist: String
        var durationSeconds: Double
        var key: String { TrackCache.key(title: title, artist: artist, durationSeconds: durationSeconds) }
    }

    private let log = Logger(subsystem: "com.emiralan.s12-adaptive-eq", category: "NowPlaying")
    private var observer: NSObjectProtocol?
    /// Called with the playing track on every "Playing" notification.
    var onTrack: ((Track) -> Void)?
    private(set) var seenAny = false

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo ?? [:]
            let state = info["Player State"] as? String ?? ""
            let keys = info.keys.map { "\($0)" }.sorted().joined(separator: ",")
            let track = Track(title: info["Name"] as? String ?? "", artist: info["Artist"] as? String ?? "",
                              durationSeconds: ((info["Total Time"] as? NSNumber)?.doubleValue ?? 0) / 1000)
            MainActor.assumeIsolated { self?.handle(state: state, track: track, keys: keys) }
        }
    }

    private func handle(state: String, track: Track, keys: String) {
        log.info("playerInfo: state=\(state, privacy: .public) keys=\(keys, privacy: .public)")
        guard state == "Playing", !track.title.isEmpty else { return }
        seenAny = true
        onTrack?(track)
    }
}
