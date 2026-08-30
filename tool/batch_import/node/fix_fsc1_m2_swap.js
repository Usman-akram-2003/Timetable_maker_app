// F.Sc Part 1-M2 had two assignments with swapped teachers: "Urdu" was
// taught by Rehan Ahmed (a Physics teacher) and "Physics" was taught by
// Syeda Nawazish Rubab (an Urdu teacher) — user-flagged from the app's
// teacher-wise view. Swaps the teachers back to match their real subjects,
// and restores the Physics row's room (null) to match the rest of M2 (38).
// Same safety pattern as the other tool/batch_import scripts: fresh backup,
// clash check, dry run by default, --confirm to write.
const fs = require('fs');
const path = require('path');
const admin = require('firebase-admin');

function arg(name) { const i = process.argv.indexOf(`--${name}`); return i !== -1 ? process.argv[i + 1] : undefined; }
const hasFlag = name => process.argv.includes(`--${name}`);

function pm(t) { const [h, m] = t.split(':').map(Number); return h * 60 + m; }
function overlap(a, b) { if (a.id === b.id) return true; return pm(a.startTime) < pm(b.endTime) && pm(b.startTime) < pm(a.endTime); }
function days(a) { return (a.customDays && a.customDays.length) ? a.customDays : Array.from({ length: a.duration }, (_, i) => a.startSlot + i); }

async function main() {
  const keyPath = arg('key'), uid = arg('uid');
  if (!keyPath || !uid) { console.error('Usage: node fix_fsc1_m2_swap.js --key <sa.json> --uid <uid> [--confirm] [--accept-clashes]'); process.exit(1); }
  admin.initializeApp({ credential: admin.credential.cert(JSON.parse(fs.readFileSync(keyPath, 'utf8'))) });
  const docRef = admin.firestore().doc(`users/${uid}/data/timetable`);
  const raw = (await docRef.get()).data();
  const live = {};
  for (const [k, v] of Object.entries(raw)) { if (typeof v !== 'string') { live[k] = v; continue; } try { live[k] = JSON.parse(v); } catch { live[k] = v; } }

  const backupFile = path.join(__dirname, '..', 'backups', `backup_${uid}_${new Date().toISOString().replace(/[:.]/g, '-')}_pre-m2swap.json`);
  fs.writeFileSync(backupFile, JSON.stringify({ uid, timetable: live }, null, 2));
  console.log('Fresh backup written:', backupFile);

  const urduA = live.assignments.find(a => a.id === '1788009713886199_56');
  const physA = live.assignments.find(a => a.id === '1788016371263254_63');
  if (!urduA || !physA) { console.error('One of the two target assignments no longer exists live — aborting.'); process.exit(1); }

  const rehan = live.teachers.find(t => t.name === 'Rehan Ahmed');
  const syeda = live.teachers.find(t => t.name === 'Syeda Nawazish Rubab');
  const room38 = live.rooms.find(r => r.name === '38');

  console.log(`\nBefore: Urdu/P4 teacher=${urduA.teacher.name}  |  Physics/P1 teacher=${physA.teacher.name} room=${physA.roomId}`);

  urduA.teacher = { id: syeda.id, name: syeda.name, department: syeda.department };
  physA.teacher = { id: rehan.id, name: rehan.name, department: rehan.department };
  physA.roomId = room38.id;

  console.log(`After:  Urdu/P4 teacher=${urduA.teacher.name}  |  Physics/P1 teacher=${physA.teacher.name} room=${physA.roomId}(38)`);

  const timeslotsById = Object.fromEntries(live.timeslots.map(t => [t.id, t]));
  const clashes = [];
  for (const na of [urduA, physA]) {
    const naSlot = timeslotsById[na.timeSlotId], naDays = new Set(days(na));
    for (const other of live.assignments) {
      if (other.id === na.id) continue;
      const oSlot = timeslotsById[other.timeSlotId];
      if (!oSlot || !overlap(naSlot, oSlot)) continue;
      if (!days(other).some(d => naDays.has(d))) continue;
      if (other.teacher.id === na.teacher.id) clashes.push(`Teacher clash: ${na.teacher.name} — ${na.course.name}(${na.classModel.shortCode}) vs ${other.course.name}(${other.classModel.shortCode})`);
      if (na.roomId && other.roomId === na.roomId) clashes.push(`Room clash: room ${na.roomId} — ${na.course.name}(${na.classModel.shortCode}) vs ${other.course.name}(${other.classModel.shortCode})`);
    }
  }

  if (clashes.length) {
    if (!hasFlag('accept-clashes')) { console.log(`\n*** ${clashes.length} CLASH(ES) — aborting: ***`); clashes.forEach(c => console.log('  ' + c)); process.exit(1); }
    console.log(`\n*** ${clashes.length} CLASH(ES) — proceeding anyway: ***`); clashes.forEach(c => console.log('  ' + c));
  } else {
    console.log('\nNo clashes. ✓');
  }

  if (!hasFlag('confirm')) { console.log('\nDry run only — nothing written.'); return; }
  await docRef.set({ assignments: JSON.stringify(live.assignments) }, { merge: true });
  console.log('\nWRITTEN.');
}
main().catch(e => { console.error(e); process.exit(1); });
