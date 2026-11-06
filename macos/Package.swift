// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pLUGINSLENS",
    platforms: [.macOS(.v15)],
    targets: [
        // zlib du système (libz)
        .systemLibrary(name: "CZlib"),
        // Lecture, écriture et modification des plugins Skyrim, sans interface (testable seul)
        .target(name: "LensCore", dependencies: ["CZlib"]),
        // Petit exécutable de parité : rejoue le scénario de tests/test_parity.py et imprime les empreintes SHA-256
        .executableTarget(name: "lens-parity", dependencies: ["LensCore"]),
        .executableTarget(name: "pLUGINSLENS", dependencies: ["LensCore"]),
        .testTarget(name: "LensCoreTests", dependencies: ["LensCore"]),
    ],
    swiftLanguageModes: [.v5]
)
