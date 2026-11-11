# `./scripts/dev.sh check` is the gate, and GitHub checks Linux

Run `./scripts/dev.sh check` before every commit: no workflow builds the Mac's code. Since #281
a small workflow checks, on every push, what the Mac cannot: the CUDA engine's code and the
portable Swift on Linux.

## The Linux workflow (#281)

`.github/workflows/linux.yml` runs on every push (the `assets/` branches aside) and on pull
requests from forks, on GitHub's Ubuntu 24.04 runner, with `permissions: contents: read`, no
secret and no action but GitHub's own checkout. Three jobs side by side.

Job `cuda`, 37 seconds on its first run:

- `scripts/kernel-check.sh` with `clang++` and `g++`: the checks of
  [one-kernel-source.md](one-kernel-source.md) that `./scripts/dev.sh check` runs on the Mac;
- the CPU target of `cuda/src` built with both compilers, and its tests run;
- `nvcc` and the CUDA headers at 13.5, the version of
  [cuda-walk-spike.md](cuda-walk-spike.md), from NVIDIA's apt repository: `cuda/src` and
  `cuda/tests` compiled for sm_120, and no double precision instruction in their PTX. Compile
  only. Since #273 also the two libraries the Swift links, the GPU's for sm_86, sm_89 and
  sm_120 ([cuda-engine.md](cuda-engine.md)): a minute in all.

Job `swift`, in the `swift:6.2-noble` image: `scripts/linux.sh check`, so the formatter, the
strict-concurrency typecheck and the tests of the Swift that builds on Linux
([linux-build.md](linux-build.md)). 8 min 54 s and 9 min 0 s on its first two whole runs, so
the workflow takes nine minutes: 40 s to fetch the image, 6 s of formatter, 2 min 15 s to build
the two modules and typecheck them, 1 min 50 s to build the tests and 4 min to run the 397 of
them. That is under the ten minutes the workflow was given, not by much, and the job is cut off
at fifteen. If it grows: running the formatter and the typecheck in a job beside the tests'
saves about a minute, and past that the floor is the longest test, `archetypesPassTheSanityCheck`,
two minutes on its own.

#273 made it grow, by the CUDA engine's CPU library, its Swift module and its tests, about 35 s
on the runner, and one run took 11 min 31 s where the one before took 8 min 1 s, most of it the
runner's own speed (the tests' build, two files longer, took 52 s more). So `scripts/linux.sh
check` now runs as two jobs: `swift`, `scripts/linux.sh test`, the modules built and every test
run; and `swift-checks`, `scripts/linux.sh lint` then `scripts/linux.sh strict`, the formatter
and the strict concurrency typecheck. Together they run what `scripts/linux.sh check` runs.

**What it does not check**: nothing of Metal and nothing of macOS (no macOS job, on purpose),
so not the files and the tests `scripts/linux-skip.txt` and `scripts/linux-skip-tests.txt` name,
not the app, and not what Metal computes; and nothing on a GPU: the runner has none, so no CUDA
kernel runs there, only on the CPU target. It adds to the Mac and replaces nothing.

**A PR merges only with the workflow green on its head.** Whoever pushed reads the run's result
and fixes a red run in the same PR.

**It is free because the repository is public.** GitHub does not meter Actions on public
repositories. If the repository ever goes private again, its Linux minutes count against the
account's allowance, one billed minute a minute where macOS counted ten, each job rounded up to
the minute. Turn the workflow off before that matters, as the macOS one was.

## Why the macOS workflow went away

`./scripts/dev.sh check` does everything the macOS workflow used to: the formatter the strict
way, a strict-concurrency typecheck of all three modules, the application build, and the whole
suite. Seventy-eight seconds when this was written.

**Why it went away.** The repository was private then and the workflow ran on `macos-latest`.
Private repositories meter Actions minutes, and macOS bills at *ten times* the clock: 215 real
minutes over the first ten days of September came to 2 148 billed against a 2 000 free
allowance, and the account was cut off mid-month. A hobby project should not pay for that. The
same 84 tests took 24 seconds on this machine, so the runner was costing seventy times the
wall clock for an identical answer. The repository is public now, which is what makes the Linux
workflow free; the Mac's check stays local all the same: it needs Metal on this machine's GPU,
which no hosted runner has.

**What was lost, and what replaces it.** CI was the only thing building the *package*, and the
package turns on strict concurrency. A `static var` on an enum compiles perfectly through
plain `swiftc` and fails there with "not concurrency-safe because it is nonisolated global
shared mutable state" — four calibration constants in `StarFormation`, left mutable so a probe
could sweep them, broke three builds in a row without a hint locally. `check` now applies that
setting by hand, per module, which is the closest this machine can get: SwiftPM itself cannot
run here at all.

`SillageRender`'s statics escape strict concurrency because they hang off classes marked
`@unchecked Sendable`. A tuning constant belongs as `static let`; if a sweep needs one
mutable, make it mutable for the sweep and put it back.

The other thing lost is the clean machine, and that one has no local replacement. CI caught a
real bug on 4 September that every targeted probe had missed, because it ran invariants the
rest of the code holds rather than the ones being looked at. `check` runs the same suite, so
it would have caught that one too — but nothing here will catch something that depends on a
fresh checkout or a different toolchain.
