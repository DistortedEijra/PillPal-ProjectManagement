import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'ocr_config.dart';
import 'time_utils.dart';

/// Scan-to-Schedule: reads a prescription or medicine label with on-device OCR
/// (Google ML Kit, works offline) and turns it into values for the Add Schedule
/// form. The user always checks and edits the values before saving.
///
/// Handwritten mode sends the photo to Gemini through Firebase AI Logic (this
/// app's Firebase project), which returns each medicine's name, dose, and times.
class PrescriptionScanner {
  static Future<XFile?> _pick(ImageSource source, {double maxWidth = 2000, int quality = 90}) =>
      ImagePicker().pickImage(
        source: source,
        imageQuality: quality,
        maxWidth: maxWidth,
      );

  /// On-device scan of printed text. Returns one result per medicine found
  /// (several when the prescription lists more than one), or null if the
  /// user cancelled the photo.
  static Future<List<ScanResult>?> scan(ImageSource source) async {
    final XFile? picked = await _pick(source);
    if (picked == null) return null;

    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final input = InputImage.fromFilePath(picked.path);
      final RecognizedText text = await recognizer.processImage(input);
      return PrescriptionParser.parseAll(text.text);
    } finally {
      await recognizer.close();
    }
  }

  // ---------------- Handwritten mode (Gemini) ----------------

  static const String _aiInstructions = '''
You read photos of medical prescriptions and medicine labels for a medicine reminder app.
Doctors' handwriting is often hard to read.
Rules:
- A prescription often lists several medicines (numbered 1., 2., 3., or separate Rx lines).
  Return EVERY medicine as its own item, in the order written. List each medicine once.
- Do not invent medicines; skip anything you cannot read.
- Fix obvious spelling mistakes in medicine names only when you are confident.
- Times: use clock times written on the prescription. Otherwise convert the frequency:
  once a day = 08:00 (21:00 if at bedtime or at night); twice a day or BID = 08:00 and 20:00;
  three times a day or TID = 08:00, 14:00, 20:00; four times a day or QID = 08:00, 12:00, 16:00, 20:00;
  every N hours = start at 08:00 and add N hours until the day is full; as needed (PRN) = no times.
- Ignore the patient's name, the doctor's name, clinic details, and license numbers.
- If the image is not a prescription or medicine label, return an empty medicines list.
''';

  static final Schema _aiSchema = Schema.object(properties: {
    'medicines': Schema.array(
      description: 'Every medicine on the prescription or label. Empty if none.',
      items: Schema.object(
        properties: {
          'name': Schema.string(
              description: 'Medicine name only, without strength or form. '
                  'Use the generic name if both brand and generic are written.'),
          'strength': Schema.string(description: 'Strength, for example "500 mg".'),
          'amount': Schema.string(
              description: 'Amount per dose, for example "1 tablet" or "5 ml".'),
          'times': Schema.array(
              items: Schema.string(), description: 'Dose times in 24-hour HH:mm.'),
          'weekly': Schema.boolean(description: 'True only if taken once a week.'),
          'directions': Schema.string(
              description: 'The directions as written, for example "1 cap 3x a day x 7 days".'),
        },
        optionalProperties: ['strength', 'amount', 'directions'],
      ),
    ),
  });

  /// Returns one result per medicine found (at least one), or null if the user
  /// cancelled the photo.
  static Future<List<ScanResult>?> scanWithAi(ImageSource source) async {
    // 1600 px is enough to read handwriting and uploads faster than 2000 px.
    final XFile? picked = await _pick(source, maxWidth: 1600, quality: 85);
    if (picked == null) return null;
    final bytes = await picked.readAsBytes();

    // App Check token first, with its own short limit, so a stuck App Check
    // shows a clear message instead of "the AI took too long".
    try {
      await FirebaseAppCheck.instance.getToken().timeout(OcrConfig.appCheckTimeout);
    } on TimeoutException {
      throw const ScanException(
          'App Check did not answer. Add this phone\'s debug token in the Firebase console '
          '(App Check > Apps > Manage debug tokens), then try again.');
    } catch (_) {
      // Not fatal here: if AI Logic really needs App Check, the request below
      // fails with a clear App Check error.
    }

    try {
      final mime = _mimeType(picked);
      final limit = OcrConfig.timeout;
      String text;
      try {
        text = await _readPhoto(OcrConfig.model, bytes, mime, limit);
      } on TimeoutException {
        // No answer. Find out why with a tiny text-only message, then try the
        // backup model once before giving up.
        final test = await _connectionTest(OcrConfig.model);
        if (test != null && test.startsWith('error:')) {
          throw ScanException('Gemini test failed: ${test.substring(6)}');
        }
        final backup = OcrConfig.fallbackModel;
        if (backup.isEmpty || backup == OcrConfig.model) {
          throw ScanException(_timeoutMessage(test));
        }
        try {
          text = await _readPhoto(backup, bytes, mime, OcrConfig.fallbackTimeout);
        } on TimeoutException {
          final test2 = await _connectionTest(backup);
          throw ScanException(_timeoutMessage(test ?? test2));
        }
      }
      return _resultsFromJson(text);
    } on SocketException {
      throw const ScanException(_noInternet);
    } on http.ClientException {
      throw const ScanException(_noInternet);
    } on QuotaExceeded {
      throw const ScanException(
          'The free AI limit was reached. Try again later, or type the details in.');
    } on ServiceApiNotEnabled {
      throw const ScanException(
          'Firebase AI Logic is not turned on yet. Open the Firebase console, go to AI Logic, '
          'and click "Get started".');
    } on FirebaseAIException catch (e) {
      final m = e.message.toLowerCase();
      if (m.contains('app check') || m.contains('appcheck') || m.contains('attestation')) {
        throw const ScanException(
            'App Check blocked the request. Add this phone\'s debug token in the Firebase '
            'console (App Check > Apps > Manage debug tokens).');
      }
      if (m.contains('model') && (m.contains('not found') || m.contains('not supported'))) {
        throw const ScanException(
            'The AI model in lib/ocr_config.dart is not available. Change OcrConfig.model.');
      }
      throw ScanException('AI scan failed: ${e.message}');
    } on FirebaseException catch (e) {
      if (e.plugin.contains('app_check') || e.plugin.contains('appcheck')) {
        throw const ScanException(
            'App Check blocked the request. Add this phone\'s debug token in the Firebase '
            'console (App Check > Apps > Manage debug tokens).');
      }
      throw ScanException('AI scan failed: ${e.message ?? e.code}');
    }
  }

  static const String _noInternet = 'No internet connection. Handwritten scan needs internet.';

  static GenerativeModel _photoModel(String modelName) => FirebaseAI.googleAI().generativeModel(
        model: modelName,
        systemInstruction: Content.system(_aiInstructions),
        generationConfig: GenerationConfig(
          // No temperature: Gemini 3 models should keep the default (1.0); a low
          // temperature can make them loop until the request times out.
          maxOutputTokens: 4096, // a prescription never needs more; stops runaway answers
          thinkingConfig: ThinkingConfig.withThinkingLevel(ThinkingLevel.low), // much faster
          responseMimeType: 'application/json',
          responseSchema: _aiSchema,
        ),
      );

  /// Sends the photo to [modelName] and returns Gemini's JSON text.
  static Future<String> _readPhoto(String modelName, Uint8List bytes, String mime, Duration limit) async {
    final watch = Stopwatch()..start();
    debugPrint('[AI scan] sending ${(bytes.length / 1024).round()} KB photo to $modelName');
    try {
      final response = await _photoModel(modelName).generateContent([
        Content.multi([
          const TextPart('Read this prescription or medicine label.'),
          InlineDataPart(mime, bytes),
        ]),
      ]).timeout(limit);
      debugPrint('[AI scan] $modelName answered in ${watch.elapsed.inSeconds} s');
      return response.text ?? '';
    } on TimeoutException {
      debugPrint('[AI scan] $modelName gave no answer in ${limit.inSeconds} s');
      rethrow;
    }
  }

  static String _timeoutMessage(String? testSeconds) {
    if (testSeconds == null) {
      return 'Gemini did not answer, and a short test message also got no answer, so this '
          'phone cannot reach Gemini right now. Check the internet (try switching between '
          'Wi-Fi and mobile data) and try again.';
    }
    return 'Gemini is reachable (test answered in $testSeconds s) but could not read this photo '
        'in time. Try again with a closer, well-lit photo of just the medicines.';
  }

  /// Sends "Reply with OK" (no photo). Returns the seconds it took, null if
  /// there was no answer in 15 s, or "error:<message>" if it failed.
  static Future<String?> _connectionTest(String modelName) async {
    final watch = Stopwatch()..start();
    try {
      final model = FirebaseAI.googleAI().generativeModel(
        model: modelName,
        generationConfig: GenerationConfig(
          maxOutputTokens: 20,
          thinkingConfig: ThinkingConfig.withThinkingLevel(ThinkingLevel.minimal),
        ),
      );
      await model
          .generateContent([Content.text('Reply with OK')])
          .timeout(const Duration(seconds: 15));
      debugPrint('[AI scan] test answered in ${watch.elapsed.inSeconds} s');
      return '${watch.elapsed.inSeconds}';
    } on TimeoutException {
      debugPrint('[AI scan] test ($modelName) got no answer in 15 s');
      return null;
    } catch (e) {
      debugPrint('[AI scan] test failed: $e');
      return 'error:$e';
    }
  }

  static String _mimeType(XFile f) {
    final fromPicker = f.mimeType;
    if (fromPicker != null && fromPicker.startsWith('image/')) return fromPicker;
    final p = f.path.toLowerCase();
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.webp')) return 'image/webp';
    if (p.endsWith('.heic') || p.endsWith('.heif')) return 'image/heic';
    return 'image/jpeg';
  }

  static String? _str(Object? v) {
    final s = v is String ? v.trim() : '';
    return s.isEmpty ? null : s;
  }

  /// Reads "08:00" (24-hour) or "8:00 AM".
  static TimeOfDay? _parseTime(Object? v) {
    if (v is! String) return null;
    final m = RegExp(r'^\s*(\d{1,2}):(\d{2})\s*$').firstMatch(v);
    if (m != null) {
      final h = int.parse(m.group(1)!);
      final min = int.parse(m.group(2)!);
      if (h < 24 && min < 60) return TimeOfDay(hour: h, minute: min);
      return null;
    }
    return parseTime12h(v);
  }

  static List<ScanResult> _resultsFromJson(String jsonText) {
    Object? data;
    try {
      data = jsonDecode(jsonText);
    } on FormatException {
      data = null;
    }
    final meds = (data is Map && data['medicines'] is List) ? data['medicines'] as List : const [];

    final results = <ScanResult>[];
    for (final m in meds) {
      if (m is! Map) continue;
      final name = _str(m['name']);
      if (name == null) continue;
      final amount = _str(m['amount']);
      final strength = _str(m['strength']);
      final dosage =
          (amount != null && strength != null) ? '$amount ($strength)' : (amount ?? strength);

      final times = <TimeOfDay>[];
      final rawTimes = m['times'];
      if (rawTimes is List) {
        for (final t in rawTimes) {
          final parsed = _parseTime(t);
          if (parsed != null &&
              !times.any((x) => x.hour == parsed.hour && x.minute == parsed.minute)) {
            times.add(parsed);
          }
        }
      }
      times.sort((a, b) => (a.hour * 60 + a.minute) - (b.hour * 60 + b.minute));
      final found = times.isNotEmpty;

      results.add(ScanResult(
        rawText: _str(m['directions']) ?? name,
        name: name,
        dosage: dosage,
        times: found ? times : [const TimeOfDay(hour: 8, minute: 0)],
        days: m['weekly'] == true ? ['Mon'] : List.of(kDaysOfWeek),
        foundFrequency: found,
      ));
    }

    if (results.isEmpty) {
      results.add(ScanResult(
        rawText: '',
        name: null,
        dosage: null,
        times: const [TimeOfDay(hour: 8, minute: 0)],
        days: List.of(kDaysOfWeek),
        foundFrequency: false,
      ));
    }
    return results;
  }
}

/// An error with a message that is safe to show to the user.
class ScanException implements Exception {
  final String message;
  const ScanException(this.message);

  @override
  String toString() => message;
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

  /// Splits a prescription with several medicines into one result each.
  /// A new medicine starts on every line that names a known medicine, or has
  /// a strength like "500 mg" after a name. Falls back to [parse] for one.
  static List<ScanResult> parseAll(String raw) {
    final lines = raw
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    final starts = <int>[];
    final names = <int, String>{};
    for (int i = 0; i < lines.length; i++) {
      final known = findKnownMedicine(lines[i]);
      String? name = known;
      if (name == null) {
        final m = _strength.firstMatch(lines[i]);
        if (m != null && m.start > 0) {
          name = _cleanName(lines[i]
              .substring(0, m.start)
              .replaceAll(RegExp(r'^(\d+[.)]\s*)?(rx|℞)?[:.\s]*', caseSensitive: false), ''));
        }
      }
      if (name == null) continue;
      final found = name;
      // Same medicine mentioned again (e.g. on its directions line): not a new one.
      if (names.values.any((n) => n.toLowerCase() == found.toLowerCase())) continue;
      starts.add(i);
      names[i] = found;
    }

    if (starts.length < 2) return [parse(raw)];

    final results = <ScanResult>[];
    for (int k = 0; k < starts.length; k++) {
      final from = starts[k];
      final to = k + 1 < starts.length ? starts[k + 1] : lines.length;
      final block = lines.sublist(from, to).join('\n');
      final r = parse(block);
      results.add(ScanResult(
        rawText: r.rawText,
        name: names[from],
        dosage: r.dosage,
        times: r.times,
        days: r.days,
        foundFrequency: r.foundFrequency,
      ));
    }
    return results;
  }

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
      name: findKnownMedicine(raw) ?? _findName(lines),
      dosage: _findDosage(raw),
      times: times,
      days: weekly ? ['Mon'] : List.of(kDaysOfWeek),
      foundFrequency: foundFrequency,
    );
  }

  /// Common generic medicines. Used to fix small OCR misspellings
  /// (for example "Amoxicilin" -> "Amoxicillin"). Add more names as needed.
  static const List<String> knownMedicines = [
    'Allopurinol', 'Ambroxol', 'Amlodipine', 'Amoxicillin', 'Ascorbic Acid', 'Aspirin',
    'Atenolol', 'Atorvastatin', 'Azithromycin', 'Betahistine', 'Bisoprolol',
    'Calcium Carbonate', 'Captopril', 'Carbocisteine', 'Carvedilol', 'Cefalexin',
    'Cephalexin', 'Cefixime', 'Cefuroxime', 'Celecoxib', 'Cetirizine', 'Ciprofloxacin',
    'Clarithromycin', 'Clonidine', 'Clopidogrel', 'Co-Amoxiclav', 'Colchicine',
    'Dexamethasone', 'Diclofenac', 'Digoxin', 'Diphenhydramine', 'Domperidone',
    'Doxycycline', 'Enalapril', 'Esomeprazole', 'Famotidine', 'Ferrous Sulfate',
    'Fluoxetine', 'Folic Acid', 'Furosemide', 'Gabapentin', 'Gliclazide', 'Glimepiride',
    'Hydrochlorothiazide', 'Ibuprofen', 'Irbesartan', 'Isosorbide', 'Lagundi',
    'Levofloxacin', 'Levothyroxine', 'Lisinopril', 'Loperamide', 'Loratadine', 'Losartan',
    'Mefenamic Acid', 'Metformin', 'Methyldopa', 'Metoclopramide', 'Metoprolol',
    'Metronidazole', 'Montelukast', 'Naproxen', 'Nifedipine', 'Omeprazole', 'Pantoprazole',
    'Paracetamol', 'Prednisone', 'Propranolol', 'Ranitidine', 'Rosuvastatin', 'Salbutamol',
    'Sertraline', 'Simvastatin', 'Sitagliptin', 'Spironolactone', 'Telmisartan', 'Tramadol',
    'Trimetazidine', 'Valsartan', 'Warfarin',
  ];

  /// Finds a known medicine in the text, allowing small spelling mistakes:
  /// none for names under 5 letters, 1 for 5-9 letters, 2 for 10 or more.
  static String? findKnownMedicine(String raw) {
    final words =
        raw.toLowerCase().split(RegExp(r'[^a-z]+')).where((w) => w.isNotEmpty).toList();
    final candidates = <String>[...words];
    for (int i = 0; i + 1 < words.length; i++) {
      candidates.add(words[i] + words[i + 1]); // two-word names, split-up words
    }

    String? best;
    int bestDistance = 1 << 30;
    int bestLength = 0;
    for (final med in knownMedicines) {
      final key = med.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
      final allowed = key.length ~/ 5;
      for (final c in candidates) {
        if ((c.length - key.length).abs() > allowed) continue;
        final d = _editDistance(c, key, allowed);
        if (d > allowed) continue;
        if (d < bestDistance || (d == bestDistance && key.length > bestLength)) {
          best = med;
          bestDistance = d;
          bestLength = key.length;
        }
      }
    }
    return best;
  }

  /// Edit distance where a missing, extra, wrong, or swapped letter each count as 1.
  /// Stops early and returns max + 1 once the distance is over [max].
  static int _editDistance(String a, String b, int max) {
    List<int>? prev2;
    var prev = List<int>.generate(b.length + 1, (j) => j);
    for (int i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0);
      cur[0] = i;
      var rowMin = i;
      for (int j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        var v = prev[j] + 1;
        if (cur[j - 1] + 1 < v) v = cur[j - 1] + 1;
        if (prev[j - 1] + cost < v) v = prev[j - 1] + cost;
        if (prev2 != null &&
            j > 1 &&
            a.codeUnitAt(i - 1) == b.codeUnitAt(j - 2) &&
            a.codeUnitAt(i - 2) == b.codeUnitAt(j - 1) &&
            prev2[j - 2] + 1 < v) {
          v = prev2[j - 2] + 1;
        }
        cur[j] = v;
        if (v < rowMin) rowMin = v;
      }
      if (rowMin > max) return max + 1;
      prev2 = prev;
      prev = cur;
    }
    return prev[b.length];
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
