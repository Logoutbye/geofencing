import 'package:flutter/widgets.dart';
import 'package:native_geofence/native_geofence.dart';

import 'models/log_entry.dart';
import 'models/office_location.dart';
import 'services/notification_service.dart';
import 'services/storage_service.dart';

/// Entry point the OS calls when the device crosses the geofence boundary —
/// this runs the SAME WAY whether the app is open, backgrounded, or fully
/// killed. There is no special-casing for app state anywhere in this file;
/// that's the whole point of native_geofence. If it fires and notifies
/// correctly once, it works identically in all three states.
///
/// EVERYTHING in this function is wrapped so that no matter what fails —
/// notification, storage, distance math, anything — it gets written into
/// the on-screen log as a visible 'error' row instead of silently vanishing.
/// You have no debugger while walking around outside; this is the
/// replacement for that.
///
/// The `@pragma('vm:entry-point')` annotation is required: without it the
/// Dart compiler can tree-shake this function away in release builds and
/// the native side won't find it.
@pragma('vm:entry-point')
Future<void> geofenceTriggered(GeofenceCallbackParams params) async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = StorageService();

  // Promote to a foreground service immediately, before anything else.
  // On Android, some OEMs (notably Xiaomi/MIUI) restrict a killed app's
  // process from being woken by a silent background broadcast, even with
  // autostart/battery settings correctly granted. A foreground service is
  // harder to block since it must show a visible ongoing notification,
  // which standard Android protects more strongly. No-op / safely ignored
  // on iOS and on Android versions/configs that don't need it.
  var promoted = false;
  try {
    await NativeGeofenceBackgroundManager.instance.promoteToForeground();
    promoted = true;
  } catch (e) {
    try {
      await storage.appendLogEntry(
        LogEntry(time: DateTime.now(), kind: 'error', message: 'promote: $e'),
      );
    } catch (_) {}
  }

  try {
    final office = await storage.getOfficeLocation();
    final officeName = office?.name ?? OfficeLocation.geofenceId;
    final lat = params.location?.latitude;
    final lng = params.location?.longitude;

    switch (params.event) {
      case GeofenceEvent.enter:
        final now = DateTime.now();
        await storage.saveCheckInTime(now);
        await storage.appendLogEntry(
          LogEntry(time: now, kind: 'enter', latitude: lat, longitude: lng),
        );
        try {
          await NotificationService.showArrived(
            officeName: officeName,
            checkInTime: now,
          );
        } catch (e) {
          await storage.appendLogEntry(
            LogEntry(
              time: DateTime.now(),
              kind: 'error',
              message: 'enter-notify: $e',
            ),
          );
        }
        break;

      case GeofenceEvent.exit:
        final now = DateTime.now();
        final checkIn = await storage.getCheckInTime();
        await storage.saveCheckOutTime(now);
        await storage.appendLogEntry(
          LogEntry(time: now, kind: 'exit', latitude: lat, longitude: lng),
        );
        final duration = checkIn != null
            ? now.difference(checkIn)
            : Duration.zero;
        try {
          await NotificationService.showLeft(
            officeName: officeName,
            totalDuration: duration,
          );
        } catch (e) {
          await storage.appendLogEntry(
            LogEntry(
              time: DateTime.now(),
              kind: 'error',
              message: 'exit-notify: $e',
            ),
          );
        }
        break;

      case GeofenceEvent.dwell:
        break; // not used in this PoC
    }
  } catch (e, stack) {
    // Catches ANYTHING not already caught above — a storage failure, a
    // bad params value, an unexpected plugin error, etc. Without this,
    // an exception here would just vanish with zero trace on-device.
    try {
      await storage.appendLogEntry(
        LogEntry(
          time: DateTime.now(),
          kind: 'error',
          message:
              'callback: $e\n${stack.toString().split('\n').take(3).join(' | ')}',
        ),
      );
    } catch (_) {
      // If even writing the error entry fails (e.g. storage itself is the
      // thing that broke), there's genuinely nothing left we can do here.
    }
  }

  if (promoted) {
    try {
      await NativeGeofenceBackgroundManager.instance.demoteToBackground();
    } catch (_) {
      // Not critical if this fails — the service will be torn down anyway
      // once this callback function returns.
    }
  }
}
