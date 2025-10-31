// Features/Sprechen/SprechenView.swift
import SwiftUI
import AVFoundation
import Speech
import Combine
import Accelerate

final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published var elapsed: TimeInterval = 0
    @Published var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startDate: Date?
    private var pauseDate: Date?
    private var accumulatedTime: TimeInterval = 0
    private var finishHandler: ((URL, Bool) -> Void)?

    func startRecording(to url: URL, sensitivity: Double) throws {
        // Session vorbereiten – minimal und stabil
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        if session.isInputGainSettable {
            let clamped = max(0.0, min(1.0, sensitivity))
            try? session.setInputGain(Float(clamped))
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128000
        ]

        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.delegate = self
        recorder?.isMeteringEnabled = true

        // State
        elapsed = 0
        accumulatedTime = 0
        isPaused = false
        isRecording = true
        startDate = Date()

        recorder?.record()
        startTimer()
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        recorder?.pause()
        isPaused = true
        pauseDate = Date()
        timer?.invalidate(); timer = nil
    }

    func resume() {
        guard isRecording, isPaused else { return }
        recorder?.record()
        isPaused = false
        if let pauseDate = pauseDate, let startDate = startDate {
            accumulatedTime += pauseDate.timeIntervalSince(startDate)
        }
        self.startDate = Date()
        self.pauseDate = nil
        startTimer()
    }

    func stop(completion: ((URL, Bool) -> Void)? = nil) {
        finishHandler = completion
        recorder?.stop()
        isRecording = false
        isPaused = false
        timer?.invalidate(); timer = nil
        if let startDate = startDate {
            let extra: TimeInterval = isPaused ? 0 : Date().timeIntervalSince(startDate)
            elapsed = accumulatedTime + extra
        }
        recorder = nil
        startDate = nil
        pauseDate = nil
        accumulatedTime = 0
        // Session deactivation moved to delegate
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        // Session nach dem finalen Schreiben freigeben
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        finishHandler?(url, flag)
        finishHandler = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let r = self.recorder else { return }
            r.updateMeters()
            self.level = r.averagePower(forChannel: 0)
            let base: TimeInterval = self.accumulatedTime
            let extra: TimeInterval = self.startDate.map { Date().timeIntervalSince($0) } ?? 0
            self.elapsed = base + extra
        }
        if let t = timer { RunLoop.current.add(t, forMode: .common) }
    }
}

final class LiveTranscriber: NSObject, ObservableObject {
    @Published var combinedText: String = ""
    @Published var currentChunk: String = ""

    private var recognizer: SFSpeechRecognizer?
    var localeCode: String = "auto"
    var partialResultsEnabled: Bool = true
    var onDeviceOnly: Bool = false
    var amplitudeThreshold: Float = 0.01
    private var micSensitivity: Double = 0.5

    // Simple silence detection
    private var silenceTimer: Timer?
    private let silenceHold: TimeInterval = 0.8

    func applyConfig(localeCode: String, partialResults: Bool, onDeviceOnly: Bool, micSensitivity: Double) {
        self.localeCode = localeCode
        self.partialResultsEnabled = partialResults
        self.onDeviceOnly = onDeviceOnly
        self.micSensitivity = micSensitivity
        // Map sensitivity (0..1) to amplitude threshold (higher sensitivity -> lower threshold)
        let minThresh: Float = 0.003  // ~ -50 dB
        let maxThresh: Float = 0.02   // ~ -34 dB
        self.amplitudeThreshold = maxThresh - Float(micSensitivity) * (maxThresh - minThresh)
    }

    private func delta(from full: String) -> String {
        let fullTrim = full.trimmingCharacters(in: .whitespacesAndNewlines)
        if combinedText.isEmpty { return fullTrim }
        if fullTrim.hasPrefix(combinedText) {
            let idx = fullTrim.index(fullTrim.startIndex, offsetBy: combinedText.count)
            return String(fullTrim[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fullTrim
    }

    func previewText() -> String {
        let d = delta(from: currentChunk)
        if d.isEmpty { return combinedText }
        return combinedText + (combinedText.isEmpty ? "" : "\n") + d
    }

    func start() {
        stop() // safety
        if localeCode == "auto" {
            recognizer = SFSpeechRecognizer()
        } else {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeCode))
        }
        // Try to apply input gain according to mic sensitivity
        let session = AVAudioSession.sharedInstance()
        if session.isInputGainSettable {
            let clamped = max(0.0, min(1.0, micSensitivity))
            try? session.setInputGain(Float(clamped))
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = partialResultsEnabled

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.request?.append(buffer)
            self.handleBufferForSilence(buffer)
        }

        engine.prepare()
        do { try engine.start() } catch { return }

        if #available(iOS 13.0, *) {
            if recognizer?.supportsOnDeviceRecognition == true {
                req.requiresOnDeviceRecognition = onDeviceOnly
            } else {
                req.requiresOnDeviceRecognition = false
            }
        }

        request = req
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let r = result {
                DispatchQueue.main.async {
                    self.currentChunk = r.bestTranscription.formattedString
                }
                if r.isFinal {
                    self.silenceTimer?.invalidate(); self.silenceTimer = nil
                    self.commitCurrentChunk()
                }
            }
            if error != nil { /* keep engine running; chunks commit on silence */ }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        silenceTimer?.invalidate(); silenceTimer = nil
        // WICHTIG: Beim Stop den letzten Teil (currentChunk) einmalig in combinedText übernehmen,
        // damit der Nutzer den finalen Text noch SPEICHERN kann.
        // Deduplizierung passiert in `commitCurrentChunk()` selbst; es entsteht kein Doppeltext.
        commitCurrentChunk()
        // lastCommitted = ""  // removed reset here
    }

    private func commitCurrentChunk() {
        let finalText = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else { currentChunk = ""; return }
        // Compute only the new suffix relative to already combined text
        let chunk = delta(from: finalText)
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { currentChunk = ""; return }
        if trimmed == lastCommitted { currentChunk = ""; return }
        // Deduplizieren: wenn der letzte angehängte Text identisch ist
        if combinedText.hasSuffix(trimmed) {
            currentChunk = ""
            return
        }
        if combinedText.components(separatedBy: "\n").last == trimmed {
            currentChunk = ""
            return
        }
        if !combinedText.isEmpty { combinedText += "\n" }
        combinedText += trimmed
        lastCommitted = trimmed
        currentChunk = ""
    }

    private func handleBufferForSilence(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?.pointee else { return }
        let frameCount = Int(buffer.frameLength)
        if frameCount == 0 { return }
        var sum: Float = 0
        vDSP_measqv(ch, 1, &sum, vDSP_Length(frameCount))
        let rms = sqrtf(sum)
        let isSilent = rms < amplitudeThreshold

        silenceTimer?.invalidate()
        if isSilent {
            // if silent, schedule commit after hold period
            silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceHold, repeats: false) { [weak self] _ in
                self?.commitCurrentChunk()
            }
            RunLoop.current.add(silenceTimer!, forMode: .common)
        }
    }

    func reset() {
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        silenceTimer?.invalidate(); silenceTimer = nil
        combinedText = ""
        currentChunk = ""
        lastCommitted = ""
    }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastCommitted: String = ""
}

final class RecordingState: ObservableObject {
    @Published var currentFileName: String?
}

struct SprechenView: View {
    @EnvironmentObject private var store: DataStore
    @StateObject private var audio = AudioRecorder()
    @StateObject private var recState = RecordingState()
    @StateObject private var live = LiveTranscriber()

    @State private var errorMsg: String?
    @State private var title: String = ""
    @State private var isTranscribing: Bool = false
    @State private var transcript: String = ""
    @State private var transcriptSaved: Bool = false
    @State private var canSave: Bool = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("speak.header.newEntry")
                    .font(.title)
                    .bold()
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            VStack(spacing: 12) {
                Text(audio.isRecording ? String(localized: "speak.status.recording") : String(localized: "speak.status.ready"))
                    .foregroundColor(.secondary)

                TextField(String(localized: "speak.placeholder.titleOptional"), text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                    .overlay(
                        HStack {
                            Spacer()
                            if !title.isEmpty {
                                Button(action: { title = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .padding(.trailing, 8)
                            }
                        }
                    )

                // Pegel + Zeit
                VStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.gray.opacity(0.2)).frame(height: 12)
                        Capsule()
                            .fill(audio.isRecording ? Color.blue : Color.gray)
                            .frame(width: CGFloat(max(0, min(1, (audio.level + 60) / 60))) * 220, height: 12)
                            .animation(.linear(duration: 0.1), value: audio.level)
                    }
                    .frame(width: 220)
                    HStack {
                        Image(systemName: "timer").foregroundColor(.secondary)
                        Text(formatTime(audio.elapsed))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                }

                // Controls
                HStack(spacing: 24) {
                    Button {
                        requestSpeechAuth()
                        transcriptSaved = false
                        transcript = ""
                        canSave = false
                        // previous code had duplicate live.start() call - removed
                        let cfg = loadSpeechConfig()
                        let fileName = "rec-\(UUID().uuidString).m4a"
                        recState.currentFileName = fileName
                        let url = store.audioURL(for: fileName)
                        do {
                            try audio.startRecording(to: url, sensitivity: cfg.micSensitivity)
                        } catch {
                            errorMsg = "\(String(localized: "speak.error.recording")): \(error.localizedDescription)"
                            return
                        }
                        live.applyConfig(localeCode: cfg.locale, partialResults: cfg.partial, onDeviceOnly: cfg.onDeviceOnly, micSensitivity: cfg.micSensitivity)
                        live.start()
                    } label: {
                        HStack(spacing: 8) { Image(systemName: "record.circle"); Text("speak.action.start") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(audio.isRecording)

                    Button {
                        live.stop()
                        transcriptSaved = false
                        let preview = live.previewText().trimmingCharacters(in: .whitespacesAndNewlines)
                        canSave = !preview.isEmpty
                        stopAndSave() // now async via recorder delegate
                    } label: {
                        Image(systemName: "stop.circle")
                    }
                    .accessibilityLabel(Text("speak.action.stop"))
                    .buttonStyle(.bordered)
                    .disabled(!audio.isRecording)

                    if audio.isRecording {
                        Button {
                            if audio.isPaused { audio.resume() } else { audio.pause() }
                        } label: {
                            Image(systemName: audio.isPaused ? "play.circle" : "pause.circle")
                        }
                        .accessibilityLabel(Text(audio.isPaused ? "speak.action.resume" : "speak.action.pause"))
                        .buttonStyle(.bordered)
                    }
                }

                // Transkript-Anzeige (Live & Nach-Transkription)
                if isTranscribing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("speak.status.transcribing")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
                // Quelle für Anzeige & Speichern ist ausschliesslich `live.previewText()`; `transcript` bleibt leer bis zum Speichern.
                // Hinweis: Single-Source-of-Truth
                // Wir zeigen bevorzugt `live.previewText()`; `transcript` bleibt leer,
                // bis der Nutzer auf „Speichern“ drückt (dort wird `transcript = shownTranscript` gesetzt).
                // So vermeiden wir doppelte Inhalte (während der Aufnahme + nachträgliche Voll-Transkription).
                let shownTranscript: String = {
                    let t = live.previewText()
                    let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? transcript : t
                }()
                if !shownTranscript.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("speak.label.transcript")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(shownTranscript)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    // unsichtbarer Anker am Ende für Auto-Scroll
                                    Color.clear
                                        .frame(height: 1)
                                        .id("TRANSCRIPT_BOTTOM")
                                }
                            }
                            .onChange(of: shownTranscript) {
                                // Beim Wachsen des Textes automatisch nach unten scrollen
                                withAnimation {
                                    proxy.scrollTo("TRANSCRIPT_BOTTOM", anchor: .bottom)
                                }
                            }
                            .frame(minHeight: 160)
                            .frame(maxHeight: (!shownTranscript.isEmpty || audio.isRecording) ? .infinity : 160, alignment: .top)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.3))
                            )
                        }
                        HStack {
                            Spacer()
                            Button {
                                transcript = shownTranscript
                                saveTranscriptEntry()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "tray.and.arrow.down")
                                    Text("common.save")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canSave || transcriptSaved || shownTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }

                if let errorMsg = errorMsg {
                    Text(errorMsg).foregroundColor(.red)
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
            .onTapGesture { titleFocused = false }
            .frame(maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity, alignment: .center)
            
        }
        .padding(.horizontal, 16)
        .padding(.vertical)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { requestSpeechAuth() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(action: { titleFocused = false }) {
                    Image(systemName: "keyboard.chevron.compact.down")
                }
                .accessibilityLabel(Text("speak.access.hideKeyboard"))
            }
        }
    }

    // MARK: - Speech (Nach-Transkription)
    private func requestSpeechAuth() {
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    private func loadSpeechConfig() -> (locale: String, onDeviceOnly: Bool, partial: Bool, micSensitivity: Double) {
        let ud = UserDefaults.standard
        let code = ud.string(forKey: "config.speech.lang") ?? Locale.current.identifier
        let onDevice = ud.object(forKey: "config.speechOnDeviceOnly") != nil ? ud.bool(forKey: "config.speechOnDeviceOnly") : false
        let partial = ud.object(forKey: "config.speechPartial") != nil ? ud.bool(forKey: "config.speechPartial") : true
        let sens = ud.object(forKey: "config.micSensitivity") != nil ? ud.double(forKey: "config.micSensitivity") : 0.5
        return (code, onDevice, partial, sens)
    }

    @available(*, deprecated, message: "Voll-File-Transkription ist deaktiviert – wir verwenden Live-Chunking. Nicht aus dem Stop-Flow aufrufen.")
    private func transcribe(url: URL, transcriptTitle: String?) {
        transcript = ""
        isTranscribing = true
        transcriptSaved = false
        let cfg = loadSpeechConfig()
        let locale = Locale(identifier: cfg.locale)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { isTranscribing = false; return }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = cfg.partial
        if #available(iOS 13.0, *) {
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = cfg.onDeviceOnly
            } else {
                request.requiresOnDeviceRecognition = false
            }
        }

        _ = recognizer.recognitionTask(with: request) { result, error in
            if let err = error {
                // Bei Fehler abbrechen, UI aktualisieren
                DispatchQueue.main.async {
                    self.isTranscribing = false
                }
                print("Transkript Fehler: \(err.localizedDescription)")
                return
            }
            if let r = result {
                if r.isFinal {
                    let text = r.bestTranscription.formattedString
                    DispatchQueue.main.async {
                        self.transcript = text
                        self.isTranscribing = false
                    }
                }
            }
        }
    }

    private func saveTranscriptEntry() {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !transcriptSaved else { return }
        let entryTitle: String
        if !title.isEmpty {
            entryTitle = String(format: String(localized: "speak.entry.titleWithName"), title)
        } else {
            entryTitle = String(localized: "speak.entry.title")
        }
        store.add(.text(trimmed, title: entryTitle))
        transcriptSaved = true
        canSave = false

        // Recorder/Livetext visuell zurücksetzen
        live.reset()
        audio.elapsed = 0
        audio.level = -60

        // View in Leerzustand versetzen
        transcript = ""
        title = ""
        errorMsg = nil
        isTranscribing = false
        recState.currentFileName = nil
    }

    private func stopAndSave() {
        audio.stop { url, ok in
            DispatchQueue.main.async {
                // Mindestprüfung: Datei existiert und ist nicht leer
                var sizeOK = false
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let fsize = attrs[.size] as? NSNumber {
                    sizeOK = fsize.intValue > 1024 // >1KB
                }

                // Wenn Aufnahme fehlschlug oder Datei zu klein -> Fehlermeldung und kein Log-Eintrag
                guard ok && sizeOK else {
                    self.errorMsg = String(localized: "speak.error.unusable")
                    self.recState.currentFileName = nil
                    self.title = ""
                    return
                }

                // Dateiname merken
                let name = url.lastPathComponent

                // Audio-Log anlegen
                self.store.add(.audio(fileName: name, title: self.title.isEmpty ? nil : self.title))

                // WICHTIG: Live-Transkript ist die EINZIGE Quelle.
                // Kein erneutes Voll-File-Transkribieren nach dem Stop – das führt zu doppeltem Text.
                // transcript bleibt absichtlich leer; die UI zeigt liveText via `shownTranscript`.
                self.isTranscribing = false
                self.canSave = true
                self.transcript = "" // nicht duplizieren – beim Speichern setzt der Button `transcript = shownTranscript`

                // Felder leeren
                self.recState.currentFileName = nil
                self.title = ""
            }
        }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

