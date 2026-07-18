import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/office_location.dart';
import '../models/log_entry.dart';

/// All local persistence for the PoC lives here. Everything is a plain
/// key-value store — no database, no accounts, no network calls.
///
/// Uses SharedPreferencesAsync (not the legacy SharedPreferences API)
/// DELIBERATELY: the legacy API caches all values in memory per-isolate
/// after first read, which goes stale across isolates — exactly the
/// situation here, since the geofence callback runs in a separate
/// background isolate from the UI. SharedPreferencesAsync always reads
/// fresh from disk, so a write from the background isolate is visible to
/// the UI isolate immediately, not just after the app is restarted.
class StorageService {
  static const _kOfficeLocation = 'office_location';
  static const _kCheckInTime = 'check_in_time';
  static const _kCheckOutTime = 'check_out_time';
  static const _kLog = 'movement_log';
  static const _maxLogEntries = 100;

  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  Future<void> saveOfficeLocation(OfficeLocation location) async {
    await _prefs.setString(_kOfficeLocation, jsonEncode(location.toJson()));
  }

  Future<OfficeLocation?> getOfficeLocation() async {
    final raw = await _prefs.getString(_kOfficeLocation);
    if (raw == null) return null;
    return OfficeLocation.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveCheckInTime(DateTime time) async {
    await _prefs.setString(_kCheckInTime, time.toIso8601String());
    await _prefs.remove(_kCheckOutTime);
  }

  Future<DateTime?> getCheckInTime() async {
    final raw = await _prefs.getString(_kCheckInTime);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> saveCheckOutTime(DateTime time) async {
    await _prefs.setString(_kCheckOutTime, time.toIso8601String());
  }

  Future<DateTime?> getCheckOutTime() async {
    final raw = await _prefs.getString(_kCheckOutTime);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> appendLogEntry(LogEntry entry) async {
    final entries = await getLog();
    entries.add(entry);
    if (entries.length > _maxLogEntries) {
      entries.removeRange(0, entries.length - _maxLogEntries);
    }
    final raw = jsonEncode(entries.map((e) => e.toJson()).toList());
    await _prefs.setString(_kLog, raw);
  }

  Future<List<LogEntry>> getLog() async {
    final raw = await _prefs.getString(_kLog);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => LogEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> clearLog() async {
    await _prefs.remove(_kLog);
  }
}