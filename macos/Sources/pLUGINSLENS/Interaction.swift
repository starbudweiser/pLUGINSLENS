// Survol, sélection et textes longs : règles « États » de Socle (survol et sélection sans encadré).
// Survol = fond neutre surface-hover, sélection = surface-selected, transition de 120 à 150 ms, coupée si l'utilisateur
// a demandé de réduire les animations. Le contour focus-ring reste réservé au focus clavier (dessiné par le système).

import AppKit
import SwiftUI

enum Interaction {
    /// Durée des transitions de couleur (s).
    static let duration: Double = 0.13

    /// « Réduire les animations » est-il actif ? (hors SwiftUI : arbre AppKit)
    @MainActor static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Style de bouton pour une ligne cliquable (liste de résultats, lien d'enregistrement) : fond neutre au survol et à
/// l'appui, ou à la sélection, sans contour ni teinte d'accent. Le focus clavier reste celui du système.
struct SocleSelectableStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        RowBody(label: configuration.label, pressed: configuration.isPressed, selected: selected)
    }

    private struct RowBody: View {
        let label: ButtonStyleConfiguration.Label
        let pressed: Bool
        let selected: Bool
        @State private var hover = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            label
                .background(pressed || selected ? Socle.C.surfaceSelected : hover ? Socle.C.surfaceHover : Color.clear)
                .onHover { hover = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: Interaction.duration), value: hover)
                .animation(reduceMotion ? nil : .easeOut(duration: Interaction.duration), value: pressed)
        }
    }
}

extension View {
    /// Texte long (nom de plugin, EditorID) : une seule ligne, tronqué au milieu, texte complet en infobulle.
    func socleMiddleTruncated(_ full: String) -> some View {
        lineLimit(1).truncationMode(.middle).help(full)
    }

    /// Nombre qui change : chiffres tabulaires et transition numérique (coupée si « Réduire les animations »).
    func socleNumber<V: Equatable>(value: V) -> some View { modifier(NumberTransition(value: value)) }
}

private struct NumberTransition<V: Equatable>: ViewModifier {
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : .easeOut(duration: Interaction.duration), value: value)
    }
}

/// Ligne de l'arbre (NSOutlineView) : fond neutre au survol (surface-hover) et à la sélection (surface-selected),
/// fondu de 130 ms, sans contour.
final class SocleRowView: NSTableRowView {
    private let hoverLayer = CALayer()
    private var area: NSTrackingArea?
    private var hovering = false
    private let hoverable: Bool

    init(hoverable: Bool) {
        self.hoverable = hoverable
        super.init(frame: .zero)
        wantsLayer = true
        hoverLayer.opacity = 0
        layer?.insertSublayer(hoverLayer, at: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isSelected: Bool { didSet { refreshHover(animated: false) } }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(Socle.C.surfaceSelected).setFill()
        bounds.fill()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            hoverLayer.backgroundColor = NSColor(Socle.C.surfaceHover).cgColor
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeEffectiveAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        guard hoverable else { return }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refreshHover(animated: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; refreshHover(animated: true) }

    private func refreshHover(animated: Bool) {
        let on = hovering && !isSelected && hoverable
        CATransaction.begin()
        if animated && !Interaction.reduceMotion {
            CATransaction.setAnimationDuration(Interaction.duration)
        } else {
            CATransaction.setDisableActions(true)
        }
        hoverLayer.opacity = on ? 1 : 0
        CATransaction.commit()
    }
}
