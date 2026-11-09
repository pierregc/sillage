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
                    ProgressView().controlSize(.small)
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
                    String(
                        format: "%d frames · %.0f Myr · %.1f GB", model.capturedFrames,
                        model.capturedMyr, Double(model.capturedBytes) / 1_073_741_824)
                )
                .font(.caption.monospacedDigit())
                ProgressView(value: model.captureFraction)

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

                Toggle("Show while computing", isOn: $model.showCanvasWhileRunning)
                    .font(.caption)
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

                Toggle("Quit when finished", isOn: $model.quitWhenFinished)
                    .font(.caption)
                    .disabled(model.stopAtMyr <= 0)

                Divider()
                Stepper(
                    "Steps per frame: \(model.stepsPerFrame)",
                    value: $model.stepsPerFrame, in: 1...64
                )
                .font(.caption)
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
                Slider(
                    value: $model.playbackPosition,
                    in: 0...Double(max(model.capturedFrames - 1, 1)))
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
            Picker("", selection: lookBinding) {
                ForEach(RenderLook.catalogue) { named in
                    Text(named.name).tag(named.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            Text(lookDescription)
                .font(.caption)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)
            Text("Light").font(.headline)
            ParameterSlider(
                title: "Brightness", value: $model.look.brightness, range: 0.02...2.0, format: "%.2f")
            ParameterSlider(
                title: "Logarithmic stretch", value: $model.look.stretch, range: 0...60,
                format: "%.0f")
            ParameterSlider(title: "Saturation", value: $model.look.saturation, range: 0...3)
            ParameterSlider(title: "Tint per galaxy", value: $model.look.galaxyTint, range: 0...1)
            Text(
                "0: each star has its population's colour. 1: each galaxy keeps its own, which makes the stars it loses readable."
            )
            .font(.caption2)
            .foregroundStyle(Palette.secondary)
            ParameterSlider(
                title: "Dust opacity", value: $model.look.dustStrength, range: 0...1.2,
                format: "%.3f")
            ParameterSlider(title: "Dust web", value: $model.look.dustWeb, range: 0...1)
            ParameterSlider(
                title: "Painted arm strength", value: $model.look.armPersistence, range: 0...2)
            Text(
                "Above 1 the arms are plain invention, which the softest styles own up to."
            )
            .font(.caption2)
            .foregroundStyle(Palette.secondary)

            Divider()
            Text("Instrument").font(.headline)
            ParameterSlider(
                title: "Star smoothing", value: $model.look.smoothingScale,
                range: 0.4...5.0)
            // How wide a splat is allowed to be. The floor is the one that matters and it was
            // reachable only from a preset: a star drawn thinner than a pixel crosses pixel
            // boundaries as it moves and twinkles on its own, whatever the detector noise is
            // set to. Measured on a take played slowly with the noise off, the worst
            // frame-to-frame jump on a single pixel falls from 81 levels at 1.1 px to 16 at
            // 3.5.
            ParameterSlider(
                title: "Minimum kernel (px)", value: $model.look.minimumKernel, range: 0.5...6)
            ParameterSlider(
                title: "Maximum kernel (px)", value: $model.look.maximumKernel, range: 4...160,
                format: "%.0f")
            ParameterSlider(
                title: "Stars under the kernel (projection)", value: $model.look.columnSmoothing,
                range: 0...120, format: "%.0f")
            ParameterSlider(title: "Compact sources", value: $model.look.glint, range: 0...1)
            ParameterSlider(title: "Glow", value: $model.look.bloomIntensity, range: 0...2)
            ParameterSlider(
                title: "Diffraction spikes", value: $model.look.spikeIntensity, range: 0...1.5)
            // What makes a bright star sparkle is these three together, and only the first of
            // them had a control: the number of arms and how far they reach were reachable
            // only from a preset.
            ParameterSlider(
                title: "Spike arms", value: $model.spikeArms, range: 0...8,
                format: "%.0f")
            ParameterSlider(
                title: "Spike length", value: $model.look.spikeLength, range: 0...200,
                format: "%.0f")
            Toggle(
                "Webb spikes",
                isOn: Binding(
                    get: { model.look.spikePattern == .webb },
                    set: { model.look.spikePattern = $0 ? .webb : .even })
            )
            .font(.caption)
            ParameterSlider(
                title: "Field star size", value: $model.look.starSize, range: 0.2...4)
            ParameterSlider(
                title: "Glow threshold", value: $model.look.bloomThreshold, range: 0.05...1.5)
            ParameterSlider(
                title: "Threshold softness", value: $model.look.bloomSoftKnee, range: 0...1)
            ParameterSlider(
                title: "White point", value: $model.look.whitePoint, range: 1...20, format: "%.1f")
            ParameterSlider(
                title: "Sky background", value: $model.look.skyLevel, range: 0...0.006,
                format: "%.4f")
            // Named for what it does rather than for what it is. Every look sits between
            // 0.0008 and 0.0022, so a range up to 0.01 put the whole useful part of it in the
            // first sixth of the track: it read as a control that did nothing until it
            // suddenly did everything, and zero was three pixels wide.
            ParameterSlider(
                title: "Twinkle (sensor noise)", value: $model.look.noiseLevel,
                range: 0...0.004, format: "%.4f")
            Text(
                "At zero, two frames of a paused scene are identical to the bit: this noise is what makes the whole background flicker. For stars that twinkle as they move, see the minimum kernel."
            )
            .font(.caption2)
            .foregroundStyle(Palette.secondary)
        }
    }

    private var view: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Camera").font(.headline)
            Picker("", selection: flightBinding) {
                Text("Orbit").tag(false)
                Text("Free flight").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

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
                        Text("F").monospaced()
                        Text("back to orbit")
                    }
                }
                .font(.caption)
                .foregroundStyle(Palette.secondary)
                // Not bound to the rig: it moves on every frame, and a binding would rebuild
                // this panel sixty times a second.
                Text(String(format: "speed %.0f kpc/s", model.flight.speed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.secondary)
            } else {
                Text("Drag to rotate, scroll to zoom · F to fly")
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
                ParameterSlider(
                    title: "Distance (kpc)", value: $model.camera.distance,
                    range: OrbitCamera.nearest...OrbitCamera.furthest, format: "%.0f")
                ParameterSlider(
                    title: "Elevation (rad)", value: $model.camera.elevation,
                    range: -OrbitCamera.elevationLimit...OrbitCamera.elevationLimit)
            }
            ParameterSlider(
                title: "Field of view", value: $model.look.fieldOfView, range: 0.2...1.4)
            Button(model.isFlying ? "Back to the scene" : "Reframe") {
                if model.isFlying { model.toggleFlight() }
                model.frameCamera()
            }
            .buttonStyle(.bordered)
        }
    }

    private var flightBinding: Binding<Bool> {
        Binding(
            get: { model.isFlying },
            set: { wanted in if wanted != model.isFlying { model.toggleFlight() } })
    }
}
