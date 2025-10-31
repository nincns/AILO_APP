import SwiftUI
import AVFoundation
import Combine


/// Wrapper to make URL identifiable for SwiftUI sheets
struct IdentifiableURL: Identifiable, Equatable {
    let id: String
    let url: URL

    init(_ url: URL) {
        self.url = url
        self.id = url.absoluteString
    }
}

/// Simple AVAudioPlayer wrapper with progress, duration and play/pause/seek.
final class AudioPlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying: Bool = false
    @Published var progress: Double = 0        // 0.0 ... 1.0
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    enum AudioError: LocalizedError {
        case fileMissing
        case fileTooSmall

        var errorDescription: String? {
            switch self {
            case .fileMissing: return "Audiodatei nicht gefunden."
            case .fileTooSmall: return "Audiodatei ist beschädigt oder leer."
            }
        }
    }

    @Published var isReady: Bool = false

    private var player: AVAudioPlayer?
    private var displayLink: CADisplayLink?
    private var lastURL: URL?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func load(url: URL) throws {
        stop()
        isReady = false
        lastURL = url

        // Prüfen, ob Datei existiert und nicht trivial klein ist
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw AudioError.fileMissing
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fsize = attrs[.size] as? NSNumber,
           fsize.intValue < 1024 { // < 1KB
            throw AudioError.fileTooSmall
        }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: [])

        let p = try AVAudioPlayer(contentsOf: url)
        p.delegate = self
        p.prepareToPlay()
        player = p
        duration = p.duration
        currentTime = p.currentTime
        progress = duration > 0 ? currentTime / duration : 0
        isReady = true

        startDisplayLink()
    }

    func play() {
        // Reload last URL if player was torn down (e.g., after stop())
        if player == nil, let last = lastURL {
            try? load(url: last)
        }
        guard let p = player else { return }
        // If playback reached the end, restart from the beginning
        if abs(p.currentTime - p.duration) < 0.01 { p.currentTime = 0 }
        if !p.isPlaying { p.play(); isPlaying = true }
    }

    func pause() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); isPlaying = false }
    }

    func stop() {
        isPlaying = false
        isReady = false
        displayLink?.invalidate(); displayLink = nil
        player?.stop()
        player = nil
        currentTime = 0
        duration = 0
        progress = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func seekBy(seconds: TimeInterval) {
        guard let p = player else { return }
        var newTime = p.currentTime + seconds
        newTime = max(0, min(newTime, p.duration))
        p.currentTime = newTime
        currentTime = newTime
        progress = duration > 0 ? currentTime / duration : 0
    }

    func seek(to progress: Double) {
        guard let p = player else { return }
        let clamped = max(0, min(1, progress))
        p.currentTime = p.duration * clamped
        currentTime = p.currentTime
        self.progress = clamped
    }

    private func startDisplayLink() {
        displayLink?.invalidate()
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func tick() {
        guard let p = player else { return }
        currentTime = p.currentTime
        duration = p.duration
        progress = duration > 0 ? currentTime / duration : 0
        isPlaying = p.isPlaying
    }

    // MARK: - AVAudioPlayerDelegate
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Keep the player loaded; just mark as stopped so the user can tap Play to restart
        isPlaying = false
        // Ensure progress shows completion
        currentTime = player.duration
        duration = player.duration
        progress = duration > 0 ? currentTime / duration : 0
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
        switch type {
        case .began:
            pause()
        case .ended:
            // Do nothing; user can resume manually. Optionally auto-resume if needed.
            break
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        // Bei Kopfhörerziehen etc. pausieren
        pause()
    }
}

/// Compact player UI presented as a sheet.
struct AudioPlayerView: View {
    let url: URL
    var title: String = "Audio"

    @Environment(\.dismiss) private var dismiss
    @StateObject private var ctrl = AudioPlaybackController()
    @State private var loadError: String? = nil
    @State private var isLoading: Bool = false

    private func fmt(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "--:--" }
        let total = Int(t.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .accessibilityLabel("Schließen")
            }

            if let err = loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Wiedergabe nicht möglich")
                        .font(.headline)
                    Text(err)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if isLoading || !ctrl.isReady {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Lade Audio…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                VStack(spacing: 10) {
                    Slider(value: Binding(
                        get: { ctrl.progress },
                        set: { ctrl.seek(to: $0) }
                    ))
                    HStack {
                        Text(fmt(ctrl.currentTime)).font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Text(fmt(ctrl.duration)).font(.caption).foregroundColor(.secondary)
                    }
                }

                HStack(spacing: 24) {
                    Button { ctrl.seekBy(seconds: -10) } label: {
                        Image(systemName: "gobackward.10")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        ctrl.isPlaying ? ctrl.pause() : ctrl.play()
                    } label: {
                        Image(systemName: ctrl.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                    }
                    .buttonStyle(.plain)

                    Button { ctrl.seekBy(seconds: +10) } label: {
                        Image(systemName: "goforward.10")
                    }
                    .buttonStyle(.bordered)
                }
            }

            Spacer(minLength: 0)
        }
        .padding()
        .frame(minHeight: 120) // kompakte Mindesthöhe, damit die Controls immer sichtbar sind
        .onAppear {
            isLoading = true
            loadError = nil
            DispatchQueue.main.async {
                do {
                    try ctrl.load(url: url)
                    // Kleines Delay, damit das Sheet vollständig steht, bevor wir abspielen
                    DispatchQueue.main.async { ctrl.play() }
                    isLoading = false
                } catch {
                    loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    isLoading = false
                }
            }
        }
        .onChange(of: url) { _, _ in
            do {
                isLoading = true
                loadError = nil
                try ctrl.load(url: url)
                DispatchQueue.main.async { ctrl.play() }
                isLoading = false
            } catch {
                loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                isLoading = false
            }
        }
        .onDisappear { ctrl.stop() }
        .presentationDetents([.fraction(0.25), .medium])
        .presentationDragIndicator(.visible)
    }
}
