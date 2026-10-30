# PillPal — Project Overview

Flutter mobile app: a medicine reminder companion for a physical Bluetooth-connected
pill dispenser ("PillPalBox"). App display name is "PillPal" (Android label), though
the package/namespace is still `com.example.myapp4` and an empty legacy native stub
exists at `app/src/main/java/com/example/medicinetracker/` (earlier working name,
now unused — safe to delete).

## What it does
1. User signs up / logs in with email+password (Firebase Auth); profile (name, age,
   gender, email) is stored in Firestore under `users/{uid}`.
2. User creates medicine schedules (name, dosage, repeat days, one or more times/day)
   stored at `users/{uid}/schedules/{scheduleId}`.
3. User pairs the app with an HC-05 Bluetooth pill dispenser (classic SPP, via
   `flutter_bluetooth_serial`), then assigns each medicine to a physical slot
   (A, B, C, ...) on the box. Slot assignments are stored in `users/{uid}.pillbox`
   (merged map, one entry per slot) and the paired device address is cached locally
   in `SharedPreferences` (`pillbox_address`).
4. `flutter_local_notifications` schedules a recurring weekly alarm-clock-style
   notification per schedule/time (`zonedSchedule`, `matchDateTimeComponents:
   dayOfWeekAndTime`), full-screen intent + custom sound, so it fires even if the
   app is closed. The notification payload is JSON encoding which medicine(s)/slot(s)
   are due.
5. When the reminder fires (foreground tap, or app launched cold from the
   notification via `getNotificationAppLaunchDetails` in `main.dart`), the app
   shows a confirmation dialog and sends a signal string over Bluetooth to the
   paired box telling it which slot to dispense from.
6. Dashboard shows today's schedules; a History tab shows Daily and Weekly logs
   (taken vs. missed) with a simple custom-painted pie chart, backed by
   `SharedPreferences`-based logging in `NotificationService`
   (`logMedicationTaken`, `getDailyLogs`, `getWeeklyLogs`, adherence rate).

## Added features (2026-10)
- `scan_to_schedule.dart` — Scan-to-Schedule: ML Kit OCR (`google_mlkit_text_recognition`) + `image_picker`; rule-based `PrescriptionParser` pre-fills name, dosage, times, days in the Add Schedule dialog (user confirms before saving). Parser (2026-10-25 rewrite) reads: days (Mon/Wed/Fri, MWF, TTh, Mon-Fri, weekdays/weekends, Tagalog Lunes..Sabado + tuwing Linggo, weekly / 2x a week spread out, every other day → Mon/Wed/Fri/Sun with a note); times (8am, 8 a.m., 8:30PM, 20:00, 1-0-1, every N hours / q8h / tuwing 8 oras, BID/TID/QID with dots, Tagalog beses, time words morning/noon/afternoon/evening/bedtime incl. umaga/tanghali/hapon/hapunan/gabi/bago matulog); dosage (1/2, ½, 1 1/2, isang tableta, tab→tablet, gtt→drop, cc→ml, 15mg/5ml syrups, skips Qty/#/Disp counts). Skips Date/Clinic/Tel lines; ScanResult has `foundDays` and `note` (duration "for 7 days", PRN).
- `escalation_service.dart` — Missed-Dose Safety Escalation: pending doses in SharedPreferences, follow-ups at +10/+20 min, auto-missed at +30 min, check-in after 2 consecutive misses, caregiver alerts in `users/{uid}/alerts`. Also owns intake logging (`logIntake`).
- `caregiver_service.dart` / `caregiver_page.dart` — Caregiver Companion Mode: invite codes (`invites/{code}`), `users/{patient}/caregivers`, `users/{caregiver}/patients`, nudges (`users/{patient}/nudges`), `CareListeners` shows nudges/alerts as local notifications while the app is open. "Care" button in the dashboard header.
- `firestore.rules` — owner + linked-caregiver read rules; must be published in the Firebase console.
- `reminder_chat_page.dart` — Reminders chat (2026-10-24): caregiver types reminders (stored as `users/{patient}/nudges`, one thread per caregiver via `fromUid`); patient opens it from My caregivers and taps Done (`done`, `doneAtMs`); caregiver sees Done / Not done yet live. Opened from the caregiver card (patient) and the "Reminders chat" button on PatientMonitorPage (caregiver).
- Account switching (2026-10-24): `AuthWrapper` keys `DashboardPage` by uid and `_fetchPillBoxAssignments` always replaces the list, so one account's PillPalBox slots never show in another; logout also calls `EscalationService.resetForLogout()`. PillPalBox slots have an "Empty" option and empty slots are saved.
- User builds the APK themselves from now on (2026-10-24): push code only, don't build or commit `release/PillPal.apk`.
- Handwritten scan (2026-10-25): `PrescriptionScanner.scanWithAi` sends the photo to Gemini via Firebase AI Logic (`firebase_ai` 5.1, `FirebaseAI.googleAI()`, model in `lib/ocr_config.dart`). Gemini 3 settings: no `temperature` (low temperature can make it loop → timeout), `ThinkingLevel.low`, `maxOutputTokens: 4096`, 1280 px photo, tries `OcrConfig.models` in order (gemini-3.5-flash, gemini-3.1-flash-lite, gemini-3.8-flash; 35 s each), moving on when a model is busy ("high demand" ServerException), over its free limit, missing, or slow; retries without thinkingConfig if a model rejects the level; if all are slow, a text-only test message says whether the phone can reach Gemini (gemini-3.8-flash rejects ThinkingLevel.minimal). App Check token pre-check with its own 20 s limit. `ocr_server/` is an earlier self-hosted Donut idea, not used.
- Several medicines on one prescription (2026-10-25): AI mode returns one item per medicine; printed mode uses `PrescriptionParser.parseAll` (splits at lines naming a medicine). `scan_review_dialog.dart` lists them with checkboxes and per-item edit (name, dose, times, days); "Add N medicines" saves them all in one Firestore batch (`_saveScannedMedicines` in dashboard). Medicines already scheduled start unticked.
- Edit schedules (2026-10-25): `medicine_editor.dart` (`showMedicineEditor`, `MedicineEdit`, `ScheduleEdits.save`). Patient: tap a medicine card (or ✎) on the dashboard; long-press still deletes. Caregiver: "Medicines" card on PatientMonitorPage with ✎ per medicine. Saves name/dosage/schedules/repeatDays + updatedAt/updatedBy/updatedByName; a caregiver rename also writes `renamedFrom`, and the patient's dashboard (live `_schedulesSub` listener) renames the PillPalBox slot, clears `renamedFrom`, re-syncs alarms and shows "X updated Y". `firestore.rules` lets a linked caregiver update only those schedule fields (must be re-published).
- PillPalBox offline reminders (2026-10-25): `arduino/pillpalbox/pillpalbox.ino` v3 saves a reminder list in EEPROM (max 40 entries: slot, day mask Mon=bit0..Sun=bit6, hh, mm) and keeps a clock (DS3231 by default via `#define USE_DS3231 1` + RTClib, falls back to millis if the module is missing), blinking the slot itself for 5 min even when Bluetooth is off. Line protocol after '#': `#T,Y,M,D,h,m,s` / `#C` / `#O,uid,name` (owner, saved with #E at EEPROM 200) / `#S,slot,mask,hh,mm` / `#E` (save) / `#Q` / `#W` (→ "OWNER uid,name" or "OWNER none"); single-char commands: over Bluetooth only A–F/0/!/? and ignored for 1.5 s after any `#` line traffic (lost `#` bytes used to leave stray letters, e.g. a "b" in the uid turned slot B steady on); a–f steady only from USB. #T/#C/#O no longer reply (SoftwareSerial cannot receive while sending). STATE debounce is now non-blocking; on disconnect only app-triggered LEDs turn off. App: `lib/pillbox_sync.dart` (`planPillBoxEntries`, `pillBoxSyncLines`, `PillBoxSync.sync`, 120 ms per line) runs on box connect and after every `_syncReminders`, only once schedules and slots loaded OK (so a failed load never wipes the box). Sketch compiles for Uno (12.6 KB flash, 1.1 KB RAM).
- PillPalBox owner (2026-10-29): the box stores who last saved its list (no screen; the app shows it). On every sync `PillBoxSync` sends the clock, asks `#W`, and if the owner is another uid calls `confirmReplace` (dashboard dialog "Use this PillPalBox?" → Keep theirs / Replace with mine). "Keep" stops list syncs until the box reconnects (`resetConnection`). The PillPalBox manager dialog shows "Medicines in the box: yours / set up by X" (`PillBoxSync.boxOwner`). Older sketches that don't answer `#W` are overwritten without asking. Sketch with DS3231: 17.9 KB flash, 71% RAM (fixed replies use F()).
- Email verification + password reset (2026-10-29): sign up checks the email format (`AuthService.looksLikeEmail`) and sends a Firebase verification link; `AuthWrapper` listens to `userChanges()` and shows `verify_email_page.dart` (auto-checks every 5 s, Resend with 60 s cooldown, "Use a different account") until verified. Accounts created before 2026-10-29 (`AuthService.verificationRequiredFrom`) are exempt so old test accounts still work. Login has "Forgot password?" (`sendPasswordReset`). Auth files are CRLF.
- Demo reset (2026-10-29): `tools/demo-data/reset_and_seed.js` (Node, firebase-admin, needs `serviceAccountKey.json` from Firebase console; git-ignored) deletes ALL Auth users and ALL Firestore collections, then creates patient@pillpal.test / caregiver@pillpal.test (password PillPal123, emailVerified, linked) with 5 medicines in slots A–E (Amoxicillin E is a 7-day course: started 3 days ago), 7 days of logs (3 missed + alerts) and 3 reminder-chat nudges. Times in Asia/Manila. Must be run by the user on their machine (this environment can't reach Google APIs).
- Notification fix (2026-10-30): `ReminderScheduler.sync` no longer cancels everything first; it runs one sync at a time (coalesces), schedules the soonest reminders first (`soonestFirst`), then follow-ups, then background checks, and only cancels ids that left the plan (`cancelAll` bumps a generation so a sync running during logout undoes itself). Before, editing a dose to "next minute" registered its alarm after that minute had passed (→ next week), so the box lit but no notification. `_triggerAlarm` now uses the alarm's id (`reminderIdFor`) and, ~8 s into the due minute, shows the notification itself if the alarm isn't on screen (`NotificationService.isShowing`).
- Release-build notifications (2026-10-30): `flutter build apk --release` shrinks resources, which removed `@drawable/icon` and `raw/fahh_effect` (only named from Dart), so every notification silently failed while debug builds worked. `android/app/src/main/res/raw/keep.xml` keeps them; `proguard-rules.pro` also keeps Gson generics for scheduled notifications. `_triggerAlarm` shows a snackbar + the Yes/No dialog if a notification still fails.
- Limited-time medicines (2026-10-30): optional `endDate` ('yyyy-MM-dd', last day inclusive; missing = ongoing) on schedules. `time_utils.dart`: `parseDateKey`, `runsOn`, `endDateForDays`, `daysLeft`, `courseText`. UI: `CourseLengthPicker` (Ongoing / 3 days / 5 days / 1 week / 2 weeks / 1 month / Pick last day) in Add Schedule, `showMedicineEditor` and the scan review edit; counting starts today. Scans fill it (`ScanResult.durationDays` from "for 7 days"/"x 2 weeks" via `PrescriptionParser.durationDaysIn`; Gemini schema has optional `days`). Finished courses: skipped by `_checkSchedules`, catch-up, history expected counts, caregiver Today card; card greyed with "Ended". `planWeeklyReminders(now:)` drops doses after the end and, when every medicine in a weekday/time group ends before next week, sets `PlannedReminder.onceAt` (one-time notification + follow-ups) instead of weekly. Due-check params carry `endDate`; `missedDoseCheckCallback` skips ended meds and stops re-arming. `planPillBoxEntries(now:)` only includes days still inside the course (box forgets it on next sync). `ScheduleEdits.save` writes endDate or deletes the field; `firestore.rules` caregiver keys include `endDate` (re-publish).
- Follow-ups after answering (2026-10-30): tapping Yes/No right after a cold start from the notification ran `skipFollowUpsFor` before `_lastPlan` was loaded, so nothing was cancelled and the next sync re-armed today's +10/+20 follow-ups. Now `skipFollowUpsFor` saves the answer in SharedPreferences (`answered_reminders`: "weekday|h|m" → due ms, pruned after 2 days, cleared by `cancelAll`/logout), cancels by `followUpIdFor(key, level)` immediately, waits for a running sync, and `_syncOnce` passes `followUpsNotBefore(...)` (due + 1 h) when scheduling follow-ups.
- Follow-ups are one-time alarms (2026-10-30, second fix): flutter_local_notifications' Android `zonedSchedule` with `matchDateTimeComponents` recomputes the date as the next matching day/time from now (`getNextFireDateMatchingDateTimeComponents`), ignoring the date passed in, so "move today's follow-ups to next week" re-armed them for today. `planFollowUps(r, now:, notBefore:)` now always sets `onceAt` (next dose's +10/+20, pushed a week while before `notBefore`), so `_schedule` uses `scheduleOneTimeNotification`; each sync re-arms them for the next dose (they lapse if the app isn't opened for a week; main reminders and due checks stay weekly). Dashboard `_firstSyncDone` Completer: `_triggerAlarm` waits (max 20 s) for the first alarm sync so a cold start inside the due minute doesn't start the in-app tracker's own follow-ups.
- `time_utils.dart` — shared `formatTime12h`, `dateKey`, `stableId`.
- `reminder_scheduler.dart` — registers every active schedule as a weekly Android alarm (`scheduleWeeklyNotification`, alarmClock mode with inexact fallback) so reminders fire when the app is closed; re-synced on load/add/delete/slot change, cancelled on logout. The dashboard's in-app timer still sends the Bluetooth signal and starts escalation, and skips its own notification when alarms are scheduled. Each reminder also gets weekly follow-up alarms at +10/+20 min (`planFollowUps`; moved to next week by `skipFollowUpsFor` once the dose is answered) and a background missed-dose check at +31 min (`background_tasks.dart`, `android_alarm_manager_plus`, self re-arming weekly) that calls `EscalationService.handleDueCheck` (logs missed if no History entry, caregiver alert, check-in + 15-min `handleCheckInTimeout`). The in-app pending tracker/catch-up only runs if alarms couldn't be scheduled. Needs Xiaomi Autostart ON.

## Architecture / key files (lib/)
- `main.dart` — app entrypoint; initializes notifications, Firebase, App Check
  (debug provider), requests BT/notification permissions, handles cold-start
  notification → Bluetooth signal flow.
- `auth_wrapper.dart` — routes to `AuthPage` or `DashboardPage` based on Firebase
  auth state.
- `auth_page.dart` / `auth_service.dart` / `signup.dart` — login/signup UI + Firebase
  Auth calls (`signup.dart` appears to be an older/alternate signup screen not
  wired into `auth_wrapper.dart`, which uses `auth_page.dart`'s combined
  login/signup toggle instead — worth checking if `signup.dart` is still used
  anywhere or is dead code).
- `dashboard.dart` (~1500 lines, the bulk of the app) — main Scaffold with
  Dashboard/History tabs, add-medicine dialog, PillPalBox manager dialog
  (scan/pair/assign slots), schedule polling timer (`_checkSchedules`) that
  triggers alarms/BT signals, delete-schedule flow, log viewers, `SimplePieChart`.
- `bluetooth_service.dart` — singleton wrapping `flutter_bluetooth_serial`:
  connect/reconnect/retry logic, `sendSignal(slot)`, broadcast streams for
  connection status and incoming data.
- `notification_service.dart` — singleton wrapping `flutter_local_notifications`:
  channel setup, permission requests (Android 13+ notif permission, Android 12+
  exact-alarm via intents), `scheduleWeeklyNotification`, and the
  SharedPreferences-backed intake-logging/adherence helpers.
- `firestore_service.dart` — thin Firestore wrapper for schedules and pillbox slot
  data (currently only partially used — much of this logic is duplicated inline
  in `dashboard.dart` rather than routed through this service).
- `debug_bluetooth_page.dart` — standalone screen for testing BT scan/connect/send
  outside the main flow (the "Debug" nav button that opens it is currently
  commented out in `dashboard.dart`).

## Stack
Flutter (Dart), Firebase (Auth, Firestore, App Check — debug providers only, not
production-hardened), `flutter_bluetooth_serial` (classic SPP, Android-only —
note this plugin is unmaintained/deprecated upstream), `flutter_local_notifications`
+ `timezone`/`flutter_timezone` for scheduling, `permission_handler` +
`android_intent_plus` for Android runtime/settings permissions, `shared_preferences`
for local caching/logging.

## Things a future session should know
- Firebase config present (`firebase.json`, presumably `google-services.json` under
  `android/app/`) — App Check is wired for debug only; would need real
  attestation providers before any release build.
- No apparent Firestore security rules file in this tree — worth checking the
  Firebase console/rules before treating this as production-ready.
- Bluetooth pairing flow assumes a specific hardware companion (HC-05 module on
  an Arduino-style dispenser) that isn't part of this repo.
- Stray top-level file named `123` (4 bytes) at repo root — looks like a stray/junk
  file, not referenced anywhere.
- Coursework context: this started as an "AppDev" course project pitch (PillPal +
  Gantt plan) and has since become a real working implementation.

## Suggested improvements (identified from code review, 2026-09)

Reliability / safety (highest priority for a health app):
- ~~**Fix slot↔medicine matching.**~~ DONE 2026-10-23: Assign Medicine is now a dropdown of the user's active schedule names (no duplicates across slots; old typed names that match case-insensitively are kept). Original note: In the PillPalBox manager, each slot's medicine
  is a free-typed `TextField`, but `_triggerAlarm` in `dashboard.dart` matches it
  against the schedule's name with exact string equality (`assignment['medicine']
  == medicineName`). A typo or case mismatch silently means the correct slot never
  fires. Replace the text field with a dropdown populated from the user's existing
  schedules so the two can never drift apart.
- **Dispensing depends on the notification being tapped.** The Bluetooth "dispense"
  signal is only sent from the in-app foreground timer (`_checkSchedules`) or when
  the user taps the notification / cold-launches from it (`main.dart`). If the app
  is backgrounded and the notification is ignored or swiped away, the pill is
  never physically dispensed even though the reminder fired. Worth moving the
  due-schedule check into a background task (WorkManager / Android foreground
  service) so dispensing doesn't depend on a tap.
- **No dispense acknowledgment.** `sendSignal` only reports whether the Bluetooth
  write succeeded, not whether the box actually rotated/dropped a pill.
  `bluetooth_service.dart` already exposes an unused `dataStream` from the
  device — worth having the Arduino side send a short ack byte back and having
  the app wait for it before marking the dose as sent.
- **Missed doses are only logged if the user actively taps "No."** If a reminder
  is ignored entirely, nothing is ever recorded as missed and no one is alerted.
  Add an automatic timeout-based "missed" fallback, and consider an optional
  caregiver/family contact that gets notified after a missed or repeated missed
  dose (the signup flow already collects age, suggesting an elder-care angle).
- Add Firestore security rules (`request.auth.uid == uid`) — none found in this
  tree; without them the database is likely wide open.

Usability:
- ~~**Edit schedules.**~~ DONE 2026-10-25 (patient and caregiver; see Added features).
- **Pill stock / low-supply tracking.** Nothing tracks remaining pill count per
  slot. Even a simple manual counter (enter starting quantity, decrement per
  confirmed dose, warn when low) needs no new hardware.
- **"Snooze" option** on the confirmation dialog, not just Yes/No, for "I'll take
  it in a bit" instead of forcing an immediate on-time/missed choice.

Smaller cleanup (not features, but adjacent): remove the unused `signup.dart`,
the empty native stub at `app/src/main/java/com/example/medicinetracker/`, and
the stray `123` file at the repo root.

## Innovation / differentiator ideas (beyond fixes — for pitches/demos)

- **Scan-to-schedule (OCR).** Camera-scan a prescription label / pill bottle
  (Google ML Kit text recognition, offline-capable) to auto-extract medicine
  name, dosage, and frequency and pre-fill the Add Schedule form.
- **Verified intake via hardware sensing.** Add an IR beam-break or weight
  sensor per slot on the Arduino side so the box confirms a pill was actually
  removed and reports it back over the existing Bluetooth link, instead of
  trusting a manual Yes/No tap. Makes the adherence log reflect reality.
- **Caregiver companion mode.** A linked second account (family/nurse) that
  sees live adherence, gets pushed alerts on missed doses, and can remotely
  trigger an extra reminder — reframes the product from "pillbox app" to
  "connected-care platform."
- **Voice-guided reminders + voice confirmation.** TTS announces what's due
  and which slot; STT accepts a spoken yes/no instead of requiring the user
  to read and tap — accessibility angle for elderly/low-vision users.
- **Adherence pattern prediction.** Even a simple rule-based pass over the
  existing weekly logs (e.g. "missed the 9pm dose 3 of the last 4 Fridays")
  to proactively suggest re-timing a slot or nudge the caregiver, rather than
  only reporting misses after the fact.
- **Missed-dose safety escalation.** Several consecutive unconfirmed doses
  triggers an in-app "are you okay?" check-in; no response alerts the
  caregiver contact. Pairs with caregiver mode above for an actual
  safety-net story, not just a reminder feature.
