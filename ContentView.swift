import SwiftUI
import Combine
import UIKit

// MARK: - Kleine Helfer

enum Haptik {
    static func tipp() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func stoß() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func gut()  { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func böse() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

/// Welches Fenster gerade offen ist. Immer nur eines, und nie länger als nötig.
enum Fenster: Identifiable, Equatable {
    case text, gehirn, einstellungen, zugang, datei, kamera
    var id: String { String(describing: self) }
}

// MARK: - Der Kopf

@MainActor
final class Kopf: ObservableObject {

    @Published var laune: Laune = .start
    @Published var sprecherName = ""
    @Published var untertitel = ""
    @Published var beschäftigt = false
    @Published var fenster: Fenster?
    @Published var anhangName = ""
    @Published var gesprächsmodus = UserDefaults.standard.bool(forKey: "gespraech")

    let stimme = Stimme()
    let gehirn = Gehirn()
    let werkzeuge = Werkzeuge()
    private let ki = KI()
    private var weiterleitungen: [AnyCancellable] = []
    private var anhang: String?

    private var schlüssel: String? { Tresor.lies("apikey") }
    var anbieter: Anbieter {
        Anbieter.mit(id: UserDefaults.standard.string(forKey: "anbieter") ?? "groq")
    }
    var modell: String { UserDefaults.standard.string(forKey: "modell") ?? "" }
    var eingerichtet: Bool { schlüssel != nil && !modell.isEmpty }

    init() {
        werkzeuge.gehirn = gehirn
        ki.gehirn = gehirn
        ki.werkzeuge = werkzeuge

        ki.beiWerkzeug = { [weak self] name in
            guard let self else { return }
            laune = .arbeitet
            zeige("BUDDY", Werkzeuge.anzeige(für: name) + "…")
        }
        werkzeuge.beiDateiWunsch = { [weak self] in self?.fenster = .datei }
        werkzeuge.beiFotoWunsch  = { [weak self] in self?.fenster = .kamera }

        stimme.beiSatz = { [weak self] text in
            Task { await self?.verarbeite(text) }
        }
        stimme.beiWeckwort = { [weak self] in
            Haptik.stoß()
            self?.laune = .neugier
            self?.zeige("", "Ja?")
        }

        for teil in [stimme.objectWillChange.eraseToAnyPublisher(),
                     gehirn.objectWillChange.eraseToAnyPublisher(),
                     werkzeuge.objectWillChange.eraseToAnyPublisher()] {
            weiterleitungen.append(teil.sink { [weak self] _ in self?.objectWillChange.send() })
        }

        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            if laune == .start { laune = .ruhe }
            if !eingerichtet { fenster = .zugang }
            else { zeige("", stimme.weckwortAn ? "Sag einfach Buddy." : "Tipp mich an.") }
        }
    }

    func zeige(_ wer: String, _ text: String) {
        sprecherName = wer
        untertitel = text
    }

    // MARK: Befehle, die BUDDY selbst abfängt

    private func istZugangsBefehl(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "ä", with: "a")
        let sache = ["api key", "apikey", "schlussel", "zugang", "anbieter"]
        let tat = ["ander", "andre", "wechsel", "wechsle", "tausch", "erneuer",
                   "zurucksetz", "reset", "neuer", "neue"]
        return sache.contains(where: t.contains) && tat.contains(where: t.contains)
    }

    // MARK: Zuhören

    func mikroDrücken() async {
        Haptik.tipp()
        if stimme.hört { stimme.zuhörenBeenden(); laune = .ruhe; return }
        if beschäftigt { stimme.redenAbbrechen(); beschäftigt = false; laune = .ruhe; return }

        guard await stimme.erlaubnisHolen() else {
            laune = .fehler
            zeige("BUDDY", stimme.hinweis)
            return
        }
        untertitel = ""
        sprecherName = ""
        laune = .hört
        stimme.zuhören()
        if !stimme.hört, !stimme.hinweis.isEmpty {
            laune = .fehler
            zeige("BUDDY", stimme.hinweis)
        }
    }

    // MARK: Dateien

    func dateiGewählt(_ url: URL?) {
        fenster = nil
        guard let url else { return }
        Task {
            laune = .arbeitet
            zeige("BUDDY", "liest \(url.lastPathComponent)…")
            let ergebnis = await Leser.lies(url)
            anhang = ergebnis.text
            anhangName = ergebnis.name
            await verarbeite("Schau dir \(ergebnis.name) an und fasse zusammen, "
                             + "was drin steht und was mir daran wichtig sein sollte.")
        }
    }

    func fotoGewählt(_ bild: UIImage?) {
        fenster = nil
        guard let bild else { return }
        Task {
            laune = .arbeitet
            zeige("BUDDY", "sieht sich das Bild an…")
            let ergebnis = await Leser.lies(bild: bild)
            anhang = ergebnis.text
            anhangName = "Foto"
            await verarbeite("Was ist auf dem Bild zu sehen und was steht darauf?")
        }
    }

    // MARK: Ablauf

    func verarbeite(_ eingabe: String) async {
        let text = eingabe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !beschäftigt else { return }

        if istZugangsBefehl(text) {
            laune = .freut
            zeige("BUDDY", "Klar. Neuer Zugang.")
            stimme.rede("Klar. Gib mir den neuen Zugang.")
            fenster = .zugang
            return
        }

        guard let schlüssel, !modell.isEmpty else { fenster = .zugang; return }

        beschäftigt = true
        laune = .denkt
        zeige("Du", text)

        let mitgabe = anhang
        anhang = nil

        do {
            let antwort = try await ki.frage(text, anbieter: anbieter, schlüssel: schlüssel,
                                             modell: modell, anhang: mitgabe)
            anhangName = ""
            gehirn.zähleGespräch()
            zeige("BUDDY", antwort)
            laune = .redet
            stimme.rede(antwort)

            // Im Hintergrund merken, was dauerhaft ist.
            let derAnbieter = anbieter
            let dasModell = modell
            Task { [ki] in
                await ki.lerne(frage: text, antwort: antwort, anbieter: derAnbieter,
                               schlüssel: schlüssel, modell: dasModell)
            }

            while stimme.spricht { try? await Task.sleep(nanoseconds: 120_000_000) }
            laune = .ruhe
            beschäftigt = false

            if gesprächsmodus && !stimme.weckwortAn {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if !beschäftigt && !stimme.hört { await mikroDrücken() }
            }
            return
        } catch {
            let fehler = (error as? KIFehler) ?? .sonstiges(error.localizedDescription)
            Haptik.böse()
            anhangName = ""
            laune = .fehler
            zeige("BUDDY", fehler.errorDescription ?? "Unbekannter Fehler.")
            stimme.rede(fehler.gesprochen)
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if laune == .fehler { laune = .ruhe }
        }
        beschäftigt = false
    }

    // MARK: Zugang

    func verbinden(anbieter: Anbieter, schlüssel: String) async -> String? {
        let k = schlüssel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return "Da steht noch nichts." }
        do {
            let gefunden = try await ki.modellSuchen(anbieter: anbieter, schlüssel: k)
            Tresor.schreib("apikey", k)
            UserDefaults.standard.set(anbieter.id, forKey: "anbieter")
            UserDefaults.standard.set(gefunden, forKey: "modell")
            Haptik.gut()
            fenster = nil
            laune = .freut
            zeige("BUDDY", "Verbunden über \(anbieter.name), Modell \(gefunden).")
            stimme.rede("Verbunden. Sag einfach Buddy, wenn du etwas brauchst.")
            Task {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                if laune == .freut { laune = .ruhe }
            }
            return nil
        } catch let fehler as KIFehler {
            if case .schlüsselUngültig = fehler {
                return "\(anbieter.name) akzeptiert diesen Schlüssel nicht."
            }
            return fehler.errorDescription
        } catch {
            return error.localizedDescription
        }
    }

    func allesVergessen() {
        gehirn.leeren()
        ki.verlaufLeeren()
        zeige("BUDDY", "Gedächtnis und Verlauf geleert.")
    }

    func verlaufLeeren() {
        ki.verlaufLeeren()
        zeige("BUDDY", "Der Gesprächsfaden ist neu.")
    }
}

// MARK: - Hauptbildschirm

struct ContentView: View {
    @StateObject private var kopf = Kopf()
    @State private var hinweisSichtbar = true

    var body: some View {
        ZStack {
            Color.leere.ignoresSafeArea()
            aura
            Staubkörner(aktiv: kopf.laune == .ruhe || kopf.laune == .hört)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                Gesicht(laune: kopf.laune, takt: kopf.stimme.takt, pegel: kopf.stimme.pegel)

                if kopf.stimme.hört {
                    Wellenform(werte: kopf.stimme.welle)
                        .frame(height: 42)
                        .padding(.horizontal, 44)
                        .padding(.top, 22)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                Spacer(minLength: 0)
                untertitelFeld
                fußzeile
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: kopf.stimme.hört)

            // Ein Fingertipp irgendwo startet das Zuhören.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { Task { await kopf.mikroDrücken() } }
                .gesture(wischen)
                .allowsHitTesting(kopf.fenster == nil)

            if let fenster = kopf.fenster, fenster != .datei, fenster != .kamera {
                Glasfenster(schließen: { schließe() }) { inhalt(für: fenster) }
                    .zIndex(10)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { kopf.fenster == .datei },
            set: { if !$0 { kopf.fenster = nil } })) {
            DateiWähler { url in kopf.dateiGewählt(url) }
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: Binding(
            get: { kopf.fenster == .kamera },
            set: { if !$0 { kopf.fenster = nil } })) {
            Kamera { bild in kopf.fotoGewählt(bild) }
                .ignoresSafeArea()
        }
    }

    // MARK: Gesten — die ganze Bedienung, ohne einen einzigen Knopf

    private var wischen: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { zug in
                guard kopf.fenster == nil else { return }
                let hoch = zug.translation.height < -50
                let runter = zug.translation.height > 50
                let seitlich = abs(zug.translation.width) > abs(zug.translation.height)

                Haptik.stoß()
                if seitlich { kopf.fenster = .einstellungen }
                else if hoch { kopf.fenster = .text }
                else if runter { kopf.fenster = .gehirn }
            }
    }

    private func schließe() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { kopf.fenster = nil }
    }

    @ViewBuilder
    private func inhalt(für fenster: Fenster) -> some View {
        switch fenster {
        case .text:          TextFenster(kopf: kopf, schließen: schließe)
        case .gehirn:        GehirnFenster(kopf: kopf)
        case .einstellungen: EinstellungFenster(kopf: kopf)
        case .zugang:        Einrichtung(kopf: kopf)
        default:             EmptyView()
        }
    }

    // MARK: Kulisse

    private var aura: some View {
        RadialGradient(colors: [scheinFarbe.opacity(kopf.laune == .hört ? 0.26 : 0.16), .clear],
                       center: .init(x: 0.5, y: 0.44),
                       startRadius: 10, endRadius: 420)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: kopf.laune)
    }

    private var scheinFarbe: Color {
        switch kopf.laune {
        case .denkt:    return .bernstein
        case .arbeitet: return .minze
        case .fehler:   return .glut
        default:        return .iris
        }
    }

    private var untertitelFeld: some View {
        ScrollView {
            VStack(spacing: 6) {
                if !kopf.sprecherName.isEmpty {
                    Text(kopf.sprecherName)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.24))
                        .textCase(.uppercase)
                        .tracking(1.1)
                }
                if !kopf.anhangName.isEmpty {
                    Label(kopf.anhangName, systemImage: "paperclip")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Color.minze.opacity(0.8))
                }
                Text(kopf.stimme.hört && !kopf.stimme.mitschrift.isEmpty
                     ? kopf.stimme.mitschrift : kopf.untertitel)
                    .font(.system(size: 16, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.64))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 32)
        }
        .frame(maxHeight: 200)
        .animation(.easeInOut(duration: 0.22), value: kopf.untertitel)
    }

    /// Die einzige bleibende Anzeige: ein Punkt, wenn das Weckwort scharf ist,
    /// und beim ersten Start ein kurzer Hinweis auf die Wischgesten.
    private var fußzeile: some View {
        VStack(spacing: 10) {
            if hinweisSichtbar {
                Text("hoch tippen · runter Gedächtnis · seitwärts Einstellungen")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.18))
                    .transition(.opacity)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(kopf.stimme.lauscht ? Color.iris : Color.white.opacity(0.12))
                    .frame(width: 5, height: 5)
                if kopf.stimme.lauscht {
                    Text("hört auf Buddy")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Color.iris.opacity(0.5))
                }
            }
            .animation(.easeInOut(duration: 0.4), value: kopf.stimme.lauscht)
        }
        .padding(.bottom, 16)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                withAnimation(.easeOut(duration: 1.2)) { hinweisSichtbar = false }
            }
        }
    }
}

// MARK: - Wellenform

struct Wellenform: View {
    let werte: [Double]

    var body: some View {
        GeometryReader { raum in
            let breite = raum.size.width / CGFloat(max(1, werte.count))
            let mitte = raum.size.height / 2
            HStack(alignment: .center, spacing: breite * 0.32) {
                ForEach(Array(werte.enumerated()), id: \.offset) { stelle, wert in
                    // Zur Mitte hin höher — sieht lebendiger aus als eine flache Reihe.
                    let form = sin(Double(stelle) / Double(werte.count) * .pi)
                    let höhe = max(3, wert * Double(mitte) * 1.9 * (0.35 + form * 0.65))
                    Capsule()
                        .fill(LinearGradient(colors: [.irisHell, .iris],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: breite * 0.68, height: höhe)
                        .opacity(0.35 + wert * 0.65)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.09), value: werte)
        }
        .shadow(color: Color.iris.opacity(0.4), radius: 12)
    }
}

// MARK: - Staubkörner

/// Langsam treibende Lichtpunkte. Nur Kulisse, aber der Raum wirkt dadurch tief.
struct Staubkörner: View {
    let aktiv: Bool

    private struct Korn: Identifiable {
        let id = UUID()
        let x: Double, y: Double, größe: Double, tempo: Double, phase: Double
    }

    private let körner: [Korn] = (0..<26).map { _ in
        Korn(x: .random(in: 0...1), y: .random(in: 0...1),
             größe: .random(in: 1.2...3.0), tempo: .random(in: 0.06...0.22),
             phase: .random(in: 0...6.28))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { schlag in
            let zeit = schlag.date.timeIntervalSince1970
            Canvas { flaeche, größe in
                for korn in körner {
                    let y = (korn.y - zeit * korn.tempo * 0.05)
                        .truncatingRemainder(dividingBy: 1)
                    let echtY = (y < 0 ? y + 1 : y) * größe.height
                    let echtX = korn.x * größe.width
                        + sin(zeit * korn.tempo + korn.phase) * 14
                    let helligkeit = 0.10 + 0.16 * (sin(zeit * 0.7 + korn.phase) + 1) / 2

                    flaeche.fill(
                        Path(ellipseIn: CGRect(x: echtX, y: echtY,
                                               width: korn.größe, height: korn.größe)),
                        with: .color(Color.iris.opacity(helligkeit))
                    )
                }
            }
        }
        .ignoresSafeArea()
        .opacity(aktiv ? 1 : 0.25)
        .animation(.easeInOut(duration: 1.2), value: aktiv)
        .allowsHitTesting(false)
    }
}

// MARK: - Das Fenster

/// Milchglas-Fläche, die von unten hereinfährt und beim Antippen daneben
/// wieder verschwindet. Alle Fenster von BUDDY sehen so aus.
struct Glasfenster<Inhalt: View>: View {
    private let schließen: () -> Void
    private let inhalt: Inhalt
    @State private var da = false

    init(schließen: @escaping () -> Void, @ViewBuilder inhalt: () -> Inhalt) {
        self.schließen = schließen
        self.inhalt = inhalt()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(da ? 0.55 : 0)
                .ignoresSafeArea()
                .onTapGesture { schließen() }

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 38, height: 4)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                inhalt
            }
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in:
                RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(LinearGradient(colors: [Color.iris.opacity(0.45), .clear],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1)
            )
            .shadow(color: Color.iris.opacity(0.22), radius: 34, y: -6)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .offset(y: da ? 0 : 700)
            .gesture(
                DragGesture().onEnded { zug in
                    if zug.translation.height > 90 { schließen() }
                }
            )
        }
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { da = true }
        }
    }
}

// MARK: - Fenster: Text

struct TextFenster: View {
    @ObservedObject var kopf: Kopf
    let schließen: () -> Void
    @State private var eingabe = ""
    @FocusState private var fokus: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                TextField("Schreib mir…", text: $eingabe, axis: .vertical)
                    .font(.system(size: 16, design: .rounded))
                    .lineLimit(1...5)
                    .focused($fokus)
                    .submitLabel(.send)
                    .onSubmit(senden)

                Button(action: senden) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(eingabe.isEmpty ? Color.white.opacity(0.2) : Color.iris)
                }
                .disabled(eingabe.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack(spacing: 10) {
                knopf("Datei", "doc.text") { kopf.fenster = .datei }
                knopf("Kamera", "camera") { kopf.fenster = .kamera }
            }
        }
        .padding(20)
        .padding(.bottom, 6)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { fokus = true } }
    }

    private func knopf(_ titel: String, _ zeichen: String,
                       _ tat: @escaping () -> Void) -> some View {
        Button {
            Haptik.tipp()
            tat()
        } label: {
            Label(titel, systemImage: zeichen)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.07), in: Capsule())
        }
    }

    private func senden() {
        let text = eingabe.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        eingabe = ""
        fokus = false
        schließen()
        Task { await kopf.verarbeite(text) }
    }
}

// MARK: - Fenster: Gedächtnis

struct GehirnFenster: View {
    @ObservedObject var kopf: Kopf
    @State private var neuerFakt = ""
    @State private var fragtNach = false

    struct Gruppe: Identifiable {
        let bereich: Bereich
        let neuronen: [Neuron]
        var id: Bereich { bereich }
    }

    private var gruppiert: [Gruppe] {
        Dictionary(grouping: kopf.gehirn.neuronen, by: \.bereich)
            .sorted { $0.value.count > $1.value.count }
            .map { Gruppe(bereich: $0.key, neuronen: $0.value.sorted { $0.stärke > $1.stärke }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Gedächtnis")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                Spacer()
                Text("\(kopf.gehirn.neuronen.count) Fakten · \(kopf.gehirn.gespräche) Gespräche")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            HStack(spacing: 8) {
                TextField("Selbst etwas merken…", text: $neuerFakt)
                    .font(.system(size: 15, design: .rounded))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.white.opacity(0.07), in: Capsule())
                    .onSubmit(fügeHinzu)
                Button(action: fügeHinzu) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 25))
                }
                .disabled(neuerFakt.trimmingCharacters(in: .whitespaces).count < 4)
            }
            .padding(.horizontal, 20)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if kopf.gehirn.neuronen.isEmpty {
                        Text("Noch nichts gespeichert. Erzähl mir etwas über dich — "
                             + "ich lege es von selbst ab.")
                            .font(.system(size: 15, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                    }
                    ForEach(gruppiert) { gruppe in
                        VStack(alignment: .leading, spacing: 7) {
                            Label(gruppe.bereich.titel, systemImage: gruppe.bereich.zeichen)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.iris.opacity(0.7))

                            ForEach(gruppe.neuronen) { neuron in
                                HStack(alignment: .top, spacing: 9) {
                                    Circle()
                                        .fill(Color.iris.opacity(0.2 + neuron.stärke * 0.26))
                                        .frame(width: 6, height: 6)
                                        .padding(.top, 6)
                                    Text(neuron.fakt)
                                        .font(.system(size: 15, design: .rounded))
                                        .foregroundStyle(Color.white.opacity(0.82))
                                    Spacer(minLength: 4)
                                    Button {
                                        Haptik.tipp()
                                        kopf.gehirn.vergessen(neuron)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(Color.white.opacity(0.22))
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .frame(maxHeight: 380)

            Button("Alles vergessen", role: .destructive) { fragtNach = true }
                .font(.system(size: 14, design: .rounded))
                .padding(.bottom, 18)
        }
        .confirmationDialog("Wirklich alles vergessen?", isPresented: $fragtNach,
                            titleVisibility: .visible) {
            Button("Gedächtnis und Verlauf löschen", role: .destructive) {
                kopf.allesVergessen()
            }
        }
    }

    private func fügeHinzu() {
        let text = neuerFakt.trimmingCharacters(in: .whitespaces)
        guard text.count > 3 else { return }
        kopf.gehirn.merken(text, bereich: .sonstiges)
        neuerFakt = ""
        Haptik.gut()
    }
}

// MARK: - Fenster: Einstellungen

struct EinstellungFenster: View {
    @ObservedObject var kopf: Kopf
    @AppStorage("rolle") private var rolle = "kumpel"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Einstellungen")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))

                schalter("Auf „Buddy" hören", "Lauscht dauerhaft im Hintergrund. Kostet Akku.",
                         an: Binding(get: { kopf.stimme.weckwortAn },
                                     set: { kopf.stimme.weckwortAn = $0 }))

                schalter("Gesprächsmodus", "Hört nach jeder Antwort von selbst wieder zu.",
                         an: Binding(get: { kopf.gesprächsmodus },
                                     set: {
                                         kopf.gesprächsmodus = $0
                                         UserDefaults.standard.set($0, forKey: "gespraech")
                                     }))

                schalter("Werkzeuge benutzen", "Wetter, Kurse, Kalender, Gerätesteuerung.",
                         an: Binding(get: { !kopf.werkzeuge.abgeschaltet },
                                     set: { kopf.werkzeuge.abgeschaltet = !$0 }))

                überschrift("Stimme")
                if !kopf.stimme.hatGuteStimme {
                    hinweisfeld("Für eine natürliche Stimme: Einstellungen, Bedienungshilfen, "
                                + "Gesprochene Inhalte, Stimmen, Deutsch — dort eine Premium-Stimme "
                                + "laden. Danach hier auswählen.")
                }
                stimmenWahl

                regler("Tonhöhe", wert: Binding(get: { kopf.stimme.tonhöhe },
                                                set: { kopf.stimme.tonhöhe = $0 }),
                       von: 0.7, bis: 1.6)
                regler("Tempo", wert: Binding(get: { kopf.stimme.tempo },
                                              set: { kopf.stimme.tempo = $0 }),
                       von: 0.38, bis: 0.66)

                Button {
                    Haptik.tipp()
                    kopf.stimme.rede("Hey, ich bin Buddy. So klinge ich.")
                } label: {
                    Label("Anhören", systemImage: "play.circle.fill")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.iris.opacity(0.16), in: Capsule())
                }

                überschrift("Persönlichkeit")
                rollenWahl

                überschrift("Zugang")
                HStack {
                    Text(kopf.anbieter.name + " · " + (kopf.modell.isEmpty ? "—" : kopf.modell))
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Wechseln") { kopf.fenster = .zugang }
                        .font(.system(size: 14, design: .rounded))
                }

                Button("Nur den Gesprächsfaden löschen") { kopf.verlaufLeeren() }
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .padding(20)
            .padding(.bottom, 10)
        }
        .frame(maxHeight: 560)
    }

    private func überschrift(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.iris.opacity(0.7))
            .textCase(.uppercase)
            .tracking(1)
            .padding(.top, 4)
    }

    private func hinweisfeld(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(Color.bernstein.opacity(0.85))
            .padding(12)
            .background(Color.bernstein.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func schalter(_ titel: String, _ unten: String, an: Binding<Bool>) -> some View {
        Toggle(isOn: an) {
            VStack(alignment: .leading, spacing: 2) {
                Text(titel).font(.system(size: 15, weight: .medium, design: .rounded))
                Text(unten).font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .tint(Color.iris)
    }

    private func regler(_ titel: String, wert: Binding<Double>,
                        von: Double, bis: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titel).font(.system(size: 13, design: .rounded))
                .foregroundStyle(.secondary)
            Slider(value: wert, in: von...bis).tint(Color.iris)
        }
    }

    private var stimmenWahl: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(kopf.stimme.stimmenAuswahl) { wahl in
                    let gewählt = kopf.stimme.stimmenId == wahl.id
                    Button {
                        Haptik.tipp()
                        kopf.stimme.stimmenId = wahl.id
                    } label: {
                        VStack(spacing: 1) {
                            Text(wahl.name)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                            Text(wahl.güte)
                                .font(.system(size: 10, design: .rounded))
                                .opacity(0.6)
                        }
                        .foregroundStyle(gewählt ? Color.leere : Color.white.opacity(0.65))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Capsule().fill(gewählt ? Color.iris
                                                           : Color.white.opacity(0.07)))
                    }
                }
            }
        }
    }

    private var rollenWahl: some View {
        HStack(spacing: 7) {
            ForEach(KI.rollen, id: \.id) { eintrag in
                Button {
                    Haptik.tipp()
                    rolle = eintrag.id
                } label: {
                    Text(eintrag.name)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(rolle == eintrag.id ? Color.leere
                                                             : Color.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(rolle == eintrag.id ? Color.iris : Color.white.opacity(0.07)))
                }
            }
        }
    }
}

// MARK: - Fenster: Zugang

struct Einrichtung: View {
    @ObservedObject var kopf: Kopf
    @State private var gewählt: Anbieter = .alle[0]
    @State private var eingabe = ""
    @State private var hinweis = ""
    @State private var fehlerhaft = false
    @State private var prüft = false
    @FocusState private var fokus: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(kopf.eingerichtet ? "Neuer Zugang." : "Hallo. Ich brauche einen Zugang.")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))

                Text("Alle vier sind kostenlos und brauchen keine Kreditkarte. "
                     + "Groq ist am schnellsten.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)

                HStack(spacing: 7) {
                    ForEach(Anbieter.alle) { a in
                        Button {
                            Haptik.tipp()
                            gewählt = a
                        } label: {
                            Text(a.name)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(gewählt.id == a.id ? Color.leere
                                                                    : Color.white.opacity(0.6))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(gewählt.id == a.id ? Color.iris
                                                             : Color.white.opacity(0.07)))
                        }
                    }
                }

                Text("Schlüssel holen bei \(gewählt.wo)")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color.iris.opacity(0.75))

                TextField(gewählt.schlüsselHinweis, text: $eingabe)
                    .font(.system(size: 15, design: .monospaced))
                    .focused($fokus)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(14)
                    .background(Color.white.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .onSubmit(prüfen)

                Button(action: prüfen) {
                    Text(prüft ? "Prüfe…" : "Verbinden")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.leere)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.iris,
                                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .disabled(prüft)
                .opacity(prüft ? 0.5 : 1)

                Text(hinweis)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(fehlerhaft ? Color.glut : Color.white.opacity(0.4))
                    .frame(minHeight: 30, alignment: .topLeading)
            }
            .padding(20)
        }
        .frame(maxHeight: 520)
        .onAppear {
            gewählt = kopf.anbieter
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { fokus = true }
        }
    }

    private func prüfen() {
        prüft = true
        hinweis = "Frage \(gewählt.name) nach den Modellen…"
        fehlerhaft = false
        Task {
            if let problem = await kopf.verbinden(anbieter: gewählt, schlüssel: eingabe) {
                hinweis = problem
                fehlerhaft = true
            }
            prüft = false
        }
    }
}
