import SwiftUI
import Security

@main
struct BUDDYApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)
        }
    }
}

/// Der API-Key landet im Schlüsselbund, nicht in den UserDefaults.
enum Tresor {
    private static let dienst = "de.julian.buddy"

    static func lies(_ konto: String) -> String? {
        let frage: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: dienst,
            kSecAttrAccount as String: konto,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var ergebnis: CFTypeRef?
        guard SecItemCopyMatching(frage as CFDictionary, &ergebnis) == errSecSuccess,
              let daten = ergebnis as? Data,
              let text = String(data: daten, encoding: .utf8),
              !text.isEmpty
        else { return nil }
        return text
    }

    static func schreib(_ konto: String, _ wert: String) {
        lösche(konto)
        let eintrag: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: dienst,
            kSecAttrAccount as String: konto,
            kSecValueData as String: Data(wert.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(eintrag as CFDictionary, nil)
    }

    static func lösche(_ konto: String) {
        let frage: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: dienst,
            kSecAttrAccount as String: konto
        ]
        SecItemDelete(frage as CFDictionary)
    }
}
