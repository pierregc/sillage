# There is no CI. `./scripts/dev.sh check` is the gate

Run it before every commit. Seventy-eight seconds, and it does everything the GitHub workflow
used to: the formatter the strict way, a strict-concurrency typecheck of all three modules,
the application build, and the whole suite.

**Why it went away.** The repository is private and the workflow ran on `macos-latest`.
Private repositories meter Actions minutes, and macOS bills at *ten times* the clock: 215 real
minutes over the first ten days of September came to 2 148 billed against a 2 000 free
allowance, and the account was cut off mid-month. A hobby project should not pay for that. The
same 84 tests take 24 seconds on this machine, so the runner was costing seventy times the
wall clock for an identical answer. If it is ever wanted back, making the repository public
restores it free and unlimited with no other change.

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
