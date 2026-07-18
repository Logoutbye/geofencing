/// One row in the on-device movement log — created either from a live
/// foreground GPS reading (kind: 'move'), a manually marked point
/// (kind: 'waypoint'), the instant the background isolate wakes up
/// (kind: 'callback_fired'), or a real background geofence callback
/// (kind: 'enter' / 'exit'). This is what lets you see fine-grained
/// movement instead of just a single check-in/check-out pair.
class LogEntry {
  final DateTime time;
  final String kind; // 'move' | 'enter' | 'exit' | 'waypoint' | 'callback_fired'
  final double distanceMeters;
  final double? latitude;
  final double? longitude;
  final String? label; // e.g. 'A', 'B', 'C' for waypoints

  const LogEntry({
    required this.time,
    required this.kind,
    required this.distanceMeters,
    this.latitude,
    this.longitude,
    this.label,
  });

  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'kind': kind,
        'distance': distanceMeters,
        'lat': latitude,
        'lng': longitude,
        'label': label,
      };

  factory LogEntry.fromJson(Map<String, dynamic> json) => LogEntry(
        time: DateTime.parse(json['time'] as String),
        kind: json['kind'] as String,
        distanceMeters: (json['distance'] as num).toDouble(),
        latitude: (json['lat'] as num?)?.toDouble(),
        longitude: (json['lng'] as num?)?.toDouble(),
        label: json['label'] as String?,
      );
}