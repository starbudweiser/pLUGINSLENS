// Choix de langue : « auto » (langue du Mac) ou fr / en / es / it, mémorisé dans les réglages (clé « language »).

import Foundation

public enum LangChoice {
    public static let auto = "auto"
    /// Entrées du menu Langue, dans leur propre langue.
    public static let menuLangs: [(code: String, label: String)] = [("fr", "Français"), ("en", "English"), ("es", "Español"), ("it", "Italiano")]

    public static func normalize(_ choice: String?) -> String {
        let c = (choice ?? "").trimmingCharacters(in: .whitespaces)
        return I18n.langs[c] != nil ? c : auto
    }

    /// Langue à afficher pour un choix mémorisé.
    public static func resolve(_ choice: String?, preferred: [String] = Locale.preferredLanguages) -> String {
        let c = normalize(choice)
        return c == auto ? I18n.systemLang(preferred) : c
    }
}
