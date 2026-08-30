// One-time repair script: re-creates the "F.Sc Part 2" program, its 7
// classes, and 42 assignments that were wiped out by an accidental program
// delete. Every teacher/course/room referenced below was resolved against
// the live data by tool/batch_import/node/../scratchpad resolve pass (see
// chat) — nothing new is created except the program, its classes, and the
// assignments themselves.
//
// Safety, matching the rest of tool/batch_import/:
//   1. Fetches a FRESH backup right before writing (in case anything
//      changed via the running app since the last backup) and writes it
//      to tool/batch_import/backups/ regardless of --confirm.
//   2. Checks every new assignment against the fresh live assignments for
//      a teacher/room clash before writing anything.
//   3. Default run is dry — prints exactly what would change. Only
//      --confirm writes to Firestore.
//
// Usage:
//   node apply_fsc2_part2.js --key <service-account.json> [--uid <uid>] [--confirm]

const fs = require('fs');
const path = require('path');
const admin = require('firebase-admin');

function arg(name, def) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 ? process.argv[i + 1] : def;
}
const hasFlag = name => process.argv.includes(`--${name}`);

// ── F.Sc Part 2 data (from the screenshot) + resolved ids ──────────────────
const PROGRAM = { id: 'fsc2p2_prog', name: 'F.Sc Part 2', level: 0 };
const CLASS_NAMES = ['E', 'E0', 'M', 'M0', 'M1', 'M2', 'M3'];

// Level-0 (Intermediate) period -> canonical timeslot id (confirmed against
// live data: ts_int_1..ts_int_6 are exactly P1-P6, 08:00-12:00).
const TS = { 1: 'ts_int_1', 2: 'ts_int_2', 3: 'ts_int_3', 4: 'ts_int_4', 5: 'ts_int_5', 6: 'ts_int_6' };

// courseName -> {id,name,code,creditHours} resolved against live courses
// (level 0). "Pak Studies" and "Pakistan Studies" are genuinely two
// different existing course records, not a label truncation — kept distinct
// on purpose. THQ id confirmed by the user (code THA-001).
const COURSES = {
  'English':   { id: '1783616422152244_34', name: 'English',   code: 'ENGLIS', creditHours: 6 },
  'Chemistry': { id: '1783616422152539_39', name: 'Chemistry', code: 'CHEMIS', creditHours: 6 },
  'Math':      { id: '1783616422152539_37', name: 'Math',      code: 'MATH',   creditHours: 6 },
  'Physics':   { id: '1783616422152539_38', name: 'Physics',   code: 'PHYSIC', creditHours: 6 },
  'Urdu':      { id: '1783616422152244_35', name: 'Urdu',      code: 'URDU',   creditHours: 6 },
  'Biology':   { id: '1783616422152539_40', name: 'Biology',   code: 'BIOLOG', creditHours: 6 },
  'Pak Studies':      { id: '1783616422153238_54', name: 'Pak Studies',      code: 'PAK ST', creditHours: 2 },
  'Pakistan Studies': { id: '1787157862086482_774', name: 'Pakistan Studies', code: 'PS',     creditHours: 2 },
  'THQ':       { id: '1787167743833774_24', name: 'THQ', code: 'THA-001', creditHours: 2 },
};

// Teacher names below are resolved against live teachers at runtime
// (resolveTeacher, same exact/prefix/dept-tiebreak logic already verified
// against this data in the dry-run pass). Spelling corrected where the
// screenshot read differently from the stored record (Zaheer "Ahmed"->"Ahmad").
const ROWS = {
  E: [
    { p: 1, course: 'English',   teacher: 'Muhammad Ahmad',   room: '47' },
    { p: 2, course: 'Chemistry', teacher: 'Mazhar Abbas',     room: '47' },
    { p: 3, course: 'Math',      teacher: 'Dr. Muhammad Tahir', room: '47' },
    { p: 4, course: 'Physics',   teacher: 'Muhammad Kaleem',  room: '47' },
    { p: 5, course: 'Urdu',      teacher: 'Muhammad Younas',  room: '47' },
    { p: 6, course: 'Pak Studies', teacher: 'Ahsan Jamal',    room: null, days: [1, 2] },
  ],
  E0: [
    { p: 1, course: 'Physics',   teacher: 'Rehan Ahmed',      room: '48' },
    { p: 2, course: 'Math',      teacher: 'Husnain Rasool Kaz', room: '48' },
    { p: 3, course: 'Chemistry', teacher: 'Razzaq Ahmad',     room: '48' },
    { p: 4, course: 'English',   teacher: 'Muhammad Ameen',   room: '48' },
    { p: 5, course: 'Urdu',      teacher: 'Kaleem Ashraf',    room: '48' },
    { p: 6, course: 'Pakistan Studies', teacher: 'Abdul Azeem Somro', room: null, days: [3, 4] },
    { p: 6, course: 'THQ',       teacher: 'Muhammad Zakria',  room: '29', days: [1, 2] },
  ],
  M: [
    { p: 1, course: 'Chemistry', teacher: 'Zaheer Ahmad',     room: '16' },
    { p: 2, course: 'Biology',   teacher: 'Muhammad Zubair',  room: '16' },
    { p: 3, course: 'Physics',   teacher: 'Muhammad Ali',     room: '16' },
    { p: 4, course: 'English',   teacher: 'Amjad Islam',      room: '16' },
    { p: 5, course: 'Urdu',      teacher: 'Syeda Nawazish Ru', room: '16' },
    { p: 6, course: 'Pak Studies', teacher: 'Abdul Azeem Somro', room: null, days: [1, 2] },
  ],
  M0: [
    { p: 1, course: 'Physics',   teacher: 'Dr. Atta-Ur-Rehman', room: '18' },
    { p: 2, course: 'Biology',   teacher: 'Rashid Mahmood',    room: '18' }, // dept-tiebreak -> Biology
    { p: 4, course: 'Urdu',      teacher: 'Muhammad Rafique',  room: '18' },
    { p: 5, course: 'Chemistry', teacher: 'Imran Ishaque',     room: '18' },
    { p: 6, course: 'Pakistan Studies', teacher: 'Abdul Azeem Somro', room: null, days: [5, 6] },
    { p: 6, course: 'THQ',       teacher: 'Muhammad Zakria',   room: '38', days: [1, 2] },
  ],
  M1: [
    { p: 1, course: 'Physics',   teacher: 'Basit Ali',        room: null },
    { p: 2, course: 'Chemistry', teacher: 'Zakia Batool',     room: null },
    { p: 3, course: 'Biology',   teacher: 'Munaza Shabn',     room: null },
    { p: 4, course: 'Urdu',      teacher: 'Aftab Haider',     room: null },
    { p: 5, course: 'English',   teacher: 'Ikram Ullah',      room: null },
    { p: 6, course: 'Pak Studies', teacher: 'Ms. Zahra Aziz', room: null, days: [1, 2] },
  ],
  M2: [
    { p: 1, course: 'English',   teacher: 'Tehseen Zafar',    room: '59' },
    { p: 2, course: 'Physics',   teacher: 'Muhammad Khalid',  room: '59' },
    { p: 3, course: 'Urdu',      teacher: 'Aftab Haider',     room: '59' },
    { p: 4, course: 'Biology',   teacher: 'Dr. Muhammad Soh', room: '59' },
    { p: 5, course: 'Chemistry', teacher: 'Muhammad Nadee',   room: '59' },
    { p: 6, course: 'Pakistan Studies', teacher: 'Zaheer Ahmad Umair', room: null, days: [1, 2] },
  ],
  M3: [
    { p: 2, course: 'Physics',   teacher: 'Bushra Karim',     room: '60' },
    { p: 3, course: 'English',   teacher: 'Abid Raza',        room: '60' },
    { p: 4, course: 'Biology',   teacher: 'Arshad Hameed',    room: '60' },
    { p: 5, course: 'Chemistry', teacher: 'Adeela Bashir',    room: '60' },
    { p: 6, course: 'Pakistan Studies', teacher: 'Ahsan Jamal', room: null, days: [5, 6] },
  ],
};

const TITLES = /\b(dr|mrs|mr|ms|prof|prof\.?\s*dr)\.?\s*/gi;
const norm = s => s.toLowerCase().replace(TITLES, '').replace(/[.\-]/g, ' ').replace(/\s+/g, ' ').trim();

function resolveTeacher(teachers, query, courseName) {
  const nq = norm(query);
  const exact = teachers.filter(x => norm(x.name) === nq);
  const starts = teachers.filter(x => norm(x.name).startsWith(nq));
  const contains = teachers.filter(x => norm(x.name).includes(nq));
  for (const pool of [exact, starts, contains]) {
    if (pool.length === 1) return pool[0];
    if (pool.length > 1) {
      const deptMatch = pool.filter(x => x.department.toLowerCase() === courseName.toLowerCase());
      if (deptMatch.length === 1) return deptMatch[0];
      throw new Error(`Ambiguous teacher "${query}" for ${courseName}: ${pool.map(p => p.name + '/' + p.department).join(', ')}`);
    }
  }
  throw new Error(`No teacher match for "${query}"`);
}

function resolveRoom(rooms, name) {
  if (name == null) return null;
  const m = rooms.filter(r => r.name.toLowerCase().trim() === name.toLowerCase().trim());
  if (m.length !== 1) throw new Error(`Room "${name}" resolved to ${m.length} matches`);
  return m[0].id;
}

function buildNewRecords(live) {
  const classes = CLASS_NAMES.map(name => ({
    id: `fsc2p2_cls_${name}`,
    programId: PROGRAM.id,
    name,
    shortCode: `${PROGRAM.name}-${name}`,
    level: 0,
  }));

  const assignments = [];
  for (const className of CLASS_NAMES) {
    const cls = classes.find(c => c.name === className);
    for (const row of ROWS[className]) {
      const teacher = resolveTeacher(live.teachers, row.teacher, row.course);
      const course = COURSES[row.course];
      if (!course) throw new Error(`Unknown course "${row.course}"`);
      const roomId = resolveRoom(live.rooms, row.room);
      const timeSlotId = TS[row.p];
      const days = row.days || null;
      assignments.push({
        id: `fsc2p2_asg_${className}_p${row.p}_${course.code}`,
        teacher: { id: teacher.id, name: teacher.name, department: teacher.department },
        course: { id: course.id, name: course.name, code: course.code, creditHours: course.creditHours },
        classModel: { id: cls.id, programId: cls.programId, name: cls.name, shortCode: cls.shortCode, level: cls.level },
        startSlot: days ? Math.min(...days) : 1,
        duration: days ? days.length : 6,
        timeSlotId,
        customDays: days || [],
        roomId,
        autoAssigned: false,
      });
    }
  }
  return { classes, assignments };
}

// ── Clash check against everything already live ────────────────────────────
function pm(t) { const [h, m] = t.split(':').map(Number); return h * 60 + m; }
function timeslotsOverlap(a, b) {
  if (a.id === b.id) return true;
  return pm(a.startTime) < pm(b.endTime) && pm(b.startTime) < pm(a.endTime);
}
function occupiedDays(a) { return (a.customDays && a.customDays.length) ? a.customDays : Array.from({ length: a.duration }, (_, i) => a.startSlot + i); }

function findClashes(newAssignments, liveAssignments, timeslotsById) {
  const clashes = [];
  const all = [...liveAssignments, ...newAssignments];
  for (const na of newAssignments) {
    const naSlot = timeslotsById[na.timeSlotId];
    const naDays = new Set(occupiedDays(na));
    for (const other of all) {
      if (other === na) continue;
      const oSlot = timeslotsById[other.timeSlotId];
      if (!naSlot || !oSlot || !timeslotsOverlap(naSlot, oSlot)) continue;
      const shared = occupiedDays(other).some(d => naDays.has(d));
      if (!shared) continue;
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
  if (!keyPath) { console.error('Usage: node apply_fsc2_part2.js --key <service-account.json> [--uid <uid>] [--confirm]'); process.exit(1); }
  const serviceAccount = JSON.parse(fs.readFileSync(keyPath, 'utf8'));
  admin.initializeApp({ credential: admin.credential.cert(serviceAccount), projectId: serviceAccount.project_id });

  let uid = arg('uid');
  if (!uid) {
    const email = arg('email', 'engr.waqasakram786@gmail.com');
    uid = (await admin.auth().getUserByEmail(email)).uid;
  }

  const db = admin.firestore();
  const docRef = db.doc(`users/${uid}/data/timetable`);
  const snap = await docRef.get();
  if (!snap.exists) { console.error('No live document found.'); process.exit(1); }
  const raw = snap.data();
  const live = {};
  for (const [k, v] of Object.entries(raw)) {
    if (typeof v !== 'string') { live[k] = v; continue; }
    try { live[k] = JSON.parse(v); } catch { live[k] = v; }
  }

  // Mandatory fresh backup before any write, regardless of --confirm.
  const backupDir = path.join(__dirname, '..', 'backups');
  const backupFile = path.join(backupDir, `backup_${uid}_${new Date().toISOString().replace(/[:.]/g, '-')}_pre-fsc2.json`);
  fs.writeFileSync(backupFile, JSON.stringify({ uid, timetable: live }, null, 2));
  console.log(`Fresh backup written: ${backupFile}`);

  if (live.programs.some(p => p.name === PROGRAM.name && p.level === PROGRAM.level)) {
    console.error(`Program "${PROGRAM.name}" already exists live — aborting so nothing gets duplicated.`);
    process.exit(1);
  }

  const timeslotsById = Object.fromEntries(live.timeslots.map(t => [t.id, t]));
  const { classes, assignments } = buildNewRecords(live);

  const clashes = findClashes(assignments, live.assignments, timeslotsById);

  console.log(`\nWill add: 1 program, ${classes.length} classes, ${assignments.length} assignments.`);
  if (clashes.length) {
    if (!hasFlag('accept-clashes')) {
      console.log(`\n*** ${clashes.length} CLASH(ES) DETECTED — aborting, nothing written. Pass --accept-clashes to proceed anyway: ***`);
      clashes.forEach(c => console.log('  ' + c));
      process.exit(1);
    }
    console.log(`\n*** ${clashes.length} CLASH(ES) — proceeding anyway (--accept-clashes), same as the app allows a clashing save: ***`);
    clashes.forEach(c => console.log('  ' + c));
  } else {
    console.log('No clashes against live data. ✓');
  }

  if (!hasFlag('confirm')) {
    console.log('\nDry run only (no --confirm passed) — nothing written.');
    assignments.forEach(a => console.log(
      `  ${a.classModel.name} P?=${a.timeSlotId} ${a.course.name} / ${a.teacher.name} / room=${a.roomId || 'none'} / days=${a.customDays.length ? a.customDays.join(',') : 'all'}`
    ));
    return;
  }

  const newPrograms   = [...live.programs, PROGRAM];
  const newClasses    = [...live.classes, ...classes];
  const newAssignments = [...live.assignments, ...assignments];

  await docRef.set({
    programs:    JSON.stringify(newPrograms),
    classes:     JSON.stringify(newClasses),
    assignments: JSON.stringify(newAssignments),
  }, { merge: true });

  console.log(`\nWRITTEN. Program + ${classes.length} classes + ${assignments.length} assignments added.`);
}

main().catch(e => { console.error(e); process.exit(1); });
