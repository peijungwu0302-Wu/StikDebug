# RouteLocation engineering rules

- This is a location-only iOS derivative of StikDebug targeting iPhone and iOS 17.4+.
- Preserve StikDebug's pairing, LocalDevVPN tunnel, DDI, idevice FFI, RSD/DVT, and location-command core. Do not reimplement idevice or Apple device protocols without a demonstrated, scoped bug.
- Keep UI code above application-facing services; views must not own DVT/device session mechanics or playback clocks.
- `MKDirections` determines navigation geometry only. User-selected km/h controls playback; never use MK travel time or OSM/Overpass speed limits.
- Straight geometry is local. Persist complete navigation geometry so saved routes play offline without recalculation.
- Background playback is critical but best-effort. Acquire resources on start, release them on stop, and never stop solely because a view disappears or the scene backgrounds.
- Reconnect attempts are bounded and preserve monotonic elapsed playback state; never restart at waypoint zero after a connection gap.
- Pairing files are sensitive trust credentials. Never log, upload, fixture, or commit their contents.
- Keep storage local-first with no backend, account, analytics, telemetry, Firebase, Supabase, or CloudKit.
- Preserve AGPL-3.0, upstream attribution, and bundled-library credits.
- Do not claim Xcode, simulator, or physical-device validation unless it actually ran.
