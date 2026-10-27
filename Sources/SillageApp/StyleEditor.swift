import AppKit
import SillageCore
import SillageRender
import SwiftUI

/// Where a scene's style is chosen: the take playing in the canvas with its transport under it,
/// the inspector on the right, and the top bar that makes the style the scene's.
struct StyleEditor: View {
    @ObservedObject var session: StyleSession
    /// Back to the scene's page.
    let leave: () -> Void
    /// Opens the take again once something else has taken the canvas.
    let reopen: () -> Void
    @State private var optionMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            StyleTopBar(session: session, leave: leave)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    StyleCanvas(session: session, reopen: reopen)
                        .frame(minWidth: 560, minHeight: 360)
                    Divider()
                    TransportBar(model: session.model)
                        .disabled(!session.isOpen)
                }
                Divider()
                ScrollView {
                    StyleInspector(session: session).padding(14)
                }
                .frame(width: 340)
            }
        }
        .panelSurface()
        .onAppear(perform: watchOption)
        .onDisappear {
            if let optionMonitor { NSEvent.removeMonitor(optionMonitor) }
            optionMonitor = nil
            session.showSaved(false)
        }
    }

    /// Holding ⌥ shows the saved style, wherever the keyboard is.
    private func watchOption() {
        guard optionMonitor == nil else { return }
        let session = self.session
        optionMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let held = event.modifierFlags.contains(.option)
            MainActor.assumeIsolated { session.showSaved(held) }
            return event
        }
    }
}

/// The scene, whether the style differs from `look.json`, Avant/Après, Annuler and the step's
/// own button: Utiliser pour la scène until the style is the scene's, then Exporter….
struct StyleTopBar: View {
    @ObservedObject var session: StyleSession
    let leave: () -> Void
    @Environment(\.queue) private var queue
    @State private var exporting = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.scene.name).font(.title2.bold().monospacedDigit())
                Text("Style · \(session.scene.batch)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.secondary)
            }
            if session.covered != nil {
                badge("Style enregistré", Color.accentColor)
            } else if session.isModified {
                badge("Modifié", Palette.warning)
            }
            Spacer()
            BeforeAfterButton(session: session)
            Button(session.isModified ? "Annuler" : "Fermer") {
                session.cancel()
                leave()
            }
            .help(
                session.isModified
                    ? "Abandonne les changements et revient à la page de la scène"
                    : "Revient à la page de la scène")
            primary
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var primary: some View {
        if session.isModified || !session.promoted {
            Button("Utiliser pour la scène") { session.promote() }
                .buttonStyle(.borderedProminent)
                .disabled(session.scene.folder == nil || !session.isOpen || session.covered != nil)
                .help(
                    session.scene.folder == nil
                        ? "Cette haute résolution n'a pas de dossier de scène"
                        : "Écrit ce style dans look.json (⌘S). Le premier style remplacé reste dans look-raw.json."
                )
        } else {
            Button("Exporter…") { exporting = true }
                .buttonStyle(.borderedProminent)
                .disabled(queue == nil || session.scene.folder == nil)
                .help("Choisir les formats ; chaque export rejoint la file d'attente")
                .sheet(isPresented: $exporting) {
                    if let queue, let folder = session.scene.folder {
                        ExportSheet(queue: queue, folders: [folder]) { exporting = false }
                    }
                }
        }
    }

    private func badge(_ text: String, _ colour: Color) -> some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(colour.opacity(0.22)))
            .overlay(Capsule().strokeBorder(colour, lineWidth: 1))
    }
}

/// Shows the saved style for as long as it is held.
struct BeforeAfterButton: View {
    @ObservedObject var session: StyleSession

    var body: some View {
        let usable = session.saved != nil && session.isOpen && (session.isModified || session.covered != nil)
        Label("Avant / Après", systemImage: "rectangle.lefthalf.inset.filled")
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(session.covered != nil ? Color.accentColor.opacity(0.35) : Palette.card)
            )
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(white: 0.3), lineWidth: 1))
            .opacity(usable ? 1 : 0.45)
            .contentShape(Rectangle())
            .onLongPressGesture(
                minimumDuration: 3600, maximumDistance: 10_000, perform: {},
                onPressingChanged: { pressing in if usable || !pressing { session.showSaved(pressing) } }
            )
            .help("Maintenir (ou maintenir ⌥) pour voir le style enregistré")
    }
}

/// The take on the canvas, or what is in the way of it.
struct StyleCanvas: View {
    @ObservedObject var session: StyleSession
    let reopen: () -> Void

    var body: some View {
        ZStack {
            Palette.canvas
            if session.isOpen {
                // Left out of the hierarchy rather than hidden, as in the workshop.
                MetalCanvas(model: session.model).background(.black)
            } else if session.model.fileActivity != nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Ouverture de la haute résolution…")
                        .font(.callout)
                        .foregroundStyle(Palette.secondary)
                }
            } else {
                VStack(spacing: 10) {
                    Text(
                        session.model.failure
                            ?? "La haute résolution de cette scène n'est plus ouverte."
                    )
                    .font(.callout)
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                    Button("Rouvrir la haute résolution", action: reopen)
                        .disabled(session.scene.take == nil)
                }
                .padding(30)
            }
        }
    }
}

/// Play, pause, speed and the playhead. Watches the model, which moves on every frame.
struct TransportBar: View {
    @ObservedObject var model: SimulationModel

    static let speeds: [(label: String, framesPerSecond: Float)] = [
        ("× 0,25", 7.5), ("× 0,5", 15), ("× 1", 30), ("× 2", 60), ("× 4", 120),
    ]

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.isPlaying.toggle()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(model.isPlaying ? "Pause (espace)" : "Lecture (espace)")
            Slider(
                value: $model.playbackPosition,
                in: 0...Double(max(model.capturedFrames - 1, 1)))
            Text(String(format: "%.0f Myr", model.elapsedMyr))
                .font(.callout.monospacedDigit())
                .frame(minWidth: 70, alignment: .trailing)
            Picker("Vitesse", selection: speed) {
                ForEach(Self.speeds, id: \.framesPerSecond) { Text($0.label).tag($0.framesPerSecond) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Vitesse de lecture, × 1 à 30 images par seconde")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// The nearest speed offered, so a speed set in the workshop still shows one.
    private var speed: Binding<Float> {
        Binding(
            get: {
                Self.speeds.min {
                    abs($0.framesPerSecond - model.playbackSpeed)
                        < abs($1.framesPerSecond - model.playbackSpeed)
                }?
                .framesPerSecond ?? 30
            },
            set: { model.playbackSpeed = $0 })
    }
}

/// Rendu, Palette, Caméra and the fine settings folded under them.
struct StyleInspector: View {
    @ObservedObject var session: StyleSession
    /// Drawn offscreen by the checks, which cannot draw pickers, and with every control live.
    var snapshot = false
    @State var fineShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let note = session.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(
                        note.hasPrefix("Auto :") || note.hasPrefix("Favori gardé")
                            || note.hasPrefix("Favori retiré") ? Palette.label : Palette.warning
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
            RenderingSection(session: session, thumbnails: session.thumbnails)
            Divider()
            PaletteSection(session: session)
            Divider()
            CameraSection(session: session)
            Divider()
            FineSettings(session: session, shown: $fineShown)
        }
        .disabled(!snapshot && (!session.isOpen || session.covered != nil))
        .environment(\.offscreen, snapshot)
    }
}

/// The catalogue's looks as renderings, each a thumbnail of the frame on the canvas: a click
/// puts the light, the instrument and the buffers on the picture and keeps the palette; "Avec
/// ses couleurs" takes the look's colours too.
struct RenderingSection: View {
    @ObservedObject var session: StyleSession
    @ObservedObject var thumbnails: StyleThumbnails
    @Environment(\.offscreen) private var offscreen

    var body: some View {
        let current = session.rendering
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Rendu").font(.headline)
                Spacer()
                Text(current.map { StyleNames.rendering($0.name) } ?? "retouché")
                    .font(.callout)
                    .foregroundStyle(Palette.secondary)
                if offscreen {
                    // ImageRenderer draws a borderless button as a blank.
                    Text("↻").font(.callout).foregroundStyle(Palette.secondary)
                } else {
                    Button {
                        thumbnails.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(thumbnails.drawing)
                    .help("Redessiner les vignettes sur l'image et le cadrage affichés")
                }
            }
            group("Télescope", world: .telescope, current: current)
            group("Libre", world: .free, current: current)
            if let current {
                Text(StyleNames.traits(current))
                    .font(.caption2)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Avec ses couleurs") { session.apply(current, colours: true) }
                    .controlSize(.small)
                    .disabled(current.palette.isEmpty || session.current.palette == current.palette)
                    .help("Prend aussi la palette de ce rendu, à la place de la palette actuelle")
            } else {
                Text(
                    "Retouché dans les réglages fins, d'après « \(StyleNames.rendering(session.current.name)) »."
                )
                .font(.caption2)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, world: SillageRender.Palette.World, current: LookFile?) -> some View {
        let files = LookCatalogue.renderings(world, in: session.catalogue)
        if !files.isEmpty {
            Text(title).font(.caption).foregroundStyle(Palette.secondary)
            TileRows(count: files.count, columns: 3) { index in
                tile(files[index], selected: files[index].name == current?.name)
            }
        }
    }

    /// A third of the 340 pt inspector, less the gaps.
    static let thumbnailWidth = 96.0

    private func tile(_ file: LookFile, selected: Bool) -> some View {
        Button {
            session.apply(file)
        } label: {
            VStack(spacing: 2) {
                Rectangle().fill(Color.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: (Self.thumbnailWidth / thumbnails.aspectRatio).rounded())
                    .overlay {
                        if let image = thumbnails.images[file.name] {
                            Image(decorative: image, scale: 2).resizable().scaledToFill()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(StyleNames.rendering(file.name))
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Color.accentColor.opacity(0.45) : Palette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(selected ? Color.accentColor : Color(white: 0.24), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(StyleNames.traits(file))
        .contextMenu {
            Button("Appliquer") { session.apply(file) }
            Button("Appliquer avec ses couleurs") { session.apply(file, colours: true) }
                .disabled(file.palette.isEmpty)
        }
    }
}

/// A grid drawn without a lazy container, which offscreen rendering leaves blank.
struct TileRows<Tile: View>: View {
    let count: Int
    let columns: Int
    @ViewBuilder let tile: (Int) -> Tile

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(stride(from: 0, to: count, by: columns)), id: \.self) { start in
                HStack(spacing: 4) {
                    ForEach(start..<start + columns, id: \.self) { index in
                        if index < count {
                            tile(index)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                        }
                    }
                }
            }
        }
    }
}

/// The world, one swatch and lock per galaxy, six proposals, "Autres palettes" and Auto.
struct PaletteSection: View {
    @ObservedObject var session: StyleSession
    @State private var name = ""
    @Environment(\.offscreen) private var offscreen

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Palette").font(.headline)
                Spacer()
                if offscreen {
                    Text(StyleNames.world(session.world)).font(.callout)
                } else {
                    Picker("Monde", selection: $session.world) {
                        Text("Télescope").tag(SillageRender.Palette.World.telescope)
                        Text("Libre").tag(SillageRender.Palette.World.free)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Télescope : proche des images de Hubble et Webb. Libre : pour la beauté seule.")
                }
            }
            CheckToggle(
                title: "Multicolore",
                isOn: Binding(get: { session.multicolour }, set: { session.setMulticolour($0) })
            )
            .help(
                "Chaque galaxie prend plusieurs couleurs, du cœur aux bords, aux jeunes étoiles et aux nœuds. Éteint, elle garde une seule couleur."
            )
            HStack(alignment: .top) {
                galaxies
                Spacer()
                if let recipe = session.current.paletteRecipe { heart(recipe).padding(.top, 4) }
            }
            proposals
            HStack {
                Button("Autres palettes") { session.moreProposals() }
                    .help("Six autres propositions, les meilleures d'un nouveau tirage")
                Spacer()
                Button {
                    session.runAuto()
                } label: {
                    HStack(spacing: 6) {
                        if session.autoRunning { ProgressView().controlSize(.small) }
                        Text("Auto")
                    }
                }
                .disabled(session.autoRunning || session.scene.folder == nil)
                .help(
                    "Choisit le rendu et la palette qui notent le mieux sur trois images clés de la haute résolution, dans ce monde. Les cadenas tiennent."
                )
            }
            .controlSize(.small)
        }
        .alert(
            "Nom de la palette",
            isPresented: Binding(
                get: { session.naming != nil }, set: { if !$0 { session.naming = nil } })
        ) {
            TextField("Nom", text: $name)
            Button("Garder") {
                if let palette = session.naming { session.saveFavourite(palette, named: name) }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Elle sera gardée dans palettes/ du dépôt, et proposée en premier.")
        }
        .onChange(of: session.naming) { _, palette in name = palette?.name ?? "" }
    }

    private var galaxies: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(0..<session.galaxyCount, id: \.self) { index in
                VStack(spacing: 4) {
                    swatch(index)
                    Button {
                        session.toggleLock(index)
                    } label: {
                        Image(systemName: session.locked.contains(index) ? "lock.fill" : "lock.open")
                            .foregroundStyle(
                                session.locked.contains(index) ? Palette.label : Palette.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(
                        session.locked.contains(index)
                            ? "Galaxie \(index + 1) : sa couleur reste"
                            : "Garder la couleur de la galaxie \(index + 1) quand la palette change")
                    Text("\(index + 1)").font(.caption2).foregroundStyle(Palette.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func swatch(_ index: Int) -> some View {
        let colour = session.current.colour(ofGalaxy: index, in: session.model.scene)
        VStack(spacing: 3) {
            if index < session.current.palette.count, session.current.palette[index].ramp != nil {
                RampSwatch(entry: session.current.palette[index], width: 38, height: 8)
            }
            colourPicker(index, colour)
        }
    }

    @ViewBuilder
    private func colourPicker(_ index: Int, _ colour: SIMD3<Float>) -> some View {
        if offscreen {
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearColour.color(colour))
                .frame(width: 38, height: 22)
        } else {
            ColorPicker(
                "Galaxie \(index + 1)",
                selection: Binding(
                    get: { LinearColour.color(colour) },
                    set: { session.setColour(LinearColour.simd($0), ofGalaxy: index) }),
                supportsOpacity: false
            )
            .labelsHidden()
            .help("Galaxie \(index + 1) : un clic ouvre le sélecteur de couleur")
        }
    }

    @ViewBuilder private var proposals: some View {
        if let note = session.proposalNote {
            Text(note).font(.caption).foregroundStyle(Palette.secondary)
        } else {
            VStack(spacing: 4) {
                ForEach(Array(session.proposals.enumerated()), id: \.offset) { _, ranked in
                    proposal(ranked)
                }
            }
        }
    }

    private func proposal(_ ranked: PaletteAuto.Ranked) -> some View {
        let chosen = session.current.paletteRecipe == ranked.palette
        return HStack(spacing: 8) {
            Button {
                session.use(ranked.palette)
            } label: {
                HStack(spacing: 8) {
                    proposalSwatches(ranked.palette)
                    Text("\(ranked.palette.family) · \(StyleNames.harmony(ranked.palette.harmony))")
                        .font(.caption)
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(StyleNames.number(ranked.score.total))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                "La note de la palette seule, de 0 à 1. Un clic l'applique, sauf aux couleurs sous cadenas.")
            heart(ranked.palette)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(chosen ? Color.accentColor.opacity(0.3) : Palette.card)
        )
    }

    /// A dot per galaxy, or its ramp when the palette has them.
    @ViewBuilder
    private func proposalSwatches(_ palette: SillageRender.Palette) -> some View {
        if palette.multicolour {
            HStack(spacing: 5) {
                ForEach(
                    Array(palette.galaxyColours(references: session.references).enumerated()),
                    id: \.offset
                ) { _, entry in
                    RampSwatch(entry: entry, width: 30, height: 14)
                }
            }
        } else {
            Swatches(colours: palette.colours)
        }
    }

    /// Full on a favourite, which a click takes out of `palettes/`; empty on any other, which
    /// a click keeps under a name.
    @ViewBuilder
    private func heart(_ palette: SillageRender.Palette) -> some View {
        let kept = session.isFavourite(palette)
        let image = Image(systemName: kept ? "heart.fill" : "heart")
            .foregroundStyle(kept ? Palette.warning : Palette.secondary)
        if offscreen {
            image
        } else {
            Button {
                session.toggleFavourite(palette)
            } label: {
                image
            }
            .buttonStyle(.plain)
            .help(
                kept
                    ? "Favori : un clic la retire de palettes/"
                    : "Garder cette palette dans palettes/, en tête des propositions")
        }
    }
}

/// One galaxy's colours as a bar from its core to its outskirts, ending on the colours of its
/// young stars and its knots; a single colour is a plain bar of it.
struct RampSwatch: View {
    let entry: GalaxyColours
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let colours = entry.swatches.map(LinearColour.color)
        HStack(spacing: 0) {
            if colours.count == 5 {
                LinearGradient(
                    colors: Array(colours[0..<3]), startPoint: .leading, endPoint: .trailing
                )
                .frame(width: width * 0.7)
                colours[3].frame(width: width * 0.15)
                colours[4].frame(width: width * 0.15)
            } else {
                colours[0].frame(width: width)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: height / 3))
        .overlay(RoundedRectangle(cornerRadius: height / 3).strokeBorder(Color(white: 0.3), lineWidth: 1))
        .help(
            colours.count == 5
                ? "Du cœur aux bords, puis les jeunes étoiles et les nœuds" : "Une seule couleur")
    }
}

/// The plan's mode, its zoom and how far it turns over the clip.
struct CameraSection: View {
    @ObservedObject var session: StyleSession
    @Environment(\.offscreen) private var offscreen

    static let modes: [(LookFile.CameraPlan.Mode, String)] = [
        (.auto, "Auto"), (.director, "Réalisateur"), (.fixed, "Fixe"), (.immersed, "Immergé"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Caméra").font(.headline)
            if offscreen {
                Text(Self.modes.first { $0.0 == session.current.camera.mode }?.1 ?? "").font(.callout)
            } else {
                Picker(
                    "Plan",
                    selection: Binding(
                        get: { session.current.camera.mode },
                        set: { session.setCameraMode($0) })
                ) {
                    ForEach(Self.modes, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ParameterSlider(title: "Zoom", value: session.binding(\.camera.zoom), range: 0.2...5)
            ParameterSlider(
                title: "Rotation sur le clip (degrés)",
                value: Binding(
                    get: { session.current.camera.rotation * 180 / .pi },
                    set: { session.binding(\.camera.rotation).wrappedValue = $0 * .pi / 180 }),
                range: -360...360, format: "%.0f")
        }
    }

    private var caption: String {
        switch session.current.camera.mode {
        case .auto: "Suit les galaxies, qui s'éloignent et se rapprochent."
        case .director: "Le réalisateur choisit ses plans en jouant la scène."
        case .fixed: "Cadré une fois sur toute la scène."
        case .immersed: "Le réalisateur, depuis l'intérieur d'un disque."
        }
    }
}

/// Lumière, Instrument, Rendu détaillé and Plan de caméra, folded, each with its reset.
struct FineSettings: View {
    @ObservedObject var session: StyleSession
    @Binding var shown: Bool

    var body: some View {
        DisclosureGroup("Réglages fins", isExpanded: $shown) {
            VStack(alignment: .leading, spacing: 10) {
                FineGroup(session: session, title: "Lumière", group: .light) {
                    LightControls(session: session)
                }
                FineGroup(session: session, title: "Instrument", group: .instrument) {
                    InstrumentControls(session: session)
                }
                FineGroup(session: session, title: "Rendu détaillé", group: .detail) {
                    DetailControls(session: session)
                }
                FineGroup(session: session, title: "Plan de caméra", group: .camera) {
                    PlanControls(session: session)
                }
            }
            .padding(.top, 8)
        }
        .font(.headline)
    }
}

struct FineGroup<Content: View>: View {
    @ObservedObject var session: StyleSession
    let title: String
    let group: LookFile.Group
    @ViewBuilder var content: Content
    @Environment(\.offscreen) private var offscreen
    @State private var shown = false

    var body: some View {
        DisclosureGroup(isExpanded: offscreen ? .constant(true) : $shown) {
            VStack(alignment: .leading, spacing: 8) {
                content
                Button("Réinitialiser") { session.reset(group) }
                    .controlSize(.small)
                    .disabled(!changed)
                    .help(
                        group == .camera
                            ? "Revient au plan du style enregistré"
                            : "Revient aux valeurs du dernier rendu choisi")
            }
            .font(.body)
            .padding(.top, 6)
        } label: {
            Text(title).font(.subheadline.bold())
        }
    }

    private var changed: Bool {
        guard let baseline = session.baseline(for: group) else { return false }
        return session.current.resetting(group, to: baseline) != session.current
    }
}

struct LightControls: View {
    @ObservedObject var session: StyleSession

    var body: some View {
        ParameterSlider(
            title: "Luminosité", value: session.binding(\.look.brightness), range: 0.02...2.0,
            format: "%.2f")
        ParameterSlider(
            title: "Étirement logarithmique", value: session.binding(\.look.stretch), range: 0...60,
            format: "%.0f")
        ParameterSlider(title: "Saturation", value: session.binding(\.look.saturation), range: 0...3)
        ParameterSlider(
            title: "Teinte par galaxie", value: session.binding(\.look.galaxyTint), range: 0...1)
        ParameterSlider(
            title: "Opacité des poussières", value: session.binding(\.look.dustStrength),
            range: 0...1.2, format: "%.3f")
        ParameterSlider(
            title: "Force des bras peints", value: session.binding(\.look.armPersistence), range: 0...2)
    }
}

struct InstrumentControls: View {
    @ObservedObject var session: StyleSession

    var body: some View {
        ParameterSlider(
            title: "Lissage des étoiles", value: session.binding(\.look.smoothingScale), range: 0.4...5.0)
        ParameterSlider(
            title: "Noyau minimal (px)", value: session.binding(\.look.minimumKernel), range: 0.5...6)
        ParameterSlider(
            title: "Noyau maximal (px)", value: session.binding(\.look.maximumKernel), range: 4...160,
            format: "%.0f")
        ParameterSlider(title: "Halo lumineux", value: session.binding(\.look.bloomIntensity), range: 0...2)
        ParameterSlider(
            title: "Seuil du halo", value: session.binding(\.look.bloomThreshold), range: 0.05...1.5)
        ParameterSlider(
            title: "Douceur du seuil", value: session.binding(\.look.bloomSoftKnee), range: 0...1)
        ParameterSlider(
            title: "Aigrettes de diffraction", value: session.binding(\.look.spikeIntensity),
            range: 0...1.5)
        ParameterSlider(
            title: "Branches des aigrettes",
            value: Binding(
                get: { Float(session.current.look.spikeArms) },
                set: { session.binding(\.look.spikeArms).wrappedValue = Int($0.rounded()) }),
            range: 0...8, format: "%.0f")
        ParameterSlider(
            title: "Longueur des aigrettes", value: session.binding(\.look.spikeLength), range: 0...200,
            format: "%.0f")
        ParameterSlider(
            title: "Netteté des aigrettes", value: session.binding(\.look.spikeSharpness), range: 0...1)
        CheckToggle(
            title: "Aigrettes de Webb",
            isOn: Binding(
                get: { session.current.look.spikePattern == .webb },
                set: { session.binding(\.look.spikePattern).wrappedValue = $0 ? .webb : .even }))
        ParameterSlider(
            title: "Taille des étoiles de champ", value: session.binding(\.look.starSize), range: 0.2...4)
        ParameterSlider(
            title: "Point blanc", value: session.binding(\.look.whitePoint), range: 1...20, format: "%.1f")
        ParameterSlider(
            title: "Fond de ciel", value: session.binding(\.look.skyLevel), range: 0...0.006,
            format: "%.4f")
        ParameterSlider(
            title: "Scintillement (bruit du capteur)", value: session.binding(\.look.noiseLevel),
            range: 0...0.004, format: "%.4f")
    }
}

/// The settings that own buffers, so each builds a new renderer: the starfield only on release.
struct DetailControls: View {
    @ObservedObject var session: StyleSession
    @State private var starCount: Float?
    @Environment(\.offscreen) private var offscreen

    var body: some View {
        Text("Ces réglages reconstruisent le rendu, au relâché.")
            .font(.caption2)
            .foregroundStyle(Palette.secondary)
        ParameterSlider(
            title: "Étoiles de champ",
            value: Binding(
                get: { starCount ?? Float(session.current.starCount) },
                set: { starCount = $0.rounded() }),
            range: 0...60_000, format: "%.0f",
            onCommit: {
                if let starCount { session.binding(\.starCount).wrappedValue = Int(starCount) }
                starCount = nil
            })
        if offscreen {
            Text("Niveaux du halo : \(session.current.bloomLevels)").font(.caption)
        } else {
            Stepper(
                "Niveaux du halo : \(session.current.bloomLevels)", value: session.binding(\.bloomLevels),
                in: 1...8
            )
            .font(.caption)
        }
        if offscreen {
            Text("Suréchantillonnage \(session.current.supersample)×").font(.caption)
        } else {
            HStack {
                Text("Suréchantillonnage").font(.caption)
                Picker("Suréchantillonnage", selection: session.binding(\.supersample)) {
                    ForEach(1...4, id: \.self) { Text("\($0)×").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        ParameterSlider(
            title: "Force des bras (fichier)", value: session.binding(\.armStrength), range: 0...2)
        CheckToggle(title: "Points bruts", isOn: session.binding(\.plain))
    }
}

/// The whole camera plan, and whether the canvas draws through it.
struct PlanControls: View {
    @ObservedObject var session: StyleSession

    var body: some View {
        CheckToggle(
            title: "Voir à travers le plan",
            isOn: Binding(
                get: { session.model.followsPlan },
                set: { session.model.followsPlan = $0 })
        )
        .help("Dessine l'image comme le rendu la cadrera, pour les plans Auto et Fixe")
        ParameterSlider(
            title: "Ouverture de l'objectif", value: session.binding(\.look.fieldOfView), range: 0.2...1.4)
        ParameterSlider(
            title: "Élévation (rad)", value: session.binding(\.camera.elevation), range: -1.5...1.5)
        PlanEndSlider(
            title: "Élévation de fin", start: session.current.camera.elevation,
            end: session.binding(\.camera.elevationEnd), range: -1.5...1.5)
        ParameterSlider(
            title: "Azimut (rad)", value: session.binding(\.camera.azimuth), range: -6.3...6.3)
        PlanEndSlider(
            title: "Azimut de fin", start: session.current.camera.azimuth,
            end: session.binding(\.camera.azimuthEnd), range: -12.6...12.6)
        ParameterSlider(
            title: "Part des particules cadrées", value: session.binding(\.camera.percentile),
            range: 0.5...1, format: "%.3f")
        ParameterSlider(
            title: "Rayon cadré (kpc, 0 = mesuré)", value: session.binding(\.camera.radius),
            range: 0...300, format: "%.0f")
    }
}

/// An end angle that may be absent, in which case the camera holds its start.
struct PlanEndSlider: View {
    let title: String
    let start: Float
    @Binding var end: Float?
    let range: ClosedRange<Float>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            CheckToggle(title: title, isOn: Binding(get: { end != nil }, set: { end = $0 ? start : nil }))
            if end != nil {
                ParameterSlider(
                    title: "", value: Binding(get: { end ?? start }, set: { end = $0 }), range: range)
            }
        }
    }
}

/// Galaxy colours as the look file keeps them, in linear sRGB.
enum LinearColour {
    private static var space: NSColorSpace? {
        CGColorSpace(name: CGColorSpace.linearSRGB).flatMap(NSColorSpace.init)
    }

    static func color(_ value: SIMD3<Float>) -> Color {
        Color(.sRGBLinear, red: Double(value.x), green: Double(value.y), blue: Double(value.z))
    }

    static func simd(_ color: Color) -> SIMD3<Float> {
        guard let space, let linear = NSColor(color).usingColorSpace(space) else { return SIMD3(1, 1, 1) }
        return SIMD3(
            Float(linear.redComponent), Float(linear.greenComponent), Float(linear.blueComponent))
    }
}
