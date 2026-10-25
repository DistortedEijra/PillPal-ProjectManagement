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
    // 1280 px is enough to read handwriting and keeps the request small.
    final XFile? picked = await _pick(source, maxWidth: 1280, quality: 80);
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
      // Try each model in turn. Free-tier Gemini models are often "busy" (high
      // demand) or slow; when one is, move straight on to the next.
      var busy = 0;
      var limited = 0;
      var missing = 0;
      for (final modelName in OcrConfig.models) {
        try {
          final text = await _readPhotoAnyThinking(modelName, bytes, mime);
          return _resultsFromJson(text);
        } on TimeoutException {
          // too slow: try the next model
        } on QuotaExceeded {
          debugPrint('[AI scan] $modelName: free limit reached');
          limited++; // free limits are per model, so the next one may still work
        } on ServerException catch (e) {
          if (_isBusy(e.message)) {
            debugPrint('[AI scan] $modelName is busy: ${e.message}');
            busy++;
          } else if (_isModelMissing(e.message)) {
            debugPrint('[AI scan] $modelName is not available: ${e.message}');
            missing++;
          } else {
            rethrow;
          }
        }
      }
      if (missing == OcrConfig.models.length) {
        throw const ScanException(
            'None of the AI models in lib/ocr_config.dart are available. Update OcrConfig.models.');
      }
      if (limited > 0 && busy == 0) {
        throw const ScanException(
            'The free AI limit was reached. Try again later, or type the details in.');
      }
      if (busy > 0) {
        throw const ScanException(
            'Gemini is very busy right now (high demand on Google\'s side). '
            'Wait a minute and try again, or type the details in.');
      }
      // Every model was too slow: check whether this phone can reach Gemini.
      throw ScanException(_timeoutMessage(await _connectionTest(OcrConfig.models.first)));
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
            'The AI model in lib/ocr_config.dart is not available. Update OcrConfig.models.');
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

  static GenerativeModel _photoModel(String modelName, {required bool lowThinking}) =>
      FirebaseAI.googleAI().generativeModel(
        model: modelName,
        systemInstruction: Content.system(_aiInstructions),
        generationConfig: GenerationConfig(
          // No temperature: Gemini 3 models should keep the default (1.0); a low
          // temperature can make them loop until the request times out.
          maxOutputTokens: 4096, // a prescription never needs more; stops runaway answers
          thinkingConfig: lowThinking
              ? ThinkingConfig.withThinkingLevel(ThinkingLevel.low) // much faster
              : null,
          responseMimeType: 'application/json',
          responseSchema: _aiSchema,
        ),
      );

  /// "The model is overloaded / experiencing high demand / unavailable".
  static bool _isBusy(String message) {
    final m = message.toLowerCase();
    return m.contains('high demand') ||
        m.contains('overloaded') ||
        m.contains('unavailable') ||
        m.contains('try again later') ||
        m.contains('503');
  }

  static bool _isModelMissing(String message) {
    final m = message.toLowerCase();
    return m.contains('model') &&
        !m.contains('thinking') &&
        (m.contains('not found') || m.contains('not supported'));
  }

  /// Reads the photo with low thinking; if this model does not accept that
  /// setting, asks again with the model's default thinking.
  static Future<String> _readPhotoAnyThinking(String modelName, Uint8List bytes, String mime) async {
    try {
      return await _readPhoto(modelName, bytes, mime, OcrConfig.timeoutPerModel, lowThinking: true);
    } on ServerException catch (e) {
      if (!e.message.toLowerCase().contains('thinking')) rethrow;
      debugPrint('[AI scan] $modelName rejected the thinking level, retrying with defaults');
      return _readPhoto(modelName, bytes, mime, OcrConfig.timeoutPerModel, lowThinking: false);
    }
  }

  /// Sends the photo to [modelName] and returns Gemini's JSON text.
  static Future<String> _readPhoto(String modelName, Uint8List bytes, String mime, Duration limit,
      {required bool lowThinking}) async {
    final watch = Stopwatch()..start();
    debugPrint('[AI scan] sending ${(bytes.length / 1024).round()} KB photo to $modelName');
    try {
      final response = await _photoModel(modelName, lowThinking: lowThinking).generateContent([
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
    if (testSeconds != null && testSeconds.startsWith('error:')) {
      return 'Gemini did not answer the photo, and a short test message failed: '
          '${testSeconds.substring(6)}';
    }
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
        // Default settings: not every model accepts every thinking level.
        generationConfig: GenerationConfig(maxOutputTokens: 50),
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

  /// True when the days came from the label ("daily", "Mon, Wed, Fri", "weekly"...).
  final bool foundDays;

  /// Extra hint for the user, e.g. "Take for 7 days." or "As needed".
  final String? note;

  const ScanResult({
    required this.rawText,
    required this.name,
    required this.dosage,
    required this.times,
    required this.days,
    required this.foundFrequency,
    this.foundDays = false,
    this.note,
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
    if (foundDays && days.length < 7) found.add('days (${days.join(', ')})');
    final missing = <String>[];
    if (name == null) missing.add('name');
    if (dosage == null) missing.add('dosage');
    if (!foundFrequency) missing.add('schedule (set to 8:00 AM)');
    var s = 'Found: ${found.join(', ')}.';
    if (missing.isNotEmpty) s += ' Not found: ${missing.join(', ')}.';
    if (note != null) s += ' $note';
    return '$s Please check everything before saving.';
  }
}

/// Rule-based parser for common prescription wording
/// (e.g. "Amoxicillin 500mg", "Take 1 capsule 3x a day", "BID", "every 8 hours").
class PrescriptionParser {
  /// Strength: "500 mg", "15mg/5ml", "100 IU", "1%".
  static final RegExp _strength = RegExp(
      r'(\d+(?:\.\d+)?)\s?(mg|mcg|µg|ug|g|iu|units?|%)(?:\s?/\s?(\d+(?:\.\d+)?)?\s?(ml|tab|cap)s?)?(?![a-z])',
      caseSensitive: false);

  /// Amount per dose: "1 tab", "1/2 tablet", "½ tab", "1 1/2 caps", "5 ml",
  /// "2 puffs", "10 drops", "isang tableta".
  static final RegExp _amount = RegExp(
      r'(?<![\w/.])(\d+\s+1/2|\d+(?:\.\d+)?|\d/\d|½|¼|one|two|three|four|half|isang|dalawang|kalahating)'
      r'\s*-?\s*(tablets?|tabs?|tableta|capsules?|caps?|kapsula|pills?|puffs?|drops?|gtts?|teaspoons?|tsps?|'
      r'tablespoons?|tbsps?|mls?|cc|sachets?|ampules?|ampoules?|patch(?:es)?|sprays?|suppositor(?:y|ies)|vials?|lozenges?)'
      r'(?![a-z])',
      caseSensitive: false);

  /// "8am", "8 a.m.", "8:30 PM", "8.30pm".
  static final RegExp _clock12 =
      RegExp(r'(?<![\d:.])(1[0-2]|0?[1-9])(?:[:.]([0-5]\d))?\s*([ap])\.?\s?m\b\.?', caseSensitive: false);

  /// 24-hour "20:00", "08:00", "9:00" (only when no AM/PM follows).
  static final RegExp _clock24 = RegExp(
      r'(?<![\d:/.])([01]?\d|2[0-3]):([0-5]\d)(?!\d)(?!\s*[ap]\.?\s?m\b)',
      caseSensitive: false);

  /// "1-0-1" style (morning-noon-night).
  static final RegExp _mnn = RegExp(r'(?<![\d\-/.])([0-2])\s?-\s?([0-2])\s?-\s?([0-2])(?![\d\-/])');

  static final RegExp _everyHours = RegExp(
      r'(?:every\s+(\d{1,2})\s*(?:hours?|hrs?|h)\b|\bq\.?\s?(\d{1,2})\s?(?:h|hrs?|hours?)\b|tuwing\s+(\d{1,2})\s+oras)',
      caseSensitive: false);

  /// "once a week", "2x a week", "twice weekly", "weekly", "isang beses sa isang linggo".
  static final RegExp _perWeek = RegExp(
      r'\b(once|twice|thrice|one|two|three|\d)\s*(?:x|times?)?\s*(?:a|per|every|each|/)\s*(?:week|wk)\b'
      r'|\b(once|twice|thrice)\s+weekly\b|\bweekly\b|\bevery\s+week\b|\bq\.?\s?wk\b'
      r'|(?:isang beses|minsan) sa isang linggo',
      caseSensitive: false);

  static final RegExp _everyOtherDay = RegExp(
      r'every\s+other\s+day|alternate\s+days?|every\s+(?:2|two)\s+days|every\s+second\s+day|\bq\.?o\.?d\b|tuwing\s+ikalawang\s+araw',
      caseSensitive: false);

  static final RegExp _duration = RegExp(
      r'(?:\bfor\s+|\bx\s*|×\s*|sa\s+loob\s+ng\s+)(\d{1,3})\s*(days?|weeks?|months?|araw|linggo)\b',
      caseSensitive: false);

  static final RegExp _asNeeded =
      RegExp(r'\bprn\b|as needed|when needed|if needed|kung kailangan', caseSensitive: false);

  /// Words for a time of day, with the time they stand for.
  static final List<(RegExp, TimeOfDay)> _timeWords = [
    (RegExp(r'\b(morning|breakfast|umaga|almusal|q\.?am)\b', caseSensitive: false),
        const TimeOfDay(hour: 8, minute: 0)),
    (RegExp(r'\b(noon|lunch|midday|tanghali|tanghalian)\b', caseSensitive: false),
        const TimeOfDay(hour: 12, minute: 0)),
    (RegExp(r'\b(afternoon|hapon|merienda)\b', caseSensitive: false), const TimeOfDay(hour: 15, minute: 0)),
    (RegExp(r'\b(evening|dinner|supper|hapunan|q\.?pm)\b', caseSensitive: false),
        const TimeOfDay(hour: 19, minute: 0)),
    (RegExp(r'\b(night|bedtime|h\.?s|q\.?h\.?s|before sleep|bago matulog|gabi)\b', caseSensitive: false),
        const TimeOfDay(hour: 21, minute: 0)),
  ];

  static const Map<String, String> _dayWords = {
    'monday': 'Mon', 'mon': 'Mon', 'lunes': 'Mon',
    'tuesday': 'Tue', 'tues': 'Tue', 'tue': 'Tue', 'martes': 'Tue',
    'wednesday': 'Wed', 'wed': 'Wed', 'miyerkules': 'Wed', 'miyerkoles': 'Wed',
    'thursday': 'Thu', 'thurs': 'Thu', 'thur': 'Thu', 'thu': 'Thu', 'huwebes': 'Thu',
    'friday': 'Fri', 'fri': 'Fri', 'biyernes': 'Fri',
    'saturday': 'Sat', 'sat': 'Sat', 'sabado': 'Sat',
    'sunday': 'Sun', 'sun': 'Sun',
  };

  static final String _dayAlt = (_dayWords.keys.toList()..sort((a, b) => b.length - a.length)).join('|');
  static final RegExp _dayName = RegExp('\\b($_dayAlt|(?:tuwing|every)\\s+linggo)s?\\.?(?![a-z])', caseSensitive: false);
  static final RegExp _dayRange = RegExp(
      '\\b($_dayAlt)s?\\.?\\s*(?:-|–|to|thru|through|until|hanggang)\\s*($_dayAlt)s?\\b',
      caseSensitive: false);
  static final RegExp _dayCodes = RegExp(r'\b(m\s?w\s?f|t\s?th\s?s|t\s?th|m\s?-\s?f)\b', caseSensitive: false);

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
        foundDays: r.foundDays,
        note: r.note,
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
    // Lines with the prescription date or the doctor's clinic hours would add
    // wrong days/times, so the schedule is read from the other lines.
    final scheduleText = lines
        .where((l) => !RegExp(r'^(date|petsa|clinic|tel|phone|address|lic|ptr|s2)\b', caseSensitive: false)
            .hasMatch(l))
        .join('\n');
    final lower = scheduleText.toLowerCase();

    final weekly = _weeklyCount(lower);
    var times = _findTimes(lower);
    final foundFrequency = times.isNotEmpty || weekly != null;
    if (times.isEmpty) times = [const TimeOfDay(hour: 8, minute: 0)];

    final days = _findDays(lower, weekly);

    final notes = <String>[];
    if (days.everyOtherDay) {
      notes.add('"Every other day" was set to Mon, Wed, Fri, Sun. Change it if needed.');
    }
    final dur = _duration.firstMatch(lower);
    if (dur != null) notes.add('Take for ${dur.group(1)} ${_durationUnit(dur.group(2)!, dur.group(1)!)}.');
    if (_asNeeded.hasMatch(lower)) notes.add('Marked "as needed" on the label.');

    return ScanResult(
      rawText: raw,
      name: findKnownMedicine(raw) ?? _findName(lines),
      dosage: _findDosage(raw),
      times: times,
      days: days.days,
      foundFrequency: foundFrequency,
      foundDays: days.found,
      note: notes.isEmpty ? null : notes.join(' '),
    );
  }

  static String _durationUnit(String unit, String n) {
    final u = unit.toLowerCase();
    final one = n == '1';
    if (u.startsWith('day') || u == 'araw') return one ? 'day' : 'days';
    if (u.startsWith('week') || u == 'linggo') return one ? 'week' : 'weeks';
    return one ? 'month' : 'months';
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

  // ---------------- dosage ----------------

  static String? _findDosage(String raw) {
    final strength = _strength.firstMatch(raw);

    RegExpMatch? amount;
    for (final m in _amount.allMatches(raw)) {
      // "5ml" inside "15mg/5ml" is part of the strength, not the dose.
      if (strength != null && m.start < strength.end && m.end > strength.start) continue;
      final value = _qtyValue(m.group(1)!);
      if (value == null || value <= 0) continue;
      final start = m.start;
      final before = raw.substring(start >= 14 ? start - 14 : 0, start).toLowerCase();
      // Skip "Qty: 30 tablets", "#60 tabs", "Dispense 21 caps".
      if (RegExp(r'(qty|quantity|#|disp|no\.|total)[^\n]*$').hasMatch(before)) continue;
      final isTake = RegExp(r'(take|sig|inumin|uminom|give|use|apply|inhale|instill|chew|dissolve)\W*$')
          .hasMatch(before);
      final unit = _unitName(m.group(2)!, 1);
      final liquid = unit == 'ml' || unit == 'tsp' || unit == 'tbsp' || unit == 'drop';
      if (!isTake && value > (liquid ? 30 : 4)) continue;
      if (isTake) {
        amount = m;
        break;
      }
      amount ??= m;
    }

    String? amountText;
    if (amount != null) {
      final value = _qtyValue(amount.group(1)!)!;
      amountText = '${_qtyText(amount.group(1)!)} ${_unitName(amount.group(2)!, value)}';
    }
    final strengthText = strength == null ? null : _strengthText(strength);

    if (amountText != null && strengthText != null) return '$amountText ($strengthText)';
    return amountText ?? strengthText;
  }

  static String _strengthText(RegExpMatch m) {
    String unit(String u) {
      final l = u.toLowerCase();
      if (l == 'iu') return 'IU';
      if (l == 'ug' || l == 'µg') return 'mcg';
      if (l == 'unit') return 'units';
      return l;
    }

    var text = m.group(2) == '%' ? '${m.group(1)}%' : '${m.group(1)} ${unit(m.group(2)!)}';
    if (m.group(4) != null) {
      final per = m.group(3);
      text += per == null ? '/${m.group(4)!.toLowerCase()}' : '/$per ${m.group(4)!.toLowerCase()}';
    }
    return text;
  }

  static const Map<String, double> _qtyWords = {
    'one': 1, 'two': 2, 'three': 3, 'four': 4, 'half': 0.5, 'isang': 1, 'dalawang': 2,
    'kalahating': 0.5, '½': 0.5, '¼': 0.25,
  };

  static double? _qtyValue(String q) {
    final t = q.trim().toLowerCase();
    if (_qtyWords.containsKey(t)) return _qtyWords[t];
    final mixed = RegExp(r'^(\d+)\s+1/2$').firstMatch(t);
    if (mixed != null) return int.parse(mixed.group(1)!) + 0.5;
    final frac = RegExp(r'^(\d)/(\d)$').firstMatch(t);
    if (frac != null) {
      final d = int.parse(frac.group(2)!);
      return d == 0 ? null : int.parse(frac.group(1)!) / d;
    }
    return double.tryParse(t);
  }

  static String _qtyText(String q) {
    final t = q.trim().toLowerCase();
    switch (t) {
      case 'half':
      case 'kalahating':
      case '½':
        return '1/2';
      case '¼':
        return '1/4';
      case 'one':
      case 'isang':
        return '1';
      case 'two':
      case 'dalawang':
        return '2';
      case 'three':
        return '3';
      case 'four':
        return '4';
    }
    return t.replaceAll(RegExp(r'\s+'), ' ');
  }

  /// "tabs" -> "tablet(s)", "gtt" -> "drop(s)", "cc" -> "ml".
  static String _unitName(String raw, double value) {
    final u = raw.toLowerCase();
    String base;
    if (u.startsWith('tab') && !u.startsWith('tablesp')) {
      base = 'tablet';
    } else if (u.startsWith('cap') || u == 'kapsula') {
      base = 'capsule';
    } else if (u.startsWith('pill')) {
      base = 'pill';
    } else if (u.startsWith('puff')) {
      base = 'puff';
    } else if (u.startsWith('drop') || u.startsWith('gtt')) {
      base = 'drop';
    } else if (u.startsWith('teasp') || u.startsWith('tsp')) {
      base = 'tsp';
    } else if (u.startsWith('tablesp') || u.startsWith('tbsp')) {
      base = 'tbsp';
    } else if (u.startsWith('ml') || u == 'cc') {
      base = 'ml';
    } else if (u.startsWith('sachet')) {
      base = 'sachet';
    } else if (u.startsWith('amp')) {
      base = 'ampule';
    } else if (u.startsWith('patch')) {
      base = 'patch';
    } else if (u.startsWith('spray')) {
      base = 'spray';
    } else if (u.startsWith('suppositor')) {
      base = 'suppository';
    } else if (u.startsWith('vial')) {
      base = 'vial';
    } else if (u.startsWith('lozenge')) {
      base = 'lozenge';
    } else {
      base = u;
    }
    if (value <= 1 || base == 'ml' || base == 'tsp' || base == 'tbsp') return base;
    if (base == 'patch') return 'patches';
    if (base == 'suppository') return 'suppositories';
    return '${base}s';
  }

  // ---------------- times ----------------

  static List<TimeOfDay> _findTimes(String lower) {
    final result = <TimeOfDay>[];
    void add(int h, int m) {
      if (!result.any((t) => t.hour == h && t.minute == m)) {
        result.add(TimeOfDay(hour: h, minute: m));
      }
    }

    List<TimeOfDay> sorted() =>
        result..sort((a, b) => (a.hour * 60 + a.minute) - (b.hour * 60 + b.minute));

    // 1) Clock times written on the label: "8am", "8:30 PM", "20:00".
    for (final m in _clock12.allMatches(lower)) {
      var h = int.parse(m.group(1)!);
      final min = int.tryParse(m.group(2) ?? '') ?? 0;
      final pm = m.group(3)!.toLowerCase() == 'p';
      if (pm && h < 12) h += 12;
      if (!pm && h == 12) h = 0;
      add(h, min);
    }
    for (final m in _clock24.allMatches(lower)) {
      add(int.parse(m.group(1)!), int.parse(m.group(2)!));
    }
    if (result.isNotEmpty) return sorted();

    // 2) "1-0-1" = morning, noon, night.
    final mnn = _mnn.firstMatch(lower);
    if (mnn != null && (mnn.group(1) != '0' || mnn.group(2) != '0' || mnn.group(3) != '0')) {
      if (mnn.group(1) != '0') add(8, 0);
      if (mnn.group(2) != '0') add(13, 0);
      if (mnn.group(3) != '0') add(20, 0);
      return sorted();
    }

    // 3) "every 8 hours" / "q8h" / "tuwing 8 oras", starting at 8:00 AM.
    final every = _everyHours.firstMatch(lower);
    if (every != null) {
      final n = int.parse(every.group(1) ?? every.group(2) ?? every.group(3)!);
      if (n >= 2 && n <= 24) {
        for (int i = 0; i < 24 ~/ n && i < 6; i++) {
          add((8 + i * n) % 24, 0);
        }
        return result; // keep 8 AM first, like the label says
      }
    }

    // 4) Words for a time of day ("morning", "after dinner", "at bedtime", "gabi").
    final words = <TimeOfDay>[];
    for (final (re, t) in _timeWords) {
      if (re.hasMatch(lower)) words.add(t);
    }

    // 5) How many times a day ("3x a day", "BID", "twice daily", "tatlong beses").
    final count = _timesPerDay(lower.replaceAll(_perWeek, ' ').replaceAll(_duration, ' '));

    if (words.isNotEmpty && (count == null || count == words.length)) {
      for (final t in words) {
        add(t.hour, t.minute);
      }
      return sorted();
    }
    switch (count) {
      case 1:
        add(8, 0);
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
    }
    return sorted();
  }

  static int? _timesPerDay(String t) {
    const end = r'(?![a-z\d])';
    if (RegExp(r'\b(q\.?i\.?d\.?|four times|4\s?x|x\s?4|4 times|apat na beses)' + end).hasMatch(t)) return 4;
    if (RegExp(r'\b(t\.?i\.?d\.?|thrice|three times|3\s?x|x\s?3|3 times|tatlong beses)' + end).hasMatch(t)) {
      return 3;
    }
    if (RegExp(r'\b(b\.?i\.?d\.?|twice|two times|2\s?x|x\s?2|2 times|dalawang beses)' + end).hasMatch(t)) {
      return 2;
    }
    if (RegExp(r'\b(o\.?d\.?|q\.?d\.?|once|daily|1\s?x|x\s?1|one time|every\s?day|isang beses|araw[-\s]araw|'
                r'q\.?am|q\.?pm|q\.?h\.?s|h\.?s)' +
            end)
        .hasMatch(t)) {
      return 1;
    }
    return null;
  }

  // ---------------- days ----------------

  /// How many days a week for "once a week", "2x a week", "weekly"... or null.
  static int? _weeklyCount(String lower) {
    final m = _perWeek.firstMatch(lower);
    if (m == null) return null;
    final word = (m.group(1) ?? m.group(2) ?? 'once').toLowerCase();
    const counts = {'once': 1, 'one': 1, 'twice': 2, 'two': 2, 'thrice': 3, 'three': 3};
    final n = counts[word] ?? int.tryParse(word) ?? 1;
    return n.clamp(1, 7);
  }

  static ({List<String> days, bool found, bool everyOtherDay}) _findDays(String lower, int? weekly) {
    final set = <String>{};

    for (final m in _dayRange.allMatches(lower)) {
      final from = kDaysOfWeek.indexOf(_dayWords[m.group(1)!.toLowerCase()]!);
      final to = kDaysOfWeek.indexOf(_dayWords[m.group(2)!.toLowerCase()]!);
      for (int i = from;; i = (i + 1) % 7) {
        set.add(kDaysOfWeek[i]);
        if (i == to) break;
      }
    }
    for (final m in _dayCodes.allMatches(lower)) {
      final code = m.group(1)!.replaceAll(RegExp(r'[\s-]'), '');
      switch (code) {
        case 'mwf':
          set.addAll(['Mon', 'Wed', 'Fri']);
          break;
        case 'tth':
          set.addAll(['Tue', 'Thu']);
          break;
        case 'tths':
          set.addAll(['Tue', 'Thu', 'Sat']);
          break;
        case 'mf':
          set.addAll(['Mon', 'Tue', 'Wed', 'Thu', 'Fri']);
          break;
      }
    }
    if (RegExp(r'\bweekdays?\b|\bweekday only\b').hasMatch(lower)) {
      set.addAll(['Mon', 'Tue', 'Wed', 'Thu', 'Fri']);
    }
    if (RegExp(r'\bweekends?\b').hasMatch(lower)) set.addAll(['Sat', 'Sun']);
    for (final m in _dayName.allMatches(lower)) {
      final w = m.group(1)!.toLowerCase();
      set.add(w.endsWith('linggo') ? 'Sun' : _dayWords[w]!);
    }

    if (set.isNotEmpty) {
      return (days: kDaysOfWeek.where(set.contains).toList(), found: true, everyOtherDay: false);
    }
    if (_everyOtherDay.hasMatch(lower)) {
      return (days: ['Mon', 'Wed', 'Fri', 'Sun'], found: true, everyOtherDay: true);
    }
    if (weekly != null) {
      const spread = {
        1: ['Mon'],
        2: ['Mon', 'Thu'],
        3: ['Mon', 'Wed', 'Fri'],
        4: ['Mon', 'Tue', 'Thu', 'Fri'],
        5: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri'],
        6: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'],
      };
      return (days: List.of(spread[weekly] ?? kDaysOfWeek), found: true, everyOtherDay: false);
    }
    // A daily frequency means every day.
    final daily = _timesPerDay(lower.replaceAll(_duration, ' ')) != null ||
        _everyHours.hasMatch(lower) ||
        RegExp(r'\bdaily\b|every\s?day|araw[-\s]araw').hasMatch(lower);
    return (days: List.of(kDaysOfWeek), found: daily, everyOtherDay: false);
  }
}
