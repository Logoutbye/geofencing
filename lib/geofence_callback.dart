import 'package:flutter/widgets.dart';
import 'package:native_geofence/native_geofence.dart';

import 'models/log_entry.dart';
import 'models/office_location.dart';
import 'services/notification_service.dart';
import 'services/storage_service.dart';

/// Entry point the OS calls when the device crosses the geofence boundary —
/// this runs the SAME WAY whether the app is open, backgrounded, or fully
/// killed. There is no special-casing for app state; that's the whole point
/// of native_geofence. If this fires and notifies correctly once, it works
/// in all three states.
///
/// The `@pragma('vm:entry-point')` annotation is required: without it the
/// Dart compiler can tree-shake this function away in release builds and
/// the native side won't find it.
@pragma('vm:entry-point')
Future<void> geofenceTriggered(GeofenceCallbackParams params) async {
  WidgetsFlutterBinding.ensureInitialized();

  final storage = StorageService();
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
        // Written INTO the log (not just debugPrint) so you can see the
        // actual failure reason on-device, with no laptop/adb needed.
        await storage.appendLogEntry(
          LogEntry(time: DateTime.now(), kind: 'error', message: 'enter: $e'),
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
      final duration =
          checkIn != null ? now.difference(checkIn) : Duration.zero;
      try {
        await NotificationService.showLeft(
          officeName: officeName,
          totalDuration: duration,
        );
      } catch (e) {
        await storage.appendLogEntry(
          LogEntry(time: DateTime.now(), kind: 'error', message: 'exit: $e'),
        );
      }
      break;

    case GeofenceEvent.dwell:
      break; // not used in this PoC
  }
}