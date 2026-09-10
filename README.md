# RouteLocation

RouteLocation is an iPhone-side location and route simulation app derived from [StikDebug](https://github.com/StikDebug/StikDebug). It keeps StikDebug's proven pairing, LocalDevVPN loopback tunnel, Developer Disk Image, `idevice` FFI, RSD/DVT, and location-simulation core, while presenting a focused, local-first route workflow.

RouteLocation is intended for sideloading, not App Store distribution. It has no account, analytics, telemetry, cloud database, or custom backend.

## Features

- System-wide developer location simulation and immediate single-point teleport
- Coordinate selection by map tap, Apple MapKit search, pasted text, imported file, or favorite
- Multi-waypoint editing, reordering, coordinate editing, and open/closed routes
- Fully local Straight routes with no routing-server dependency
- Apple `MKDirections` Navigation routes for automobile and walking geometry
- Complete saved navigation geometry for later playback without recalculation or Internet
- Precise decimal custom speeds, including **18.6 km/h**
- Deterministic 0.5-second elapsed-time playback without pre-generating sample arrays
- Once and Infinite Loop modes with continuous final-to-first closed-route geometry
- Persistent favorite locations and individually stored saved-route JSON files
- Best-effort background playback using StikDebug's audio/location keep-alive infrastructure
- Network-path monitoring and bounded device-session reconnect that preserves elapsed progress
- Setup diagnostics for pairing, tunnel, DDI, location simulation, network interface, and reachability

Fixed-speed playback never uses OpenStreetMap/Overpass speed limits or `MKRoute.expectedTravelTime`. `MKDirections` determines geometry only; the selected km/h value controls movement.

## Requirements

- iPhone running iOS 17.4 or later
- Developer Mode enabled
- A valid pairing file for that same iPhone
- [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044) running
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

## Normal use

Open RouteLocation → load a favorite route → set **18.6 km/h** → select **Infinite Loop** → Start Playback → switch to another app. The Map tab shows the current simulated position and lap number when RouteLocation is foregrounded.

To teleport, tap the map or search for a place and choose **Simulate Here**. **Return to Real Location** clears the developer-simulated location.

### Straight Route

Straight geometry connects waypoints in their entered order. Closing a route explicitly adds the final-waypoint-to-first-waypoint segment. Geometry creation and playback are local and require no routing server or Internet connection once the coordinates exist.

### Navigation Route

Navigation mode resolves every adjacent waypoint pair independently with Apple `MKDirections`; a closed route also resolves the last-to-first pair. A failed segment identifies its waypoint pair and no partial geometry replaces the existing route.

Calculating or recalculating a Navigation route requires Internet. Saving stores all resolved polyline coordinates. Loading the saved route later uses those cached coordinates directly and does not call `MKDirections` unless **Calculate with Apple Maps** is explicitly selected again.

Changing a waypoint, transport mode, or closed/open state marks navigation geometry stale. Changing speed, playback mode, or route name does not.

## Offline behavior

Saved favorites, Straight routes, saved Navigation geometry, custom speed, infinite looping, and DVT playback remain available without Internet as long as LocalDevVPN and the on-device services are reachable. Apple search, new navigation calculations, and uncached map tiles may fail while offline. An offline network status does not block cached-route playback.

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

Build artifacts require GitHub sign-in. Tagged RouteLocation releases publish the same unsigned IPA on the repository's **Releases** page, where public downloads do not require an account.

## Security and privacy

RouteLocation stores favorites and routes under its Application Support directory. Favorites use one atomic JSON file; each route has an independent atomically written JSON file so one interrupted write cannot corrupt every route. Coordinates are not uploaded except to normal Apple MapKit services when you explicitly request search or navigation calculation. Pairing contents are never displayed or intentionally logged.

## Testing boundary

Unit tests cover parsing, geometry/cumulative distances, binary-search interpolation, straight/closed construction, playback math, elapsed-time reconnect continuity, Codable round trips, and saved geometry reload. Those tests do not prove physical-device pairing, DDI mounting, LocalDevVPN, DVT commands, background survival, or target-app behavior; those require a real iPhone.

## Credits and license

RouteLocation is a derivative of **StikDebug** by Stephen Bove (Stik) and contributors, and does not claim original authorship of its device communication core. The bundled `idevice` work is credited to jkcoxson and its contributors. [TLocation](https://github.com/truongkma/t-location) informed the location-only product scope. Background/network ideas were adapted selectively from StikDebug [PR #432](https://github.com/StikDebug/StikDebug/pull/432) by dizzafizza; the route engine and persistence architecture here were implemented for RouteLocation rather than merging that PR wholesale.

The upstream **GNU Affero General Public License v3.0** is preserved unchanged in [LICENSE](LICENSE) and applies to this derivative.
