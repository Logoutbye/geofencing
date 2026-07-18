/// Human-readable time/date formatting shared by the UI and notifications.
/// No intl dependency — kept dead simple for this PoC.
class TimeFormat {
  static String time(DateTime t) {
    final hour24 = t.hour;
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    final period = hour24 < 12 ? 'am' : 'pm';
    final minute = t.minute.toString().padLeft(2, '0');
    final second = t.second.toString().padLeft(2, '0');
    return '$hour12:$minute:$second $period';
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String dateTime(DateTime t) {
    final local = t.toLocal();
    return '${_months[local.month - 1]} ${local.day}, ${time(local)}';
  }
}