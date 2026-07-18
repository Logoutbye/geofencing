import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:native_geofence/native_geofence.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:disable_battery_optimization/disable_battery_optimization.dart';

import 'geofence_callback.dart';
import 'models/log_entry.dart';
import 'models/office_location.dart';
import 'services/notification_service.dart';
import 'services/storage_service.dart';
import 'utils/time_format.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NativeGeofenceManager.instance.initialize();
  await NotificationService.init();
  runApp(const GeofencePocApp());
}

class GeofencePocApp extends StatelessWidget {
  const GeofencePocApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Geofence PoC',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _storage = StorageService();
  final _radiusController = TextEditingController(text: '15');

  OfficeLocation? _office;
  List<ActiveGeofence> _registered = [];
  List<LogEntry> _log = [];

  bool _busy = false;
  String? _statusMessage;

  // Foreground-only live distance readout — purely a debugging aid so you
  // can watch the number while walking around. Has nothing to do with the
  // actual background geofence, which is handled entirely by the OS.
  StreamSubscription<Position>? _positionSub;
  double? _liveDistanceMeters;
  double? _lastLoggedDistance;

  // Instant cross-isolate signal from geofence_callback.dart — only fires
  // if the app process is still alive (open or backgrounded, not killed).
  final ReceivePort _geofencePort = ReceivePort();
  String? _lastLiveEvent;
  bool? _batteryOptDisabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    IsolateNameServer.removePortNameMapping('native_geofence_send_port');
    IsolateNameServer.registerPortWithName(
      _geofencePort.sendPort,
      'native_geofence_send_port',
    );
    _geofencePort.listen((dynamic data) {
      if (!mounted) return;
      setState(() => _lastLiveEvent = data.toString());
      _refresh(); // pull the freshly-written log row in too
    });
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _radiusController.dispose();
    _positionSub?.cancel();
    _geofencePort.close();
    IsolateNameServer.removePortNameMapping('native_geofence_send_port');
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Refresh whenever the app comes back to the foreground, so a
    // background enter/exit event shows up immediately when reopened.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final office = await _storage.getOfficeLocation();
    final registered = await NativeGeofenceManager.instance.getRegisteredGeofences();
    final log = await _storage.getLog();
    if (!mounted) return;
    setState(() {
      _office = office;
      _registered = registered;
      _log = log;
    });
    if (office != null) _startLiveDistanceTracking(office);
    try {
      final disabled = await DisableBatteryOptimization.isAllBatteryOptimizationDisabled;
      if (mounted) setState(() => _batteryOptDisabled = disabled);
    } catch (_) {
      // Not on Android, or the platform check isn't available — ignore.
    }
  }

  void _startLiveDistanceTracking(OfficeLocation office) {
    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 1, // update every ~1m of movement
      ),
    ).listen((position) async {
      final meters = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        office.latitude,
        office.longitude,
      );
      if (!mounted) return;
      setState(() => _liveDistanceMeters = meters);

      // Log a "move" row whenever the distance shifts by 3m+ since the
      // last logged reading — this is the "mark it even for small
      // movement" log you asked for, independent of enter/exit events.
      final last = _lastLoggedDistance;
      if (last == null || (meters - last).abs() >= 3) {
        _lastLoggedDistance = meters;
        final entry = LogEntry(
          time: DateTime.now(),
          kind: 'move',
          distanceMeters: meters,
          latitude: position.latitude,
          longitude: position.longitude,
        );
        await _storage.appendLogEntry(entry);
        if (!mounted) return;
        setState(() => _log = [..._log, entry]);
      }
    });
  }

  String _nextWaypointLabel() {
    final used = _log.where((e) => e.kind == 'waypoint').length;
    // A, B, C ... Z, then AA, AB ... (won't realistically be needed, but safe)
    var n = used;
    var label = '';
    do {
      label = String.fromCharCode(65 + (n % 26)) + label;
      n = (n ~/ 26) - 1;
    } while (n >= 0);
    return label;
  }

  Future<void> _markPoint() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      final label = _nextWaypointLabel();
      final distance = _office == null
          ? 0.0
          : Geolocator.distanceBetween(
              position.latitude, position.longitude,
              _office!.latitude, _office!.longitude,
            );
      final entry = LogEntry(
        time: DateTime.now(),
        kind: 'waypoint',
        distanceMeters: distance,
        latitude: position.latitude,
        longitude: position.longitude,
        label: label,
      );
      await _storage.appendLogEntry(entry);
      if (!mounted) return;
      setState(() {
        _log = [..._log, entry];
        _statusMessage = 'Marked point $label at this spot.';
      });
    } catch (e) {
      setState(() => _statusMessage = 'Could not mark point: $e');
    }
  }

  Future<bool> _ensurePermissions() async {
    // Foreground location first.
    final whenInUse = await Permission.locationWhenInUse.request();
    if (!whenInUse.isGranted) {
      setState(() => _statusMessage = 'Location permission denied.');
      return false;
    }

    // "Always" / background location is required for geofence events to
    // fire while the app is closed. On Android/iOS this typically must be
    // granted as a second step after "while using the app" is approved.
    final always = await Permission.locationAlways.request();
    if (!always.isGranted) {
      setState(() => _statusMessage =
          'Background ("Allow all the time") location permission is required '
          'for the geofence to trigger while the app is closed.');
      return false;
    }

    final notif = await Permission.notification.request();
    if (!notif.isGranted) {
      setState(() => _statusMessage =
          'Notification permission denied — geofence events will still be '
          'logged, but no alert will show.');
      // Not a hard blocker — logging still works without it — but flagged
      // clearly so a "no notification" result isn't mistaken for a dead
      // geofence.
    }

    return true;
  }

  Future<void> _setOfficeLocationHere() async {
    setState(() {
      _busy = true;
      _statusMessage = null;
    });

    try {
      final hasPermission = await _ensurePermissions();
      if (!hasPermission) return;

      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() => _statusMessage = 'Please turn on device location services.');
        return;
      }

      // One-time GPS fix. This is the ONLY direct location read in the
      // app — after this, monitoring is handled entirely by the OS.
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      final parsedRadius = double.tryParse(_radiusController.text.trim());
      // 10m floor for tight-space testing (20-40 steps ≈ 15-30m). Below
      // this, ordinary GPS jitter (often 5-15m on its own) will cause
      // false enter/exit flapping regardless of the geofence.
      final radius = (parsedRadius == null || parsedRadius < 10) ? 15.0 : parsedRadius;

      final office = OfficeLocation(
        name: 'Office',
        latitude: position.latitude,
        longitude: position.longitude,
        radiusMeters: radius,
      );

      await _storage.saveOfficeLocation(office);

      // Replace any previous geofence with this one.
      await NativeGeofenceManager.instance.removeAllGeofences();

      final geofence = Geofence(
        id: OfficeLocation.geofenceId,
        location: Location(latitude: office.latitude, longitude: office.longitude),
        radiusMeters: office.radiusMeters,
        triggers: const {
          GeofenceEvent.enter,
          GeofenceEvent.exit,
        },
        androidSettings: const AndroidGeofenceSettings(
          initialTriggers: {GeofenceEvent.enter},
          notificationResponsiveness: Duration(seconds: 30),
        ),
        iosSettings: const IosGeofenceSettings(),
      );

      await NativeGeofenceManager.instance.createGeofence(
        geofence,
        geofenceTriggered,
      );

      setState(() => _statusMessage =
          'Office location saved and geofence registered. '
          'You can close the app now.');

      await _refresh();
    } on NativeGeofenceException catch (e) {
      setState(() => _statusMessage = 'Geofence error: ${e.code} ${e.message ?? ''}');
    } catch (e) {
      setState(() => _statusMessage = 'Failed to set location: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRegistered = _registered.any((g) => g.id == OfficeLocation.geofenceId);

    return Scaffold(
      appBar: AppBar(title: const Text('Geofence PoC')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Step 1 — Set your office location',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    const Text(
                      'Stand at the exact spot, tap the button below. This reads '
                      'your GPS once and registers a geofence of the radius below.',
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _radiusController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: false),
                      decoration: const InputDecoration(
                        labelText: 'Radius (meters)',
                        helperText: 'Minimum 10m — GPS noise alone is usually '
                            '±5-15m, so smaller than that will misfire even '
                            'with a perfect geofence. For a 20-40 step space, '
                            'try 15m. Re-tap the button after changing this '
                            'to re-register.',
                        helperMaxLines: 3,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _busy ? null : _setOfficeLocationHere,
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.location_on),
                      label: const Text('Set Office Location Here'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => NotificationService.showTest(),
                      icon: const Icon(Icons.notifications_active),
                      label: const Text('Send Test Notification'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _markPoint,
                      icon: const Icon(Icons.flag),
                      label: Text('Mark Point (next: ${_nextWaypointLabel()})'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () async {
                        try {
                          await DisableBatteryOptimization
                              .showDisableAllOptimizationsSettings(
                            'Enable Auto Start',
                            'Turn this ON so the app can run in the background '
                                'and detect the geofence while closed.',
                            'Disable Battery Optimization',
                            'Set this app to "No restrictions" / "Unrestricted" '
                                'so the OS does not kill it while closed.',
                          );
                        } catch (e) {
                          if (!mounted) return;
                          setState(() => _statusMessage =
                              'Battery settings screen not available: $e');
                        }
                        await _refresh();
                      },
                      icon: const Icon(Icons.battery_alert),
                      label: Text(
                        _batteryOptDisabled == null
                            ? 'Fix Background/Battery Settings'
                            : _batteryOptDisabled!
                                ? 'Battery Settings ✅ (tap to review again)'
                                : 'Fix Background/Battery Settings ⚠️',
                      ),
                    ),
                    if (_statusMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(_statusMessage!,
                          style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Status', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    _StatusRow(
                      label: 'Saved location',
                      value: _office == null
                          ? 'Not set'
                          : '${_office!.latitude.toStringAsFixed(5)}, '
                            '${_office!.longitude.toStringAsFixed(5)} '
                            '(${_office!.radiusMeters.toInt()}m radius)',
                    ),
                    _StatusRow(
                      label: 'Geofence registered with OS',
                      value: isRegistered ? 'Yes ✅' : 'No',
                    ),
                    if (_lastLiveEvent != null)
                      _StatusRow(
                        label: 'Last instant signal (app was alive)',
                        value: _lastLiveEvent!,
                      ),
                    if (_office != null && _liveDistanceMeters != null)
                      _StatusRow(
                        label: 'Live distance (app open only)',
                        value:
                            '${_liveDistanceMeters!.toStringAsFixed(1)}m — '
                            '${_liveDistanceMeters! <= _office!.radiusMeters ? 'INSIDE ✅' : 'outside'}',
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Movement log', style: Theme.of(context).textTheme.titleMedium),
                        TextButton(
                          onPressed: _log.isEmpty
                              ? null
                              : () async {
                                  await _storage.clearLog();
                                  setState(() {
                                    _log = [];
                                    _lastLoggedDistance = null;
                                  });
                                },
                          child: const Text('Clear'),
                        ),
                      ],
                    ),
                    Text(
                      'move = this screen watching you walk (foreground only). '
                      'waypoint (A, B, C…) = you tapped "Mark Point". '
                      'WOKE = the background isolate fired, before anything '
                      'else runs — proof the OS actually called your code. '
                      'ENTER/EXIT = the real geofence event, works with the '
                      'app closed.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    if (_log.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('No entries yet — set a location and start moving.'),
                      )
                    else
                      ...List.generate(_log.length, (i) {
                        final entry = _log[_log.length - 1 - i]; // newest first
                        return _LogRow(entry: entry);
                      }),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Note: "Live distance" only updates while this screen is open — '
              'it\'s a debugging aid to watch while you walk, not part of the '
              'actual background geofence. The real test is closing the app '
              'and checking that a notification still appears.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Now close the app completely and walk into / out of the office. '
              'A notification should appear without opening the app. Reopen '
              'the app afterward and pull down to refresh the status above.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  final LogEntry entry;
  const _LogRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (entry.kind) {
      'enter' => (Icons.login, Colors.green, 'ENTER'),
      'exit' => (Icons.logout, Colors.orange, 'EXIT'),
      'waypoint' => (Icons.flag, Colors.blue, entry.label ?? '?'),
      'callback_fired' => (Icons.bolt, Colors.purple, 'WOKE'),
      _ => (Icons.my_location, Colors.grey, 'move'),
    };
    final coords = (entry.latitude != null && entry.longitude != null)
        ? '${entry.latitude!.toStringAsFixed(5)}, ${entry.longitude!.toStringAsFixed(5)}'
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          SizedBox(
            width: 44,
            child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(TimeFormat.dateTime(entry.time), style: const TextStyle(fontSize: 13)),
                if (coords != null)
                  Text(coords, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              ],
            ),
          ),
          Text('${entry.distanceMeters.toStringAsFixed(1)}m'),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final String label;
  final String value;
  const _StatusRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 3, child: Text(label)),
          Expanded(
            flex: 4,
            child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}