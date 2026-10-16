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
