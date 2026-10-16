# PillPal

Flutter + Firebase medicine reminder app that works with **PillPalBox**, a Bluetooth (HC-05) pill organizer whose LEDs show which compartment to open.

## Features
- Medicine schedules with alarm-style reminders, intake confirmation, and Daily/Weekly history
- PillPalBox pairing and slot assignment (lights the right compartment at dose time)
- **Scan-to-Schedule** — scan a prescription or label (Google ML Kit OCR, offline) to pre-fill the Add Schedule form
- **Missed-Dose Safety Escalation** — follow-up reminders at +10 and +20 min, auto-marked missed at +30 min with a caregiver alert, and an "Are you okay?" check-in after 2 missed doses in a row (no answer in 15 min alerts the caregiver)
- **Caregiver Companion Mode** — link a caregiver with a 6-character invite code; they see today's doses, 7-day adherence, and alerts, and can send a reminder

## Download
`release/PillPal.apk` — release build (Android). Copy it to a phone and open it to install (allow "Install unknown apps" if asked). Signed with the debug key, so it is for testing/demo, not the Play Store.

## Setup
1. `flutter pub get`
2. `android/app/google-services.json` holds the Firebase config (Firebase project `app-dev-thirdyear`).
3. Publish `firestore.rules` in Firebase console → Firestore Database → Rules (needed for Caregiver mode).
4. `flutter run`

Note: alerts and caregiver reminders are delivered while the app is open (no Cloud Functions/FCM yet). Bluetooth does not work on the Android emulator.
