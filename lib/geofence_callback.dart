import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:native_geofence/native_geofence.dart';

import 'models/log_entry.dart';
import 'models/office_location.dart';
import 'services/notification_service.dart';
import 'services/storage_service.dart';

/// Entry point the OS calls in a background isolate when the device
/// crosses the geofence boundary — including when the app is fully closed.
///
/// The `@pragma('vm:entry-point')` annotation is required: without it the
/// Dart compiler can tree-shake this function away in release builds and
/// the native side won't find it.
@pragma('vm:entry-point')
Future<void> geofenceTriggered(GeofenceCallbackParams params) async {
  // Background isolates need their own binding before touching plugins.
  WidgetsFlutterBinding.ensureInitialized();

  debugPrint('Geofence callback fired: ${params.event}');

  // If the main app isolate is still alive (app open or just backgrounded,
  // not fully killed), push the event straight to it for an instant UI
  // update. If the app was fully killed, this silently finds nothing —
  // that's fine, the storage log below is the source of truth either way.
  final sendPort = IsolateNameServer.lookupPortByName('native_geofence_send_port');
  sendPort?.send('${params.event.name} @ ${DateTime.now()}');

  final storage = StorageService();

  // LOG FIRST, always — before anything that could possibly fail or
  // throw. This row is the ground truth: if it's in the log after your
  // test, the OS woke your code, no matter what happened with
  // notifications after this point.
  await storage.appendLogEntry(
    LogEntry(time: DateTime.now(), kind: 'callback_fired', distanceMeters: 0),
  );

  // Notification is best-effort from here on — wrapped so a notification
  // failure (permission revoked, plugin hiccup, etc.) can NEVER stop the
  // rest of this function, including the enter/exit logging below.
  try {
    await NotificationService.showDebugCallbackFired(params.event.toString());
  } catch (e) {
    debugPrint('Debug notification failed (non-fatal): $e');
  }

  final office = await storage.getOfficeLocation();
  final officeName = office?.name ?? OfficeLocation.geofenceId;

  // Prefer the location the event itself carries — no extra GPS request,
  // one less thing that can fail/timeout in the background. Only fall
  // back to a fresh fix if the event didn't include one.
  double? lat = params.location?.latitude;
  double? lng = params.location?.longitude;
  if (lat == null || lng == null) {
    try {
      final pos = await Geolocator.getCurrentPosition();
      lat = pos.latitude;
      lng = pos.longitude;
    } catch (_) {
      // Best effort — a missing location shouldn't block anything below.
    }
  }
  final distance = (office != null && lat != null && lng != null)
      ? Geolocator.distanceBetween(lat, lng, office.latitude, office.longitude)
      : 0.0;

  switch (params.event) {
    case GeofenceEvent.enter:
      final now = DateTime.now();
      await storage.saveCheckInTime(now);
      // Log BEFORE notifying, same reasoning as above.
      await storage.appendLogEntry(
        LogEntry(
          time: now,
          kind: 'enter',
          distanceMeters: distance,
          latitude: lat,
          longitude: lng,
        ),
      );
      try {
        await NotificationService.showArrived(
          officeName: officeName,
          checkInTime: now,
        );
      } catch (e) {
        debugPrint('Arrived notification failed (non-fatal): $e');
      }
      break;

    case GeofenceEvent.exit:
      final now = DateTime.now();
      final checkIn = await storage.getCheckInTime();
      await storage.saveCheckOutTime(now);
      await storage.appendLogEntry(
        LogEntry(
          time: now,
          kind: 'exit',
          distanceMeters: distance,
          latitude: lat,
          longitude: lng,
        ),
      );

      final duration =
          checkIn != null ? now.difference(checkIn) : Duration.zero;

      try {
        await NotificationService.showLeft(
          officeName: officeName,
          totalDuration: duration,
        );
      } catch (e) {
        debugPrint('Left notification failed (non-fatal): $e');
      }
      break;

    case GeofenceEvent.dwell:
      // Not used in this PoC — enter/exit is enough to prove the concept.
      debugPrint('Dwell event received (ignored in this PoC).');
      break;
  }
}