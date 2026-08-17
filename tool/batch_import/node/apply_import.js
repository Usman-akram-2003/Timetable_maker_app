// Writes a finalized JSON (produced by resolve_import.dart --write-finalized)
// to the live Firestore document, re-encoding each field into a JSON
// string exactly as _saveData() does. Refuses to run without --confirm,
// even if a valid --finalized file is given, as a second deliberate guard.
//
// Usage:
//   node apply_import.js --key <service-account.json> --finalized <finalized.json> [--uid <uid>] [--email <email>] --confirm

const fs = require('fs');
const admin = require('firebase-admin');

function arg(name, def) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 ? process.argv[i + 1] : def;
}
function flag(name) {
  return process.argv.includes(`--${name}`);
}

async function main() {
  const keyPath = arg('key');
  const finalizedPath = arg('finalized');
  const confirmed = flag('confirm');

  if (!keyPath || !finalizedPath) {
    console.error('Usage: node apply_import.js --key <service-account.json> --finalized <finalized.json> [--uid <uid>] [--email <email>] --confirm');
    process.exit(1);
  }
  if (!confirmed) {
    console.error('Refusing to write without --confirm. Re-run the same command with --confirm added once you\'ve reviewed the dry-run summary.');
    process.exit(1);
  }

  const serviceAccount = JSON.parse(fs.readFileSync(keyPath, 'utf8'));
  admin.initializeApp({ credential: admin.credential.cert(serviceAccount), projectId: serviceAccount.project_id });

  let uid = arg('uid');
  if (!uid) {
    const email = arg('email', 'engr.waqasakram786@gmail.com');
    const userRecord = await admin.auth().getUserByEmail(email);
    uid = userRecord.uid;
    console.log(`Resolved uid from email ${email}: ${uid}`);
  }

  const finalized = JSON.parse(fs.readFileSync(finalizedPath, 'utf8'));

  // Re-encode each field into a JSON string, matching _saveData() exactly.
  const doc = {};
  for (const key of ['departments', 'teachers', 'courses', 'programs', 'classes', 'rooms',
      'timeslots', 'time_slot_locks', 'combinedRules', 'electiveGroups', 'shiftRules', 'assignments']) {
    doc[key] = JSON.stringify(finalized[key] ?? []);
  }

  const db = admin.firestore();
  await db.doc(`users/${uid}/data/timetable`).set(doc, { merge: true });

  console.log(`\nWrote to users/${uid}/data/timetable:`);
  console.log(`  teachers:${finalized.teachers.length} courses:${finalized.courses.length} `
      + `programs:${finalized.programs.length} classes:${finalized.classes.length} `
      + `rooms:${finalized.rooms.length} timeslots:${finalized.timeslots.length} `
      + `assignments:${finalized.assignments.length} electiveGroups:${finalized.electiveGroups.length}`);
  console.log('\nDone. Open the app (it auto-refreshes from Firestore) and check the Matrix/Data views.');
}

main().catch((e) => { console.error(e); process.exit(1); });
