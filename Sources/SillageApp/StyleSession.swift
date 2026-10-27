import Combine
import Foundation
import SillageCore
import SillageRender
import SwiftUI

/// One scene's style being chosen. The picture and the look file are the model's; this holds
/// what the editor adds to them: the style as saved, the palettes proposed, the locks, Auto
/// and Avant/Après.
@MainActor
final class StyleSession: ObservableObject {
    typealias World = SillageRender.Palette.World

    let scene: LibraryScene
    let model: SimulationModel
    let catalogue: [LookFile]
    let references: [TelescopeReference]
    /// `look.json` as it stands: what Annuler goes back to and Avant/Après shows.
    @Published private(set) var saved: LookFile?
    /// A look was promoted over the explored one, so the next step is the export.
    @Published private(set) var promoted: Bool
    /// The world the proposals and Auto are drawn in.
    @Published var world: World {
        didSet {
            guard world != oldValue else { return }
            round = 0
            propose()
        }
    }
    /// The favourites that fit the world and the galaxies, then the best of the round.
    var proposals: [PaletteAuto.Ranked] {
        favouriteProposals
            + generated.filter { drawn in
                !favouriteProposals.contains { $0.palette == drawn.palette }
            }
    }
    @Published private(set) var generated: [PaletteAuto.Ranked] = []
    @Published private(set) var favouriteProposals: [PaletteAuto.Ranked] = []
    @Published private(set) var favourites: [FavouritePalettes.Favourite]
    /// The palette waiting for a name, which the heart asks once.
    @Published var naming: SillageRender.Palette?
    let favouritesDirectory: URL
    @Published private(set) var proposalNote: String?
    /// Galaxies whose colour no proposal or Auto replaces.
    @Published var locked: Set<Int> = []
    @Published private(set) var autoRunning = false
    /// What Auto found, or why a write failed.
    @Published private(set) var note: String?
    /// The file the saved style covers while Avant/Après is held.
    @Published private(set) var covered: LookFile?
    /// The Rendu section's thumbnails, which publish on their own.
    let thumbnails: StyleThumbnails

    /// Proposals shown at a time.
    static let proposalCount = 6

    private var coveredFollows = false
    /// What Lumière, Instrument and Rendu détaillé go back to: the last rendering applied.
    private var renderingBaseline: LookFile?
    private var round = 0
    private var proposing: Task<Void, Never>?
    private let sceneFile: SceneFile?
    private var watching: AnyCancellable?

    init(
        scene: LibraryScene, model: SimulationModel,
        catalogue: [LookFile] = LookCatalogue.repository,
        references: [TelescopeReference] = TelescopeReference.repository,
        favouritesDirectory: URL = FavouritePalettes.directory
    ) {
        self.scene = scene
        self.model = model
        self.catalogue = catalogue
        self.references = references
        self.favouritesDirectory = favouritesDirectory
        favourites = FavouritePalettes.load(from: favouritesDirectory)
        let folder = scene.folder
        let saved = folder.flatMap { try? LookFile.decoded(from: Data(contentsOf: $0.look)) }
        self.saved = saved
        promoted = folder.map { FileManager.default.fileExists(atPath: $0.rawLook.path) } ?? false
        sceneFile = folder.flatMap { try? SceneFile.decoded(from: Data(contentsOf: $0.scene)) }
        world = saved?.world ?? .free
        thumbnails = StyleThumbnails(model: model, catalogue: catalogue, folder: folder)
        // The inspector watches this rather than the model, which publishes on every frame.
        watching = Publishers.MergeMany(
            model.$lookFile.map { _ in () }.eraseToAnyPublisher(),
            model.$followsPlan.map { _ in () }.eraseToAnyPublisher(),
            model.$stage.map { _ in () }.eraseToAnyPublisher(),
            model.$mode.map { _ in () }.eraseToAnyPublisher(),
            model.$sceneFolder.map { _ in () }.eraseToAnyPublisher(),
            model.$fileActivity.map { _ in () }.eraseToAnyPublisher(),
            model.$isPreparing.map { _ in () }.eraseToAnyPublisher(),
            model.$failure.map { _ in () }.eraseToAnyPublisher()
        ).sink { [weak self] in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
        thumbnails.session = self
        propose()
    }

    /// The scene's take is the one on the canvas, loaded and ready to edit.
    var isOpen: Bool {
        model.stage == .running && model.mode == .playback && model.sceneFolder == scene.folder
            && model.fileActivity == nil && !model.isPreparing
    }

    /// The style being edited, also while the saved one is on screen.
    var current: LookFile { covered ?? model.lookFile }

    var isModified: Bool { saved.map { current != $0 } ?? false }

    /// The catalogue's rendering the style draws with, untouched.
    var rendering: LookFile? { catalogue.first { current.uses(rendering: $0) } }

    var galaxyCount: Int { sceneFile?.galaxies.count ?? model.scene.galaxies.count }

    // MARK: Rendering

    func apply(_ rendering: LookFile, colours: Bool = false) {
        guard edit({ $0.withRendering(rendering, colours: colours) }) else { return }
        renderingBaseline = model.lookFile
        if colours { world = rendering.world }
    }

    // MARK: Palette

    /// The best proposals of a round, drawn off the main actor unless `waiting`. Each round
    /// draws 48 candidates from the scene's seed and keeps the best six, so every round is as
    /// good as the first.
    func propose(waiting: Bool = false) {
        proposing?.cancel()
        showFavourites()
        let (galaxies, world, references) = (galaxyCount, world, references)
        let base = sceneFile?.seed ?? model.scene.seed
        let seed = base &+ UInt64(round) &* 0x9E37_79B9_7F4A_7C15
        let draw: @Sendable () -> Result<[PaletteAuto.Ranked], any Error> = {
            Result {
                try PaletteAuto.ranked(
                    galaxies: galaxies, world: world, seed: seed, telescope: references)
            }
        }
        if waiting { return show(draw()) }
        proposing = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { draw() }.value
            guard !Task.isCancelled else { return }
            self?.show(outcome)
        }
    }

    private func show(_ outcome: Result<[PaletteAuto.Ranked], any Error>) {
        switch outcome {
        case .success(let ranked):
            generated = Array(ranked.prefix(Self.proposalCount))
            proposalNote = nil
        case .failure(let error):
            generated = []
            proposalNote = favouriteProposals.isEmpty ? Self.describe(error) : nil
        }
    }

    private func showFavourites() {
        let references = references
        favouriteProposals = FavouritePalettes.fitting(
            favourites, world: world, galaxies: galaxyCount
        ).map {
            PaletteAuto.Ranked(palette: $0.palette, score: PaletteScore($0.palette, references: references))
        }
    }

    // MARK: Favourites

    func isFavourite(_ palette: SillageRender.Palette) -> Bool {
        FavouritePalettes.favourite(matching: palette, in: favourites) != nil
    }

    /// A heart on a favourite takes it out of `palettes/`; on any other palette it asks a name.
    func toggleFavourite(_ palette: SillageRender.Palette) {
        guard let favourite = FavouritePalettes.favourite(matching: palette, in: favourites) else {
            naming = palette
            return
        }
        do {
            try FavouritePalettes.remove(favourite, in: favouritesDirectory)
            note = "Favori retiré : \(favourite.name)"
        } catch {
            note = "Favori non retiré : \(error.localizedDescription)"
        }
        reloadFavourites()
    }

    func saveFavourite(_ palette: SillageRender.Palette, named name: String) {
        naming = nil
        do {
            let kept = try FavouritePalettes.save(palette, named: name, in: favouritesDirectory)
            note = "Favori gardé : palettes/\(kept.name).palette.json"
        } catch let error as FavouritePalettes.Failure {
            note = "Favori non gardé : \(error.description)"
        } catch {
            note = "Favori non gardé : \(error.localizedDescription)"
        }
        reloadFavourites()
    }

    private func reloadFavourites() {
        favourites = FavouritePalettes.load(from: favouritesDirectory)
        showFavourites()
    }

    /// The next round, for "Autres palettes".
    func moreProposals(waiting: Bool = false) {
        round += 1
        propose(waiting: waiting)
    }

    func use(_ palette: SillageRender.Palette) {
        let (locked, references) = (locked, references)
        let scene = model.scene
        edit { $0.withPalette(palette, keeping: locked, in: scene, references: references) }
    }

    func toggleLock(_ galaxy: Int) {
        if locked.contains(galaxy) { locked.remove(galaxy) } else { locked.insert(galaxy) }
    }

    func setColour(_ colour: SIMD3<Float>, ofGalaxy index: Int) {
        guard isOpen, covered == nil else { return }
        model.setColour(colour, ofGalaxy: index)
    }

    private static func describe(_ error: any Error) -> String {
        switch error as? PaletteGenerator.Failure {
        case .tooManyGalaxies:
            "Les propositions vont jusqu'à 5 galaxies : les couleurs se choisissent une à une."
        case .noRoom:
            "Aucune palette de ce monde ne sépare autant de galaxies."
        default:
            "Pas de proposition : \(error)"
        }
    }

    // MARK: Auto

    private struct Pick: Sendable {
        var rendering: LookFile
        var palette: SillageRender.Palette
        var score: Float
        var tried: Int
    }

    private enum AutoFailure: Error, CustomStringConvertible {
        case nothing
        var description: String { "aucun couple rendu et palette n'a pu être noté" }
    }

    /// The best rendering and palette of the world on three key frames of the take (#124),
    /// over the locks and the camera.
    func runAuto() {
        guard let folder = scene.folder, !autoRunning, isOpen else { return }
        autoRunning = true
        note = nil
        let (world, catalogue, references) = (world, catalogue, references)
        let favourites = FavouritePalettes.fitting(favourites, world: world, galaxies: galaxyCount)
            .map(\.palette)
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Pick, any Error> in
                Result {
                    let found = try StyleAuto.choose(
                        folder, world: world, catalogue: catalogue, references: references,
                        favourites: favourites)
                    guard let best = found.ranked.first,
                        let rendering = catalogue.first(where: { $0.name == best.rendering })
                    else { throw AutoFailure.nothing }
                    return Pick(
                        rendering: rendering, palette: best.palette, score: best.total,
                        tried: found.ranked.count)
                }
            }.value
            self?.finishAuto(outcome)
        }
    }

    private func finishAuto(_ outcome: Result<Pick, any Error>) {
        autoRunning = false
        switch outcome {
        case .success(let pick):
            let (locked, references) = (locked, references)
            let scene = model.scene
            guard
                edit({
                    $0.withRendering(pick.rendering).withPalette(
                        pick.palette, keeping: locked, in: scene, references: references)
                })
            else { return }
            renderingBaseline = model.lookFile
            note =
                "Auto : rendu \(StyleNames.rendering(pick.rendering.name)), palette "
                + "\(pick.palette.family) \(StyleNames.harmony(pick.palette.harmony)), "
                + "note \(StyleNames.number(pick.score)), la meilleure de \(pick.tried) essais"
        case .failure(let error):
            note = "Auto n'a pas abouti : \(error)"
        }
    }

    // MARK: Camera and fine settings

    /// The plan's mode, drawn through on the canvas when it has a picture to give.
    func setCameraMode(_ mode: LookFile.CameraPlan.Mode) {
        let changed = edit { file in
            var file = file
            file.camera.mode = mode
            return file
        }
        if changed { model.followsPlan = [.fixed, .auto].contains(mode) }
    }

    /// Where a group's Réinitialiser goes: the camera to the saved style, the rest to the last
    /// rendering applied, else to the saved style.
    func baseline(for group: LookFile.Group) -> LookFile? {
        group == .camera ? saved : renderingBaseline ?? saved
    }

    func reset(_ group: LookFile.Group) {
        guard let baseline = baseline(for: group) else { return }
        guard edit({ $0.resetting(group, to: baseline) }) else { return }
        if group == .camera { model.followsPlan = [.fixed, .auto].contains(model.lookFile.camera.mode) }
    }

    // MARK: Before and after, cancel, promote

    /// While held, the saved style is on screen; on release, the one being edited is back.
    func showSaved(_ shown: Bool) {
        if shown {
            guard covered == nil, let saved, isOpen, saved != model.lookFile else { return }
            covered = model.lookFile
            coveredFollows = model.followsPlan
            model.lookFile = saved
            model.followsPlan = [.fixed, .auto].contains(saved.camera.mode)
        } else if let covered {
            model.lookFile = covered
            model.followsPlan = coveredFollows
            self.covered = nil
        }
    }

    /// Puts the saved style back on the picture.
    func cancel() {
        showSaved(false)
        if let saved, isOpen, model.lookFile != saved {
            model.adopt(saved, from: scene.folder?.look)
        }
    }

    /// Writes the style as the scene's `look.json`, the explored one kept as `look-raw.json`.
    @discardableResult
    func promote() -> Bool {
        showSaved(false)
        guard let folder = scene.folder, isOpen else { return false }
        do {
            try folder.promote(model.lookFile)
            model.lookURL = folder.look
            saved = model.lookFile
            promoted = true
            note = nil
            return true
        } catch {
            note = "Style non enregistré : \(error.localizedDescription)"
            return false
        }
    }

    /// A field of the style, edited through the session so nothing moves while the saved style
    /// is on screen.
    func binding<Value>(_ path: WritableKeyPath<LookFile, Value>) -> Binding<Value> {
        Binding(
            get: { self.current[keyPath: path] },
            set: { value in
                self.edit { file in
                    var file = file
                    file[keyPath: path] = value
                    return file
                }
            })
    }

    @discardableResult
    private func edit(_ change: (LookFile) -> LookFile) -> Bool {
        guard isOpen, covered == nil else { return false }
        model.lookFile = change(model.lookFile)
        return true
    }
}

/// The words the editor shows for the catalogue's names.
enum StyleNames {
    static func rendering(_ name: String) -> String {
        if let named = RenderLook.catalogue.first(where: { $0.id == name }) { return named.name }
        let words = name.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func harmony(_ harmony: SillageRender.Palette.Harmony) -> String {
        switch harmony {
        case .analogous: "analogue"
        case .complementary: "complémentaire"
        case .splitComplementary: "complémentaire divisée"
        case .triadic: "triadique"
        case .tetradic: "tétradique"
        case .monochrome: "monochrome"
        }
    }

    static func world(_ world: SillageRender.Palette.World) -> String {
        switch world {
        case .telescope: "Télescope"
        case .free: "Libre"
        }
    }

    static func number(_ value: Float) -> String {
        String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// Halo, aigrettes, poussières, étoiles de champ and luminosité, the five things a
    /// rendering changes most.
    static func traits(_ file: LookFile) -> String {
        let look = file.look
        var parts: [String] = []
        parts.append("halo \(Self.number(look.bloomIntensity))")
        if look.spikeArms > 0, look.spikeIntensity > 0 {
            let pattern = look.spikePattern == .webb ? " de Webb" : ""
            parts.append("\(look.spikeArms) aigrettes\(pattern)")
        } else {
            parts.append("sans aigrettes")
        }
        parts.append("poussières \(Self.number(look.dustStrength))")
        parts.append(
            file.starCount == 0
                ? "sans étoiles de champ"
                : "\(file.starCount.formatted(.number.locale(Locale(identifier: "fr_FR")))) étoiles de champ")
        parts.append("luminosité \(Self.number(look.brightness))")
        return parts.joined(separator: " · ")
    }
}
