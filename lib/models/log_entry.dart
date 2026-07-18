/// One row in the simple event log — 'enter', 'exit', or 'error' (a
/// notification that failed to show, with the reason).
class LogEntry {
  final DateTime time;
  final String kind; // 'enter' | 'exit' | 'error'
  final double? latitude;
  final double? longitude;
  final String? message; // error text, when kind == 'error'

  const LogEntry({
    required this.time,
    required this.kind,
    this.latitude,
    this.longitude,
    this.message,
  });

  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'kind': kind,
        'lat': latitude,
        'lng': longitude,
        'message': message,
      };

  factory LogEntry.fromJson(Map<String, dynamic> json) => LogEntry(
        time: DateTime.parse(json['time'] as String),
        kind: json['kind'] as String,
        latitude: (json['lat'] as num?)?.toDouble(),
        longitude: (json['lng'] as num?)?.toDouble(),
        message: json['message'] as String?,
      );
}