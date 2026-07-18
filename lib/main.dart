import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:native_geofence/native_geofence.dart';
import 'package:permission_handler/permission_handler.dart';

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
  final _radiusController = TextEditingController(text: '20');

  OfficeLocation? _office;
  List<ActiveGeofence> _registered = [];
  List<LogEntry> _log = [];

  bool _busy = false;
  String? _statusMessage;

  // Foreground-only live distance readout — a debugging aid so you can
  // watch the number while walking, separate from the actual background
  // geofence which the OS handles on its own regardless of this screen.
  StreamSubscription<Position>? _positionSub;
  double? _liveDistanceMeters;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _radiusController.dispose();
    _positionSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final office = await _storage.getOfficeLocation();
    final registered = await NativeGeofenceManager.instance
        .getRegisteredGeofences();
    final log = await _storage.getLog();
    if (!mounted) return;
    setState(() {
      _office = office;
      _registered = registered;
      _log = log;
    });
    if (office != null) _startLiveDistanceTracking(office);
  }

  void _startLiveDistanceTracking(OfficeLocation office) {
    _positionSub?.cancel();
    _positionSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 1,
          ),
        ).listen((position) {
          if (!mounted) return;
          setState(() {
            _liveDistanceMeters = Geolocator.distanceBetween(
              position.latitude,
              position.longitude,
              office.latitude,
              office.longitude,
            );
          });
        });
  }

  Future<bool> _ensurePermissions() async {
    final whenInUse = await Permission.locationWhenInUse.request();
    if (!whenInUse.isGranted) {
      setState(() => _statusMessage = 'Location permission denied.');
      return false;
    }
    final always = await Permission.locationAlways.request();
    if (!always.isGranted) {
      setState(
        () => _statusMessage =
            'Background ("Allow all the time") location permission is required '
            'for the geofence to trigger while the app is closed.',
      );
      return false;
    }
    await Permission.notification.request();
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
        setState(
          () => _statusMessage = 'Please turn on device location services.',
        );
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      final parsedRadius = double.tryParse(_radiusController.text.trim());
      final radius = (parsedRadius == null || parsedRadius < 10)
          ? 20.0
          : parsedRadius;

      final office = OfficeLocation(
        name: 'Office',
        latitude: position.latitude,
        longitude: position.longitude,
        radiusMeters: radius,
      );

      await _storage.saveOfficeLocation(office);
      await NativeGeofenceManager.instance.removeAllGeofences();

      final geofence = Geofence(
        id: OfficeLocation.geofenceId,
        location: Location(
          latitude: office.latitude,
          longitude: office.longitude,
        ),
        radiusMeters: office.radiusMeters,
        triggers: const {GeofenceEvent.enter, GeofenceEvent.exit},
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

      setState(
        () =>
            _statusMessage = 'Saved and registered. You can close the app now.',
      );
      await _refresh();
    } on NativeGeofenceException catch (e) {
      setState(
        () => _statusMessage = 'Geofence error: ${e.code} ${e.message ?? ''}',
      );
    } catch (e) {
      setState(() => _statusMessage = 'Failed to set location: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRegistered = _registered.any(
      (g) => g.id == OfficeLocation.geofenceId,
    );

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
                    Text(
                      'Set your location',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Stand at the spot, set a radius, tap the button.',
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _radiusController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: false,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Radius (meters)',
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
                      label: const Text('Set Location Here'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => NotificationService.showTest(),
                      icon: const Icon(Icons.notifications_active),
                      label: const Text('Send Test Notification'),
                    ),
                    if (_statusMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _statusMessage!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
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
                    Text(
                      'Status',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    _StatusRow(
                      label: 'Saved location',
                      value: _office == null
                          ? 'Not set'
                          : '${_office!.latitude.toStringAsFixed(5)}, '
                                '${_office!.longitude.toStringAsFixed(5)} '
                                '(${_office!.radiusMeters.toInt()}m)',
                    ),
                    _StatusRow(
                      label: 'Geofence registered',
                      value: isRegistered ? 'Yes ✅' : 'No',
                    ),
                    if (_office != null && _liveDistanceMeters != null)
                      _StatusRow(
                        label: 'Live distance (app open only)',
                        value:
                            '${_liveDistanceMeters!.toStringAsFixed(1)}m — '
                            '${_liveDistanceMeters! <= _office!.radiusMeters ? 'INSIDE ✅' : 'OUTSIDE'}',
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
                        Text(
                          'Event log',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        TextButton(
                          onPressed: _log.isEmpty
                              ? null
                              : () async {
                                  await _storage.clearLog();
                                  setState(() => _log = []);
                                },
                          child: const Text('Clear'),
                        ),
                      ],
                    ),
                    if (_log.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('No entries yet.'),
                      )
                    else
                      ...List.generate(_log.length, (i) {
                        final entry = _log[_log.length - 1 - i];
                        return _LogRow(entry: entry);
                      }),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '"Live distance" only updates while this screen is open — watch '
              'it while walking to see exactly when you cross the radius. Exit '
              'detection is typically slower than entry (Android waits for a '
              'more confident signal before firing EXIT, to avoid false '
              'triggers from GPS jitter) — give it a couple of minutes '
              'standing clearly outside before assuming it failed.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Close the app completely, walk out and back in. A notification '
              'should appear either way. Reopen and pull to refresh to check the log.',
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
      _ => (Icons.error, Colors.red, 'ERROR'),
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
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  TimeFormat.dateTime(entry.time),
                  style: const TextStyle(fontSize: 13),
                ),
                if (coords != null)
                  Text(
                    coords,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                if (entry.message != null)
                  Text(
                    entry.message!,
                    style: const TextStyle(fontSize: 11, color: Colors.red),
                  ),
              ],
            ),
          ),
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
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
