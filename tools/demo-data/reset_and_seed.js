#!/usr/bin/env node
/*
  PillPal demo reset

  1. Deletes EVERY account (Firebase Authentication) and ALL Firestore data
     in the project the key belongs to.
  2. Creates two demo accounts with sample data:
       Patient   patient@pillpal.test    / PillPal123
       Caregiver caregiver@pillpal.test  / PillPal123
     (already linked; email already verified, so no verification step)

  Run (in this folder):
     npm install
     node reset_and_seed.js            (asks you to type RESET)
     node reset_and_seed.js --yes      (no question)

  Needs serviceAccountKey.json in this folder:
  Firebase console > Project settings > Service accounts > Generate new private key.
  Keep that file private (it is in .gitignore).
*/

const fs = require('fs');
const path = require('path');
const readline = require('readline');
const admin = require('firebase-admin');

const keyPath = process.argv.find((a) => a.endsWith('.json')) || path.join(__dirname, 'serviceAccountKey.json');
if (!fs.existsSync(keyPath)) {
  console.error(`\nMissing ${keyPath}\nDownload it from Firebase console > Project settings > Service accounts > ` +
    'Generate new private key, save it here as serviceAccountKey.json, then run again.\n');
  process.exit(1);
}
const serviceAccount = JSON.parse(fs.readFileSync(keyPath, 'utf8'));
admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
const auth = admin.auth();
const db = admin.firestore();
const { Timestamp } = admin.firestore;

// ---------------- demo content ----------------
const PASSWORD = 'PillPal123';
const PATIENT = { email: 'patient@pillpal.test', name: 'Rosa Santos', age: '72', gender: 'Female' };
const CAREGIVER = { email: 'caregiver@pillpal.test', name: 'Ana Santos', age: '41', gender: 'Female' };

const EVERY_DAY = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const MEDICINES = [
  { name: 'Losartan', dosage: '1 tablet (50 mg)', times: [[8, 0]], days: EVERY_DAY, slot: 'A' },
  { name: 'Metformin', dosage: '1 tablet (500 mg)', times: [[8, 0], [20, 0]], days: EVERY_DAY, slot: 'B' },
  { name: 'Atorvastatin', dosage: '1 tablet (20 mg)', times: [[21, 0]], days: EVERY_DAY, slot: 'C' },
  { name: 'Vitamin D3', dosage: '1 capsule (1000 IU)', times: [[9, 0]], days: ['Mon', 'Wed', 'Fri'], slot: 'D' },
];

// Doses missed in the sample history: [days ago, medicine, "h:mm AM"]. Everything else = taken.
const MISSED = [
  [1, 'Atorvastatin', '9:00 PM'],
  [3, 'Metformin', '8:00 PM'],
  [5, 'Atorvastatin', '9:00 PM'],
];

// ---------------- helpers ----------------
const MANILA_OFFSET_MS = 8 * 60 * 60 * 1000; // Philippines, no daylight saving

/** Wall-clock parts in Manila for a moment. */
function manila(date) {
  const d = new Date(date.getTime() + MANILA_OFFSET_MS);
  return { y: d.getUTCFullYear(), mo: d.getUTCMonth(), d: d.getUTCDate(), h: d.getUTCHours(), mi: d.getUTCMinutes(), dow: d.getUTCDay() };
}
/** The real moment for a Manila wall-clock time. */
function manilaMoment(y, mo, d, h = 0, mi = 0) {
  return new Date(Date.UTC(y, mo, d, h, mi) - MANILA_OFFSET_MS);
}
const pad = (n) => String(n).padStart(2, '0');
const dateKey = (p) => `${p.y}-${pad(p.mo + 1)}-${pad(p.d)}`; // same as the app's dateKey()
const dayName = (p) => ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][p.dow];
/** Same text as the app's formatTime12h(), e.g. "8:00 AM". */
function time12(h, m) {
  const hour = h === 0 ? 12 : h > 12 ? h - 12 : h;
  return `${hour}:${pad(m)} ${h >= 12 ? 'PM' : 'AM'}`;
}

async function confirm() {
  if (process.argv.includes('--yes')) return true;
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const answer = await new Promise((res) =>
    rl.question(`\nThis DELETES every account and all data in Firebase project "${serviceAccount.project_id}".\n` +
      'Type RESET to continue: ', res));
  rl.close();
  return answer.trim() === 'RESET';
}

// ---------------- reset ----------------
async function deleteAllUsers() {
  let total = 0;
  let pageToken;
  do {
    const page = await auth.listUsers(1000, pageToken);
    const uids = page.users.map((u) => u.uid);
    if (uids.length) {
      const res = await auth.deleteUsers(uids);
      total += res.successCount;
      if (res.failureCount) console.warn(`  ${res.failureCount} account(s) could not be deleted`);
    }
    pageToken = page.pageToken;
  } while (pageToken);
  return total;
}

async function deleteAllFirestore() {
  const collections = await db.listCollections();
  for (const col of collections) await db.recursiveDelete(col);
  return collections.map((c) => c.id);
}

// ---------------- seed ----------------
async function createUser(p) {
  const user = await auth.createUser({
    email: p.email,
    password: PASSWORD,
    displayName: p.name,
    emailVerified: true, // demo accounts skip the verification email
  });
  await db.collection('users').doc(user.uid).set({
    name: p.name, age: p.age, gender: p.gender, email: p.email, uid: user.uid,
  });
  return user.uid;
}

async function seed() {
  const now = new Date();
  const today = manila(now);
  const startOfToday = manilaMoment(today.y, today.mo, today.d);
  const daysAgo = (n, h = 0, mi = 0) => manilaMoment(today.y, today.mo, today.d - n, h, mi);

  const patientUid = await createUser(PATIENT);
  const caregiverUid = await createUser(CAREGIVER);
  const patientRef = db.collection('users').doc(patientUid);
  const caregiverRef = db.collection('users').doc(caregiverUid);
  const batch = db.batch();

  // Medicines (created 2 weeks ago so the History tab shows a full week)
  const created = Timestamp.fromDate(daysAgo(14, 7, 30));
  for (const m of MEDICINES) {
    batch.set(patientRef.collection('schedules').doc(), {
      name: m.name,
      dosage: m.dosage,
      schedules: m.times.map(([hour, minute]) => ({ hour, minute })),
      repeatDays: m.days,
      createdAt: created,
      isActive: true,
    });
  }

  // PillPalBox slots A-D
  batch.update(patientRef, {
    pillbox_assignments: MEDICINES.map((m) => ({ slot: m.slot, medicine: m.name })),
  });

  // Intake history: the last 7 days, up to now
  let taken = 0;
  let missed = 0;
  for (let n = 6; n >= 0; n--) {
    const day = manila(daysAgo(n, 12));
    const intakes = [];
    for (const m of MEDICINES) {
      if (!m.days.includes(dayName(day))) continue;
      for (const [h, mi] of m.times) {
        if (daysAgo(n, h, mi) > now) continue; // not due yet today
        const t = time12(h, mi);
        const isMissed = MISSED.some(([ago, name, time]) => ago === n && name === m.name && time === t);
        intakes.push(isMissed ? { medicine: m.name, time: t, status: 'missed', auto: true } : { medicine: m.name, time: t, status: 'on_time' });
        isMissed ? missed++ : taken++;
      }
    }
    if (intakes.length) batch.set(patientRef.collection('logs').doc(dateKey(day)), { intakes });
  }

  // Caregiver alerts for the missed doses
  for (const [ago, name, t] of MISSED) {
    const m = MEDICINES.find((x) => x.name === name);
    const [h, mi] = m.times.find(([hh, mm]) => time12(hh, mm) === t);
    const at = daysAgo(ago, h, mi + 30);
    if (at > now) continue;
    batch.set(patientRef.collection('alerts').doc(), {
      type: 'missed_dose',
      message: `Missed ${name} (${m.dosage}) due at ${t}. No confirmation after 30 minutes.`,
      severity: 'high',
      medicine: name,
      createdAt: Timestamp.fromDate(at),
      createdAtMs: at.getTime(),
    });
  }

  // Link the caregiver to the patient
  const linkedAt = Timestamp.fromDate(daysAgo(10, 18, 0));
  batch.set(patientRef.collection('caregivers').doc(caregiverUid), {
    name: CAREGIVER.name, email: CAREGIVER.email, inviteCode: 'DEMO24', linkedAt,
  });
  batch.set(caregiverRef.collection('patients').doc(patientUid), { name: PATIENT.name, linkedAt });

  // Reminders chat (caregiver -> patient)
  const chat = [
    [2, 7, 45, 'Good morning Nay! Please take your Losartan after breakfast.', true, 8, 5],
    [1, 20, 50, "Don't forget your Atorvastatin before bed 💊", false],
    [0, 7, 50, 'Good morning! Your Metformin is in slot B.', true, 8, 2],
  ];
  for (const [ago, h, mi, message, done, dh, dmi] of chat) {
    const at = daysAgo(ago, h, mi);
    if (at > now) continue;
    const doneAt = done ? daysAgo(ago, dh, dmi) : null;
    batch.set(patientRef.collection('nudges').doc(), {
      fromUid: caregiverUid,
      fromName: CAREGIVER.name,
      message,
      handled: true, // don't pop up old messages as notifications
      done: !!(doneAt && doneAt <= now),
      ...(doneAt && doneAt <= now ? { doneAt: Timestamp.fromDate(doneAt), doneAtMs: doneAt.getTime() } : {}),
      createdAt: Timestamp.fromDate(at),
      createdAtMs: at.getTime(),
    });
  }

  await batch.commit();
  return { patientUid, caregiverUid, taken, missed, startOfToday };
}

// ---------------- main ----------------
(async () => {
  if (!(await confirm())) {
    console.log('Cancelled. Nothing was changed.');
    process.exit(0);
  }
  console.log(`\nProject: ${serviceAccount.project_id}`);
  console.log('Deleting accounts...');
  console.log(`  ${await deleteAllUsers()} account(s) deleted`);
  console.log('Deleting Firestore data...');
  const cols = await deleteAllFirestore();
  console.log(`  deleted collections: ${cols.join(', ') || '(none)'}`);
  console.log('Creating demo data...');
  const r = await seed();
  console.log(`  history: ${r.taken} taken, ${r.missed} missed`);
  console.log('\nDone. Demo accounts (password for both: ' + PASSWORD + ')');
  console.log(`  Patient:   ${PATIENT.email}  (${PATIENT.name})`);
  console.log(`  Caregiver: ${CAREGIVER.email}  (${CAREGIVER.name})`);
  console.log('\nOn each phone: log out of PillPal (or reinstall) and log in with a demo account.');
  process.exit(0);
})().catch((e) => {
  console.error('\nFailed:', e.message || e);
  process.exit(1);
});
