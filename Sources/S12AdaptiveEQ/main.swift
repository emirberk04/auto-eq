import AppKit
import EQCore

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--render-ui"), i + 1 < args.count {
        app.setActivationPolicy(.prohibited)
        let mode = args.firstIndex(of: "--visualizer").flatMap { args.indices.contains($0 + 1) ? Visualizer(rawValue: args[$0 + 1]) : nil }
        UIRenderer.render(to: args[i + 1], dark: args.contains("--dark"), visualizer: mode)
        exit(0)
    }
    if let i = args.firstIndex(of: "--measure-preview"), i + 1 < args.count, let url = URL(string: args[i + 1]) {
        // Measures one preview URL like Keşfet does (for tuning).
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let audio = try PreviewDecoder.decode(data)
                let q = SoundQuality.measure(left: audio.left, right: audio.right, sampleRate: audio.sampleRate)
                let v = try VocalDetector.vocalFraction(left: audio.left, right: audio.right, sampleRate: audio.sampleRate)
                print("score \(Int(q.score)) PLR \(Int(q.plrDb)) vocals \(Int(v * 100))% \(q.issues)")
                exit(0)
            } catch {
                print("failed: \(error)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }
    if args.contains("--discover-once") {
        // Runs one Keşfet search and prints the result (for checking the pipeline).
        Task {
            do {
                let d = try await DiscoveryEngine().discover(excluding: [], requireVocals: true) { print("… \($0.genre) \($0.checked)") }
                print("found: \(d.title) — \(d.artist) [\(d.genre) / \(d.storeGenre)] score \(Int(d.score)) vocals \(Int((d.vocals ?? 0) * 100))% PLR \(Int(d.plrDb)) \(d.issues) \(d.url)")
                exit(0)
            } catch {
                print("failed: \(error)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
