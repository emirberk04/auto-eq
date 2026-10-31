import AVFAudio
import AudioToolbox
import SoundAnalysis
import EQCore
import Foundation
import os

/// A discovered track: unrelated to what Emir listens to, little known, measured to sound good.
struct Discovery: Codable, Identifiable, Equatable {
    var id: Int // iTunes trackId
    var title: String
    var artist: String
    var genre: String
    var storeGenre: String
    var url: URL
    var score: Double
    var plrDb: Double
    var issues: [String]
    /// Share of the preview with singing or rapping (nil in finds from before it was measured).
    var vocals: Double?
    var foundAt = Date()

    /// Opens in Music.app rather than the browser.
    var musicURL: URL {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.scheme = "music"
        return c?.url ?? url
    }
}

/// Random genre (MusicBrainz) → random recordings of it → match in the Apple Music catalog
/// (iTunes Search) → measure the 30 s preview in memory → first one that sounds good.
/// Sends nothing but the genre name and "artist title" searches (CLAUDE.md §15).
actor DiscoveryEngine {
    struct Progress: Sendable { var genre: String; var checked: Int }
    enum Failure: Error { case nothingFound }

    private let log = Logger(subsystem: "com.emiralan.s12-adaptive-eq", category: "Discovery")
    private let session: URLSession
    private var genres: [String] = []
    private var lastMusicBrainz = Date.distantPast
    private let storefront: String

    private static let userAgent = "S12AdaptiveEQ/0.1 ( personal macOS app )"
    private static let maxGenres = 10
    private static let candidatesPerGenre = 6
    private static let fallbackScore = 45.0
    /// With `requireVocals`: at least this share of the preview must have singing/rapping.
    static let minVocalFraction = 0.3
    /// Genres that are (almost) always instrumental: not worth the queries when vocals are wanted.
    private static let instrumentalWords = [
        "ambient", "drone", "classical", "baroque", "instrumental", "soundtrack", "score", "chamber",
        "orchestral", "symphon", "concerto", "sonata", "noise", "field recording", "techno", "post-rock",
        "math rock", "library", "new age", "meditation", "minimalism", "guitar", "piano", "gamelan",
    ]

    init() {
        let config = URLSessionConfiguration.ephemeral // no cookies, no disk cache
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: config)
        storefront = (Locale.current.region?.identifier ?? "TR").lowercased()
    }

    func discover(excluding seen: Set<Int>, requireVocals: Bool,
                  progress: @Sendable (Progress) -> Void) async throws -> Discovery {
        if genres.isEmpty { genres = try await loadGenres() }
        let pool = requireVocals
            ? genres.filter { g in !Self.instrumentalWords.contains { g.lowercased().contains($0) } } : genres
        var best: Discovery?
        var checked = 0
        for _ in 0..<Self.maxGenres {
            try Task.checkCancellation()
            guard let genre = pool.randomElement() else { break }
            progress(Progress(genre: genre, checked: checked))
            let recordings = (try? await recordings(tagged: genre, vocal: requireVocals)) ?? []
            for (title, artist) in recordings.shuffled().prefix(Self.candidatesPerGenre) {
                try Task.checkCancellation()
                guard let match = try? await storeMatch(title: title, artist: artist), !seen.contains(match.trackId),
                      let preview = match.previewUrl else { continue }
                checked += 1
                progress(Progress(genre: genre, checked: checked))
                guard let (quality, vocals) = try? await measure(preview, vocals: requireVocals) else { continue }
                let found = Discovery(id: match.trackId, title: match.trackName, artist: match.artistName, genre: genre,
                                      storeGenre: match.primaryGenreName ?? "", url: match.trackViewUrl,
                                      score: quality.score, plrDb: quality.plrDb, issues: quality.issues, vocals: vocals)
                log.info("candidate \(genre, privacy: .public): '\(found.title, privacy: .public)' score \(quality.score, format: .fixed(precision: 0)) vocals \((vocals ?? -1) * 100, format: .fixed(precision: 0))%")
                if requireVocals, (vocals ?? 0) < Self.minVocalFraction { continue }
                if quality.score >= SoundQuality.acceptScore { return found }
                if found.score > (best?.score ?? Self.fallbackScore) { best = found }
            }
        }
        if let best { return best }
        throw Failure.nothingFound
    }

    // MARK: MusicBrainz (≤ 1 request per second)

    private func musicBrainz(_ path: String, _ query: [URLQueryItem]) async throws -> Data {
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/" + path)!
        c.queryItems = query
        // 503 = throttled: back off and retry a few times.
        for attempt in 0..<4 {
            let wait = 1.1 * Double(1 << attempt) - Date().timeIntervalSince(lastMusicBrainz)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            lastMusicBrainz = Date()
            let (data, response) = try await session.data(from: c.url!)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return data }
            log.notice("MusicBrainz \(code) (attempt \(attempt + 1))")
            guard code == 503 else { break }
        }
        throw URLError(.badServerResponse)
    }

    private func loadGenres() async throws -> [String] {
        let data = try await musicBrainz("genre/all", [URLQueryItem(name: "fmt", value: "txt")])
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private struct RecordingPage: Decodable {
        struct Recording: Decodable {
            struct Credit: Decodable { var name: String }
            var title: String
            var artistCredit: [Credit]?
            enum CodingKeys: String, CodingKey { case title, artistCredit = "artist-credit" }
        }
        var count: Int
        var recordings: [Recording]
    }

    /// Recordings tagged with `genre`, from a random page. Prefers ones with an ISRC (they are
    /// usually on streaming services); falls back to all when there are too few.
    private func recordings(tagged genre: String, vocal: Bool) async throws -> [(String, String)] {
        var tag = "tag:\"\(genre.replacingOccurrences(of: "\"", with: ""))\""
        if vocal { tag += " AND NOT tag:instrumental" }
        for query in [tag + " AND isrc:*", tag] {
            func page(_ offset: Int) async throws -> RecordingPage {
                let data = try await musicBrainz("recording", [
                    .init(name: "query", value: query), .init(name: "limit", value: "50"),
                    .init(name: "offset", value: String(offset)), .init(name: "fmt", value: "json"),
                ])
                return try JSONDecoder().decode(RecordingPage.self, from: data)
            }
            var result = try await page(0)
            guard result.count >= 8 else { continue }
            if result.count > 50 { result = try await page(Int.random(in: 0...min(result.count - 50, 2000))) }
            let pairs = result.recordings.compactMap { r in r.artistCredit?.first.map { (r.title, $0.name) } }
            // One per artist, so a single prolific artist does not dominate.
            var artists = Set<String>()
            return pairs.filter { artists.insert($0.1.lowercased()).inserted }
        }
        return []
    }

    // MARK: iTunes Search

    private struct StoreResults: Decodable {
        struct Track: Decodable {
            var trackId: Int
            var trackName: String
            var artistName: String
            var trackViewUrl: URL
            var previewUrl: URL?
            var primaryGenreName: String?
        }
        var results: [Track]
    }

    private func storeMatch(title: String, artist: String) async throws -> StoreResults.Track? {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [
            .init(name: "term", value: "\(artist) \(title)"), .init(name: "entity", value: "song"),
            .init(name: "limit", value: "5"), .init(name: "country", value: storefront),
        ]
        let (data, _) = try await session.data(from: c.url!)
        let tracks = try JSONDecoder().decode(StoreResults.self, from: data).results
        let wantArtist = Self.normalized(artist), wantTitle = Self.normalized(title)
        return tracks.first { t in
            let a = Self.normalized(t.artistName), n = Self.normalized(t.trackName)
            return (a.contains(wantArtist) || wantArtist.contains(a)) && (n.hasPrefix(wantTitle) || wantTitle.hasPrefix(n))
        }
    }

    private static func normalized(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Preview measurement (memory only)

    /// Sound quality, and the vocal share when asked (only for previews that sound good enough).
    private func measure(_ preview: URL, vocals: Bool) async throws -> (SoundQuality, Double?) {
        let (data, _) = try await session.data(from: preview)
        let audio = try PreviewDecoder.decode(data)
        let quality = SoundQuality.measure(left: audio.left, right: audio.right, sampleRate: audio.sampleRate)
        guard vocals, quality.score > Self.fallbackScore else { return (quality, nil) }
        return (quality, try VocalDetector.vocalFraction(left: audio.left, right: audio.right, sampleRate: audio.sampleRate))
    }
}

/// Decodes an in-memory audio file (the AAC .m4a previews) to Float32 stereo without
/// touching the disk.
enum PreviewDecoder {
    struct Audio { var left: [Float]; var right: [Float]; var sampleRate: Double }
    struct DecodeError: Error { var status: OSStatus }

    private final class Source {
        let data: Data
        init(_ data: Data) { self.data = data }
    }

    static func decode(_ data: Data) throws -> Audio {
        let source = Source(data)
        let context = Unmanaged.passUnretained(source).toOpaque()
        var file: AudioFileID?
        var status = AudioFileOpenWithCallbacks(context, { ctx, position, count, buffer, read in
            let source = Unmanaged<Source>.fromOpaque(ctx).takeUnretainedValue()
            let start = Int(position), n = max(0, min(Int(count), source.data.count - start))
            if n > 0 { source.data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), from: start..<start + n) }
            read.pointee = UInt32(n)
            return noErr
        }, nil, { ctx in
            Int64(Unmanaged<Source>.fromOpaque(ctx).takeUnretainedValue().data.count)
        }, nil, kAudioFileM4AType, &file)
        guard status == noErr, let file else { throw DecodeError(status: status) }
        defer { AudioFileClose(file) }

        var ext: ExtAudioFileRef?
        status = ExtAudioFileWrapAudioFileID(file, false, &ext)
        guard status == noErr, let ext else { throw DecodeError(status: status) }
        defer { ExtAudioFileDispose(ext) }

        var fileFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat)
        guard status == noErr, fileFormat.mSampleRate > 0 else { throw DecodeError(status: status) }
        var client = AudioStreamBasicDescription(
            mSampleRate: fileFormat.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32,
            mReserved: 0)
        status = ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else { throw DecodeError(status: status) }

        var left: [Float] = [], right: [Float] = []
        let chunk = 8192
        var l = [Float](repeating: 0, count: chunk), r = l
        while true {
            var frames = UInt32(chunk)
            status = l.withUnsafeMutableBytes { lb in
                r.withUnsafeMutableBytes { rb in
                    let list = AudioBufferList.allocate(maximumBuffers: 2)
                    defer { list.unsafeMutablePointer.deallocate() }
                    list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(lb.count), mData: lb.baseAddress)
                    list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(rb.count), mData: rb.baseAddress)
                    return ExtAudioFileRead(ext, &frames, list.unsafeMutablePointer)
                }
            }
            guard status == noErr else { throw DecodeError(status: status) }
            if frames == 0 { break }
            left.append(contentsOf: l.prefix(Int(frames)))
            right.append(contentsOf: r.prefix(Int(frames)))
        }
        return Audio(left: left, right: right, sampleRate: fileFormat.mSampleRate)
    }
}

/// Is there singing or rapping in an excerpt? Apple's built-in sound classifier, on device.
enum VocalDetector {
    static let labels: Set<String> = ["singing", "choir_singing", "rapping", "yodeling"]
    static let windowConfidence = 0.35

    private final class Collector: NSObject, SNResultsObserving {
        var windows = 0, vocal = 0
        var confidences: [Double] = []
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let best = labels.compactMap { result.classification(forIdentifier: $0)?.confidence }.max() ?? 0
            windows += 1
            confidences.append(best)
            if best >= windowConfidence { vocal += 1 }
        }
    }

    /// Fraction (0…1) of ~1.5 s-spaced 3 s windows that contain vocals.
    static func vocalFraction(left: [Float], right: [Float], sampleRate: Double) throws -> Double {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)) else { return 0 }
        buffer.frameLength = AVAudioFrameCount(left.count)
        let mono = buffer.floatChannelData![0]
        for i in left.indices { mono[i] = (left[i] + right[i]) / 2 }
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.overlapFactor = 0.5
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let collector = Collector()
        try analyzer.add(request, withObserver: collector)
        analyzer.analyze(buffer, atAudioFramePosition: 0)
        analyzer.completeAnalysis()
        return collector.windows == 0 ? 0 : Double(collector.vocal) / Double(collector.windows)
    }
}
