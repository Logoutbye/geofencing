# Geofence PoC

Proof of concept: register a geofence once, then get an automatic
notification when you enter/exit — **even with the app fully closed**.
UI and backend are intentionally minimal; the only thing this proves is
that OS-level background geofencing works.

## How it works

- **`geolocator`** — used exactly once, to read your current GPS position
  when you tap "Set Office Location Here." Never polled after that.
- **`shared_preferences`** — stores the saved office (name/lat/lng/radius)
  and the last check-in/check-out timestamps. No database, no accounts.
- **`native_geofence`** — hands the region off to the OS (Android
  `GeofencingClient`, iOS `CLLocationManager` region monitoring). The OS —
  not your app — watches the region and wakes a background isolate on
  enter/exit, so there's no continuous tracking and the app can be closed
  or killed.
- **`flutter_local_notifications`** — fires the "Arrived" / "Left" alert
  from that background isolate.

Flow matches the spec exactly:
`open app once → set location → close app → walk in → OS detects it →
notification appears`.

## Project layout

```
lib/
  main.dart                    UI: one button, one status card
  geofence_callback.dart       top-level background entry point (@pragma('vm:entry-point'))
  models/office_location.dart  the saved geofence target
  services/storage_service.dart      SharedPreferences wrapper
  services/notification_service.dart flutter_local_notifications wrapper
android/app/src/main/AndroidManifest.xml   permissions + receivers
ios/Runner/AppDelegate.swift               plugin registrant callback
ios/Runner/Info-additions.plist.txt        keys to merge into Info.plist
```

## Setup

1. Copy this `lib/`, `pubspec.yaml`, and the `android/`/`ios/` files into a
   fresh `flutter create geofence_poc` project (or drop them into your own
   project, merging the Android manifest / iOS files rather than
   overwriting yours).
2. `flutter pub get`

### Android

- Set `minSdkVersion` to **23 or above** in `android/app/build.gradle`.
- Kotlin **1.9.25+** and Gradle **8+** are required by `native_geofence` —
  bump these if `flutter pub get`/build complains.
- The manifest in this repo already has the required permissions and the
  three `native_geofence` receivers/service wired in.

### iOS

- Merge the keys from `ios/Runner/Info-additions.plist.txt` into
  `ios/Runner/Info.plist`.
- Set `platform :ios, '14.0'` in `ios/Podfile`.
- `AppDelegate.swift` is already updated to register the plugin for
  background callbacks.
- `pod install` inside `ios/`.

### Notes on `GeofenceCallbackParams`

`geofence_callback.dart` reads `params.event` (an enter/exit/dwell enum).
This matches the `native_geofence` API at the time this was written
(v1.2.2) — if a later version renames a field, your editor's autocomplete
on `params.` inside `geofenceTriggered` will show the current shape; the
rest of the logic (save timestamp → notify) doesn't need to change.

## Testing the success criteria

> "I set my office location once, close the app, enter the area, and my
> phone automatically shows 'Arrived at Office'."

1. Run the app on a **real device** (geofencing is unreliable on
   simulators/emulators — see note below).
2. Grant location permission when prompted, then grant **"Allow all the
   time"** when prompted a second time (Android) or choose **"Always
   Allow"** (iOS) — this second grant is required or background events
   won't fire.
3. Stand where you want "Office" to be, tap **Set Office Location Here**.
   The status card should show the saved coordinates and "Geofence
   registered with OS: Yes ✅".
4. **Force-close the app** (swipe it away from recents — not just
   backgrounding it).
5. Walk out past the 100m radius, then back in.
6. A **"✅ Arrived at Office"** notification should appear with no app
   open. Walking back out should trigger **"🏠 Left Office"** with the
   elapsed duration.
7. Reopen the app and pull to refresh — check-in/check-out times should
   reflect what happened while it was closed.

**Testing in a small (2-3 room) space:**

The app now has a **Radius (meters)** field above the button (default 25m,
floor of 15m) so you can shrink/grow the geofence and re-test without
touching code — just change the number and tap "Set Office Location Here"
again to re-register.

Be aware of the actual ceiling on precision here: consumer GPS is
typically accurate to ~5-20m outdoors with a clear sky, and indoors
(walls/roof blocking satellites) it's often worse and can fall back to
wifi/cell-based positioning, which is fuzzier still. A "room" is usually
3-5m across. That means **no radius setting will reliably distinguish
one room from the next room** — the location fix itself doesn't have
that resolution, geofence or no geofence. What a smaller radius *does*
give you is a more meaningful test of "did I leave the general small
zone" (e.g. "left the bed/desk area") than the default 100m, which is
far too big for a 2-3 room space. If you need genuinely sub-5m precision
indoors, that's a different problem (BLE beacons / UWB / indoor
positioning) — out of scope for GPS-based geofencing.

**Device/emulator caveats:**
- Android emulators often won't fire geofence events unless some app is
  actively using location — open Google Maps briefly to force a location
  fix if testing on an emulator.
- iOS simulators don't support region monitoring at all — use a real
  iPhone.
- Real GPS geofences are rarely exact at very small radii; 100m is a
  reasonable radius for reliable indoor/outdoor testing.

## Explicitly out of scope (per the spec)

No auth, no API, no database, no accounts, no continuous location
tracking, no map picker UI. Everything is local `SharedPreferences` plus
one local notification.# geofencing
