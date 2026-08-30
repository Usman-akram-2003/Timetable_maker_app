// Revision pass for F.Sc Part 2, cross-checked against Desktop\Teacherwise.xlsx
// (the master teacher-wise register). Fixes 6 assignments that were wrong in
// the original screenshot-based reconstruction (apply_fsc2_part2.js), and
// adds 2 that the screenshot never showed (rows were cut off / not visible).
// Matches existing assignments by (class shortCode, course name) rather than
// a fixed id, since the admin has been live-editing this data through the
// app in parallel — ids for some of these rows have already changed.
//
// Same safety pattern as apply_fsc2_part2.js: fresh backup always, clash
// check, dry run by default, --confirm to write, --accept-clashes required
// if the clash check finds anything.
//
// Usage: node revise_fsc2_part2.js --key <sa.json> --uid <uid> [--confirm] [--accept-clashes]

const fs = require('fs');
const path = require('path');
const admin = require('firebase-admin');

function arg(name, def) { const i = process.argv.indexOf(`--${name}`); return i !== -1 ? process.argv[i + 1] : def; }
const hasFlag = name => process.argv.includes(`--${name}`);

const TS = { 1: 'ts_int_1', 2: 'ts_int_2', 3: 'ts_int_3', 4: 'ts_int_4', 5: 'ts_int_5', 6: 'ts_int_6' };

// Field updates keyed by (class, course name as currently stored).
const UPDATES = [
  { cls: 'E0', course: 'Physics',   set: { period: 2 } },
  { cls: 'E0', course: 'Math',      set: { period: 1 } },
  { cls: 'M3', course: 'Chemistry', set: { period: 1 } },
  { cls: 'M',  course: 'English',   set: { teacherName: 'M. Awais Khan' } },
  { cls: 'M2', course: 'Pakistan Studies', set: { days: [3, 4] } },
  { cls: 'M0', course: 'Pakistan Studies', set: { teacherName: 'Ms. Zahra Aziz' } },
];

// New assignments the screenshot never showed (rows cut off).
const COURSES = {
  English: { id: '1783616422152244_34', name: 'English', code: 'ENGLIS', creditHours: 6 },
  Urdu:    { id: '1783616422152244_35', name: 'Urdu',    code: 'URDU',   creditHours: 6 },
};
const ADDITIONS = [
  { cls: 'M0', course: 'English', period: 3, teacherName: 'Rida Nadeem', room: '18' },
  { cls: 'M3', course: 'Urdu',    period: 5, teacherName: 'Amna Anwar',  room: '60' },
];

function pm(t) { const [h, m] = t.split(':').map(Number); return h * 60 + m; }
function timeslotsOverlap(a, b) { if (a.id === b.id) return true; return pm(a.startTime) < pm(b.endTime) && pm(b.startTime) < pm(a.endTime); }
function occupiedDays(a) { return (a.customDays && a.customDays.length) ? a.customDays : Array.from({ length: a.duration }, (_, i) => a.startSlot + i); }

function findClashes(changedAssignments, allAssignments, timeslotsById) {
  const clashes = [];
  for (const na of changedAssignments) {
    const naSlot = timeslotsById[na.timeSlotId];
    const naDays = new Set(occupiedDays(na));
    for (const other of allAssignments) {
      if (other === na || other.id === na.id) continue;
      const oSlot = timeslotsById[other.timeSlotId];
      if (!naSlot || !oSlot || !timeslotsOverlap(naSlot, oSlot)) continue;
      if (!occupiedDays(other).some(d => naDays.has(d))) continue;
      if (other.teacher.id === na.teacher.id) {
        clashes.push(`Teacher clash: ${na.teacher.name} — ${na.course.name}(${na.classModel.shortCode}) vs ${other.course.name}(${other.classModel.shortCode})`);
      }
      if (na.roomId && other.roomId === na.roomId) {
        clashes.push(`Room clash: room ${na.roomId} — ${na.course.name}(${na.classModel.shortCode}) vs ${other.course.name}(${other.classModel.shortCode})`);
      }
    }
  }
  return clashes;
}

async function main() {
  const keyPath = arg('key');
  if (!keyPath) { console.error('Usage: node revise_fsc2_part2.js --key <sa.json> --uid <uid> [--confirm] [--accept-clashes]'); process.exit(1); }
  const serviceAccount = JSON.parse(fs.readFileSync(keyPath, 'utf8'));
  admin.initializeApp({ credential: admin.credential.cert(serviceAccount), projectId: serviceAccount.project_id });
  const uid = arg('uid');
  if (!uid) { console.error('--uid required'); process.exit(1); }

  const db = admin.firestore();
  const docRef = db.doc(`users/${uid}/data/timetable`);
  const snap = await docRef.get();
  const raw = snap.data();
  const live = {};
  for (const [k, v] of Object.entries(raw)) {
    if (typeof v !== 'string') { live[k] = v; continue; }
    try { live[k] = JSON.parse(v); } catch { live[k] = v; }
  }

  const backupDir = path.join(__dirname, '..', 'backups');
  const backupFile = path.join(backupDir, `backup_${uid}_${new Date().toISOString().replace(/[:.]/g, '-')}_pre-fsc2-revise.json`);
  fs.writeFileSync(backupFile, JSON.stringify({ uid, timetable: live }, null, 2));
  console.log(`Fresh backup written: ${backupFile}`);

  const prog = live.programs.find(p => p.name === 'F.Sc Part 2');
  if (!prog) { console.error('F.Sc Part 2 program not found live.'); process.exit(1); }
  const classesByName = {};
  for (const c of live.classes) if (c.programId === prog.id) classesByName[c.name] = c;

  const teacherByName = name => {
    const m = live.teachers.filter(t => t.name === name);
    if (m.length !== 1) throw new Error(`Teacher "${name}" resolved to ${m.length} matches`);
    return m[0];
  };
  const roomByName = name => {
    const m = live.rooms.filter(r => r.name === name);
    if (m.length !== 1) throw new Error(`Room "${name}" resolved to ${m.length} matches`);
    return m[0];
  };

  const assignments = live.assignments; // will mutate in place for updates
  const changed = [];
  const log = [];

  for (const u of UPDATES) {
    const cls = classesByName[u.cls];
    if (!cls) throw new Error(`Class ${u.cls} not found`);
    const idx = assignments.findIndex(a => a.classModel.id === cls.id && a.course.name === u.course);
    if (idx === -1) { log.push(`SKIP (not found): ${u.cls} ${u.course}`); continue; }
    const a = assignments[idx];
    const before = `${a.classModel.name} ${a.course.name}: P${Object.entries(TS).find(([,v])=>v===a.timeSlotId)?.[0]} teacher=${a.teacher.name} days=${JSON.stringify(a.customDays)}`;
    const next = { ...a };
    if (u.set.period) { next.timeSlotId = TS[u.set.period]; next.startSlot = 1; next.duration = 6; next.customDays = a.customDays.length ? a.customDays : []; }
    if (u.set.teacherName) { const t = teacherByName(u.set.teacherName); next.teacher = { id: t.id, name: t.name, department: t.department }; }
    if (u.set.days) { next.customDays = u.set.days; next.startSlot = Math.min(...u.set.days); next.duration = u.set.days.length; }
    assignments[idx] = next;
    changed.push(next);
    log.push(`UPDATE: ${before}  ->  P${Object.entries(TS).find(([,v])=>v===next.timeSlotId)?.[0]} teacher=${next.teacher.name} days=${JSON.stringify(next.customDays)}`);
  }

  const newOnes = [];
  for (const add of ADDITIONS) {
    const cls = classesByName[add.cls];
    const course = COURSES[add.course];
    const teacher = teacherByName(add.teacherName);
    const room = roomByName(add.room);
    const already = assignments.find(a => a.classModel.id === cls.id && a.course.id === course.id);
    if (already) { log.push(`SKIP ADD (already exists): ${add.cls} ${add.course}`); continue; }
    const rec = {
      id: `fsc2p2_asg_${add.cls}_p${add.period}_${course.code}_rev`,
      teacher: { id: teacher.id, name: teacher.name, department: teacher.department },
      course: { id: course.id, name: course.name, code: course.code, creditHours: course.creditHours },
      classModel: { id: cls.id, programId: cls.programId, name: cls.name, shortCode: cls.shortCode, level: cls.level },
      startSlot: 1, duration: 6, timeSlotId: TS[add.period], customDays: [], roomId: room.id, autoAssigned: false,
    };
    newOnes.push(rec);
    changed.push(rec);
    log.push(`ADD: ${add.cls} ${add.course} P${add.period} ${teacher.name} room=${room.name}`);
  }

  console.log('\n--- Planned changes ---');
  log.forEach(l => console.log('  ' + l));

  const timeslotsById = Object.fromEntries(live.timeslots.map(t => [t.id, t]));
  const finalAssignments = [...assignments, ...newOnes];
  const clashes = findClashes(changed, finalAssignments, timeslotsById);

  if (clashes.length) {
    if (!hasFlag('accept-clashes')) {
      console.log(`\n*** ${clashes.length} CLASH(ES) — aborting, nothing written. Pass --accept-clashes to proceed anyway: ***`);
      clashes.forEach(c => console.log('  ' + c));
      process.exit(1);
    }
    console.log(`\n*** ${clashes.length} CLASH(ES) — proceeding anyway (--accept-clashes): ***`);
    clashes.forEach(c => console.log('  ' + c));
  } else {
    console.log('\nNo new clashes introduced. ✓');
  }

  if (!hasFlag('confirm')) {
    console.log('\nDry run only (no --confirm) — nothing written.');
    return;
  }

  await docRef.set({
    assignments: JSON.stringify(finalAssignments),
  }, { merge: true });
  console.log(`\nWRITTEN. ${UPDATES.length} field-updates + ${newOnes.length} new assignments.`);
}

main().catch(e => { console.error(e); process.exit(1); });
