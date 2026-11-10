# `./scripts/dev.sh check` is the gate, and GitHub checks Linux

Run `./scripts/dev.sh check` before every commit: no workflow builds the Mac's code. Since #281
a small workflow checks, on every push, what the Mac cannot: the CUDA engine's code on Linux.

## The Linux workflow (#281)

`.github/workflows/linux.yml` runs on every push (the `assets/` branches aside) and on pull
requests from forks, on GitHub's Ubuntu 24.04 runner, with `permissions: contents: read`, no
secret and no action but GitHub's own checkout. Job `cuda`, about two minutes, capped at ten:

- `scripts/kernel-check.sh` with `clang++` and `g++`: the checks of
  [one-kernel-source.md](one-kernel-source.md) that `./scripts/dev.sh check` runs on the Mac;
- the CPU target of `cuda/src` built with both compilers, and its tests run;
- `nvcc` and the CUDA headers at 13.5, the version of
  [cuda-walk-spike.md](cuda-walk-spike.md), from NVIDIA's apt repository: `cuda/src` and
  `cuda/tests` compiled for sm_120, and no double precision instruction in their PTX. Compile
  only.

**What it does not check**: nothing of Metal and nothing of macOS (no macOS job, on purpose),
so not the formatter, not the strict-concurrency typecheck, not the app and not the Swift tests
of the Mac; and nothing on a GPU: the runner has none, so no CUDA kernel runs there, only on the
CPU target. It adds to the Mac and replaces nothing. #272 adds a `swift` job that builds and
tests the portable Swift on Linux.

**A PR merges only with the workflow green on its head.** Whoever pushed reads the run's result
and fixes a red run in the same PR.

**It is free because the repository is public.** GitHub does not meter Actions on public
repositories. If the repository ever goes private again, its Linux minutes count against the
account's allowance, one billed minute a minute where macOS counted ten: at two minutes a push,
the 2 000 free minutes of a month are a thousand pushes. Turn the workflow off before that
matters, as the macOS one was.

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
