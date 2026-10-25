# Flutter-specific additions.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.embedding.android.**  { *; }
-keep class io.flutter.embedding.engine.**  { *; }
-keep class io.flutter.plugin.common.**  { *; }
# Added rule for flutter_local_notifications
-keep class com.dexterous.flutterlocalnotifications.** { *; }

# ML Kit text recognition (Scan-to-Schedule): only the Latin model is used
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
-keep class com.google.mlkit.** { *; }

# Flutter references Play Core (deferred components), which this app does not use
-dontwarn com.google.android.play.core.**
