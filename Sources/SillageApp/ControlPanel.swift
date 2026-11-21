import SillageCore
import SillageRender
import SwiftUI

/// Live controls for the running simulation. Everything here applies immediately: the scene
/// itself is edited on the setup screen, not while it runs.
struct ControlPanel: View {
    @ObservedObject var model: SimulationModel

    var body: some View {
        ScrollView {
            ControlPanelContent(model: model).padding(14)
        }
        .frame(width: 290)
        .panelSurface()
    }
}

/// Split out from the scroll view so it can be rendered offscreen for inspection.
struct ControlPanelContent: View {
    @ObservedObject var model: SimulationModel
    @Environment(\.queue) private var queue
    @Environment(\.offscreen) private var offscreen
    @State private var exporting = false

    private var exportFolder: SceneFolder? { model.isOpenedTake ? model.takeFolder : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            transport
            Divider()
            capture
            Divider()
            rendering
            Divider()
            view
        }
    }

    private var transport: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.mode == .playback ? "Playback" : "Simulation running")
                .font(.headline)
            HStack {
                Button(model.isPlaying ? "Pause" : "Play") { model.isPlaying.toggle() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Restart") { model.restart() }
            }
            .buttonStyle(.bordered)

            Button("Edit scene") { model.returnToSetup() }
                .buttonStyle(.bordered)

            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "t = %.0f Myr", model.elapsedMyr))
                    .font(.callout.monospacedDigit())
                Spacer()
                if model.mode == .running {
                    Text(String(format: "%.1f Myr/s", model.megayearsPerSecond))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.secondary)
                }
            }
            Text(
                String(
                    format: "%@ particles · %.1f ms per frame shown",
                    model.particleCount >= 1_000_000
                        ? String(format: "%.1f M", Double(model.particleCount) / 1_000_000)
                        : "\(model.particleCount / 1000) k",
                    model.frameMilliseconds)
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(Palette.secondary)

            if let activity = model.fileActivity {
                HStack(spacing: 6) {
                    if offscreen {
                        Image(systemName: "hourglass")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(activity).font(.caption)
                }
            }

            if let failure = model.failure {
                Text(failure).font(.caption).foregroundStyle(Palette.warning)
            }
        }
    }

    /// Capture and playback. A run records itself from the moment it starts: self-gravity
    /// costs hundreds of milliseconds a step, so a scene that has already been computed once
    /// should never have to be computed again just to be watched.
    @ViewBuilder
    private var capture: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Take").font(.headline)

            switch model.mode {
            case .running:
                Text(
                    "\(model.capturedFrames) \(model.capturedFrames == 1 ? "frame" : "frames") · "
                        + String(
                            format: "%.0f Myr · %.1f GB", model.capturedMyr,
                            Double(model.capturedBytes) / 1_073_741_824)
                )
                .font(.caption.monospacedDigit())
                if offscreen {
                    OffscreenTrack(fraction: Float(model.captureFraction))
                } else {
                    ProgressView(value: model.captureFraction)
                }

                if let why = model.captureSpillFailure {
                    Text("Cannot spill to disk, the take carries on in memory. \(why)")
                        .font(.caption2)
                        .foregroundStyle(Palette.warning)
                } else if model.captureSpilling {
                    Text(
                        String(
                            format:
                                "Memory budget reached: the take carries on to disk (%.1f GB). No frame is lost.",
                            Double(model.captureDiskBytes) / 1_073_741_824)
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Stop and replay") { model.stopAndReplay() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canReplay)
                    Button("Open…") { TakeFiles.open(model) }
                        .buttonStyle(.bordered)
                }

                ParameterSlider(
                    title: "Memory budget (GB)",
                    value: Binding(
                        get: { Float(model.memoryBudgetGigabytes) },
                        set: { model.memoryBudgetGigabytes = Double($0) }),
                    range: 0.5...24, format: "%.1f")
                Text(
                    "What the take keeps in memory. Beyond that it carries on to disk, never losing a frame."
                )
                .font(.caption2)
                .foregroundStyle(Palette.secondary)

                CheckToggle(title: "Show while computing", isOn: $model.showCanvasWhileRunning)
                Text(
                    "Drawing a few million particles takes a real share of the GPU the computation runs on."
                )
                .font(.caption2)
                .foregroundStyle(Palette.secondary)

                Divider()
                Text("End of run").font(.caption.bold())
                ParameterSlider(
                    title: "Stop at (Myr)",
                    value: Binding(
                        get: { Float(model.stopAtMyr) },
                        set: { model.stopAtMyr = Double($0) }),
                    range: 0...8000, format: "%.0f")
                Text(
                    model.stopAtMyr > 0
                        ? "The run will stop on its own and switch to playback."
                        : "At 0, the run never stops on its own."
                )
                .font(.caption2)
                .foregroundStyle(Palette.secondary)

                if let destination = model.finishDestination {
                    HStack {
                        Text("Will be written to \(destination.lastPathComponent)")
                            .font(.caption2)
                            .foregroundStyle(Palette.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("Cancel") { model.cancelSaveWhenFinished() }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                    }
                } else {
                    Button("Save when finished…") { TakeFiles.saveWhenFinished(model) }
                        .buttonStyle(.bordered)
                }

                CheckToggle(title: "Quit when finished", isOn: $model.quitWhenFinished)
                    .disabled(model.stopAtMyr <= 0)

                Divider()
                CountStepper(
                    title: "Steps per frame: \(model.stepsPerFrame)",
                    value: $model.stepsPerFrame, range: 1...64)
                Text("Higher, the take spans more time for the same memory.")
                    .font(.caption2)
                    .foregroundStyle(Palette.secondary)

            case .playback:
                if model.reachedFinish {
                    Text("Run ended at the requested time.")
                        .font(.caption)
                        .foregroundStyle(Palette.label)
                }
                Text(
                    String(
                        format: "%d frames · %.0f Myr · %.0f MB", model.capturedFrames,
                        model.capturedMyr, model.capturedMegabytes)
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(Palette.secondary)
                if offscreen {
                    OffscreenTrack(
                        fraction: Float(model.playbackPosition / Double(max(model.capturedFrames - 1, 1))))
                } else {
                    Slider(
                        value: $model.playbackPosition,
                        in: 0...Double(max(model.capturedFrames - 1, 1)))
                }
                ParameterSlider(
                    title: "Speed (frames/s)", value: $model.playbackSpeed, range: 1...120,
                    format: "%.0f")
                HStack {
                    Button("Save…") { TakeFiles.save(model) }
                    Button("Open…") { TakeFiles.open(model) }
                    // A video is made from a scene folder, through the queue and its presets.
                    if queue != nil, exportFolder != nil {
                        Button("Video…") { exporting = true }
                            .help("Exports this take's scene with the presets")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(model.fileActivity != nil)
                .sheet(isPresented: $exporting) {
                    if let queue, let exportFolder {
                        ExportSheet(queue: queue, folders: [exportFolder]) { exporting = false }
                    }
                }

                if model.isOpenedTake {
                    Text(
                        "Take opened from a file. Every image setting stays live; restarting would recompute it from its scene."
                    )
                    .font(.caption2)
                    .foregroundStyle(Palette.secondary)
                } else {
                    HStack {
                        Button("Resume computing") { model.resumeRunning() }
                        Button("New take") { model.restartCapture() }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var lookBinding: Binding<String> {
        Binding(
            get: { model.lookName },
            set: { id in
                guard let named = RenderLook.catalogue.first(where: { $0.id == id }) else { return }
                model.adopt(named)
            })
    }

    private var lookDescription: String {
        switch model.lookName {
        case "dream": "Wide kernels and generous bloom: the disk turns to cloud."
        case "gloss": "Tight kernels, long spikes: a field of single sparks."
        case "ink": "Near-black sky, restrained colour. For wide shots."
        case "ember": "Warm and heavy, the dust does most of the drawing."
        default: "What the instrument would actually record."
        }
    }

    /// Split the way the two halves of the picture are: what light the galaxy sends, and
    /// what the telescope does with it. Ten sliders in one column say nothing about which
    /// knob to reach for.
    private var rendering: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rendering").font(.headline)
            // A whole look in one press, from the honest telescope to the frankly invented.
            // The sliders below stay live afterwards: a look is a place to start, not a mode.
            MenuChoice(
                selection: lookBinding, options: RenderLook.catalogue.map { ($0.name, $0.id) })
            Text(lookDescription)
                .font(.caption)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)
            section("Light", .light)
            Divider()
            section("Instrument", .instrument)
        }
    }

    /// One section of the look, the same controls the style editor's fine settings show.
    private func section(_ title: String, _ group: LookFile.Group) -> some View {
        let baseline = RenderLook.catalogue.first { $0.id == model.lookName }?.look
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            LookControlList(group: group, look: $model.look)
            Button("Reset") {
                if let baseline { model.look = model.look.resetting(group, to: baseline) }
            }
            .controlSize(.small)
            .disabled(baseline.map { model.look.resetting(group, to: $0) == model.look } ?? true)
            .help("Back to the values of the rendering chosen above")
        }
    }

    private var view: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Camera").font(.headline)
            SegmentedChoice(
                selection: flightBinding, options: [("Orbit", false), ("Free flight", true)])

            if model.isFlying {
                Text("Drag to look, scroll for speed")
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow {
                        Text("W S").monospaced()
                        Text("forward, back")
                    }
                    GridRow {
                        Text("A D").monospaced()
                        Text("left, right")
                    }
                    GridRow {
                        Text("␣ C").monospaced()
                        Text("up, down")
                    }
                    GridRow {
                        Text("← →").monospaced()
                        Text("turn")
                    }
                    GridRow {
                        Text("↑ ↓").monospaced()
                        Text("look up, look down")
                    }
                    GridRow {
                        Text("⇧ ⌃").monospaced()
                        Text("faster, slower")
                    }
                    GridRow {
                        Text("[ ]").monospaced()
                        Text("a step of the throttle")
                    }
                    if model.mode == .playback {
                        GridRow {
                            Text("R").monospaced()
                            Text("record, stop")
                        }
                        GridRow {
                            Text("K").monospaced()
                            Text("a key of the path")
                        }
                    }
                    GridRow {
                        Text("F").monospaced()
                        Text("back to orbit")
                    }
                }
                .font(.caption)
                .foregroundStyle(Palette.secondary)
                // Not bound to the rig: it moves on every frame, and a binding would rebuild
                // this panel sixty times a second.
                FlySpeedLabel(session: model.flights)
            } else {
                Text("Drag to rotate, scroll to zoom · F to fly")
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
                ParameterSlider(
                    title: "Distance (kpc)", value: $model.camera.distance,
                    range: OrbitCamera.nearest...OrbitCamera.furthest, format: "%.0f")
                ParameterSlider(
                    title: "Elevation (°)", value: $model.camera.elevation.degrees,
                    range: (-OrbitCamera.elevationLimit...OrbitCamera.elevationLimit).inDegrees,
                    format: "%.0f")
            }
            ParameterSlider(
                title: "Field of view", value: $model.look.fieldOfView, range: 0.2...1.4)
            Button(model.isFlying ? "Back to the scene" : "Reframe") {
                if model.isFlying { model.toggleFlight() }
                model.frameCamera()
            }
            .buttonStyle(.bordered)
            if model.mode == .playback {
                Divider()
                FlightPanel(model: model, session: model.flights)
            }
        }
    }

    private var flightBinding: Binding<Bool> {
        Binding(
            get: { model.isFlying },
            set: { wanted in if wanted != model.isFlying { model.toggleFlight() } })
    }
}
