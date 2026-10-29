import 'package:flutter/material.dart';

/// Shared helpers so every screen writes and reads times the same way
/// (the History tab matches logs by this exact text, e.g. "8:00 AM").
const List<String> kDaysOfWeek = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String formatTime12h(TimeOfDay t) {
  final hour = t.hour == 0 ? 12 : t.hour > 12 ? t.hour - 12 : t.hour;
  final minute = t.minute.toString().padLeft(2, '0');
  final period = t.hour >= 12 ? 'PM' : 'AM';
  return '$hour:$minute $period';
}

String dateKey(DateTime d) {
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Stable positive 31-bit hash (String.hashCode is not guaranteed stable).
int stableId(String s) {
  int h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0x7fffffff;
  }
  return h;
}

/// Parses "8:00 AM" / "12:30 PM" (the format of [formatTime12h]).
TimeOfDay? parseTime12h(String text) {
  final m = RegExp(r'^\s*(\d{1,2}):(\d{2})\s*(AM|PM)\s*$', caseSensitive: false).firstMatch(text);
  if (m == null) return null;
  var h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  final pm = m.group(3)!.toUpperCase() == 'PM';
  if (h == 12) h = 0;
  if (pm) h += 12;
  return TimeOfDay(hour: h, minute: min);
}

/// Shifts a weekly slot (weekday 1-7 + time) by [minutes], wrapping across
/// midnight and across Sunday -> Monday.
(int, TimeOfDay) shiftWeekly(int weekday, TimeOfDay time, int minutes) {
  const week = 7 * 24 * 60;
  final total = (((weekday - 1) * 1440 + time.hour * 60 + time.minute + minutes) % week + week) % week;
  return (total ~/ 1440 + 1, TimeOfDay(hour: (total % 1440) ~/ 60, minute: total % 60));
}

/// Next moment (strictly after [from]) that falls on [weekday] at [hour]:[minute].
DateTime nextWeeklyAt(int weekday, int hour, int minute, {DateTime? from}) {
  final start = from ?? DateTime.now();
  var candidate = DateTime(start.year, start.month, start.day, hour, minute);
  var guard = 0;
  while (candidate.weekday != weekday && guard++ < 7) {
    candidate = DateTime(candidate.year, candidate.month, candidate.day + 1, hour, minute);
  }
  if (!candidate.isAfter(start)) {
    candidate = DateTime(candidate.year, candidate.month, candidate.day + 7, hour, minute);
  }
  return candidate;
}

// ---------- Limited-time medicines ("for 1 week", "until Nov 6") ----------
// A schedule may have `endDate`: its last day, as 'yyyy-MM-dd' (see dateKey).
// No endDate = ongoing.

DateTime? parseDateKey(String? s) {
  if (s == null || s.isEmpty) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s.trim());
  if (m == null) return null;
  return DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
}

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// True if a medicine with this [endDate] is still taken on [day].
bool runsOn(String? endDate, DateTime day) {
  final end = parseDateKey(endDate);
  return end == null || !_dayOnly(day).isAfter(end);
}

/// End date for a course of [days] days that starts on [from] (default today).
/// "7 days" starting today ends 6 days from now.
String endDateForDays(int days, {DateTime? from}) {
  final start = _dayOnly(from ?? DateTime.now());
  return dateKey(DateTime(start.year, start.month, start.day + days - 1));
}

/// Days left including today (0 = already ended), or null when ongoing.
int? daysLeft(String? endDate, {DateTime? now}) {
  final end = parseDateKey(endDate);
  if (end == null) return null;
  final left = end.difference(_dayOnly(now ?? DateTime.now())).inDays + 1;
  return left < 0 ? 0 : left;
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "Nov 6".
String shortDate(DateTime d) => '${_months[d.month - 1]} ${d.day}';

/// "Until Nov 6 (7 days left)", "Last day today", "Ended Nov 6", or "Ongoing".
String courseText(String? endDate, {DateTime? now}) {
  final end = parseDateKey(endDate);
  if (end == null) return 'Ongoing';
  final left = daysLeft(endDate, now: now)!;
  if (left == 0) return 'Ended ${shortDate(end)}';
  if (left == 1) return 'Last day today';
  return 'Until ${shortDate(end)} ($left days left)';
}
