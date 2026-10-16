import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

import 'time_utils.dart';

/// Scan-to-Schedule: reads a prescription or medicine label with on-device OCR
/// (Google ML Kit, works offline) and turns it into values for the Add Schedule
/// form. The user always checks and edits the values before saving.
class PrescriptionScanner {
  static Future<ScanResult?> scan(ImageSource source) async {
    final XFile? picked = await ImagePicker().pickImage(
      source: source,
      imageQuality: 90,
      maxWidth: 2000,
    );
    if (picked == null) return null;

    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final input = InputImage.fromFilePath(picked.path);
      final RecognizedText text = await recognizer.processImage(input);
      return PrescriptionParser.parse(text.text);
    } finally {
      await recognizer.close();
    }
  }
}

class ScanResult {
  final String rawText;
  final String? name;
  final String? dosage;
  final List<TimeOfDay> times;
  final List<String> days;
  final bool foundFrequency;

  const ScanResult({
    required this.rawText,
    required this.name,
    required this.dosage,
    required this.times,
    required this.days,
    required this.foundFrequency,
  });

  bool get isEmpty => name == null && dosage == null && !foundFrequency;

  String get summary {
    if (rawText.trim().isEmpty || isEmpty) {
      return "Couldn't read the details. Try a clearer, well-lit photo, or type them in.";
    }
    final found = <String>[];
    if (name != null) found.add('name');
    if (dosage != null) found.add('dosage');
    if (foundFrequency) found.add('${times.length} time(s) a day');
    final missing = <String>[];
    if (name == null) missing.add('name');
    if (dosage == null) missing.add('dosage');
    if (!foundFrequency) missing.add('schedule (set to 8:00 AM)');
    var s = 'Found: ${found.join(', ')}.';
    if (missing.isNotEmpty) s += ' Not found: ${missing.join(', ')}.';
    return '$s Please check everything before saving.';
  }
}

/// Rule-based parser for common prescription wording
/// (e.g. "Amoxicillin 500mg", "Take 1 capsule 3x a day", "BID", "every 8 hours").
class PrescriptionParser {
  static final RegExp _strength =
      RegExp(r'(\d+(?:\.\d+)?)\s?(mg|mcg|µg|g|ml|iu|units?)\b', caseSensitive: false);
  static final RegExp _amount = RegExp(
      r'\b(\d+(?:\.\d+)?|1/2|one|two|three|half)\s*(tablets?|tabs?|capsules?|caps?|pills?|puffs?|drops?|teaspoons?|tsp|sachets?)\b',
      caseSensitive: false);
  static final RegExp _clock =
      RegExp(r'\b(1[0-2]|0?[1-9])(?::([0-5]\d))?\s*(am|pm|a\.m\.|p\.m\.)(?![a-z])', caseSensitive: false);
  static final RegExp _everyHours =
      RegExp(r'(?:every\s+(\d{1,2})\s*(?:hours?|hrs?|h)\b|\bq\s?(\d{1,2})\s?h\b)', caseSensitive: false);

  static const Set<String> _skipFirstWords = {
    'rx', 'take', 'patient', 'name', 'dr', 'doctor', 'md', 'date', 'pharmacy', 'refill',
    'refills', 'qty', 'quantity', 'address', 'tel', 'phone', 'sig', 'age', 'prescription',
    'clinic', 'hospital', 'license', 'lic', 'ptr', 's2', 'mr', 'mrs', 'ms', 'sex',
    'signature', 'for', 'tablet', 'tablets', 'capsule', 'capsules', 'by', 'no', 'dispense',
    'once', 'twice', 'every', 'daily', 'after', 'before', 'with',
  };

  static ScanResult parse(String raw) {
    final lines = raw
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final lower = raw.toLowerCase();

    var times = _findTimes(lower);
    final foundFrequency = times.isNotEmpty;
    if (times.isEmpty) times = [const TimeOfDay(hour: 8, minute: 0)];

    final weekly = RegExp(r'\b(once a week|weekly|every week)\b').hasMatch(lower);

    return ScanResult(
      rawText: raw,
      name: _findName(lines),
      dosage: _findDosage(raw),
      times: times,
      days: weekly ? ['Mon'] : List.of(kDaysOfWeek),
      foundFrequency: foundFrequency,
    );
  }

  static String? _findName(List<String> lines) {
    // 1) A line with a strength ("Losartan 50 mg") -> the words before it.
    for (final line in lines) {
      final m = _strength.firstMatch(line);
      if (m != null && m.start > 0) {
        final before = line.substring(0, m.start).replaceAll(RegExp(r'^(rx|℞)[:.\s]*', caseSensitive: false), '');
        final cleaned = _cleanName(before);
        if (cleaned != null) return cleaned;
      }
    }
    // 2) Otherwise the first line that looks like a word, not a label.
    for (final line in lines) {
      final cleaned = _cleanName(line);
      if (cleaned != null) return cleaned;
    }
    return null;
  }

  static String? _cleanName(String s) {
    var t = s
        .replaceAll(RegExp(r'[^A-Za-z0-9\-\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceFirst(RegExp(r'^\d+\s*'), '');
    if (t.length < 3) return null;
    final letters = t.replaceAll(RegExp(r'[^A-Za-z]'), '').length;
    if (letters < t.length * 0.6) return null;
    final firstWord = t.split(' ').first.toLowerCase();
    if (_skipFirstWords.contains(firstWord)) return null;
    return t
        .split(' ')
        .take(3)
        .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }

  static String? _findDosage(String raw) {
    RegExpMatch? amount;
    for (final m in _amount.allMatches(raw)) {
      final start = m.start;
      final before = raw.substring(start >= 8 ? start - 8 : 0, start).toLowerCase();
      if (before.contains('take')) {
        amount = m;
        break;
      }
      final n = double.tryParse(m.group(1)!);
      if (amount == null && (n == null || n <= 4)) amount = m; // skip "30 tablets" quantities
    }
    final strength = _strength.firstMatch(raw);

    final amountText = amount == null ? null : '${amount.group(1)} ${amount.group(2)}'.toLowerCase();
    final strengthText = strength == null ? null : '${strength.group(1)} ${strength.group(2)!.toLowerCase()}';

    if (amountText != null && strengthText != null) return '$amountText ($strengthText)';
    return amountText ?? strengthText;
  }

  static List<TimeOfDay> _findTimes(String lower) {
    final result = <TimeOfDay>[];
    void add(int h, int m) {
      if (!result.any((t) => t.hour == h && t.minute == m)) {
        result.add(TimeOfDay(hour: h, minute: m));
      }
    }

    // 1) Exact clock times written on the label.
    for (final m in _clock.allMatches(lower)) {
      var h = int.parse(m.group(1)!);
      final min = int.tryParse(m.group(2) ?? '') ?? 0;
      final pm = m.group(3)!.startsWith('p');
      if (pm && h < 12) h += 12;
      if (!pm && h == 12) h = 0;
      add(h, min);
    }
    if (result.isNotEmpty) {
      result.sort((a, b) => (a.hour * 60 + a.minute) - (b.hour * 60 + b.minute));
      return result;
    }

    // 2) "every 8 hours" / "q8h", starting at 8:00 AM.
    final every = _everyHours.firstMatch(lower);
    if (every != null) {
      final n = int.parse(every.group(1) ?? every.group(2)!);
      if (n >= 2 && n <= 24) {
        for (int i = 0; i < 24 ~/ n && i < 6; i++) {
          add((8 + i * n) % 24, 0);
        }
        return result;
      }
    }

    // 3) "3x a day", "twice daily", BID/TID/QID.
    int? count;
    if (RegExp(r'\b(qid|four times|4\s?x|4 times)\b').hasMatch(lower)) {
      count = 4;
    } else if (RegExp(r'\b(tid|thrice|three times|3\s?x|3 times)\b').hasMatch(lower)) {
      count = 3;
    } else if (RegExp(r'\b(bid|twice|two times|2\s?x|2 times)\b').hasMatch(lower)) {
      count = 2;
    } else if (RegExp(r'\b(once|od|qd|daily|1\s?x|one time|every day|everyday)\b').hasMatch(lower)) {
      count = 1;
    }
    final night = RegExp(r'\b(bedtime|at night|hs|before sleep|evening)\b').hasMatch(lower);

    switch (count) {
      case 1:
        if (night) {
          add(21, 0);
        } else {
          add(8, 0);
        }
        break;
      case 2:
        add(8, 0);
        add(20, 0);
        break;
      case 3:
        add(8, 0);
        add(14, 0);
        add(20, 0);
        break;
      case 4:
        add(8, 0);
        add(12, 0);
        add(16, 0);
        add(20, 0);
        break;
      default:
        if (night) add(21, 0);
    }
    return result;
  }
}
