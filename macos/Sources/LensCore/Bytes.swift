// Utilitaires d'octets et de texte : traduction ligne à ligne des fonctions de src/plugin_core.py.

import Foundation

public typealias Bytes = [UInt8]

public enum LensError: Error, CustomStringConvertible {
    case notPlugin
    case truncated(String)
    case zlib(Int32)
    case invalid(String)

    public var description: String {
        switch self {
        case .notPlugin: return L("en-tête TES4 absent : ce n'est pas un plugin au format Skyrim")
        case .truncated(let w): return L("données tronquées ({w})", ["w": w])
        case .zlib(let c): return L("erreur de décompression zlib ({c})", ["c": c])
        case .invalid(let m): return m
        }
    }
}

public let COMPRESSED: UInt32 = 0x40000
public let ESL_FLAG: UInt32 = 0x200

public let RFLAGS: [(UInt32, String)] = [
    (0x20, N_("Supprimé")), (0x400, N_("Persistant (surtout REFR)")), (0x800, N_("Désactivé au départ")),
    (0x1000, N_("Ignoré")), (0x40000, N_("Compressé")),
]
public let TES4FLAGS: [(UInt32, String)] = [
    (0x1, N_("Fichier maître")), (0x80, N_("Chaînes localisées")), (0x200, N_("Maître léger (ESL)")),
]
public let GROUP_TYPES = [
    "Top", "World children", "Interior block", "Interior sub-block", "Exterior block",
    "Exterior sub-block", "Cell children", "Topic children", "Cell persistent",
    "Cell temporary", "Cell visible distant",
]

// MARK: - Nombres

/// format(n, "X").zfill(w)
public func hexs(_ n: UInt32, _ w: Int = 8) -> String {
    let s = String(n, radix: 16, uppercase: true)
    return s.count >= w ? s : String(repeating: "0", count: w - s.count) + s
}

public func hexs(_ n: Int, _ w: Int = 8) -> String {
    let s = String(n, radix: 16, uppercase: true)
    return s.count >= w ? s : String(repeating: "0", count: w - s.count) + s
}

public func hexs(_ n: UInt8, _ w: Int = 2) -> String { hexs(UInt32(n), w) }

/// Lecture little-endian ; lève une erreur hors limites (struct.error en Python).
public func u32(_ b: Bytes, _ p: Int = 0) throws -> UInt32 {
    guard p >= 0, p + 4 <= b.count else { throw LensError.truncated("u32") }
    return UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
}

/// u32 sans erreur pour les tableaux dont la taille a été vérifiée avant.
@inline(__always) public func u32s(_ b: Bytes, _ p: Int = 0) -> UInt32 {
    UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
}

public func p32(_ v: UInt32) -> Bytes {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}

public func p32(_ v: Int) -> Bytes { p32(UInt32(truncatingIfNeeded: v)) }

// MARK: - Texte

/// Octets → texte latin-1 (s4)
public func s4(_ b: Bytes, _ p: Int = 0) -> String {
    let lo = max(0, min(p, b.count)), hi = max(lo, min(p + 4, b.count))
    var s = String.UnicodeScalarView()
    for x in b[lo..<hi] { s.append(Unicode.Scalar(x)) }
    return String(s)
}

public func te(_ s: String) -> Bytes { Array(s.utf8) }

public func td(_ b: Bytes) -> String { String(decoding: b, as: UTF8.self) }

public func lc(_ s: String) -> String { s.lowercased() }

func typeBytes(_ t: String) -> Bytes {
    var out = Array(t.utf8.prefix(4))
    while out.count < 4 { out.append(0) }
    return out
}

/// Équivalent de .replace(/\0.*$/, '') en JavaScript : coupe à partir du premier NUL dont la suite ne contient
/// aucun saut de ligne (\n, \r, U+2028, U+2029).
public func stripNul(_ s: String) -> String {
    let sc = Array(s.unicodeScalars)
    var last = -1
    for (i, c) in sc.enumerated() where c == "\n" || c == "\r" || c == "\u{2028}" || c == "\u{2029}" { last = i }
    var i = last + 1
    while i < sc.count {
        if sc[i] == "\0" {
            var v = String.UnicodeScalarView()
            v.append(contentsOf: sc[..<i])
            return String(v)
        }
        i += 1
    }
    return s
}

public func isText(_ d: Bytes) -> Bool {
    guard d.count > 1, d[d.count - 1] == 0 else { return false }
    for b in d[..<(d.count - 1)] where !((32 <= b && b < 127) || b == 9 || b == 10 || b == 13) { return false }
    return true
}

public func textOf(_ d: Bytes) -> String {
    td(d.last == 0 ? Array(d.dropLast()) : d)
}

public func textBytes(_ s: String) -> Bytes { te(s) + [0] }

public func hexBytes(_ d: Bytes) -> String { d.map { hexs($0, 2) }.joined(separator: " ") }

/// Espaces au sens de str.isspace() de Python.
func isPySpace(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 9...13, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
    default: return false
    }
}

/// str.strip() de Python
public func pyStrip(_ s: String) -> String {
    let sc = Array(s.unicodeScalars)
    var a = 0, b = sc.count
    while a < b, isPySpace(sc[a]) { a += 1 }
    while b > a, isPySpace(sc[b - 1]) { b -= 1 }
    var v = String.UnicodeScalarView()
    v.append(contentsOf: sc[a..<b])
    return String(v)
}

/// Tri des chaînes par points de code (comme Python).
public func scalarLess(_ a: String, _ b: String) -> Bool {
    var i = a.unicodeScalars.makeIterator(), j = b.unicodeScalars.makeIterator()
    while true {
        let x = i.next(), y = j.next()
        switch (x, y) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (x?, y?):
            if x.value != y.value { return x.value < y.value }
        }
    }
}

/// Égalité par points de code (Swift compare par équivalence canonique).
public func scalarEq(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.elementsEqual(b.unicodeScalars)
}

/// Chaîne hachable par points de code : sert de clé de dictionnaire identique à Python.
public struct Key: Hashable {
    public let s: [UInt32]
    public init(_ str: String) { s = str.unicodeScalars.map { $0.value } }
}

/// parse_hex_bytes : octets hexadécimaux séparés par des espaces ou virgules, nil si invalide.
public func parseHexBytes(_ s: String) -> Bytes? {
    var digits: [UInt8] = []
    for c in s.unicodeScalars {
        if isPySpace(c) || c == "," { continue }
        // \s Python (unicode) : on retire aussi les espaces insécables, comme re.sub(r"[\s,]", "")
        guard c.isASCII, let h = Character(c).hexDigitValue else { return nil }
        digits.append(UInt8(h))
    }
    guard digits.count % 2 == 0 else { return nil }
    var out = Bytes()
    out.reserveCapacity(digits.count / 2)
    var i = 0
    while i < digits.count { out.append(digits[i] << 4 | digits[i + 1]); i += 2 }
    return out
}

/// parseInt(s, 16) >>> 0 de JavaScript (nil si NaN).
public func jsParseHex(_ s: String) -> UInt32? {
    let sc = Array(s.unicodeScalars)
    var i = 0
    while i < sc.count, isPySpace(sc[i]) { i += 1 }
    var neg = false
    if i < sc.count, sc[i] == "+" || sc[i] == "-" { neg = sc[i] == "-"; i += 1 }
    func isHex(_ c: Unicode.Scalar) -> Bool { c.isASCII && Character(c).isHexDigit }
    var start = i
    if i + 1 < sc.count, sc[i] == "0", sc[i + 1] == "x" || sc[i + 1] == "X", i + 2 < sc.count, isHex(sc[i + 2]) {
        start = i + 2
    }
    var j = start
    while j < sc.count, isHex(sc[j]) { j += 1 }
    guard j > start else { return nil }
    // Valeur modulo 2^32 : seuls les 8 derniers chiffres comptent
    var v: UInt32 = 0
    for c in sc[max(start, j - 8)..<j] { v = v << 4 | UInt32(Character(c).hexDigitValue!) }
    return neg ? (0 &- v) : v
}

/// parseFloat de JavaScript (nil si NaN)
public func jsParseFloat(_ s: String) -> Double? {
    let sc = Array(s.unicodeScalars)
    var i = 0
    while i < sc.count, isPySpace(sc[i]) { i += 1 }
    var txt = ""
    if i < sc.count, sc[i] == "+" || sc[i] == "-" { txt.unicodeScalars.append(sc[i]); i += 1 }
    func digit(_ k: Int) -> Bool { k < sc.count && sc[k].value >= 48 && sc[k].value <= 57 }
    if i + 8 <= sc.count, String(String.UnicodeScalarView(sc[i..<(i + 8)])) == "Infinity" {
        return txt == "-" ? -Double.infinity : Double.infinity
    }
    var j = i
    var body = ""
    if digit(j) {
        while digit(j) { body.unicodeScalars.append(sc[j]); j += 1 }
        if j < sc.count, sc[j] == "." {
            body += "."; j += 1
            while digit(j) { body.unicodeScalars.append(sc[j]); j += 1 }
        }
    } else if j < sc.count, sc[j] == ".", digit(j + 1) {
        body += "."; j += 1
        while digit(j) { body.unicodeScalars.append(sc[j]); j += 1 }
    } else {
        return nil
    }
    // exposant : seulement s'il est complet
    if j < sc.count, sc[j] == "e" || sc[j] == "E" {
        var k = j + 1
        var e = "e"
        if k < sc.count, sc[k] == "+" || sc[k] == "-" { e.unicodeScalars.append(sc[k]); k += 1 }
        if digit(k) {
            while digit(k) { e.unicodeScalars.append(sc[k]); k += 1 }
            body += e
        }
    }
    return strtod(txt + body, nil)
}

/// struct.pack("<f", v) : float 32 bits (arrondi au plus proche, ±inf en cas de dépassement).
public func f32(_ v: Double) -> Bytes {
    let f = Float(v)
    return withUnsafeBytes(of: f.bitPattern.littleEndian) { Array($0) }
}

public func floatOf(_ d: Bytes, _ p: Int = 0) -> Float {
    Float(bitPattern: u32s(d, p))
}

/// Équivalent de f"{x:.7g}" de Python pour un float32.
public func fmtG7(_ f: Float) -> String {
    let v = Double(f)
    if v.isNaN { return "nan" }
    if v.isInfinite { return v < 0 ? "-inf" : "inf" }
    return String(format: "%.7g", v)
}

public func u32Hint(_ d: Bytes) -> String {
    guard d.count == 4 else { return "" }
    let u = u32s(d)
    return "u32 \(u) · i32 \(Int32(bitPattern: u)) · f32 \(fmtG7(floatOf(d))) · form \(hexs(u))"
}
