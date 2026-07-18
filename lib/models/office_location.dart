/// The one saved geofence target for this PoC.
///
/// Kept deliberately tiny — this is not a multi-geofence system, just enough
/// to prove entry/exit detection works while the app is closed.
class OfficeLocation {
  static const String geofenceId = 'office';

  final String name;
  final double latitude;
  final double longitude;
  final double radiusMeters;

  const OfficeLocation({
    required this.name,
    required this.latitude,
    required this.longitude,
    this.radiusMeters = 100,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        'radius': radiusMeters,
      };

  factory OfficeLocation.fromJson(Map<String, dynamic> json) => OfficeLocation(
        name: json['name'] as String,
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        radiusMeters: (json['radius'] as num).toDouble(),
      );
}