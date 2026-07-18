import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../utils/time_format.dart';

/// Thin wrapper around flutter_local_notifications.
///
/// Must be safe to call from the background isolate that native_geofence
/// spins up for the geofence callback, so init() re-creates the plugin
/// instance rather than relying on any app-level singleton state.
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    const settings = InitializationSettings(android: androidInit, iOS: iosInit);

    await _plugin.initialize(settings: settings);

    // NOTE: deliberately NOT calling requestNotificationsPermission() here.
    // That call requires a live Android Activity, which does not exist in
    // the background isolate native_geofence uses for the geofence
    // callback — calling it there throws a NullPointerException
    // ("Context.getSystemService on a null object reference") and crashes
    // before the actual notification .show() call is ever reached.
    // Permission requesting is handled once, correctly, in the foreground
    // via permission_handler's Permission.notification.request() in
    // main.dart's _ensurePermissions(). init() here only sets up the
    // plugin/channel, which is safe to do from any isolate.

    _initialized = true;
  }

  static Future<void> showTest() async {
    await init();
    final now = DateTime.now();
    await _plugin.show(
      id: 1000,
      title: '🔔 Test notification',
      body: 'This fired at ${TimeFormat.time(now)}.',
      notificationDetails: _details(),
    );
  }

  static Future<void> showArrived({
    required String officeName,
    required DateTime checkInTime,
  }) async {
    await init();
    final formatted = TimeFormat.time(checkInTime);
    await _plugin.show(
      id: 1001,
      title: '✅ Arrived at $officeName',
      body: 'Work started:\n$formatted',
      notificationDetails: _details(),
    );
  }

  static Future<void> showLeft({
    required String officeName,
    required Duration totalDuration,
  }) async {
    await init();
    final formatted = _formatDuration(totalDuration);
    await _plugin.show(
      id: 1002,
      title: '🏠 Left $officeName',
      body: 'Total work time:\n$formatted',
      notificationDetails: _details(),
    );
  }

  static NotificationDetails _details() {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        'geofence_events',
        'Geofence Events',
        channelDescription: 'Arrival and departure notifications',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );
  }

  static String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    if (hours <= 0) return '$minutes minutes';
    return '$hours hours $minutes minutes';
  }
}