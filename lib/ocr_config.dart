/// Settings for the Handwritten (AI) mode of Scan-to-Schedule.
///
/// The photo is read by Gemini through Firebase AI Logic, using this app's
/// Firebase project (Gemini Developer API, free Spark plan).
class OcrConfig {
  /// Gemini model that reads the prescriptions. If Google retires it, put a
  /// current model name here (Firebase console > AI Logic lists them).
  static const String model = 'gemini-3.8-flash';

  /// Give up if Gemini has not answered after this long.
  static const Duration timeout = Duration(seconds: 90);

  /// Give up on getting an App Check token after this long.
  static const Duration appCheckTimeout = Duration(seconds: 20);

  /// Optional fixed App Check debug token, so every test phone can use the same
  /// one (Firebase console > App Check > Apps > Manage debug tokens > Add).
  /// Leave empty and each install makes its own token, shown in the run log.
  /// For testing only: anyone who has this APK can use the token.
  static const String appCheckDebugToken = 'C08D7F89-223B-4AEB-82B8-FF834E9BF384';
}
