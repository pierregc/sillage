# The portable Swift on Linux (#272)

Step 3 of epic #269. The CUDA engine is driven from Swift on Linux, so the Swift that is not
Metal has to build and pass its tests there: the scene and its sampling, the cameras, the looks,
the takes, the checkpoints and the reports a full pass uses. Before this, nothing built on
Linux: `SillageCore` imported Apple's `simd`, and some portable logic sat in files that import
Metal, CryptoKit or AVFoundation. `scripts/linux.sh check` now passes on Linux x86_64, and
`./scripts/dev.sh check` passes on the Mac with the same code doing the same thing.

## Install Swift 6.2 (Ubuntu 24.04, x86_64)

What worked in a cloud session of Claude Code, whose network lets `download.swift.org` through:

```sh
mkdir -p /opt/swift /tmp/swift-dl
cd /tmp/swift-dl
curl -sSfL -C - --retry 3 -O \
  https://download.swift.org/swift-6.2-release/ubuntu2404/swift-6.2-RELEASE/swift-6.2-RELEASE-ubuntu24.04.tar.gz
tar -xzf swift-6.2-RELEASE-ubuntu24.04.tar.gz -C /opt/swift --strip-components=1
export PATH=/opt/swift/usr/bin:$PATH
swift --version        # Swift version 6.2 (swift-6.2-RELEASE)
```

The archive is 1 GB; `-C -` resumes it if the proxy cuts the transfer, which it did once. Its
SHA-256 was `8e3d63a3371caad495e694414b9b9a22c5f68c6473077406c7296472a41bc077`. swift-testing
(`import Testing`) and the formatter (`swift format`) come with the toolchain, and so does the
testing macro plugin; `libcurl`, `libxml2`, `libncurses` and `zlib` were already on the image.
`scripts/linux.sh` finds `/opt/swift/usr/bin` by itself when `swiftc` is not on the `PATH`.

## `scripts/linux.sh`

In the manner of `dev.sh`: plain `swiftc`, no SwiftPM, output in `.build/linux/`.

| command | what it does |
| --- | --- |
| `build` | `SillageCore` whole, then `SillageRender` without the files of `scripts/linux-skip.txt` |
| `test [args]` | `build`, then the tests of both modules without those of `scripts/linux-skip-tests.txt`, with swift-testing's own arguments (`--filter name`) |
| `strict` | the strict concurrency typecheck of both modules, as `dev.sh strict` does |
| `lint` | `swift format lint --recursive --strict Sources Tests`, the same formatter run as on the Mac |
| `check` | `lint`, `strict`, then `test`: the gate on Linux. About ten minutes on four cores |
| `files` | the files each build takes, for debugging a skip list |

A skip list is one file name a line, a reason after `#`. A name that is not a file is an error,
so a list cannot go stale. The tests run in `Europe/Paris` (`TZ` is set when it is not), because
some of them read the clock in the zone they were written in.

Typechecking one test file against the built modules takes a second:
`swiftc -typecheck -I .build/linux -parse-as-library Tests/SillageCoreTests/X.swift`. Running
a few tests alone is `swiftc -Onone -I .build/linux -L .build/linux -lSillageCore
-parse-as-library <files> runner.swift`, with the same `runner.swift` as `dev.sh`.

## What builds

- **`SillageCore`, every file**, `ParticleSystem.streamingLightTracers` included.
- **`SillageRender`, every file but 23**, which need an Apple framework or a type defined in one:
  Metal (the solver, the tree builder, the renderer, the shaders' pipelines, the thumbnails),
  CoreGraphics, CoreText, ImageIO, CoreVideo and CoreMedia (PNGs, the look grid and sheet,
  `ExportedFile`), QuartzCore, AVFoundation and VideoToolbox (`VideoWriter`, the codec's
  properties). `scripts/linux-skip.txt` names each with its framework.
- **The tests of both modules but 19 files**, the ones that need Metal, AVFoundation, ImageIO or
  CoreGraphics, and the queue and night runner's, which start and watch processes with calls only
  macOS has. 387 tests ran on Linux the day this was written, 6 more since.

Everything the ticket asked for builds: `SceneFolder`, `LookFile` and its extensions,
`RenderLook`, `GalaxyColours`, `PaletteRamps`, the cameras (`Camera`, `AutoCamera`,
`OrbitCamera`, `FlyCamera`, `Cinematographer`, `ShotPlan`, `ShotReplay`), `KeyFrames`,
`DiskFrame`, `Recording` and `RecordingFile`, `RunCheckpoint`, `RunStatus`, `CostModel`,
`StepProfile`, `VideoPreset` and `VideoCodec`, and the full pass's framing, now `TakeFraming`.
The queue and the night's runner build too, with stand-ins that start and probe nothing.

## `simd` on Linux

`Sources/SillageCore/SIMDLinux.swift`, all under `#if !canImport(simd)`, defines what the code
takes from Apple's module over the standard library's `SIMD2`, `SIMD3` and `SIMD4`: `simd_length`,
`simd_length_squared`, `simd_distance`, `simd_dot`, `simd_normalize`, `simd_cross`, `simd_min`,
`simd_max`, `simd_clamp`, `simd_mix`, `simd_sum`, `smoothstep`, `fract`, `simd_determinant`,
`simd_inverse`, `simd_transpose`, and `simd_float3x3`, `simd_double3x3` and `simd_float4x4` with
the operations the code uses. A dot is `a.x * b.x + a.y * b.y + a.z * b.z`, left to right,
written out; the test below says whether it gives Apple's bits.

A file that uses those functions or types imports them behind a guard:

```swift
#if canImport(simd)
    import simd
#else
    import Foundation
    import SillageCore
#endif
```

`Foundation` is there because on the Mac `simd` brings Darwin's math with it (`sin`, `exp`,
`sqrt`) and a file that only imported `simd` had no other source for them. `SillageCore` is
there for the files of `SillageRender` that do not import it otherwise. The Mac takes the first
branch, so it compiles what it always did. **A new portable file that uses a simd function takes
this guard**; one that only names `SIMD3<Float>` needs no import at all. A file that imports
Metal, AVFoundation or CoreGraphics is not portable: split it, or list it.

## What moved, and what stayed

The Mac compiles every one of these, so each is a commit of its own, and each is a move of text
with the edits below and no rewrite.

| from | to | what changed besides the place |
| --- | --- | --- |
| `TakeExport.swift` | `VideoPreset.swift` | nothing |
| `VideoCodec.swift` | `VideoCodec+AVFoundation.swift` | `avCodec`, `compressionProperties` and `VideoMetadata.items` moved; the rest stays |
| `Renderer.swift` | `RenderSettings.swift` | nothing |
| `LookFile+Render.swift` | `Renderer+Look.swift` | the two `Renderer` methods that take a look file |
| `TakeExport.replay`, `.prepare` | `TakeFraming.swift` | `prepare` takes any `FramePreparing`, which `Renderer` is; callers use the new name |
| `Recording.swift` | `RecordingMetal.swift` | `copy(frame:into:)` does its work in `copy(frame:to:)` on a raw pointer and the Metal overload only takes the address; `SnapshotExpander` and `ExpandParams` moved |
| `MetalBarnesHutSolver.State`, `.CheckpointError`, `RunVideos.Progress`, `KeyFrameTake.Entry` | `CheckpointRecords.swift`, `RunCheckpoint.swift` | top-level types `SolverState`, `RunCheckpointError`, `VideoProgress` and `KeyFrameEntry`; the old names are typealiases, so uses and JSON are unchanged |
| `RunCheckpoint.codeVersion` | same | CryptoKit's SHA-256 on the Mac, `PortableSHA256` elsewhere; `F_FULLFSYNC` under `canImport(Darwin)` |
| `StyleAuto.swift` | `StyleAuto+Sheet.swift` | `ranked`, `score`, `Outcome` and `choose`, which draw a `LookSheet`, moved |
| `QueueStore.swift` | `ProcessProbe.swift` | `ProcessProbe` and `Spawn` moved under `canImport(Darwin)`, with Linux stand-ins |

Smaller edits: `RunStatus.append`, the runner's App Nap assertion and the night's line
buffering are under `canImport(Darwin)`; the WebP writer's body is under `canImport(CoreGraphics)`
and throws `noWebPEncoder` elsewhere; `NightRecipe.daySeed` is two expressions, because Swift on
Linux would not type-check the one in time; `LookStageTests` leaves its one look grid test out
where CoreGraphics is missing, and `SceneFolderTests` writes `SolverState` for the type it wrote
as `MetalBarnesHutSolver.State`.

**`concurrentPerform`.** libdispatch on Linux declares the closure of
`DispatchQueue.concurrentPerform` `@Sendable`, which Apple's does not, so the strict concurrency
check refused every use that shares a buffer between its iterations on purpose. A
`concurrentPerform(iterations:execute:)` in `SillageCore` calls `DispatchQueue.concurrentPerform`
on the Mac and hides the closure from the check on Linux; the tree builder, the GIF and
animation writers and the take reader call it. A new use of the Dispatch function in a portable
file fails `strict` on Linux with "capture of ... non-Sendable type": call this one instead.

## The cross-platform check

`Tests/SillageCoreTests/CrossPlatformTests.swift` prints, and asserts nothing: the SHA-256 of a
merger preset's sample (100 k drawn from 25 k massive, 75 104 tracers among 137 500 particles)
over its positions, velocities and masses, and over each other attribute; then one digest per
libm function, in `Float` and in `Double`, over the same 4 001 inputs; then one per simd function.
The digests come from `PortableSHA256`, written out and checked against the standard vectors, so
the two platforms hash the same way. `docs/notes/linux-build-digests.txt` holds what Linux
x86_64 gives (Swift 6.2, glibc 2.39), the same in two runs.

To compare: on the Mac, `./scripts/dev.sh test --filter CrossPlatformTests`, keep the
`CROSSPLATFORM` lines, sort them and `diff` them against that file.

ANSWER PENDING: the Mac's lines.

## What the CUDA tickets can rely on

- The scene, sampling, cameras, looks, takes, checkpoints, status files and costs build and pass
  their tests on Linux, so `sillage-cuda` can link `SillageCore` and `SillageRender` there.
- `TakeFraming.replay` and `.prepare` are the full pass's cameras and per-shot look, with no
  Metal in them. An engine that draws a frame conforms to `FramePreparing`.
- `Recording.copy(frame:to:)` reads a take's frame into any memory, a pinned buffer included.
- `RunCheckpoint`, `SolverState`, `VideoProgress` and `KeyFrameEntry` are the checkpoint's whole
  format, free of Metal types, and a checkpoint's JSON did not change.
- `PortableSHA256` is there for any digest that has to be the same on both platforms.
