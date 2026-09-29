# RouteLocation v1.2.12 Bootstrap Session Implementation Plan

## Global constraints

- Preserve the v1.2.11 StikDebug pairing, LocalDevVPN, DDI, RSD/DVT, and assisted-bootstrap core.
- Keep research and warm-up location-free: neither path may call `location_simulation_set` or mutate the production target.
- Keep production location-session state serialized on `LocationSimulationCommandQueue`; experimental trials own temporary handles and always clean them.
- Keep `source.json`, release tags, `main`, and the production release workflow untouched.
- Target only the RouteLocation app version: marketing 1.2.12, build 8.

## Review focus

Session ownership/cleanup, concurrent preparation, healthy-session preservation, explicit endpoint injection, one-shot assisted fallback, immutable research reports, no real Shortcut URLs in tests, and English UI without hard-coded Traditional Chinese.

## Task 1: Location simulation session abstraction

Add a serialized prepared-session API around the existing FFI state. Add deterministic test seams for preparation, reuse, cleanup, and no-location-write preparation. Refactor `simulate_location` and clear behavior to reuse the prepared handle without duplicating the pairing/RSD/DVT bootstrap chain.

## Task 2: Endpoint strategy and warm session

Add validated `BootstrapEndpointMode` and explicit target resolution while preserving the legacy default. Integrate automatic Wi-Fi-only warm preparation into `LocationSessionCoordinator`; skip quietly for missing pairing, offline/cellular-only state, existing healthy sessions, or duplicate work. Expose developer-only endpoint selection without changing global target state for trials.

## Task 3: Isolated production-equivalent research trials

Add a temporary-handle FFI probe that reports the furthest stage and sanitized error metadata without touching production state or writing a location. Update direct cellular research to use explicit targets and preserve the existing Assisted fallback exactly once.

## Task 4: Full Cellular Research Suite

Create an immutable combined run model and orchestrator covering snapshot, session health, utun, Bonjour timeout, path probes, endpoint TCP matrix, and isolated FFI trials for 10.7.0.1 and 127.0.0.1. Add copy/share TXT and JSON from the same completed run and improve neutral candidate-peer diagnostics.

## Task 5: Localization audit and version metadata

Route user-facing strings through `L10n`, add English translations for the audit surface, keep Traditional Chinese natural as the source language, and set only the app target to marketing 1.2.12/build 8. Add tests for localization coverage and ensure test Shortcut seams never invoke `shortcuts://`.

## Verification

Run repository/static checks on Windows, validate plist/strings syntax, inspect the complete diff, and use the branch GitHub Actions workflow for macOS compilation and deterministic tests. Do not create a v1.2.12 tag or release.
