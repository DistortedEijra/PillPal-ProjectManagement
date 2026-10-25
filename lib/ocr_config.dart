/// Settings for the Handwritten (AI) mode of Scan-to-Schedule.
///
/// The photo is read by Gemini through Firebase AI Logic, using this app's
/// Firebase project (Gemini Developer API, free Spark plan).
class OcrConfig {
  /// Gemini models that read the prescriptions, tried in this order. If one
  /// is busy ("high demand") or too slow, the next one is tried. If Google
  /// retires a model, replace it (Firebase console > AI Logic lists models).
  static const List<String> models = [
    'gemini-3.5-flash', // stable, supported until at least May 2027
    'gemini-3.1-flash-lite', // lighter, usually less busy
    'gemini-3.8-flash', // newest, but often in high demand
  ];

  /// Time limit for each model before moving on to the next one.
  static const Duration timeoutPerModel = Duration(seconds: 35);

  /// Give up on getting an App Check token after this long.
  static const Duration appCheckTimeout = Duration(seconds: 20);

  /// Optional fixed App Check debug token, so every test phone can use the same
  /// one (Firebase console > App Check > Apps > Manage debug tokens > Add).
  /// Leave empty and each install makes its own token, shown in the run log.
  /// For testing only: anyone who has this APK can use the token.
  static const String appCheckDebugToken = 'C08D7F89-223B-4AEB-82B8-FF834E9BF384';
}
