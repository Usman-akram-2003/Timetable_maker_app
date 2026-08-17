// Restores users/{uid}/data/timetable to an exact prior snapshot from a
// backup file produced by fetch_and_backup.js. Full overwrite (merge:
// false), not a merge — this is the "undo everything the batch import did"
// button. Refuses to run without --confirm.
//
// Usage:
//   node restore_backup.js --key <service-account.json> --backup <backup.json> [--uid <uid>] --confirm

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
  const backupPath = arg('backup');
  const confirmed = flag('confirm');

  if (!keyPath || !backupPath) {
    console.error('Usage: node restore_backup.js --key <service-account.json> --backup <backup.json> [--uid <uid>] --confirm');
    process.exit(1);
  }
  if (!confirmed) {
    console.error('Refusing to restore without --confirm.');
    process.exit(1);
  }

  const serviceAccount = JSON.parse(fs.readFileSync(keyPath, 'utf8'));
  admin.initializeApp({ credential: admin.credential.cert(serviceAccount), projectId: serviceAccount.project_id });

  const backup = JSON.parse(fs.readFileSync(backupPath, 'utf8'));
  const uid = arg('uid', backup.uid);
  if (!uid) {
    console.error('No --uid given and the backup file has no uid field.');
    process.exit(1);
  }

  const doc = {};
  for (const [key, value] of Object.entries(backup.timetable)) {
    doc[key] = JSON.stringify(value);
  }

  const db = admin.firestore();
  await db.doc(`users/${uid}/data/timetable`).set(doc, { merge: false });

  console.log(`Restored users/${uid}/data/timetable from ${backupPath} (full overwrite).`);
}

main().catch((e) => { console.error(e); process.exit(1); });
