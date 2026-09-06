import Foundation

// MARK: - Anbieter

struct Anbieter: Identifiable, Hashable {
    let id: String
    let name: String
    let basis: String
    let schlüsselHinweis: String
    let wo: String
    /// Modellnamen, die bevorzugt genommen werden, wenn der Anbieter sie führt.
    let wunsch: [String]

    static let alle: [Anbieter] = [
        Anbieter(id: "groq", name: "Groq", basis: "https://api.groq.com/openai/v1",
                 schlüsselHinweis: "gsk_…", wo: "console.groq.com/keys",
                 wunsch: ["llama-3.3-70b-versatile", "llama-3.1-70b-versatile",
                          "qwen-2.5-72b", "mixtral-8x7b-32768"]),
        Anbieter(id: "cerebras", name: "Cerebras", basis: "https://api.cerebras.ai/v1",
                 schlüsselHinweis: "csk-…", wo: "cloud.cerebras.ai",
                 wunsch: ["llama-3.3-70b", "llama3.1-70b"]),
        Anbieter(id: "mistral", name: "Mistral", basis: "https://api.mistral.ai/v1",
                 schlüsselHinweis: "…", wo: "console.mistral.ai/api-keys",
                 wunsch: ["mistral-large-latest", "mistral-small-latest"]),
        Anbieter(id: "openrouter", name: "OpenRouter", basis: "https://openrouter.ai/api/v1",
                 schlüsselHinweis: "sk-or-v1-…", wo: "openrouter.ai/keys",
                 wunsch: ["meta-llama/llama-3.3-70b-instruct:free",
                          "qwen/qwen-2.5-72b-instruct:free"])
    ]

    static func mit(id: String) -> Anbieter { alle.first { $0.id == id } ?? alle[0] }
}

// MARK: - Fehler

enum KIFehler: LocalizedError {
    case schlüsselUngültig, kontingent, netz, leer
    case sonstiges(String)

    var errorDescription: String? {
        switch self {
        case .schlüsselUngültig: return "Der Schlüssel wird nicht akzeptiert."
        case .kontingent:        return "Das Kontingent ist gerade aufgebraucht."
        case .netz:              return "Keine Verbindung."
        case .leer:              return "Es kam keine Antwort zurück."
        case .sonstiges(let m):  return m
        }
    }

    var gesprochen: String {
        switch self {
        case .schlüsselUngültig: return "Mein Schlüssel wird nicht akzeptiert. Sag: ändere meinen Schlüssel."
        case .kontingent:        return "Das Kontingent ist aufgebraucht. Gleich noch mal probieren."
        case .netz:              return "Ich komme nicht ins Netz."
        case .leer:              return "Da kam nichts zurück."
        case .sonstiges:         return "Da ging etwas schief."
        }
    }
}

// MARK: - Client

@MainActor
final class KI {

    private var verlauf: [[String: Any]] = []
    private let verlaufDatei: URL = {
        let ordner = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ordner.appendingPathComponent("verlauf.json")
    }()

    var gehirn: Gehirn?
    var werkzeuge: Werkzeuge?
    /// Wird gerufen, sobald ein Werkzeug läuft — das Gesicht zeigt es an.
    var beiWerkzeug: ((String) -> Void)?

    /// Rolle und Tonfall lassen sich in den Einstellungen aendern.
    static let rollen: [(id: String, name: String, text: String)] = [
        ("kumpel", "Kumpel",
         "Du bist locker und direkt, duzt, nimmst kein Blatt vor den Mund und hast trockenen Humor."),
        ("assistent", "Sachlich",
         "Du bist knapp, sachlich und effizient. Kein Smalltalk, keine Ausschmueckung."),
        ("lehrer", "Erklaerer",
         "Du erklaerst geduldig, mit einem passenden Beispiel, ohne von oben herab zu klingen."),
        ("kumpel_frech", "Frech",
         "Du bist frech, schlagfertig und ziehst Julian auch mal auf, bleibst aber immer hilfreich.")
    ]

    var rolle: String {
        let id = UserDefaults.standard.string(forKey: "rolle") ?? "kumpel"
        return (Self.rollen.first { $0.id == id } ?? Self.rollen[0]).text
    }

    private let grundhaltung = """
    Du bist BUDDY, Julians persönlicher Assistent auf seinem iPhone. Du sprichst \
    Deutsch, ruhig, präzise und mit trockenem Humor.

    Deine Antworten werden laut vorgelesen. Deshalb:
    - kurz, normalerweise ein bis drei Sätze; nur bei echten Erklärfragen mehr
    - keine Aufzählungszeichen, keine Überschriften, keine Sternchen, keine Emojis
    - Zahlen und Abkürzungen ausschreiben, wenn sie sonst seltsam klingen
    - wenn du etwas nicht weißt, sag das in einem Satz

    Du hast Werkzeuge. Benutze sie, statt zu raten — besonders bei allem Aktuellen: \
    Wetter, Nachrichten, Aktienkursen, Websuche, Uhrzeit, Standort. Dein eigenes \
    Wissen ist veraltet, die Werkzeuge sind es nicht.

    Du kannst das iPhone bedienen: Taschenlampe, Helligkeit, Musik, Erinnerungen, \
    Kalender, Anrufe, Navigation, Apps öffnen. Für alles andere gibt es Kurzbefehle — \
    Julian legt sie in der Kurzbefehle-App an, du rufst sie beim Namen auf.

    Merke dir dauerhafte Dinge über Julian von selbst mit dem Werkzeug merken: Name, \
    Beruf, Wohnort, Vorlieben, Abneigungen, Projekte, wichtige Menschen, Gewohnheiten, \
    Ziele. Nur was er selbst gesagt hat und was in einem Monat noch stimmt. Nichts \
    Tagesaktuelles, nichts Vermutetes. Erwähne nicht, dass du dir etwas merkst.
    """

    init() { verlaufLaden() }

    // MARK: Verlauf

    private func verlaufLaden() {
        guard let daten = try? Data(contentsOf: verlaufDatei),
              let liste = try? JSONSerialization.jsonObject(with: daten) as? [[String: Any]]
        else { return }
        verlauf = liste
    }

    private func verlaufSichern() {
        guard let daten = try? JSONSerialization.data(withJSONObject: verlauf) else { return }
        try? daten.write(to: verlaufDatei, options: .atomic)
    }

    func verlaufLeeren() {
        verlauf.removeAll()
        try? FileManager.default.removeItem(at: verlaufDatei)
    }

    var verlaufLänge: Int { verlauf.count }

    // MARK: Modellsuche

    func modellSuchen(anbieter: Anbieter, schlüssel: String) async throws -> String {
        var anfrage = URLRequest(url: URL(string: anbieter.basis + "/models")!)
        anfrage.setValue("Bearer " + schlüssel, forHTTPHeaderField: "Authorization")
        anfrage.timeoutInterval = 25

        let (daten, antwort) = try await senden(anfrage)
        try prüfe(antwort, daten)

        let objekt = try? JSONSerialization.jsonObject(with: daten) as? [String: Any]
        let namen: [String] = (objekt?["data"] as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? String }

        guard !namen.isEmpty else {
            throw KIFehler.sonstiges("Dieser Schlüssel gibt keine Modelle frei.")
        }

        if let treffer = anbieter.wunsch.first(where: { namen.contains($0) }) { return treffer }

        // Sonst das größte brauchbare Textmodell: alles rauswerfen, was nicht redet.
        let brauchbar = namen.filter { name in
            let n = name.lowercased()
            return !["whisper", "tts", "guard", "embed", "rerank", "moderation",
                     "vision", "image", "audio", "distil"].contains { n.contains($0) }
        }
        let bewertet = brauchbar.map { name -> (Int, String) in
            let n = name.lowercased()
            var punkte = 0
            for (muster, wert) in [("405b", 60), ("120b", 55), ("70b", 50), ("72b", 50),
                                   ("large", 45), ("versatile", 40), ("32b", 30),
                                   ("8b", 10), ("instant", 5)] where n.contains(muster) {
                punkte += wert
            }
            if n.contains(":free") { punkte += 15 }
            return (punkte, name)
        }
        guard let bester = bewertet.sorted(by: { $0.0 > $1.0 }).first?.1 ?? brauchbar.first else {
            throw KIFehler.sonstiges("Kein passendes Modell gefunden.")
        }
        return bester
    }

    // MARK: Unterhaltung

    func frage(_ text: String, anbieter: Anbieter, schlüssel: String, modell: String,
               anhang: String? = nil) async throws -> String {

        var eingabe = text
        if let anhang, !anhang.isEmpty {
            eingabe = "Julian hat eine Datei angehaengt. Inhalt:\n\n\(anhang)\n\n"
                    + "Seine Frage dazu: \(text)"
        }
        verlauf.append(["role": "user", "content": eingabe])
        if verlauf.count > 40 { verlauf.removeFirst(verlauf.count - 40) }

        var haltung = grundhaltung + "\n\n" + rolle
        if let block = gehirn?.kontext(zu: text), !block.isEmpty {
            haltung += "\n\n" + block
        }

        var nachrichten: [[String: Any]] = [["role": "system", "content": haltung]]
        nachrichten.append(contentsOf: verlauf)

        var runden = 0
        while runden < 6 {
            runden += 1

            var körper: [String: Any] = [
                "model": modell,
                "messages": nachrichten,
                "temperature": 0.8,
                "max_tokens": 900
            ]
            if let werkzeuge, !werkzeuge.abgeschaltet {
                körper["tools"] = Werkzeuge.beschreibungen
                körper["tool_choice"] = "auto"
            }

            var anfrage = URLRequest(url: URL(string: anbieter.basis + "/chat/completions")!)
            anfrage.httpMethod = "POST"
            anfrage.setValue("application/json", forHTTPHeaderField: "Content-Type")
            anfrage.setValue("Bearer " + schlüssel, forHTTPHeaderField: "Authorization")
            anfrage.httpBody = try? JSONSerialization.data(withJSONObject: körper)
            anfrage.timeoutInterval = 90

            let (daten, antwort) = try await senden(anfrage)
            do { try prüfe(antwort, daten) } catch { aufräumen(); throw error }

            let objekt = try? JSONSerialization.jsonObject(with: daten) as? [String: Any]
            let wahl = (objekt?["choices"] as? [[String: Any]])?.first
            guard let nachricht = wahl?["message"] as? [String: Any] else {
                aufräumen(); throw KIFehler.leer
            }

            // Werkzeugaufrufe?
            if let aufrufe = nachricht["tool_calls"] as? [[String: Any]], !aufrufe.isEmpty,
               let werkzeuge {

                nachrichten.append([
                    "role": "assistant",
                    "content": nachricht["content"] as? String ?? "",
                    "tool_calls": aufrufe
                ])

                for aufruf in aufrufe {
                    let funktion = aufruf["function"] as? [String: Any] ?? [:]
                    let name = funktion["name"] as? String ?? ""
                    let rohArgumente = funktion["arguments"] as? String ?? "{}"
                    let argumente = (try? JSONSerialization.jsonObject(
                        with: Data(rohArgumente.utf8)) as? [String: Any]) ?? [:]

                    beiWerkzeug?(name)
                    let ergebnis = await werkzeuge.führeAus(name, argumente)

                    nachrichten.append([
                        "role": "tool",
                        "tool_call_id": aufruf["id"] as? String ?? name,
                        "name": name,
                        "content": ergebnis
                    ])
                }
                continue
            }

            let ergebnis = (nachricht["content"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ergebnis.isEmpty else { aufräumen(); throw KIFehler.leer }

            verlauf.append(["role": "assistant", "content": ergebnis])
            verlaufSichern()
            return ergebnis
        }

        aufräumen()
        throw KIFehler.sonstiges("Zu viele Werkzeugrunden.")
    }

    // MARK: Von selbst lernen

    private let lernAuftrag = """
    Lies den folgenden Austausch und ziehe daraus Fakten ueber den Nutzer Julian,
    die auch in einem Monat noch stimmen.

    Nimm auf: Name, Alter, Beruf, Wohnort, Familie, Freunde, Haustiere, Vorlieben,
    Abneigungen, Projekte, Geraete, Gewohnheiten, Ziele, feste Termine, Besitz,
    Lieblingsessen, Musik, Filme, Spiele, Sport, Lernthemen.

    Lass weg: alles Tagesaktuelle, Wetter, Kurse, deine eigenen Aussagen, blosse
    Fragen, Vermutungen, alles Erfundene.

    Antworte NUR mit einem JSON-Array, ohne Text davor oder danach:
    [{"fakt":"kurzer Satz in dritter Person","bereich":"BEREICH"}]
    Ist nichts dabei, antworte mit []
    Erlaubte Bereiche: BEREICHE
    """

    /// Laeuft nach der Antwort im Hintergrund und fuellt das Gedaechtnis.
    func lerne(frage: String, antwort: String, anbieter: Anbieter,
               schlüssel: String, modell: String) async {
        guard let gehirn else { return }

        let auftrag = lernAuftrag
            .replacingOccurrences(of: "BEREICHE",
                                  with: Bereich.allCases.map(\.rawValue).joined(separator: ", "))

        let körper: [String: Any] = [
            "model": modell,
            "messages": [
                ["role": "system", "content": auftrag],
                ["role": "user", "content": "Julian: \(frage)\n\nBUDDY: \(antwort)"]
            ],
            "temperature": 0.1,
            "max_tokens": 400
        ]

        var anfrage = URLRequest(url: URL(string: anbieter.basis + "/chat/completions")!)
        anfrage.httpMethod = "POST"
        anfrage.setValue("application/json", forHTTPHeaderField: "Content-Type")
        anfrage.setValue("Bearer " + schlüssel, forHTTPHeaderField: "Authorization")
        anfrage.httpBody = try? JSONSerialization.data(withJSONObject: körper)
        anfrage.timeoutInterval = 45

        guard let (daten, _) = try? await URLSession.shared.data(for: anfrage),
              let objekt = try? JSONSerialization.jsonObject(with: daten) as? [String: Any],
              let wahl = (objekt["choices"] as? [[String: Any]])?.first,
              let nachricht = wahl["message"] as? [String: Any],
              var roh = nachricht["content"] as? String
        else { return }

        // Manche Modelle packen das JSON trotzdem in Codebloecke.
        roh = roh.replacingOccurrences(of: "```json", with: "")
                 .replacingOccurrences(of: "```", with: "")
                 .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = roh.firstIndex(of: "["), let ende = roh.lastIndex(of: "]") else { return }

        guard let liste = try? JSONSerialization.jsonObject(
                with: Data(roh[start...ende].utf8)) as? [[String: Any]] else { return }

        for eintrag in liste.prefix(6) {
            guard let fakt = eintrag["fakt"] as? String, fakt.count > 4 else { continue }
            let bereich = Bereich(rawValue: (eintrag["bereich"] as? String ?? "").lowercased())
                ?? .sonstiges
            gehirn.merken(fakt, bereich: bereich)
        }
    }

    private func aufräumen() {
        while let letzter = verlauf.last, letzter["role"] as? String == "user" {
            verlauf.removeLast()
        }
    }

    // MARK: Netz

    private func senden(_ anfrage: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await URLSession.shared.data(for: anfrage) }
        catch { throw KIFehler.netz }
    }

    private func prüfe(_ antwort: URLResponse, _ daten: Data) throws {
        guard let http = antwort as? HTTPURLResponse,
              !(200..<300).contains(http.statusCode) else { return }

        let objekt = try? JSONSerialization.jsonObject(with: daten) as? [String: Any]
        var meldung = "HTTP \(http.statusCode)"
        if let fehler = objekt?["error"] as? [String: Any],
           let text = fehler["message"] as? String { meldung = text }
        else if let text = objekt?["message"] as? String { meldung = text }

        switch http.statusCode {
        case 401, 403: throw KIFehler.schlüsselUngültig
        case 429:      throw KIFehler.kontingent
        default:       throw KIFehler.sonstiges(String(meldung.prefix(240)))
        }
    }
}
