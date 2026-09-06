import Foundation

/// Die Bereiche des Gedächtnisses — übernommen aus JARVIS.
enum Bereich: String, CaseIterable, Codable {
    case person, vorlieben, abneigungen, arbeit, projekte, technik
    case menschen, orte, gewohnheiten, ziele, besitz, essen
    case medien, sport, lernen, termine, sonstiges

    var titel: String {
        switch self {
        case .person:       return "Person"
        case .vorlieben:    return "Vorlieben"
        case .abneigungen:  return "Abneigungen"
        case .arbeit:       return "Arbeit"
        case .projekte:     return "Projekte"
        case .technik:      return "Technik"
        case .menschen:     return "Menschen"
        case .orte:         return "Orte"
        case .gewohnheiten: return "Gewohnheiten"
        case .ziele:        return "Ziele"
        case .besitz:       return "Besitz"
        case .essen:        return "Essen und Trinken"
        case .medien:       return "Musik, Filme, Spiele"
        case .sport:        return "Sport"
        case .lernen:       return "Lernen"
        case .termine:      return "Feste Termine"
        case .sonstiges:    return "Sonstiges"
        }
    }

    var zeichen: String {
        switch self {
        case .person:       return "person.fill"
        case .vorlieben:    return "heart.fill"
        case .abneigungen:  return "hand.thumbsdown.fill"
        case .arbeit:       return "briefcase.fill"
        case .projekte:     return "hammer.fill"
        case .technik:      return "cpu"
        case .menschen:     return "person.2.fill"
        case .orte:         return "mappin"
        case .gewohnheiten: return "repeat"
        case .ziele:        return "target"
        case .besitz:       return "shippingbox.fill"
        case .essen:        return "fork.knife"
        case .medien:       return "play.circle.fill"
        case .sport:        return "figure.run"
        case .lernen:       return "book.fill"
        case .termine:      return "calendar"
        case .sonstiges:    return "sparkles"
        }
    }
}

struct Neuron: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var bereich: Bereich
    var fakt: String
    var stärke: Double = 1.0
    var abrufe: Int = 0
    var erstellt: Date = Date()
    var berührt: Date = Date()
}

/// Wortstämme, damit „programmiert" und „programmiere" zusammenfinden.
private enum Wortmühle {
    static let füllwörter: Set<String> = [
        "der", "die", "das", "und", "in", "im", "von", "vom", "zu", "zur", "zum",
        "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "mit", "auf",
        "ist", "sind", "hat", "hab", "habe", "sein", "seine", "er", "sie", "es",
        "julian", "nutzer", "benutzer", "user", "für", "als", "am", "an", "ich",
        "mein", "meine", "meinen", "was", "wie", "wer", "wo", "wann", "warum"
    ]

    static let endungen = ["ungen", "ung", "ern", "est", "end", "en", "er", "es",
                           "st", "em", "e", "n", "s", "t"]

    static func stämme(_ text: String) -> Set<String> {
        let flach = text.lowercased()
            .replacingOccurrences(of: "ä", with: "a")
            .replacingOccurrences(of: "ö", with: "o")
            .replacingOccurrences(of: "ü", with: "u")
            .replacingOccurrences(of: "ß", with: "ss")
        let wörter = flach
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !füllwörter.contains($0) }
        return Set(wörter.map(stamm))
    }

    private static func stamm(_ wort: String) -> String {
        for endung in endungen where wort.count - endung.count >= 4 && wort.hasSuffix(endung) {
            return String(wort.dropLast(endung.count))
        }
        return wort
    }
}

/// Das Langzeitgedächtnis. Jeder Fakt ist ein Neuron; häufig abgerufene
/// Neuronen werden stärker und tauchen eher wieder auf.
@MainActor
final class Gehirn: ObservableObject {

    @Published private(set) var neuronen: [Neuron] = []

    private let ablage: URL = {
        let ordner = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ordner.appendingPathComponent("gehirn.json")
    }()

    /// Wie oft BUDDY schon gefragt wurde und seit wann es ihn gibt.
    @Published private(set) var gespräche: Int =
        UserDefaults.standard.integer(forKey: "gespraeche")
    let seit: Date = {
        if let d = UserDefaults.standard.object(forKey: "seit") as? Date { return d }
        let jetzt = Date()
        UserDefaults.standard.set(jetzt, forKey: "seit")
        return jetzt
    }()

    init() { laden() }

    func zähleGespräch() {
        gespräche += 1
        UserDefaults.standard.set(gespräche, forKey: "gespraeche")
    }

    // MARK: Ablage

    private func laden() {
        guard let daten = try? Data(contentsOf: ablage),
              let liste = try? JSONDecoder().decode([Neuron].self, from: daten)
        else { return }
        neuronen = liste
    }

    private func sichern() {
        guard let daten = try? JSONEncoder().encode(neuronen) else { return }
        try? daten.write(to: ablage, options: .atomic)
    }

    // MARK: Schreiben

    /// Legt einen Fakt ab. Bekanntes wird verstärkt statt verdoppelt.
    @discardableResult
    func merken(_ fakt: String, bereich: Bereich = .sonstiges) -> Bool {
        let sauber = fakt.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard sauber.count > 3 else { return false }

        let neu = Wortmühle.stämme(sauber)
        if let treffer = neuronen.firstIndex(where: { ähnlich(Wortmühle.stämme($0.fakt), neu) }) {
            neuronen[treffer].stärke = min(3.0, neuronen[treffer].stärke + 0.2)
            neuronen[treffer].berührt = Date()
            sichern()
            return false
        }

        neuronen.append(Neuron(bereich: bereich, fakt: sauber))
        sichern()
        return true
    }

    private func ähnlich(_ a: Set<String>, _ b: Set<String>) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return Double(a.intersection(b).count) / Double(a.union(b).count) > 0.62
    }

    @discardableResult
    func vergessen(suchtext: String) -> [String] {
        let gesucht = Wortmühle.stämme(suchtext)
        guard !gesucht.isEmpty else { return [] }
        let weg = neuronen.filter { !Wortmühle.stämme($0.fakt).isDisjoint(with: gesucht) }
        neuronen.removeAll { treffer in weg.contains(where: { $0.id == treffer.id }) }
        sichern()
        return weg.map(\.fakt)
    }

    func vergessen(_ neuron: Neuron) {
        neuronen.removeAll { $0.id == neuron.id }
        sichern()
    }

    func leeren() {
        neuronen.removeAll()
        sichern()
    }

    // MARK: Lesen

    /// Die Fakten, die zu einer Frage passen — reine Wortüberlappung, gewichtet
    /// mit der Stärke des Neurons.
    func suche(_ frage: String, limit: Int = 8) -> [Neuron] {
        let begriffe = Wortmühle.stämme(frage)
        guard !begriffe.isEmpty else { return [] }

        let bewertet: [(Double, Neuron)] = neuronen.compactMap { neuron in
            let wörter = Wortmühle.stämme(neuron.fakt)
            let gemeinsam = begriffe.intersection(wörter)
            guard !gemeinsam.isEmpty else { return nil }
            let punkte = Double(gemeinsam.count) / Double(begriffe.union(wörter).count) * neuron.stärke
            return (punkte, neuron)
        }

        let besten = bewertet.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
        berühren(besten)
        return Array(besten)
    }

    /// Der Gedächtnisblock, der dem Modell mitgegeben wird.
    func kontext(zu frage: String) -> String {
        var gefunden = suche(frage, limit: 12)
        // Die stärksten Fakten sind immer dabei, auch ohne Worttreffer.
        let kern = neuronen.sorted { $0.stärke > $1.stärke }.prefix(8)
        for neuron in kern where !gefunden.contains(where: { $0.id == neuron.id }) {
            gefunden.append(neuron)
        }
        guard !gefunden.isEmpty else { return "" }
        let zeilen = gefunden.map { "- \($0.fakt)" }.joined(separator: "\n")
        return """
        Das weißt du bereits über Julian. Nutze es, ohne es aufzuzählen und ohne \
        zu erwähnen, dass du dich erinnerst:
        \(zeilen)
        """
    }

    private func berühren(_ liste: [Neuron]) {
        guard !liste.isEmpty else { return }
        for neuron in liste {
            guard let i = neuronen.firstIndex(where: { $0.id == neuron.id }) else { continue }
            neuronen[i].abrufe += 1
            neuronen[i].berührt = Date()
            neuronen[i].stärke = min(3.0, neuronen[i].stärke + 0.05)
        }
        sichern()
    }
}
