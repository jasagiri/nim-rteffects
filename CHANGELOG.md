# Changelog

## [0.2.0] - 2026-03-29

### Added
- **Full `ref object` support**: `Eff[T]` now handles user-defined ref types via `boxRef`/`unboxRef`.
- **VM Event-Driven Engine**: Replaced O(N) frame scans with optimized pending lists for O(1) frame dispatch.
- **Algebraic Completeness**: Added `meet` and `negate` operations for `Eval[T]` type.
- **Strict Error Reporting**: Budget exhaustion now returns an explicit `Timeout` error.
- **Memory Safety**: Runtime type validation (`of` checks) added to all unboxing operations.

### Changed
- **Standard Handlers Refactor**: HTTP and File handlers now use `ref object` payloads instead of newline-separated strings (BREAKING).
- **VM Queue**: `readyQ` migrated from `seq` to `Deque` for better memory efficiency.

### Fixed
- Fixed memory leakage in VM's `readyQ` growth.
- Fixed silent value loss when using user-defined types in `pure` or `andThen`.
- Eliminated all compilation warnings under `--warningAsError:on`.

## [2.0.0] - 2026-03-15

### Added
- Complete rewrite with state-machine VM engine.
- Belnap 4-valued evaluation semantics (Eval[T]).
- Tiered API structure (Algebra, VM, Semantics).
- Standard handler definitions for HTTP and File I/O.
- Initial set of 17 examples.

## [1.0.0] - 2026-03-01
- Initial release with basic algebraic effects.
