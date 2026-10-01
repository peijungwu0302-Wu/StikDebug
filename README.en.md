# RouteLocation

[繁體中文](README.md) | English

RouteLocation is a local location-simulation and route-playback tool for iPhone. Choose a coordinate or place, build routes on the device, and play them at a custom speed. RouteLocation is a location-only derivative of StikDebug; it does not require an account, custom backend, or cloud sync.

## Install

Add the official source in SideStore's source manager:

<https://raw.githubusercontent.com/peijungwu0302-Wu/StikDebug/main/source.json>

Install and update RouteLocation from the source page. You can also download the latest unsigned IPA and sign it with SideStore, AltStore, TrollStore, or another compatible tool:

<https://github.com/peijungwu0302-Wu/StikDebug/releases/latest/download/RouteLocation-unsigned.ipa>

GitHub Releases are the canonical changelog for each version.

## Features

- Select a single location from the map, search, favorites, or exact coordinates.
- Create, preview, save, and play multi-waypoint routes with straight or Apple Maps navigation geometry.
- Adjust playback speed, pause and resume, choose finite or infinite laps, and preserve route progress through location-connection recovery.
- Switch directly between a single point and route playback without first restoring the real location.
- Manage favorite places, recent locations, and saved routes.
- Choose Traditional Chinese or English, System / Light / Dark appearance, and a text-size preference that applies only to read-only coordinate values.

## Requirements

- iPhone running iOS 17.4 or later.
- Developer Mode enabled in iPhone Settings.
- A valid pairing file for this device. Pairing files are sensitive trust credentials; do not share, commit, or upload them.
- [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044) installed and enabled to provide the local network path from RouteLocation to device services.
- Wi-Fi or cellular data; Wi-Fi is not a product requirement.
- The IPA installed and signed with SideStore, AltStore, TrollStore, or another compatible tool.

### DDI is optional

The Developer Disk Image (DDI) is an Apple developer-service component. RouteLocation checks and prepares it on a best-effort basis; an already-mounted image needs no duplicate work, and preparation failures are recorded for diagnostics while available location flows continue. An unmounted DDI does not block normal single-point or route location simulation. View its status or manually check/mount it under **Settings → Developer Tools**. DDI does not store or retrieve the device's real GPS position.

## First-time setup

1. Enable Developer Mode in iPhone Settings.
2. Install RouteLocation from the SideStore source, or install and sign the unsigned IPA.
3. Import a valid pairing file belonging to this iPhone.
4. Enable LocalDevVPN and grant the location access RouteLocation requests.
5. Return to the map; select a location and start simulation while Wi-Fi or cellular data is available.

Normal location use does not require DDI to be mounted first. If the device channel is not ready, follow the setup or connection guidance shown in the app. Pairing, LocalDevVPN, and device-service failures are separate from DDI status.

## Wi-Fi and cellular data

Either Wi-Fi or cellular data can carry the device-service connection. LocalDevVPN supplies only the local path from RouteLocation to the same iPhone; it does not proxy ordinary Internet traffic for other apps. If a cold cellular start needs the assisted flow, configure RouteLocation's Data Off / Data On Shortcuts first and follow the in-app instructions. That flow may temporarily turn cellular data off; DDI is not a prerequisite for it.

Apple Maps search, uncached map tiles, reverse geocoding, and new navigation-route calculations may require Internet access. Straight geometry and complete saved navigation geometry can be used locally.

## Single-point and route simulation

Select or enter a coordinate on the map, then tap **Simulate Here**. If a single point is already active, you can retarget directly without first restoring the real location. To create a route, add waypoints, choose straight or navigation geometry, set speed and lap behavior, preview, and then start playback. While playing, adjust speed, pause, or resume; if the location connection is interrupted, the app preserves progress through its existing recovery flow.

**Restore Real Location** stops the current simulation and clears the developer location override so the device returns to real GPS. Direct switching between a single point and a route preserves the simulated state instead of switching to real GPS first.

## Favorites and My

The **My** tab manages favorite places, recent locations, and saved routes. Favorite sorting—including manual order—is shared with the map's quick favorite picker. Data stays on the device; removing or reordering favorites does not upload it.

## Appearance, language, and coordinate text

Under **Settings → Interface**, choose Traditional Chinese or English, System / Light / Dark appearance, and Smaller, Standard, Larger, or Follow System coordinate text. The coordinate-text preference applies only to read-only exact-coordinate displays; it does not change place names, routes, buttons, ordinary text, or coordinate-entry fields.

## Optional Health Sync

Health Sync can calculate steps from elapsed time or distance during route playback and attempt to write them to Apple Health. It is optional; step writing requires usable HealthKit capability in the current signing configuration and user authorization. Some free sideloading signatures do not include the required HealthKit entitlement, so step sync may be unavailable. This does not affect single-point location, route playback, or any location feature. Single-point teleports do not record steps.

## Background playback limitations

Background playback is best-effort and managed by iOS. Force-quitting the app, iOS process termination, a device restart, a LocalDevVPN interruption, or other system conditions may stop playback. RouteLocation does not stop playback merely because a view changes or the app enters the background, and it cannot control another app's VPN.

## Privacy

RouteLocation stores favorites and routes locally and has no accounts, analytics, telemetry, custom backend, CloudKit, or route uploads. Apple services are contacted only when you use map display, search, navigation calculations, or place/address lookup. Pairing-file contents are not uploaded.

## Build from source

An actual iOS build requires macOS and Xcode:

```sh
xcodebuild -project StikDebug.xcodeproj -scheme StikDebug \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

GitHub Actions runs tests, archives the app, and packages an IPA on feature branches; production releases promote the same verified IPA artifact without rebuilding from the production tag. The unsigned IPA contains no personal Apple ID, signing certificate, or pairing file.

## Testing boundary

Automated tests cover coordinate parsing, route geometry and playback, persistence, connection recovery, and other application logic. Unit tests cannot prove behavior on a particular iPhone, carrier, LocalDevVPN setup, pairing file, RSD/DVT session, or iOS background state; those still require physical-device validation. Do not treat CI or simulator results as a guarantee for every device.

## Credits and license

RouteLocation is derived from **StikDebug**, developed by Stephen Bove (Stik) and contributors, and retains its upstream device-communication core and license. The `idevice` work is credited to jkcoxson and its contributors; see the source and license files for other upstream and package credits.

This project is distributed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**. See [LICENSE](LICENSE).
