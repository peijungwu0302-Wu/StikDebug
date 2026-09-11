# RouteLocation

RouteLocation is an iPhone-side location and route simulation app derived from [StikDebug](https://github.com/StikDebug/StikDebug). It keeps StikDebug's proven pairing, LocalDevVPN loopback tunnel, Developer Disk Image, `idevice` FFI, RSD/DVT, and location-simulation core, while presenting a focused, local-first route workflow.

RouteLocation is intended for sideloading, not App Store distribution. It has no account, analytics, telemetry, cloud database, or custom backend.

Latest public unsigned IPA (no GitHub login): https://github.com/peijungwu0302-Wu/StikDebug/releases/latest/download/RouteLocation-unsigned.ipa

The app's development, fallback, and first-launch language is Traditional Chinese. A complete English localization can be selected from RouteLocation's Settings tab.

## Features

- System-wide developer location simulation and immediate single-point teleport
- Coordinate selection by map tap, Apple MapKit search, exact coordinate entry, pasted text, imported file, or favorite
- Multi-waypoint editing, reordering, coordinate editing, and GPX/CSV/JSON/GeoJSON/KML file import
- Fully local Straight routes with no routing-server dependency
- Apple `MKDirections` Navigation routes for automobile and walking geometry
- Complete saved navigation geometry for later playback without recalculation or Internet
- Precise decimal custom speeds, including **18.6 km/h**
- Deterministic 0.5-second elapsed-time playback without pre-generating sample arrays
- Once and Infinite Loop modes with continuous final-to-first closed-route geometry
- Persistent favorite locations, favorite routes, explicit route naming/renaming, and individually stored saved-route JSON files
- New routes default to a closed path with Infinite Loop playback; loaded routes preserve their saved behavior
- Best-effort background playback using StikDebug's audio/location keep-alive infrastructure
- Wi-Fi/cellular path monitoring, real RSD tunnel health checks, and bounded device-session reconnect that preserves elapsed progress
- Setup diagnostics for pairing, LocalDevVPN tunnel stage, DDI, DVT, location simulation, active transport, and Internet reachability
- Sanitized on-device diagnostic reports that never include pairing credentials

Fixed-speed playback never uses OpenStreetMap/Overpass speed limits or `MKRoute.expectedTravelTime`. `MKDirections` determines geometry only; the selected km/h value controls movement.

## Requirements

- iPhone running iOS 17.4 or later
- Developer Mode enabled
- A valid pairing file for that same iPhone
- [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044) running
- Wi-Fi **or cellular data**; Wi-Fi is not a RouteLocation requirement
- Developer Disk Image files prepared and mounted by RouteLocation
- RouteLocation installed through SideStore, AltStore, or another compatible sideloading signer

The pairing file contains sensitive device-trust credentials. Never post it, commit it, upload it, or send its raw contents to another person. RouteLocation stores it locally and does not log or upload its contents. See the [StikDebug pairing guide](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md).

## First setup

1. Enable Developer Mode in iOS Settings if it is not already enabled.
2. Sign and install the unsigned IPA with SideStore or AltStore.
3. Open RouteLocation and use **Setup → Import Pairing File**.
4. Start LocalDevVPN and return to RouteLocation.
5. Confirm Pairing File is Present, Device Tunnel is Connected, and Developer Disk Image is Mounted.
6. Grant Always location access when requested for the strongest best-effort background behavior.

Normal use does not require a Windows PC or Mac after those prerequisites are ready.

## Cellular-only workflow

RouteLocation is designed to attempt direct startup with Wi-Fi completely off:

1. Turn Wi-Fi off in iOS Settings.
2. Turn Cellular Data on and verify ordinary 4G/5G Internet access.
3. Connect LocalDevVPN.
4. Open RouteLocation and confirm **Transport: Cellular**.
5. Check that the Device Tunnel and DVT session connect, then teleport or start a route.
6. Put RouteLocation in the background and open the target app. That app's Internet traffic continues over cellular; RouteLocation does not proxy it.

LocalDevVPN remains required. It supplies only the local route from RouteLocation to the device's RSD/DVT services and is separate from ordinary cellular Internet. Actual successful location commands are stronger health evidence than an auxiliary attempt to open a new RSD/bootstrap connection. An `ECONNREFUSED` bootstrap probe therefore does not tear down a DVT session whose location commands still work. Recovery begins only after repeated real command failures, and deterministic playback continues from monotonic elapsed time instead of restarting the route.

If direct cellular bootstrap cannot expose the device service, Setup shows **Cellular Bootstrap Mode**: keep LocalDevVPN enabled, temporarily turn Cellular Data off, and return to RouteLocation. It automatically retries Pairing → Tunnel → RSD → DDI → DVT; after the first location command succeeds, Cellular Data can be restored. RouteLocation cannot automate Cellular Data and does not require Wi-Fi or Airplane Mode.

This offline-bootstrap-then-cellular workflow has been physically confirmed on one iPhone, but remains dependent on iOS version, carrier and LocalDevVPN behavior and is not a universal compatibility guarantee.

## Optional HealthKit step synchronization

Settings → Health Sync can write route-derived steps using only new simulated distance and an editable stride length (default 0.80 m). Writes are batched at roughly 30 seconds and flushed when playback stops or the app backgrounds. Teleports generate no steps, and reconnect does not duplicate distance. HealthKit is independent: denial, failure, or unavailable entitlement never interrupts location simulation.

SideStore/AltStore free provisioning may not preserve HealthKit capability. In that case RouteLocation reports that the current signature does not support HealthKit while location features continue normally. Written samples retain RouteLocation as their source and third-party apps may choose not to count them.

RouteLocation uses no NextDNS, custom DNS blocking, backend server, analytics or telemetry. SideStore/AltStore performs user-side signing, installation and seven-day refresh; RouteLocation never asks for Apple ID, Anisette data, certificates or account passwords.

If iLoader's **Manage Pairing File** screen does not list RouteLocation, use iLoader's **Export** action for the same iPhone or iPad. Transfer the exported pairing file to the device, then import it from **RouteLocation → 設定 → 匯入配對檔案**. Do not use another device's file, and do not rely on iLoader's app-specific **Place** list recognizing RouteLocation's bundle identifier.

## Normal use

Open RouteLocation → load a favorite route → set **18.6 km/h** → select **Infinite Loop** → Start Playback → switch to another app. The Map tab shows the route name, current simulated position, distance, speed, and lap number when RouteLocation is foregrounded. It also provides distinct Stop, Clear Route, and Return to Real Location actions.

To teleport, tap the map or search for a place and choose **Simulate Here**. **Return to Real Location** clears the developer-simulated location.

### Straight Route

Straight geometry connects waypoints in their entered order. Closing a route explicitly adds the final-waypoint-to-first-waypoint segment. Geometry creation and playback are local and require no routing server or Internet connection once the coordinates exist.

### Navigation Route

Navigation mode resolves every adjacent waypoint pair independently with Apple `MKDirections`; a closed route also resolves the last-to-first pair. A failed segment identifies its waypoint pair and no partial geometry replaces the existing route.

Calculating or recalculating a Navigation route requires Internet. Saving stores all resolved polyline coordinates. Loading the saved route later uses those cached coordinates directly and does not call `MKDirections` unless **Calculate with Apple Maps** is explicitly selected again.

Changing a waypoint, transport mode, or closed/open state marks navigation geometry stale. Changing speed, playback mode, or route name does not.

## Offline behavior

Saved favorites, Straight routes, saved Navigation geometry, custom speed, infinite looping, and DVT playback remain available without Internet as long as LocalDevVPN and the on-device services are reachable. Apple search, new navigation calculations, and uncached map tiles may fail while offline. Wi-Fi is never required by RouteLocation, and an Internet-offline status does not block cached-route playback.

## Background limitations

Background playback is critical but necessarily best-effort under iOS. RouteLocation acquires silent-audio, low-accuracy Core Location, and renewable background-task resources only while teleport or route playback is active, and releases them when simulation stops.

Force-quitting RouteLocation stops it. iOS process termination, reboot, a broken LocalDevVPN tunnel, DDI/device-service failure, or other system conditions may also stop simulation. RouteLocation does not claim permanent execution and cannot automate another app's VPN controls.

## Build from source

Xcode on macOS is required for an actual iOS build:

```sh
xcodebuild -project StikDebug.xcodeproj -scheme StikDebug \
  -configuration Debug -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

The historical project/target/module name remains `StikDebug` to minimize risk to upstream project structure; the built product and display name are `RouteLocation.app` / RouteLocation. Product-facing names are centralized in `ProductIdentity.swift` and Xcode build settings.

### GitHub Actions unsigned IPA

Open **Actions → Build RouteLocation IPA → Run workflow**. The macOS job resolves Swift packages, compiles with signing disabled, runs unit tests on an available iPhone simulator where supported, packages `Payload/RouteLocation.app`, and uploads `RouteLocation-unsigned.ipa`. The IPA contains no personal Apple ID, provisioning profile, signing certificate, or pairing file and is intended to be re-signed by SideStore/AltStore.

Build artifacts require GitHub sign-in. Tagged releases publish both a versioned IPA and stable `RouteLocation-unsigned.ipa` on the public **Releases** page. The stable latest URL is https://github.com/peijungwu0302-Wu/StikDebug/releases/latest/download/RouteLocation-unsigned.ipa.

## Security and privacy

RouteLocation stores favorites and routes under its Application Support directory. Favorites use one atomic JSON file; each route has an independent atomically written JSON file so one interrupted write cannot corrupt every route. Coordinates are not uploaded except to normal Apple MapKit services when you explicitly request search or navigation calculation. Pairing contents are never displayed or intentionally logged.

## Testing boundary

Unit tests cover parsing, geometry/cumulative distances, binary-search interpolation, straight/closed construction, playback math, transport classification/transitions, retry policy, healthy/stale handoff behavior, elapsed-time reconnect continuity, Codable round trips, and saved geometry reload. Those tests do not prove physical-device cellular RSD/DVT connectivity, pairing, DDI mounting, LocalDevVPN, background survival, or target-app Internet behavior; those require a real iPhone.

## Credits and license

RouteLocation is a derivative of **StikDebug** by Stephen Bove (Stik) and contributors, and does not claim original authorship of its device communication core. The bundled `idevice` work is credited to jkcoxson and its contributors. [TLocation](https://github.com/truongkma/t-location) informed the location-only product scope. Background/network ideas were adapted selectively from StikDebug [PR #432](https://github.com/StikDebug/StikDebug/pull/432) by dizzafizza; the route engine and persistence architecture here were implemented for RouteLocation rather than merging that PR wholesale.

The upstream **GNU Affero General Public License v3.0** is preserved unchanged in [LICENSE](LICENSE) and applies to this derivative.
