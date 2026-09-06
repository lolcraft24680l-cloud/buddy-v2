import Foundation
import CoreLocation
import AVFoundation
import MediaPlayer
import EventKit
import UIKit

/// Alles, was BUDDY jenseits des Redens tun kann.
/// Das Modell entscheidet per Werkzeugaufruf, was es braucht.
@MainActor
final class Werkzeuge: NSObject, ObservableObject, CLLocationManagerDelegate {

    /// Notschalter, falls ein Modell mit Werkzeugen nicht zurechtkommt.
    @Published var abgeschaltet = false
    /// Für die Anzeige: was gerade läuft.
    @Published var läuft = ""

    private let ort = CLLocationManager()
    private var ortWartend: [CheckedContinuation<CLLocation?, Never>] = []
    private let kalender = EKEventStore()
    weak var gehirn: Gehirn?
    /// Fenster, die sich auf Zuruf oeffnen und danach wieder verschwinden.
    var beiDateiWunsch: (() -> Void)?
    var beiFotoWunsch: (() -> Void)?

    override init() {
        super.init()
        ort.delegate = self
        ort.desiredAccuracy = kCLLocationAccuracyHundredMeters
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    // MARK: - Beschreibung für das Modell (OpenAI-Format)

    static var beschreibungen: [[String: Any]] { katalog.map(\.schema) }

    private struct Eintrag {
        let name: String
        let zweck: String
        let felder: [String: Any]
        let pflicht: [String]

        var schema: [String: Any] {
            let funktion: [String: Any] = [
                "name": name,
                "description": zweck,
                "parameters": ["type": "object", "properties": felder, "required": pflicht]
            ]
            return ["type": "function", "function": funktion]
        }
    }

    private static func text(_ beschreibung: String) -> [String: Any] {
        ["type": "string", "description": beschreibung]
    }

    private static let katalog: [Eintrag] = [
        // Wissen und Netz
        Eintrag(name: "wetter", zweck: "Aktuelles Wetter und Vorhersage für heute.",
                felder: ["ort": text("Ortsname. Weglassen für den aktuellen Standort.")],
                pflicht: []),
        Eintrag(name: "nachrichten", zweck: "Aktuelle Schlagzeilen aus Deutschland.",
                felder: ["anzahl": ["type": "integer", "description": "1 bis 8."]],
                pflicht: []),
        Eintrag(name: "aktie",
                zweck: "Aktueller Börsenkurs einer Aktie, eines Index oder einer Kryptowährung.",
                felder: ["was": text("Firmenname oder Kürzel, etwa Apple, Tesla, DAX, Bitcoin.")],
                pflicht: ["was"]),
        Eintrag(name: "websuche",
                zweck: "Sucht im Netz. Für alles Aktuelle, das kein anderes Werkzeug abdeckt.",
                felder: ["frage": text("Die Suchanfrage.")],
                pflicht: ["frage"]),
        Eintrag(name: "wikipedia", zweck: "Kurze Zusammenfassung zu einem Begriff.",
                felder: ["begriff": text("Wonach nachgeschlagen werden soll.")],
                pflicht: ["begriff"]),
        Eintrag(name: "zeit", zweck: "Aktuelles Datum und Uhrzeit.",
                felder: [:], pflicht: []),

        // Ort
        Eintrag(name: "standort", zweck: "Wo Julian sich gerade befindet.",
                felder: [:], pflicht: []),
        Eintrag(name: "navigation", zweck: "Öffnet die Karten-App mit einer Route zum Ziel.",
                felder: ["ziel": text("Adresse oder Ortsname.")],
                pflicht: ["ziel"]),

        // Gerät
        Eintrag(name: "taschenlampe", zweck: "Schaltet die Taschenlampe ein oder aus.",
                felder: ["an": ["type": "boolean", "description": "true für ein."]],
                pflicht: ["an"]),
        Eintrag(name: "helligkeit", zweck: "Stellt die Bildschirmhelligkeit ein.",
                felder: ["prozent": ["type": "integer", "description": "0 bis 100."]],
                pflicht: ["prozent"]),
        Eintrag(name: "musik", zweck: "Steuert die Musikwiedergabe.",
                felder: ["aktion": text("start, pause, weiter, zurueck oder laeuft")],
                pflicht: ["aktion"]),
        Eintrag(name: "batterie", zweck: "Akkustand und Ladezustand des iPhones.",
                felder: [:], pflicht: []),
        Eintrag(name: "kopieren", zweck: "Legt Text in die Zwischenablage.",
                felder: ["text": text("Was kopiert werden soll.")],
                pflicht: ["text"]),
        Eintrag(name: "app_oeffnen", zweck: "Öffnet eine App auf dem iPhone.",
                felder: ["name": text("Zum Beispiel WhatsApp, Spotify, Kamera, Einstellungen.")],
                pflicht: ["name"]),
        Eintrag(name: "anrufen", zweck: "Startet einen Anruf.",
                felder: ["nummer": text("Telefonnummer.")],
                pflicht: ["nummer"]),
        Eintrag(name: "nachricht_schreiben",
                zweck: "Öffnet die Nachrichten-App mit vorgeschriebenem Text.",
                felder: ["nummer": text("Empfänger, optional."),
                         "text": text("Der Nachrichtentext.")],
                pflicht: ["text"]),
        Eintrag(name: "kurzbefehl",
                zweck: "Startet einen Kurzbefehl aus Julians Kurzbefehle-App. Damit lässt "
                     + "sich alles steuern, wofür er dort einen Kurzbefehl angelegt hat, "
                     + "etwa Licht, Fokus oder Geräte im Haus.",
                felder: ["name": text("Exakter Name des Kurzbefehls."),
                         "eingabe": text("Optionaler Text als Eingabe.")],
                pflicht: ["name"]),

        // Organisation
        Eintrag(name: "erinnerung", zweck: "Legt eine Erinnerung in der Erinnerungen-App an.",
                felder: ["text": text("Woran erinnert werden soll."),
                         "wann": text("Zeitpunkt, etwa 'morgen 8 Uhr' oder '2026-09-08 14:30'.")],
                pflicht: ["text"]),
        Eintrag(name: "termin_anlegen", zweck: "Trägt einen Termin in den Kalender ein.",
                felder: ["titel": text("Worum es geht."),
                         "wann": text("Startzeit, etwa 'morgen 15 Uhr' oder '2026-09-08 15:00'."),
                         "minuten": ["type": "integer", "description": "Dauer, Standard 60."]],
                pflicht: ["titel", "wann"]),
        Eintrag(name: "termine_lesen", zweck: "Liest anstehende Kalendertermine.",
                felder: ["tage": ["type": "integer", "description": "Tage voraus, Standard 1."]],
                pflicht: []),

        // Fenster und Rechnen
        Eintrag(name: "datei_oeffnen",
                zweck: "Oeffnet die Dateiauswahl, damit Julian eine Datei zum Auswerten "
                     + "aussuchen kann. Nimm das, wenn er von einer Datei, einem PDF oder "
                     + "einem Dokument spricht, ohne dass schon eines angehaengt ist.",
                felder: [:], pflicht: []),
        Eintrag(name: "foto_aufnehmen",
                zweck: "Oeffnet die Kamera, damit Julian etwas fotografieren kann, das du "
                     + "dir ansehen sollst.",
                felder: [:], pflicht: []),
        Eintrag(name: "rechnen", zweck: "Rechnet einen Ausdruck exakt aus.",
                felder: ["ausdruck": text("Zum Beispiel (1290 * 1.19) / 3")],
                pflicht: ["ausdruck"]),

        // Gedächtnis
        Eintrag(name: "merken", zweck: "Legt einen dauerhaften Fakt über Julian ab.",
                felder: ["fakt": text("Kurzer Satz in der dritten Person."),
                         "bereich": text(Bereich.allCases.map(\.rawValue).joined(separator: ", "))],
                pflicht: ["fakt"]),
        Eintrag(name: "vergessen", zweck: "Löscht Fakten aus dem Gedächtnis.",
                felder: ["suchtext": text("Wonach gesucht werden soll.")],
                pflicht: ["suchtext"]),
        Eintrag(name: "gedaechtnis_zeigen", zweck: "Listet auf, was über Julian gespeichert ist.",
                felder: [:], pflicht: [])
    ]

    /// Kurzer Text für die Anzeige, während ein Werkzeug arbeitet.
    static func anzeige(für name: String) -> String {
        switch name {
        case "wetter":              return "sieht nach dem Wetter"
        case "nachrichten":         return "liest die Nachrichten"
        case "aktie":               return "prüft den Kurs"
        case "websuche":            return "sucht im Netz"
        case "wikipedia":           return "schlägt nach"
        case "standort":            return "sucht den Standort"
        case "navigation":          return "plant die Route"
        case "taschenlampe":        return "Taschenlampe"
        case "helligkeit":          return "Helligkeit"
        case "musik":               return "Musik"
        case "batterie":            return "prüft den Akku"
        case "kopieren":            return "kopiert"
        case "app_oeffnen":         return "öffnet die App"
        case "anrufen":             return "wählt"
        case "nachricht_schreiben": return "schreibt"
        case "kurzbefehl":          return "startet den Kurzbefehl"
        case "erinnerung":          return "legt die Erinnerung an"
        case "termin_anlegen":      return "trägt den Termin ein"
        case "termine_lesen":       return "sieht in den Kalender"
        case "merken":              return "merkt sich das"
        case "vergessen":           return "vergisst"
        case "datei_oeffnen":       return "öffnet die Dateiauswahl"
        case "foto_aufnehmen":      return "öffnet die Kamera"
        case "rechnen":             return "rechnet"
        case "gedaechtnis_zeigen":  return "geht das Gedächtnis durch"
        default:                    return "arbeitet"
        }
    }

    // MARK: - Ausführung

    func führeAus(_ name: String, _ a: [String: Any]) async -> String {
        läuft = Self.anzeige(für: name)
        defer { läuft = "" }

        switch name {
        case "wetter":              return await wetter(a["ort"] as? String)
        case "nachrichten":         return await nachrichten(zahl(a["anzahl"]) ?? 4)
        case "aktie":               return await aktie(a["was"] as? String ?? "")
        case "websuche":            return await websuche(a["frage"] as? String ?? "")
        case "wikipedia":           return await wikipedia(a["begriff"] as? String ?? "")
        case "zeit":                return zeit()
        case "standort":            return await standortText()
        case "navigation":          return navigation(a["ziel"] as? String ?? "")
        case "taschenlampe":        return taschenlampe(wahr(a["an"]) ?? true)
        case "helligkeit":          return helligkeit(zahl(a["prozent"]) ?? 50)
        case "musik":               return musik(a["aktion"] as? String ?? "")
        case "batterie":            return batterie()
        case "kopieren":            return kopieren(a["text"] as? String ?? "")
        case "app_oeffnen":         return appÖffnen(a["name"] as? String ?? "")
        case "anrufen":             return anrufen(a["nummer"] as? String ?? "")
        case "nachricht_schreiben": return nachricht(a["nummer"] as? String,
                                                     a["text"] as? String ?? "")
        case "kurzbefehl":          return kurzbefehl(a["name"] as? String ?? "",
                                                      a["eingabe"] as? String)
        case "erinnerung":          return await erinnerung(a["text"] as? String ?? "",
                                                            a["wann"] as? String)
        case "termin_anlegen":      return await terminAnlegen(a["titel"] as? String ?? "",
                                                               a["wann"] as? String ?? "",
                                                               zahl(a["minuten"]) ?? 60)
        case "termine_lesen":       return await termineLesen(zahl(a["tage"]) ?? 1)
        case "datei_oeffnen":       beiDateiWunsch?()
                                    return "Die Dateiauswahl ist offen. Sag Julian, "
                                         + "er soll die Datei aussuchen."
        case "foto_aufnehmen":      beiFotoWunsch?()
                                    return "Die Kamera ist offen. Sag Julian, "
                                         + "er soll das Bild aufnehmen."
        case "rechnen":             return rechnen(a["ausdruck"] as? String ?? "")
        case "merken":              return merken(a)
        case "vergessen":           return vergessen(a["suchtext"] as? String ?? "")
        case "gedaechtnis_zeigen":  return gedächtnisZeigen()
        default:                    return "Unbekanntes Werkzeug."
        }
    }

    /// Manche Modelle schicken Zahlen und Wahrheitswerte als Text.
    private func zahl(_ wert: Any?) -> Int? {
        if let i = wert as? Int { return i }
        if let d = wert as? Double { return Int(d) }
        if let s = wert as? String { return Int(s) }
        return nil
    }

    private func wahr(_ wert: Any?) -> Bool? {
        if let b = wert as? Bool { return b }
        if let s = wert as? String {
            return ["true", "ja", "an", "1", "ein"].contains(s.lowercased())
        }
        if let i = wert as? Int { return i != 0 }
        return nil
    }

    // MARK: - Wetter

    private func wetter(_ gesucht: String?) async -> String {
        var breite = 0.0, länge = 0.0, name = ""

        if let gesucht, !gesucht.isEmpty {
            guard let treffer = await geokodieren(gesucht) else {
                return "Ort \(gesucht) nicht gefunden."
            }
            (breite, länge, name) = treffer
        } else {
            guard let position = await aktuellerOrt() else {
                return "Standort nicht verfügbar. Die Ortung muss erlaubt sein."
            }
            breite = position.coordinate.latitude
            länge = position.coordinate.longitude
            name = "Hier"
        }

        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(breite)"
            + "&longitude=\(länge)&current=temperature_2m,apparent_temperature,weather_code,"
            + "wind_speed_10m&daily=temperature_2m_max,temperature_2m_min,"
            + "precipitation_probability_max&timezone=auto&forecast_days=1"),
              let o = await holeObjekt(url),
              let jetzt = o["current"] as? [String: Any],
              let tag = o["daily"] as? [String: Any]
        else { return "Wetterdienst nicht erreichbar." }

        let t = jetzt["temperature_2m"] as? Double ?? 0
        let gefühlt = jetzt["apparent_temperature"] as? Double ?? t
        let wind = jetzt["wind_speed_10m"] as? Double ?? 0
        let code = jetzt["weather_code"] as? Int ?? 0
        let hoch = (tag["temperature_2m_max"] as? [Double])?.first ?? t
        let tief = (tag["temperature_2m_min"] as? [Double])?.first ?? t
        let regen = (tag["precipitation_probability_max"] as? [Int])?.first ?? 0

        return "\(name): \(Self.himmel(code)), \(Int(t.rounded())) Grad, gefühlt "
             + "\(Int(gefühlt.rounded())). Heute \(Int(tief.rounded())) bis "
             + "\(Int(hoch.rounded())) Grad, Regenwahrscheinlichkeit \(regen) Prozent, "
             + "Wind \(Int(wind.rounded())) Kilometer pro Stunde."
    }

    private static func himmel(_ code: Int) -> String {
        switch code {
        case 0:       return "klar"
        case 1, 2:    return "überwiegend heiter"
        case 3:       return "bedeckt"
        case 45, 48:  return "neblig"
        case 51...57: return "Nieselregen"
        case 61...67: return "Regen"
        case 71...77: return "Schnee"
        case 80...82: return "Schauer"
        case 95...99: return "Gewitter"
        default:      return "wechselhaft"
        }
    }

    private func geokodieren(_ suche: String) async -> (Double, Double, String)? {
        guard let begriff = suche.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name="
                            + begriff + "&count=1&language=de&format=json"),
              let o = await holeObjekt(url),
              let treffer = (o["results"] as? [[String: Any]])?.first,
              let breite = treffer["latitude"] as? Double,
              let länge = treffer["longitude"] as? Double
        else { return nil }
        return (breite, länge, treffer["name"] as? String ?? suche)
    }

    // MARK: - Nachrichten

    private func nachrichten(_ anzahl: Int) async -> String {
        guard let url = URL(string: "https://www.tagesschau.de/api2u/homepage/"),
              let o = await holeObjekt(url),
              let liste = o["news"] as? [[String: Any]]
        else { return "Nachrichtenquelle nicht erreichbar." }

        let titel = liste.compactMap { $0["title"] as? String }
            .prefix(max(1, min(anzahl, 8)))
        guard !titel.isEmpty else { return "Gerade keine Meldungen." }
        return titel.enumerated().map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: " ")
    }

    // MARK: - Börse

    private func aktie(_ was: String) async -> String {
        guard !was.isEmpty else { return "Kein Wert angegeben." }
        guard let symbol = await symbolFinden(was) else {
            return "Für \(was) habe ich kein Kürzel gefunden."
        }
        guard let kodiert = symbol.0.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/"
                            + kodiert + "?interval=1d&range=5d"),
              let o = await holeObjekt(url),
              let ergebnis = ((o["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let meta = ergebnis["meta"] as? [String: Any],
              let kurs = meta["regularMarketPrice"] as? Double
        else { return "Kurs für \(symbol.1) ist gerade nicht abrufbar." }

        let vortag = meta["chartPreviousClose"] as? Double
            ?? meta["previousClose"] as? Double ?? kurs
        let währung = meta["currency"] as? String ?? ""
        let differenz = kurs - vortag
        let prozent = vortag > 0 ? differenz / vortag * 100 : 0
        let richtung = differenz >= 0 ? "plus" : "minus"

        return String(format: "%@ steht bei %.2f %@, %@ %.2f Prozent zum Vortag.",
                      symbol.1, kurs, währung, richtung, abs(prozent))
    }

    /// Liefert Kürzel und Klarnamen.
    private func symbolFinden(_ was: String) async -> (String, String)? {
        let bekannt: [String: (String, String)] = [
            "dax": ("^GDAXI", "Der DAX"), "mdax": ("^MDAX", "Der MDAX"),
            "dow": ("^DJI", "Der Dow Jones"), "dow jones": ("^DJI", "Der Dow Jones"),
            "nasdaq": ("^IXIC", "Der Nasdaq"), "s&p": ("^GSPC", "Der S&P 500"),
            "s&p 500": ("^GSPC", "Der S&P 500"), "euro stoxx": ("^STOXX50E", "Der Euro Stoxx 50"),
            "bitcoin": ("BTC-EUR", "Bitcoin"), "btc": ("BTC-EUR", "Bitcoin"),
            "ethereum": ("ETH-EUR", "Ethereum"), "eth": ("ETH-EUR", "Ethereum"),
            "gold": ("GC=F", "Gold"), "silber": ("SI=F", "Silber"),
            "öl": ("BZ=F", "Brent-Öl"), "oel": ("BZ=F", "Brent-Öl")
        ]
        let schlüssel = was.lowercased().trimmingCharacters(in: .whitespaces)
        if let treffer = bekannt[schlüssel] { return treffer }

        guard let begriff = was.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://query2.finance.yahoo.com/v1/finance/search?q="
                            + begriff + "&quotesCount=1&newsCount=0"),
              let o = await holeObjekt(url),
              let treffer = (o["quotes"] as? [[String: Any]])?.first,
              let symbol = treffer["symbol"] as? String
        else {
            // Vielleicht war es ohnehin schon ein Kürzel.
            return (was.uppercased(), was.uppercased())
        }
        let klarname = treffer["shortname"] as? String
            ?? treffer["longname"] as? String ?? symbol
        return (symbol, klarname)
    }

    // MARK: - Suche und Nachschlagen

    private func websuche(_ frage: String) async -> String {
        guard let begriff = frage.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.duckduckgo.com/?q=" + begriff
                            + "&format=json&no_html=1&skip_disambig=1")
        else { return "Ungültige Anfrage." }

        if let o = await holeObjekt(url) {
            if let text = o["AbstractText"] as? String, !text.isEmpty {
                let quelle = o["AbstractSource"] as? String ?? "DuckDuckGo"
                return "\(text) (Quelle: \(quelle))"
            }
            if let antwort = o["Answer"] as? String, !antwort.isEmpty { return antwort }
            let verwandt = (o["RelatedTopics"] as? [[String: Any]] ?? [])
                .compactMap { $0["Text"] as? String }.prefix(3)
            if !verwandt.isEmpty { return verwandt.joined(separator: " — ") }
        }
        // Wenn die Sofortantwort nichts hergibt, hilft meistens Wikipedia.
        return await wikipedia(frage)
    }

    private func wikipedia(_ begriff: String) async -> String {
        guard let suche = begriff.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return "Ungültige Anfrage." }

        var titel = begriff
        if let url = URL(string: "https://de.wikipedia.org/w/api.php?action=opensearch&search="
                         + suche + "&limit=1&format=json"),
           let daten = await holeDaten(url),
           let liste = try? JSONSerialization.jsonObject(with: daten) as? [Any],
           liste.count > 1, let namen = liste[1] as? [String], let erster = namen.first {
            titel = erster
        }

        guard let kodiert = titel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://de.wikipedia.org/api/rest_v1/page/summary/" + kodiert),
              let o = await holeObjekt(url),
              let auszug = o["extract"] as? String, !auszug.isEmpty
        else { return "Zu \(begriff) finde ich nichts." }

        return String(auszug.prefix(700))
    }

    // MARK: - Standort

    private func standortText() async -> String {
        guard let position = await aktuellerOrt() else { return "Standort nicht verfügbar." }
        let orte = try? await CLGeocoder().reverseGeocodeLocation(position)
        guard let treffer = orte?.first else {
            return "Position: \(position.coordinate.latitude), \(position.coordinate.longitude)"
        }
        return [treffer.thoroughfare, treffer.postalCode, treffer.locality]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private func aktuellerOrt() async -> CLLocation? {
        if ort.authorizationStatus == .notDetermined { ort.requestWhenInUseAuthorization() }
        guard ort.authorizationStatus == .authorizedWhenInUse
                || ort.authorizationStatus == .authorizedAlways else { return nil }
        if let frisch = ort.location, frisch.timestamp.timeIntervalSinceNow > -120 { return frisch }

        return await withCheckedContinuation { fortsetzen in
            ortWartend.append(fortsetzen)
            ort.requestLocation()
            // Kommt binnen acht Sekunden nichts, wird trotzdem geantwortet.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                let offen = ortWartend
                ortWartend.removeAll()
                offen.forEach { $0.resume(returning: ort.location) }
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {
        Task { @MainActor in
            let letzte = l.last
            ortWartend.forEach { $0.resume(returning: letzte) }
            ortWartend.removeAll()
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {
        Task { @MainActor in
            ortWartend.forEach { $0.resume(returning: nil) }
            ortWartend.removeAll()
        }
    }

    // MARK: - Gerät

    private func taschenlampe(_ an: Bool) -> String {
        guard let gerät = AVCaptureDevice.default(for: .video), gerät.hasTorch else {
            return "Dieses Gerät hat keine schaltbare Taschenlampe."
        }
        do {
            try gerät.lockForConfiguration()
            if an { try gerät.setTorchModeOn(level: 1.0) } else { gerät.torchMode = .off }
            gerät.unlockForConfiguration()
            return an ? "Taschenlampe an." : "Taschenlampe aus."
        } catch {
            return "Die Taschenlampe lässt sich gerade nicht schalten."
        }
    }

    private func helligkeit(_ prozent: Int) -> String {
        let wert = Double(max(0, min(100, prozent))) / 100
        UIScreen.main.brightness = wert
        return "Helligkeit auf \(Int(wert * 100)) Prozent."
    }

    private func musik(_ aktion: String) -> String {
        let spieler = MPMusicPlayerController.systemMusicPlayer
        switch aktion.lowercased() {
        case "start", "play", "weiterspielen", "abspielen":
            spieler.play();               return "Läuft."
        case "pause", "stopp", "stop":
            spieler.pause();              return "Pausiert."
        case "weiter", "next", "naechster", "nächster":
            spieler.skipToNextItem();     return "Nächster Titel."
        case "zurueck", "zurück", "previous":
            spieler.skipToPreviousItem(); return "Vorheriger Titel."
        default:
            guard let titel = spieler.nowPlayingItem else { return "Es läuft gerade nichts." }
            return "\(titel.title ?? "Unbekannt") von \(titel.artist ?? "unbekannt")."
        }
    }

    private func batterie() -> String {
        let stand = Int((UIDevice.current.batteryLevel * 100).rounded())
        guard stand >= 0 else { return "Akkustand nicht auslesbar." }
        let zustand: String
        switch UIDevice.current.batteryState {
        case .charging: zustand = ", lädt gerade"
        case .full:     zustand = ", voll"
        default:        zustand = ""
        }
        return "Akku bei \(stand) Prozent\(zustand)."
    }

    private func kopieren(_ text: String) -> String {
        UIPasteboard.general.string = text
        return "In die Zwischenablage gelegt."
    }

    private static let apps: [String: String] = [
        "whatsapp": "whatsapp://", "spotify": "spotify://", "instagram": "instagram://",
        "youtube": "youtube://", "tiktok": "snssdk1128://", "telegram": "tg://",
        "kamera": "camera://", "einstellungen": "App-Prefs:", "karten": "maps://",
        "musik": "music://", "mail": "message://", "nachrichten": "sms:",
        "telefon": "tel:", "kalender": "calshow://", "notizen": "mobilenotes://",
        "erinnerungen": "x-apple-reminderkit://", "safari": "https://www.google.de",
        "netflix": "nflx://", "discord": "discord://", "signal": "sgnl://",
        "snapchat": "snapchat://", "x": "twitter://", "twitter": "twitter://",
        "reddit": "reddit://", "paypal": "paypal://", "kurzbefehle": "shortcuts://",
        "wetter": "weather://", "uhr": "clock-alarm://", "fotos": "photos-redirect://",
        "appstore": "itms-apps://"
    ]

    private func appÖffnen(_ name: String) -> String {
        let schlüssel = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard let schema = Self.apps[schlüssel] else {
            return "Diese App kenne ich nicht. Bekannt sind unter anderem: "
                 + Self.apps.keys.sorted().prefix(14).joined(separator: ", ")
        }
        öffne(schema)
        return "\(name) geöffnet."
    }

    private func navigation(_ ziel: String) -> String {
        guard !ziel.isEmpty else { return "Kein Ziel angegeben." }
        let kodiert = ziel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ziel
        öffne("maps://?daddr=\(kodiert)&dirflg=d")
        return "Karten mit Route nach \(ziel) geöffnet."
    }

    private func anrufen(_ nummer: String) -> String {
        let sauber = nummer.filter { "+0123456789".contains($0) }
        guard !sauber.isEmpty else { return "Keine gültige Nummer." }
        öffne("tel://\(sauber)")
        return "Anruf an \(sauber) wird gestartet."
    }

    private func nachricht(_ nummer: String?, _ text: String) -> String {
        let kodiert = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let empfänger = (nummer ?? "").filter { "+0123456789".contains($0) }
        öffne("sms:\(empfänger)&body=\(kodiert)")
        return "Nachrichten-App geöffnet. Absenden muss Julian selbst."
    }

    private func kurzbefehl(_ name: String, _ eingabe: String?) -> String {
        guard !name.isEmpty else { return "Kein Kurzbefehl angegeben." }
        let kodiert = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        var ziel = "shortcuts://run-shortcut?name=\(kodiert)"
        if let eingabe, !eingabe.isEmpty,
           let t = eingabe.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            ziel += "&input=text&text=\(t)"
        }
        öffne(ziel)
        return "Kurzbefehl \(name) gestartet. Passiert nichts, gibt es ihn unter dem Namen nicht."
    }

    private func öffne(_ text: String) {
        guard let url = URL(string: text) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Erinnerungen und Kalender

    private func erinnerung(_ text: String, _ wann: String?) async -> String {
        guard !text.isEmpty else { return "Kein Text angegeben." }
        guard (try? await kalender.requestFullAccessToReminders()) == true else {
            return "Zugriff auf Erinnerungen fehlt. Einstellungen, BUDDY, Erinnerungen."
        }

        let eintrag = EKReminder(eventStore: kalender)
        eintrag.title = text
        eintrag.calendar = kalender.defaultCalendarForNewReminders()

        var zusatz = ""
        if let wann, let zeitpunkt = Self.zeitpunkt(aus: wann) {
            eintrag.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: zeitpunkt)
            eintrag.addAlarm(EKAlarm(absoluteDate: zeitpunkt))
            zusatz = " für " + Self.hübsch(zeitpunkt)
        }

        do {
            try kalender.save(eintrag, commit: true)
            return "Erinnerung angelegt\(zusatz): \(text)"
        } catch {
            return "Die Erinnerung ließ sich nicht speichern."
        }
    }

    private func terminAnlegen(_ titel: String, _ wann: String, _ minuten: Int) async -> String {
        guard !titel.isEmpty else { return "Kein Titel angegeben." }
        guard (try? await kalender.requestFullAccessToEvents()) == true else {
            return "Zugriff auf den Kalender fehlt. Einstellungen, BUDDY, Kalender."
        }
        guard let start = Self.zeitpunkt(aus: wann) else {
            return "Den Zeitpunkt \(wann) verstehe ich nicht."
        }

        let termin = EKEvent(eventStore: kalender)
        termin.title = titel
        termin.startDate = start
        termin.endDate = start.addingTimeInterval(TimeInterval(max(5, minuten) * 60))
        termin.calendar = kalender.defaultCalendarForNewEvents
        termin.addAlarm(EKAlarm(relativeOffset: -900))

        do {
            try kalender.save(termin, span: .thisEvent, commit: true)
            return "Termin eingetragen: \(titel), \(Self.hübsch(start))."
        } catch {
            return "Der Termin ließ sich nicht speichern."
        }
    }

    private func termineLesen(_ tage: Int) async -> String {
        guard (try? await kalender.requestFullAccessToEvents()) == true else {
            return "Zugriff auf den Kalender fehlt."
        }
        let jetzt = Date()
        let bis = jetzt.addingTimeInterval(TimeInterval(max(1, tage) * 86400))
        let suche = kalender.predicateForEvents(withStart: jetzt, end: bis, calendars: nil)
        let termine = kalender.events(matching: suche).prefix(8)

        guard !termine.isEmpty else {
            return tage <= 1 ? "Heute steht nichts mehr an."
                             : "In den nächsten \(tage) Tagen steht nichts an."
        }
        return termine.map { "\(Self.hübsch($0.startDate)): \($0.title ?? "Termin")" }
            .joined(separator: ". ")
    }

    /// Versteht sowohl ISO-Zeitpunkte als auch lockere deutsche Angaben.
    private static func zeitpunkt(aus text: String) -> Date? {
        let kal = Calendar.current
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)

        for muster in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm",
                       "dd.MM.yyyy HH:mm", "yyyy-MM-dd"] {
            let former = DateFormatter()
            former.locale = Locale(identifier: "de_DE")
            former.dateFormat = muster
            if let treffer = former.date(from: text) { return treffer }
        }

        var stunde = 9, minute = 0
        if let bereich = t.range(of: "\\d{1,2}[:.]\\d{2}", options: .regularExpression) {
            let teile = t[bereich].split(whereSeparator: { $0 == ":" || $0 == "." })
            stunde = Int(teile[0]) ?? 9
            minute = teile.count > 1 ? (Int(teile[1]) ?? 0) : 0
        } else if let bereich = t.range(of: "\\d{1,2}(?=\\s*uhr)", options: .regularExpression) {
            stunde = Int(t[bereich]) ?? 9
        }

        var versatz = 0
        if t.contains("übermorgen") || t.contains("uebermorgen") { versatz = 2 }
        else if t.contains("morgen") { versatz = 1 }

        guard let basis = kal.date(byAdding: .day, value: versatz, to: Date()) else { return nil }
        var teile = kal.dateComponents([.year, .month, .day], from: basis)
        teile.hour = stunde
        teile.minute = minute
        guard let ergebnis = kal.date(from: teile) else { return nil }

        // Ohne Tagesangabe und schon vorbei? Dann ist morgen gemeint.
        if versatz == 0 && ergebnis < Date() {
            return kal.date(byAdding: .day, value: 1, to: ergebnis)
        }
        return ergebnis
    }

    private static func hübsch(_ datum: Date) -> String {
        let former = DateFormatter()
        former.locale = Locale(identifier: "de_DE")
        former.dateFormat = Calendar.current.isDateInToday(datum)
            ? "'heute um' HH:mm" : "EEEE, d. MMMM 'um' HH:mm"
        return former.string(from: datum)
    }

    private func zeit() -> String {
        let former = DateFormatter()
        former.locale = Locale(identifier: "de_DE")
        former.dateFormat = "EEEE, d. MMMM yyyy, HH:mm"
        return former.string(from: Date()) + " Uhr"
    }

    // MARK: - Rechnen

    private func rechnen(_ ausdruck: String) -> String {
        var sauber = ausdruck
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "x", with: "*")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "^", with: "**")
        sauber = sauber.filter { "0123456789.+-*/()% ".contains($0) }
        guard !sauber.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "Kein gültiger Ausdruck."
        }
        guard let wert = NSExpression(format: sauber)
            .expressionValue(with: nil, context: nil) as? NSNumber else {
            return "Das kann ich so nicht rechnen."
        }
        let d = wert.doubleValue
        return d == d.rounded() && abs(d) < 1e15
            ? "\(Int(d))"
            : String(format: "%.6g", d)
    }

    // MARK: - Gedächtnis

    private func merken(_ a: [String: Any]) -> String {
        guard let fakt = a["fakt"] as? String, let gehirn else { return "Nichts zu merken." }
        let bereich = Bereich(rawValue: (a["bereich"] as? String ?? "").lowercased()) ?? .sonstiges
        return gehirn.merken(fakt, bereich: bereich)
            ? "Gemerkt unter \(bereich.titel)."
            : "War schon bekannt, wurde verstärkt."
    }

    private func vergessen(_ suchtext: String) -> String {
        guard let gehirn else { return "Kein Gedächtnis verfügbar." }
        let weg = gehirn.vergessen(suchtext: suchtext)
        return weg.isEmpty ? "Dazu war nichts gespeichert."
                           : "Gelöscht: \(weg.joined(separator: "; "))"
    }

    private func gedächtnisZeigen() -> String {
        guard let gehirn, !gehirn.neuronen.isEmpty else { return "Das Gedächtnis ist leer." }
        return Dictionary(grouping: gehirn.neuronen, by: \.bereich)
            .map { "\($0.key.titel): " + $0.value.map(\.fakt).joined(separator: "; ") }
            .joined(separator: ". ")
    }

    // MARK: - Netz

    private func holeDaten(_ url: URL) async -> Data? {
        var anfrage = URLRequest(url: url)
        anfrage.timeoutInterval = 15
        anfrage.setValue("Mozilla/5.0 (iPhone) BUDDY/1.2", forHTTPHeaderField: "User-Agent")
        anfrage.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (daten, _) = try? await URLSession.shared.data(for: anfrage) else { return nil }
        return daten
    }

    private func holeObjekt(_ url: URL) async -> [String: Any]? {
        guard let daten = await holeDaten(url) else { return nil }
        return try? JSONSerialization.jsonObject(with: daten) as? [String: Any]
    }
}
