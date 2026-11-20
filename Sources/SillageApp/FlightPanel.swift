import SillageRender
import SwiftUI

/// The throttle as the panel reads it. Its own view so that a step of the throttle redraws this
/// and not the whole panel, which the rig, moving sixty times a second, must never do.
struct FlySpeedLabel: View {
    @ObservedObject var session: FlightSession

    var body: some View {
        Text("speed \(session.speedLabel)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(Palette.secondary)
    }
}

/// Recording, keys and the scene's flights (#298): Record beside free flight, the path set key by
/// key, and each flight played on the canvas, renamed or put in the Bin. A video of a flight is
/// asked of Video…, which lists them.
struct FlightPanel: View {
    @ObservedObject var model: SimulationModel
    @ObservedObject var session: FlightSession
    @State private var renaming: String?
    @State private var name = ""

    var body: some View {
        if model.mode == .playback {
            VStack(alignment: .leading, spacing: 8) {
                Text("Flights").font(.headline)
                if session.canKeep {
                    recorder
                    if model.isFlying || session.waypointCount > 0 { waypoints }
                    if session.isPlaying { transport }
                    if let notice = session.notice {
                        Text(notice).font(.caption).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    flights
                } else {
                    Text("A flight is recorded over a take of a scene.")
                        .font(.caption).foregroundStyle(Palette.secondary)
                }
            }
        }
    }

    private var recorder: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    session.toggleRecording()
                } label: {
                    Label(
                        session.isRecording ? "Stop" : "Record",
                        systemImage: session.isRecording ? "stop.fill" : "record.circle")
                }
                .buttonStyle(.bordered)
                .tint(session.isRecording ? .red : nil)
                .help(
                    "R. Records the camera and the playhead in free flight; pausing freezes time in the flight"
                )
                if session.isRecording {
                    Text(String(format: "%.1f s", session.recordedSeconds))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(Palette.warning)
                }
            }
            Toggle("Banking", isOn: $session.banking)
                .font(.caption)
                .help("The camera leans into a turn, eased, and levels when the turn stops")
            if session.isRecording {
                Text("Pausing freezes time in the flight. Moving the playhead ends the recording.")
                    .font(.caption2).foregroundStyle(Palette.secondary)
            }
        }
    }

    private var waypoints: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                session.waypointCount == 0
                    ? "K sets a key where the camera is"
                    : String(format: "%d keys · %.1f s", session.waypointCount, session.waypointSeconds)
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(Palette.secondary)
            if session.waypointCount > 0 {
                HStack {
                    Button("Save path") { session.saveWaypoints() }
                        .disabled(session.waypointCount < 2)
                    Button("Undo") { session.removeLastWaypoint() }
                    Button("Clear") { session.clearWaypoints() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var transport: some View {
        VStack(alignment: .leading, spacing: 4) {
            Slider(
                value: Binding(get: { session.playedSeconds }, set: { session.seek(to: $0) }),
                in: 0...max(session.flightSeconds, 0.1))
            HStack {
                Button(session.playedPaused ? "Resume" : "Pause") { session.togglePause() }
                Button("Take the controls") { session.takeOver() }
                Spacer()
                Text(String(format: "%.1f / %.1f s", session.playedSeconds, session.flightSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.secondary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var flights: some View {
        if session.listings.isEmpty {
            Text("No flights yet. Record one, or set keys with K.")
                .font(.caption).foregroundStyle(Palette.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(session.listings) { listing in row(listing) }
            }
        }
    }

    private func row(_ listing: FlightListing) -> some View {
        let playing = session.playingName == listing.name
        return HStack(spacing: 6) {
            if renaming == listing.name {
                TextField("name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        session.rename(listing.name, to: name)
                        renaming = nil
                    }
                    .onExitCommand { renaming = nil }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(listing.name).font(.callout)
                    Text(detail(listing))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(listing.fault == nil ? Palette.secondary : Palette.warning)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Button {
                if playing { session.takeOver() } else { session.play(listing.name) }
            } label: {
                Image(systemName: playing ? "stop.fill" : "play.fill")
            }
            .help(playing ? "Take the controls" : "Plays the flight on the canvas")
            .disabled(listing.fault != nil)
            Button {
                name = listing.name
                renaming = listing.name
            } label: {
                Image(systemName: "pencil")
            }
            .help("Rename")
            Button {
                session.delete(listing.name)
            } label: {
                Image(systemName: "trash")
            }
            .help("Moves the flight to the Bin")
        }
        .buttonStyle(.borderless)
    }

    private func detail(_ listing: FlightListing) -> String {
        if let fault = listing.fault { return fault }
        return String(format: "%.0f s · %d keys", listing.seconds ?? 0, listing.keys ?? 0)
    }
}
