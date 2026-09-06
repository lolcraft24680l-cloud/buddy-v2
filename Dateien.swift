import SwiftUI
import PDFKit
import Vision
import UniformTypeIdentifiers
import PhotosUI

/// Liest Dateien und Bilder ein und macht Text daraus, den das Modell versteht.
enum Leser {

    struct Ergebnis {
        let name: String
        let art: String
        let text: String
        let vorschau: UIImage?
    }

    /// Was BUDDY öffnen kann.
    static let arten: [UTType] = [
        .pdf, .plainText, .rtf, .html, .json, .xml, .commaSeparatedText,
        .sourceCode, .swiftSource, .pythonScript, .javaScript, .yaml,
        .image, .zip, .item
    ]

    static func lies(_ url: URL) async -> Ergebnis {
        let name = url.lastPathComponent
        let zugriff = url.startAccessingSecurityScopedResource()
        defer { if zugriff { url.stopAccessingSecurityScopedResource() } }

        if url.pathExtension.lowercased() == "pdf" {
            return await pdf(url, name: name)
        }
        if let bild = UIImage(contentsOfFile: url.path) {
            let text = await erkenneText(in: bild)
            return Ergebnis(name: name, art: "Bild",
                            text: text.isEmpty ? "Im Bild ist kein lesbarer Text."
                                               : "Text im Bild:\n" + text,
                            vorschau: bild)
        }
        // Alles andere als Text versuchen.
        if let daten = try? Data(contentsOf: url),
           let text = String(data: daten, encoding: .utf8)
                   ?? String(data: daten, encoding: .isoLatin1) {
            return Ergebnis(name: name, art: "Textdatei",
                            text: String(text.prefix(24000)), vorschau: nil)
        }
        return Ergebnis(name: name, art: "unbekannt",
                        text: "Diese Datei kann ich nicht lesen.", vorschau: nil)
    }

    private static func pdf(_ url: URL, name: String) async -> Ergebnis {
        guard let dokument = PDFDocument(url: url) else {
            return Ergebnis(name: name, art: "PDF", text: "Das PDF ließ sich nicht öffnen.",
                            vorschau: nil)
        }
        var text = ""
        for seite in 0..<min(dokument.pageCount, 60) {
            if let inhalt = dokument.page(at: seite)?.string { text += inhalt + "\n" }
        }

        let vorschau = dokument.page(at: 0)?
            .thumbnail(of: CGSize(width: 300, height: 400), for: .mediaBox)

        // Gescannte PDFs haben keinen Textlayer — dann per Texterkennung.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 40,
           let seite = dokument.page(at: 0) {
            let bild = seite.thumbnail(of: CGSize(width: 1600, height: 2200), for: .mediaBox)
            text = await erkenneText(in: bild)
        }

        let kopf = "PDF \(name), \(dokument.pageCount) Seiten.\n\n"
        return Ergebnis(name: name, art: "PDF",
                        text: kopf + String(text.prefix(24000)), vorschau: vorschau)
    }

    static func lies(bild: UIImage, name: String = "Foto") async -> Ergebnis {
        let text = await erkenneText(in: bild)
        var beschreibung = "Bild \(name), \(Int(bild.size.width)) mal \(Int(bild.size.height)) Punkte."
        if !text.isEmpty { beschreibung += "\n\nText im Bild:\n" + text }
        else { beschreibung += "\n\nIm Bild ist kein lesbarer Text." }
        return Ergebnis(name: name, art: "Bild", text: beschreibung, vorschau: bild)
    }

    /// Texterkennung auf dem Gerät, kein Netz nötig.
    static func erkenneText(in bild: UIImage) async -> String {
        guard let cg = bild.cgImage else { return "" }
        return await withCheckedContinuation { fortsetzen in
            let anfrage = VNRecognizeTextRequest { ergebnis, _ in
                let zeilen = (ergebnis.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                fortsetzen.resume(returning: zeilen.joined(separator: "\n"))
            }
            anfrage.recognitionLevel = .accurate
            anfrage.recognitionLanguages = ["de-DE", "en-US"]
            anfrage.usesLanguageCorrection = true

            let bearbeiter = VNImageRequestHandler(cgImage: cg, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do { try bearbeiter.perform([anfrage]) }
                catch { fortsetzen.resume(returning: "") }
            }
        }
    }
}

// MARK: - Auswahlfenster

/// Dateiauswahl, die sich nach getaner Arbeit selbst wieder schließt.
struct DateiWähler: UIViewControllerRepresentable {
    let fertig: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let wähler = UIDocumentPickerViewController(forOpeningContentTypes: Leser.arten,
                                                    asCopy: true)
        wähler.delegate = context.coordinator
        wähler.allowsMultipleSelection = false
        return wähler
    }

    func updateUIViewController(_ v: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Bote { Bote(fertig: fertig) }

    final class Bote: NSObject, UIDocumentPickerDelegate {
        let fertig: (URL?) -> Void
        init(fertig: @escaping (URL?) -> Void) { self.fertig = fertig }

        func documentPicker(_ c: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) { fertig(urls.first) }
        func documentPickerWasCancelled(_ c: UIDocumentPickerViewController) { fertig(nil) }
    }
}

/// Kameraaufnahme für „schau dir das an".
struct Kamera: UIViewControllerRepresentable {
    let fertig: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let wähler = UIImagePickerController()
        wähler.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera)
            ? .camera : .photoLibrary
        wähler.delegate = context.coordinator
        return wähler
    }

    func updateUIViewController(_ v: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Bote { Bote(fertig: fertig) }

    final class Bote: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let fertig: (UIImage?) -> Void
        init(fertig: @escaping (UIImage?) -> Void) { self.fertig = fertig }

        func imagePickerController(_ c: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info:
                                   [UIImagePickerController.InfoKey: Any]) {
            fertig(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ c: UIImagePickerController) { fertig(nil) }
    }
}
