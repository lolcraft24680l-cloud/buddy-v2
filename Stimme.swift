import AVFoundation
import Speech

/// Zuhören und Reden. Kann drei Dinge gleichzeitig im Kopf behalten:
/// auf das Weckwort lauschen, einen Befehl aufnehmen und selbst sprechen.
@MainActor
final class Stimme: NSObject, ObservableObject {

    // MARK: Zustand nach außen

    @Published var mitschrift = ""
    @Published var hört = false
    @Published var spricht = false
    @Published var lauscht = false          // Weckwort-Bereitschaft
    @Published var hinweis = ""
    /// Mikrofonpegel 0 bis 1 — davon leben Augen und Wellenform.
    @Published var pegel: Double = 0
    /// Die letzten Pegelwerte für die Wellenform.
    @Published var welle: [Double] = Array(repeating: 0, count: 42)
    /// Zählt bei jedem gesprochenen Wort hoch.
    @Published var takt = 0

    var beiSatz: ((String) -> Void)?
    var beiWeckwort: (() -> Void)?

    // MARK: Einstellungen

    @Published var weckwortAn: Bool = UserDefaults.standard.bool(forKey: "weckwort") {
        didSet {
            UserDefaults.standard.set(weckwortAn, forKey: "weckwort")
            weckwortAn ? lauschenStarten() : lauschenBeenden()
        }
    }

    @Published var stimmenId: String = UserDefaults.standard.string(forKey: "stimme") ?? "" {
        didSet { UserDefaults.standard.set(stimmenId, forKey: "stimme") }
    }
    @Published var tonhöhe: Double = UserDefaults.standard.object(forKey: "tonhoehe") as? Double ?? 1.28 {
        didSet { UserDefaults.standard.set(tonhöhe, forKey: "tonhoehe") }
    }
    @Published var tempo: Double = UserDefaults.standard.object(forKey: "tempo") as? Double ?? 0.51 {
        didSet { UserDefaults.standard.set(tempo, forKey: "tempo") }
    }

    /// Die Weckwörter, auf die BUDDY reagiert.
    private let weckwörter = ["buddy", "budi", "buddi", "bady", "batti", "börti"]

    // MARK: Innereien

    private let motor = AVAudioEngine()
    private let erkenner = SFSpeechRecognizer(locale: Locale(identifier: "de-DE"))
    private var anfrage: SFSpeechAudioBufferRecognitionRequest?
    private var aufgabe: SFSpeechRecognitionTask?
    private let sprecher = AVSpeechSynthesizer()

    private var uhr: Timer?
    private var neustartUhr: Timer?
    private var hatGesprochen = false
    private var imWeckmodus = false
    private let wartezeitVorSprache: TimeInterval = 9.0
    private let stilleNachSprache: TimeInterval = 1.6

    override init() {
        super.init()
        sprecher.delegate = self
        if weckwortAn {
            Task { if await erlaubnisHolen() { lauschenStarten() } }
        }
    }

    // MARK: - Stimmen

    struct Wahl: Identifiable, Hashable {
        let id: String
        let name: String
        let güte: String
    }

    /// Alle deutschen Stimmen des Geräts, die beste zuerst.
    var stimmenAuswahl: [Wahl] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("de") }
            .sorted { rang($0) > rang($1) }
            .map { Wahl(id: $0.identifier, name: $0.name, güte: güteName($0.quality)) }
    }

    private func rang(_ stimme: AVSpeechSynthesisVoice) -> Int {
        var punkte = 0
        switch stimme.quality {
        case .premium:  punkte += 100
        case .enhanced: punkte += 60
        default:        punkte += 10
        }
        // Helle, jüngere Stimmen zuerst — das ist der gewünschte Klang.
        for name in ["anna", "helena", "petra", "eva", "marlene"]
        where stimme.name.lowercased().contains(name) { punkte += 30 }
        return punkte
    }

    private func güteName(_ g: AVSpeechSynthesisVoice.Quality) -> String {
        switch g {
        case .premium:  return "Premium"
        case .enhanced: return "Erweitert"
        default:        return "Standard"
        }
    }

    private func besteStimme() -> AVSpeechSynthesisVoice? {
        if !stimmenId.isEmpty, let gewählt = AVSpeechSynthesisVoice(identifier: stimmenId) {
            return gewählt
        }
        let deutsche = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("de") }
        return deutsche.max(by: { rang($0) < rang($1) }) ?? AVSpeechSynthesisVoice(language: "de-DE")
    }

    /// Ob überhaupt eine hochwertige Stimme installiert ist.
    var hatGuteStimme: Bool {
        AVSpeechSynthesisVoice.speechVoices()
            .contains { $0.language.hasPrefix("de") && $0.quality != .default }
    }

    // MARK: - Erlaubnis

    func erlaubnisHolen() async -> Bool {
        let spracheOK = await withCheckedContinuation { fortsetzen in
            SFSpeechRecognizer.requestAuthorization { status in
                fortsetzen.resume(returning: status == .authorized)
            }
        }
        guard spracheOK else {
            hinweis = "Spracherkennung ist nicht erlaubt. Einstellungen, BUDDY, Spracherkennung."
            return false
        }
        let mikroOK = await withCheckedContinuation { fortsetzen in
            AVAudioApplication.requestRecordPermission { fortsetzen.resume(returning: $0) }
        }
        if !mikroOK { hinweis = "Das Mikrofon ist nicht erlaubt. Einstellungen, BUDDY, Mikrofon." }
        return mikroOK
    }

    // MARK: - Weckwort

    /// Dauerhaftes, gerätelokales Lauschen auf „Buddy".
    func lauschenStarten() {
        guard weckwortAn, !hört, !imWeckmodus, !spricht else { return }

        // Ohne Erlaubnis erst fragen, dann lauschen.
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVAudioApplication.shared.recordPermission == .granted else {
            Task { if await erlaubnisHolen() { lauschenStarten() } }
            return
        }
        imWeckmodus = true
        starteAufnahme(weckmodus: true)
    }

    func lauschenBeenden() {
        imWeckmodus = false
        neustartUhr?.invalidate(); neustartUhr = nil
        if !hört { aufräumen() }
        lauscht = false
    }

    private func weckwortGefunden(in text: String) -> String? {
        let flach = text.lowercased()
        guard let treffer = weckwörter.compactMap({ wort -> Range<String.Index>? in
            flach.range(of: wort)
        }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }

        // Alles nach dem Weckwort ist schon der Befehl.
        let rest = String(flach[treffer.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?"))
        return rest
    }

    // MARK: - Aufnahme

    func zuhören() {
        guard !hört else { return }
        redenAbbrechen()
        imWeckmodus = false
        starteAufnahme(weckmodus: false)
    }

    private func starteAufnahme(weckmodus: Bool) {
        guard let erkenner, erkenner.isAvailable else {
            if !weckmodus { hinweis = "Die Spracherkennung ist gerade nicht verfügbar." }
            return
        }
        aufräumen()

        do {
            let sitzung = AVAudioSession.sharedInstance()
            try sitzung.setCategory(.playAndRecord, mode: .default,
                                    options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try sitzung.setActive(true, options: .notifyOthersOnDeactivation)

            let neu = SFSpeechAudioBufferRecognitionRequest()
            neu.shouldReportPartialResults = true
            neu.taskHint = weckmodus ? .search : .dictation
            // Weckwort läuft lokal — sonst wäre das Kontingent in Minuten leer.
            neu.requiresOnDeviceRecognition = weckmodus
            anfrage = neu

            let eingang = motor.inputNode
            eingang.removeTap(onBus: 0)
            let format = eingang.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                if !weckmodus { hinweis = "Das Mikrofon ist gerade belegt." }
                aufräumen()
                return
            }

            eingang.installTap(onBus: 0, bufferSize: 2048, format: format) { puffer, _ in
                neu.append(puffer)

                guard let kanal = puffer.floatChannelData?[0] else { return }
                let anzahl = Int(puffer.frameLength)
                guard anzahl > 0 else { return }
                var summe: Float = 0
                for i in stride(from: 0, to: anzahl, by: 8) { summe += kanal[i] * kanal[i] }
                let effektiv = sqrt(summe / Float(max(1, anzahl / 8)))
                let sichtbar = Double(min(1, max(0, (effektiv * 14).squareRoot())))

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.pegel = self.pegel * 0.55 + sichtbar * 0.45
                    if self.hört {
                        self.welle.removeFirst()
                        self.welle.append(self.pegel)
                    }
                }
            }

            motor.prepare()
            try motor.start()

            mitschrift = ""
            hatGesprochen = false
            if weckmodus {
                lauscht = true
                // Apple beendet Erkennungen nach etwa einer Minute — neu ansetzen.
                neustartUhr = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.imWeckmodus, !self.hört else { return }
                        self.starteAufnahme(weckmodus: true)
                    }
                }
            } else {
                hinweis = ""
                hört = true
                welle = Array(repeating: 0, count: 42)
                uhrStellen(wartezeitVorSprache)
            }

            aufgabe = erkenner.recognitionTask(with: neu) { [weak self] ergebnis, fehler in
                Task { @MainActor in
                    guard let self else { return }
                    if let ergebnis {
                        self.verarbeiteErkennung(ergebnis.bestTranscription.formattedString,
                                                 endgültig: ergebnis.isFinal,
                                                 weckmodus: weckmodus)
                        return
                    }
                    if fehler != nil {
                        if weckmodus {
                            // Im Weckmodus einfach still wieder ansetzen.
                            if self.imWeckmodus && !self.hört {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                    if self.imWeckmodus && !self.hört {
                                        self.starteAufnahme(weckmodus: true)
                                    }
                                }
                            }
                        } else {
                            if !self.hatGesprochen {
                                self.hinweis = "Ich habe nichts verstanden. Tipp es gern ein."
                            }
                            self.abschließen()
                        }
                    }
                }
            }
        } catch {
            if !weckmodus { hinweis = "Das Mikrofon lässt sich nicht öffnen." }
            aufräumen()
        }
    }

    private func verarbeiteErkennung(_ text: String, endgültig: Bool, weckmodus: Bool) {
        if weckmodus {
            guard let rest = weckwortGefunden(in: text) else { return }
            imWeckmodus = false
            lauscht = false
            aufräumen()
            beiWeckwort?()
            if rest.count > 3 {
                // Der Befehl kam gleich mit — nicht noch mal nachfragen.
                beiSatz?(rest)
            } else {
                zuhören()
            }
            return
        }

        guard hört else { return }
        if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            mitschrift = text
            hatGesprochen = true
            uhrStellen(stilleNachSprache)
        }
        if endgültig { abschließen() }
    }

    private func uhrStellen(_ sekunden: TimeInterval) {
        uhr?.invalidate()
        uhr = Timer.scheduledTimer(withTimeInterval: sekunden, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.abschließen() }
        }
    }

    private func abschließen() {
        guard hört else { return }
        let text = mitschrift.trimmingCharacters(in: .whitespacesAndNewlines)
        zuhörenBeenden()
        if !text.isEmpty { beiSatz?(text) }
    }

    func zuhörenBeenden() {
        guard hört || motor.isRunning else { return }
        aufräumen()
        // Wenn das Weckwort an ist, sofort wieder lauschen.
        if weckwortAn && !spricht {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.lauschenStarten()
            }
        }
    }

    private func aufräumen() {
        uhr?.invalidate(); uhr = nil
        neustartUhr?.invalidate(); neustartUhr = nil
        anfrage?.endAudio()
        aufgabe?.finish()
        aufgabe = nil
        anfrage = nil
        if motor.isRunning { motor.stop() }
        motor.inputNode.removeTap(onBus: 0)
        hört = false
        lauscht = false
        pegel = 0
    }

    // MARK: - Reden

    func rede(_ text: String) {
        // Beim Reden darf das Weckwort nicht mithören, sonst hört er sich selbst.
        lauschenBeenden()

        let sitzung = AVAudioSession.sharedInstance()
        try? sitzung.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? sitzung.setActive(true)

        let äußerung = AVSpeechUtterance(string: text)
        äußerung.voice = besteStimme()
        äußerung.rate = Float(tempo)
        äußerung.pitchMultiplier = Float(tonhöhe)
        äußerung.postUtteranceDelay = 0.08
        äußerung.preUtteranceDelay = 0.05

        spricht = true
        sprecher.speak(äußerung)
    }

    func redenAbbrechen() {
        if sprecher.isSpeaking { sprecher.stopSpeaking(at: .immediate) }
        spricht = false
    }

    /// Nach dem Sprechen: Weckwort wieder scharf stellen.
    private func nachDemReden() {
        spricht = false
        if weckwortAn {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.lauschenStarten()
            }
        }
    }
}

extension Stimme: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString r: NSRange,
                                       utterance u: AVSpeechUtterance) {
        Task { @MainActor in self.takt &+= 1 }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.nachDemReden() }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.spricht = false }
    }
}
