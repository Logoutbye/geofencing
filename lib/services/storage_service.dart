import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/office_location.dart';
import '../models/log_entry.dart';

/// All local persistence for the PoC lives here. Everything is a plain
/// SharedPreferences key — no database, no accounts, no network calls.
class StorageService {
  static const _kOfficeLocation = 'office_location';
  static const _kCheckInTime = 'check_in_time';
  static const _kCheckOutTime = 'check_out_time';
  static const _kLog = 'movement_log';
  static const _maxLogEntries = 100;

  Future<void> saveOfficeLocation(OfficeLocation location) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kOfficeLocation, jsonEncode(location.toJson()));
  }

  Future<OfficeLocation?> getOfficeLocation() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kOfficeLocation);
    if (raw == null) return null;
    return OfficeLocation.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveCheckInTime(DateTime time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCheckInTime, time.toIso8601String());
    // Clear any stale checkout from a previous visit.
    await prefs.remove(_kCheckOutTime);
  }

  Future<DateTime?> getCheckInTime() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kCheckInTime);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> saveCheckOutTime(DateTime time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCheckOutTime, time.toIso8601String());
  }

  Future<DateTime?> getCheckOutTime() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kCheckOutTime);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  /// Appends one row to the movement/geofence log (newest last in storage;
  /// callers typically display it reversed). Trims to [_maxLogEntries] so
  /// it can't grow unbounded during a long test session.
  Future<void> appendLogEntry(LogEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = await getLog();
    entries.add(entry);
    if (entries.length > _maxLogEntries) {
      entries.removeRange(0, entries.length - _maxLogEntries);
    }
    final raw = jsonEncode(entries.map((e) => e.toJson()).toList());
    await prefs.setString(_kLog, raw);
  }

  Future<List<LogEntry>> getLog() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLog);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => LogEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> clearLog() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kLog);
  }
}