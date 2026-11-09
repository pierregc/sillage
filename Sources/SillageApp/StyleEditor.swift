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
                    CanvasLegend(session: session)
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

/// The scene, whether the style differs from `look.json`, Before / After, Cancel and the step's
/// own button: Use for scene until the style is the scene's, then Export….
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
                badge("Saved style", Color.accentColor)
            } else if session.isModified {
                badge("Modified", Palette.warning)
            }
            Spacer()
            BeforeAfterButton(session: session)
            Button(session.isModified ? "Cancel" : "Close") {
                session.cancel()
                leave()
            }
            .help(
                session.isModified
                    ? "Discards the changes and goes back to the scene's page"
                    : "Goes back to the scene's page")
            primary
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var primary: some View {
        if session.isModified || !session.promoted {
            Button("Use for scene") { session.promote() }
                .buttonStyle(.borderedProminent)
                .disabled(session.scene.folder == nil || !session.isOpen || session.covered != nil)
                .help(
                    session.scene.folder == nil
                        ? "This high resolution has no scene folder"
                        : "Writes this style to look.json (⌘S). The first style replaced stays in look-raw.json."
                )
        } else {
            Button("Export…") { exporting = true }
                .buttonStyle(.borderedProminent)
                .disabled(queue == nil || session.scene.folder == nil)
                .help("Choose the formats; each export joins the queue")
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
        Label("Before / After", systemImage: "rectangle.lefthalf.inset.filled")
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
            .help("Hold (or hold ⌥) to see the saved style")
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
                // Left out of the hierarchy rather than hidden, as in the workshop. In the clip's
                // shape, so the canvas frames the rectangle a 16:9 export does.
                MetalCanvas(model: session.model).background(.black)
                    .aspectRatio(session.thumbnails.aspectRatio, contentMode: .fit)
            } else if session.model.fileActivity != nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Opening the high resolution…")
                        .font(.callout)
                        .foregroundStyle(Palette.secondary)
                }
            } else {
                VStack(spacing: 10) {
                    Text(
                        session.model.failure
                            ?? "This scene's high resolution is no longer open."
                    )
                    .font(.callout)
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                    Button("Reopen the high resolution", action: reopen)
                        .disabled(session.scene.take == nil)
                }
                .padding(30)
            }
        }
    }
}

/// What the canvas shows and what the mouse does there: the export keeps the plan, so a view
/// the plan does not hold is said to be lost.
struct CanvasLegend: View {
    @ObservedObject var session: StyleSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.model.followsPlan ? "video" : "eye")
            Text(text).lineLimit(2)
            Spacer(minLength: 8)
            if !session.model.followsPlan {
                Button("Back to the camera plan") { session.model.followsPlan = true }
                    .controlSize(.small)
            } else if ![.fixed, .auto].contains(session.current.camera.mode) {
                Button("Switch to Fixed") { session.setCameraMode(.fixed) }
                    .controlSize(.small)
                    .help("One framing for the whole clip, set with the mouse")
            }
        }
        .font(.caption)
        .foregroundStyle(Palette.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .disabled(!session.isOpen)
    }

    private var text: String {
        guard session.model.followsPlan else {
            return "Free view: the export does not keep it, it follows the camera plan."
        }
        let shape = session.frameShape
        switch session.current.camera.mode {
        case .fixed, .auto:
            return "Export framing (\(shape)): drag turns the camera, scroll sets the "
                + "zoom, and this framing is what gets saved."
        case .director:
            return "Director's shots, as in the export (\(shape)): drag turns its wide "
                + "shots, scroll brings them closer; it frames the close-ups itself."
        case .immersed:
            return "Director's shots from inside a disk, as in the export (\(shape)): it chooses "
                + "where to look, scroll sets the zoom."
        }
    }
}

/// Play, pause, speed and the playhead. Watches the model, which moves on every frame.
struct TransportBar: View {
    @ObservedObject var model: SimulationModel

    static let speeds: [(label: String, framesPerSecond: Float)] = [
        ("× 0.25", 7.5), ("× 0.5", 15), ("× 1", 30), ("× 2", 60), ("× 4", 120),
    ]

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.isPlaying.toggle()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(model.isPlaying ? "Pause (space)" : "Play (space)")
            Slider(
                value: $model.playbackPosition,
                in: 0...Double(max(model.capturedFrames - 1, 1)))
            Text(String(format: "%.0f Myr", model.elapsedMyr))
                .font(.callout.monospacedDigit())
                .frame(minWidth: 70, alignment: .trailing)
            Picker("Speed", selection: speed) {
                ForEach(Self.speeds, id: \.framesPerSecond) { Text($0.label).tag($0.framesPerSecond) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Playback speed, × 1 being 30 frames per second")
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

/// Rendering, Palette, Camera and the fine settings folded under them.
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
                        note.hasPrefix("Auto:") || note.hasPrefix("Favourite kept")
                            || note.hasPrefix("Favourite removed") ? Palette.label : Palette.warning
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
                Text("Rendering").font(.headline)
                Spacer()
                Text(current.map { StyleNames.rendering($0.name) } ?? "tweaked")
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
                    .help("Redraw the thumbnails on the frame and framing shown")
                }
            }
            group("Telescope", world: .telescope, current: current)
            group("Free", world: .free, current: current)
            if let current {
                Text(StyleNames.traits(current))
                    .font(.caption2)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("With its colours") { session.apply(current, colours: true) }
                    .controlSize(.small)
                    .disabled(current.palette.isEmpty || session.current.palette == current.palette)
                    .help("Also takes this rendering's palette, in place of the current one")
            } else {
                Text(
                    "Tweaked in the fine settings, from “\(StyleNames.rendering(session.current.name))”."
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
            Button("Apply") { session.apply(file) }
            Button("Apply with its colours") { session.apply(file, colours: true) }
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
                    Picker("World", selection: $session.world) {
                        Text("Telescope").tag(SillageRender.Palette.World.telescope)
                        Text("Free").tag(SillageRender.Palette.World.free)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Telescope: close to Hubble and Webb images. Free: for beauty alone.")
                }
            }
            CheckToggle(
                title: "Multicolour",
                isOn: Binding(get: { session.multicolour }, set: { session.setMulticolour($0) })
            )
            .help(
                "Each galaxy takes several colours, from core to outskirts, young stars and knots. Off, it keeps a single colour."
            )
            HStack(alignment: .top) {
                galaxies
                Spacer()
                if let recipe = session.current.paletteRecipe { heart(recipe).padding(.top, 4) }
            }
            proposals
            HStack {
                Button("More palettes") { session.moreProposals() }
                    .help("Six more proposals, the best of a new draw")
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
                    "Picks the rendering and palette that score best on three key frames of the high resolution, in this world. Locks hold."
                )
            }
            .controlSize(.small)
        }
        .alert(
            "Palette name",
            isPresented: Binding(
                get: { session.naming != nil }, set: { if !$0 { session.naming = nil } })
        ) {
            TextField("Name", text: $name)
            Button("Keep") {
                if let palette = session.naming { session.saveFavourite(palette, named: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will be kept in the repository's palettes/ and proposed first.")
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
                            ? "Galaxy \(index + 1): its colour stays"
                            : "Keep galaxy \(index + 1)'s colour when the palette changes")
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
                "Galaxy \(index + 1)",
                selection: Binding(
                    get: { LinearColour.color(colour) },
                    set: { session.setColour(LinearColour.simd($0), ofGalaxy: index) }),
                supportsOpacity: false
            )
            .labelsHidden()
            .help("Galaxy \(index + 1): a click opens the colour picker")
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
                "The palette's own score, from 0 to 1. A click applies it, except to locked colours.")
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
                    ? "Favourite: a click removes it from palettes/"
                    : "Keep this palette in palettes/, at the top of the proposals")
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
                ? "From core to outskirts, then young stars and knots" : "A single colour")
    }
}

/// The plan's mode, its zoom and how far it turns over the clip.
struct CameraSection: View {
    @ObservedObject var session: StyleSession
    @Environment(\.offscreen) private var offscreen

    static let modes: [(LookFile.CameraPlan.Mode, String)] = [
        (.auto, "Auto"), (.director, "Director"), (.fixed, "Fixed"), (.immersed, "Immersed"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Camera").font(.headline)
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
            ParameterSlider(
                title: "Zoom",
                value: Binding(
                    get: { log2(session.current.camera.zoom) },
                    set: { session.binding(\.camera.zoom).wrappedValue = exp2($0) }),
                range: Self.octaves, reading: { Self.reading(zoom: exp2($0)) })
            ParameterSlider(
                title: "Rotation over the clip (degrees)",
                value: Binding(
                    get: { session.current.camera.rotation * 180 / .pi },
                    set: { session.binding(\.camera.rotation).wrappedValue = $0 * .pi / 180 }),
                range: -360...360, format: "%.0f"
            )
            .disabled(!session.current.camera.placesCamera)
        }
    }

    private var caption: String {
        switch session.current.camera.mode {
        case .auto:
            "Follows the galaxies as they draw apart and close in. On the image, drag turns the "
                + "camera and scroll sets the zoom."
        case .director:
            "Wide shots and close-ups of a disk and of the encounter, chosen by the "
                + "director. On the image, drag turns its wide shots and scroll brings them "
                + "closer; the close-ups it frames itself."
        case .fixed:
            "Framed once on the whole scene. On the image, drag turns the camera and "
                + "scroll sets the zoom."
        case .immersed:
            "The director, from inside a disk: it chooses where to look, the zoom "
                + "moves it away from or towards the disk's centre."
        }
    }

    /// The zoom in octaves, so one sits in the middle and twice as far is as far as twice as close.
    private static let octaves: ClosedRange<Float> = {
        let zoom = LookFile.CameraPlan.zoomRange
        return log2(zoom.lowerBound)...log2(zoom.upperBound)
    }()

    /// The zoom said as distance, since below one the camera stands further back.
    static func reading(zoom: Float) -> String {
        let times = StyleNames.oneDecimal
        if abs(zoom - 1) < 0.005 { return "× 1 · the measured framing" }
        return zoom < 1
            ? "× \(StyleNames.number(zoom)) · \(times(1 / zoom)) times further"
            : "× \(StyleNames.number(zoom)) · \(times(zoom)) times closer"
    }
}

/// Light, Instrument, Detailed rendering and Camera plan, folded, each with its reset.
struct FineSettings: View {
    @ObservedObject var session: StyleSession
    @Binding var shown: Bool

    var body: some View {
        DisclosureGroup("Fine settings", isExpanded: $shown) {
            VStack(alignment: .leading, spacing: 10) {
                FineGroup(session: session, title: "Light", group: .light) {
                    LightControls(session: session)
                }
                FineGroup(session: session, title: "Instrument", group: .instrument) {
                    InstrumentControls(session: session)
                }
                FineGroup(session: session, title: "Detailed rendering", group: .detail) {
                    DetailControls(session: session)
                }
                FineGroup(session: session, title: "Camera plan", group: .camera) {
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
                Button("Reset") { session.reset(group) }
                    .controlSize(.small)
                    .disabled(!changed)
                    .help(
                        group == .camera
                            ? "Back to the saved style's camera plan"
                            : "Back to the values of the last rendering chosen")
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
            title: "Brightness", value: session.binding(\.look.brightness), range: 0.02...2.0,
            format: "%.2f")
        ParameterSlider(
            title: "Logarithmic stretch", value: session.binding(\.look.stretch), range: 0...60,
            format: "%.0f")
        ParameterSlider(title: "Saturation", value: session.binding(\.look.saturation), range: 0...3)
        ParameterSlider(
            title: "Tint per galaxy", value: session.binding(\.look.galaxyTint), range: 0...1)
        ParameterSlider(
            title: "Dust opacity", value: session.binding(\.look.dustStrength),
            range: 0...1.2, format: "%.3f")
        ParameterSlider(
            title: "Dust web", value: session.binding(\.look.dustWeb), range: 0...1)
        ParameterSlider(
            title: "Painted arm strength", value: session.binding(\.look.armPersistence), range: 0...2)
    }
}

struct InstrumentControls: View {
    @ObservedObject var session: StyleSession

    var body: some View {
        ParameterSlider(
            title: "Star smoothing", value: session.binding(\.look.smoothingScale), range: 0.4...5.0)
        ParameterSlider(
            title: "Minimum kernel (px)", value: session.binding(\.look.minimumKernel), range: 0.5...6)
        ParameterSlider(
            title: "Maximum kernel (px)", value: session.binding(\.look.maximumKernel), range: 4...160,
            format: "%.0f")
        ParameterSlider(
            title: "Stars under the kernel (projection)", value: session.binding(\.look.columnSmoothing),
            range: 0...120, format: "%.0f")
        ParameterSlider(title: "Compact sources", value: session.binding(\.look.glint), range: 0...1)
        ParameterSlider(title: "Glow", value: session.binding(\.look.bloomIntensity), range: 0...2)
        ParameterSlider(
            title: "Glow threshold", value: session.binding(\.look.bloomThreshold), range: 0.05...1.5)
        ParameterSlider(
            title: "Threshold softness", value: session.binding(\.look.bloomSoftKnee), range: 0...1)
        ParameterSlider(
            title: "Diffraction spikes", value: session.binding(\.look.spikeIntensity),
            range: 0...1.5)
        ParameterSlider(
            title: "Spike arms",
            value: Binding(
                get: { Float(session.current.look.spikeArms) },
                set: { session.binding(\.look.spikeArms).wrappedValue = Int($0.rounded()) }),
            range: 0...8, format: "%.0f")
        ParameterSlider(
            title: "Spike length", value: session.binding(\.look.spikeLength), range: 0...200,
            format: "%.0f")
        ParameterSlider(
            title: "Spike sharpness", value: session.binding(\.look.spikeSharpness), range: 0...1)
        CheckToggle(
            title: "Webb spikes",
            isOn: Binding(
                get: { session.current.look.spikePattern == .webb },
                set: { session.binding(\.look.spikePattern).wrappedValue = $0 ? .webb : .even }))
        ParameterSlider(
            title: "Field star size", value: session.binding(\.look.starSize), range: 0.2...4)
        ParameterSlider(
            title: "White point", value: session.binding(\.look.whitePoint), range: 1...20, format: "%.1f")
        ParameterSlider(
            title: "Sky background", value: session.binding(\.look.skyLevel), range: 0...0.006,
            format: "%.4f")
        ParameterSlider(
            title: "Twinkle (sensor noise)", value: session.binding(\.look.noiseLevel),
            range: 0...0.004, format: "%.4f")
    }
}

/// The settings that own buffers, so each builds a new renderer: the starfield only on release.
struct DetailControls: View {
    @ObservedObject var session: StyleSession
    @State private var starCount: Float?
    @Environment(\.offscreen) private var offscreen

    var body: some View {
        Text("These settings rebuild the renderer on release.")
            .font(.caption2)
            .foregroundStyle(Palette.secondary)
        ParameterSlider(
            title: "Field stars",
            value: Binding(
                get: { starCount ?? Float(session.current.starCount) },
                set: { starCount = $0.rounded() }),
            range: 0...60_000, format: "%.0f",
            onCommit: {
                if let starCount { session.binding(\.starCount).wrappedValue = Int(starCount) }
                starCount = nil
            })
        if offscreen {
            Text("Glow levels: \(session.current.bloomLevels)").font(.caption)
        } else {
            Stepper(
                "Glow levels: \(session.current.bloomLevels)", value: session.binding(\.bloomLevels),
                in: 1...8
            )
            .font(.caption)
        }
        if offscreen {
            Text("Supersampling \(session.current.supersample)×").font(.caption)
        } else {
            HStack {
                Text("Supersampling").font(.caption)
                Picker("Supersampling", selection: session.binding(\.supersample)) {
                    ForEach(1...4, id: \.self) { Text("\($0)×").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        ParameterSlider(
            title: "Arm strength (file)", value: session.binding(\.armStrength), range: 0...2)
        CheckToggle(title: "Raw points", isOn: session.binding(\.plain))
    }
}

/// The whole camera plan, and whether the canvas draws through it.
struct PlanControls: View {
    @ObservedObject var session: StyleSession

    var body: some View {
        CheckToggle(
            title: "View through the plan",
            isOn: Binding(
                get: { session.model.followsPlan },
                set: { session.model.followsPlan = $0 })
        )
        .help(
            "Draws the image as the export will frame it, in every mode. Unticked, the mouse "
                + "moves a free view the export does not keep.")
        // The immersed director chooses its own lens and angles.
        Group {
            ParameterSlider(
                title: "Field of view", value: session.binding(\.look.fieldOfView),
                range: 0.2...1.4)
            ParameterSlider(
                title: "Elevation (rad)", value: session.binding(\.camera.elevation), range: -1.5...1.5)
            PlanEndSlider(
                title: "End elevation", start: session.current.camera.elevation,
                end: session.binding(\.camera.elevationEnd), range: -1.5...1.5)
            ParameterSlider(
                title: "Azimuth (rad)", value: session.binding(\.camera.azimuth), range: -6.3...6.3)
            PlanEndSlider(
                title: "End azimuth", start: session.current.camera.azimuth,
                end: session.binding(\.camera.azimuthEnd), range: -12.6...12.6)
        }
        .disabled(!session.current.camera.placesCamera)
        ParameterSlider(
            title: "Share of particles framed", value: session.binding(\.camera.percentile),
            range: 0.5...1, format: "%.3f")
        ParameterSlider(
            title: "Framed radius (kpc, 0 = measured)", value: session.binding(\.camera.radius),
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
