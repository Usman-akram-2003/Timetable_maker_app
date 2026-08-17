// Reads the app's live per-user Firestore document, writes it to a local
// timestamped JSON file. This file serves TWO purposes at once:
//   1. The mandatory pre-write backup (restore with restore_backup.js).
//   2. The seed file resolve_import.dart reads to know what teachers/
//      courses/classes/etc. already exist, so its fuzzy-matching and
//      dedup logic sees real current state instead of an empty slate.
//
// Never writes anything — read-only against Firestore.
//
// Usage:
//   node fetch_and_backup.js --key <service-account.json> [--uid <uid>] [--email <email>]

const fs = require('fs');
const path = require('path');
const admin = require('firebase-admin');

function arg(name, def) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 ? process.argv[i + 1] : def;
}

async function main() {
  const keyPath = arg('key');
  if (!keyPath) {
    console.error('Usage: node fetch_and_backup.js --key <service-account.json> [--uid <uid>] [--email <email>]');
    process.exit(1);
  }
  const serviceAccount = JSON.parse(fs.readFileSync(keyPath, 'utf8'));
  const projectId = serviceAccount.project_id;

  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
    projectId,
  });

  let uid = arg('uid');
  if (!uid) {
    const email = arg('email', 'engr.waqasakram786@gmail.com');
    const userRecord = await admin.auth().getUserByEmail(email);
    uid = userRecord.uid;
    console.log(`Resolved uid from email ${email}: ${uid}`);
  }

  const db = admin.firestore();
  const timetableSnap = await db.doc(`users/${uid}/data/timetable`).get();
  const settingsSnap = await db.doc(`users/${uid}/data/settings`).get();

  if (!timetableSnap.exists) {
    console.error(`No document found at users/${uid}/data/timetable — check --uid/--email.`);
    process.exit(1);
  }

  const rawTimetable = timetableSnap.data();
  const timetable = {};
  // Every field on the live doc is a JSON-encoded STRING (see _saveData()
  // in lib/viewmodels/data_entry_viewmodel.dart) — decode each into a
  // real array so both this backup file and resolve_import.dart's seed
  // reader can use them directly without a second decode step.
  for (const [key, value] of Object.entries(rawTimetable)) {
    if (typeof value === 'string') {
      try { timetable[key] = JSON.parse(value); }
      catch { timetable[key] = value; } // leave non-JSON strings as-is
    } else {
      timetable[key] = value;
    }
  }

  const settings = settingsSnap.exists ? settingsSnap.data() : {};

  const ts = new Date().toISOString().replace(/:/g, '-');
  const outDir = path.join(__dirname, '..', 'backups');
  fs.mkdirSync(outDir, { recursive: true });
  const outPath = path.join(outDir, `backup_${uid}_${ts}.json`);
  fs.writeFileSync(outPath, JSON.stringify({ uid, timetable, settings }, null, 2));

  console.log(`\nBackup + seed written to: ${outPath}`);
  console.log(`  teachers:${(timetable.teachers || []).length} courses:${(timetable.courses || []).length} `
      + `programs:${(timetable.programs || []).length} classes:${(timetable.classes || []).length} `
      + `rooms:${(timetable.rooms || []).length} timeslots:${(timetable.timeslots || []).length} `
      + `assignments:${(timetable.assignments || []).length} electiveGroups:${(timetable.electiveGroups || []).length}`);
  console.log(`\nNext: dart run tool/batch_import/dart/resolve_import.dart --seed ${outPath}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
