// Rebuilds Islamic Studies (Islamiat) allocations for INTERMEDIATE classes
// only (per user instruction — Bachelor-level left untouched) — from the
// "Islamic Studies" section of Teacherwise.xlsx (Sheet1 rows 170-178,
// dedicated Islamiat dept teachers; rows 5-16, Arabic dept teachers who also
// teach Islamiat, yellow-highlighted cells only).
//
// Removes every EXISTING Intermediate-Islamiat assignment/combinedRule
// first, then writes the fresh set decoded from the register. Bookings that
// combine 2-3 classes into one session become CombinedClassRules; single
// classes become plain Assignments. Bachelor Islamiat (BACH array) is kept
// in this file for reference but is NOT applied.
//
// Dry-run by default (prints the full plan, writes nothing). --confirm to write.
// Always takes a fresh backup first via fetch_and_backup.js — run that first.
//
// Usage:
//   node apply_islamic_studies.js --key <service-account.json> --uid <uid> [--confirm]

const fs = require('fs');
const admin = require('firebase-admin');

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 ? process.argv[i + 1] : undefined;
}
const CONFIRM = process.argv.includes('--confirm');

// ── Bachelor bookings: {t, part, subj, days, period} ────────────────────────
// part: '1' | 'III' | 'V' | 'VII' | 'VIII' (matches "BS Semester <part>" program)
// period: 1-6, the BS period column-group the booking sat in on the sheet.
const BACH = [
  // Dr. Hafiz Muhammad Ajmal
  { t: 'Ajmal', part: '1', subj: 'IT', days: [1, 2], period: 2 },
  { t: 'Ajmal', part: '1', subj: 'Chemistry', days: [4, 5], period: 2 },
  // Hafiz Sami Ullah
  { t: 'SamiUllah', part: '1', subj: 'Data Science', days: [1, 2], period: 1 },
  { t: 'SamiUllah', part: '1', subj: 'Math', days: [3, 4], period: 1 },
  { t: 'SamiUllah', part: '1', subj: 'Zoology', days: [5, 6], period: 1 },
  // Munazza Qari
  { t: 'Qari', part: '1', subj: 'English', days: [1], period: 1 },
  { t: 'Qari', part: '1', subj: 'Stat', days: [3], period: 1 },
  { t: 'Qari', part: '1', subj: 'BBA', days: [5, 6], period: 1 },
  { t: 'Qari', part: '1', subj: 'Botany', days: [1, 2], period: 2 },
  { t: 'Qari', part: '1', subj: 'English', days: [3], period: 2 },
  { t: 'Qari', part: '1', subj: 'Stat', days: [4], period: 2 },
  // Ayube Sabir
  { t: 'Sabir', part: '1', subj: 'Political Science', days: [3, 4], period: 1 },
  { t: 'Sabir', part: '1', subj: 'Environmental Science', days: [1, 2], period: 2 },
  { t: 'Sabir', part: '1', subj: 'Urdu', days: [3, 4], period: 2 },
  { t: 'Sabir', part: '1', subj: 'Physics', days: [4, 5], period: 3 },
  // Abdul Hanan
  { t: 'Hanan', part: 'III', subj: 'Chemistry', days: [4], period: 1 },
  { t: 'Hanan', part: 'VIII', subj: 'Urdu', days: [1], period: 3 },
  { t: 'Hanan', part: 'V', subj: 'Math', days: [5], period: 3 },
  { t: 'Hanan', part: 'VII', subj: 'Urdu', days: [4, 5, 6], period: 5 },
  { t: 'Hanan', part: 'VIII', subj: 'Zoology', days: [2], period: 6 },
  { t: 'Hanan', part: 'VIII', subj: 'Botany', days: [4], period: 6 },
  { t: 'Hanan', part: 'VII', subj: 'English', days: [5], period: 6 },
  { t: 'Hanan', part: 'VII', subj: 'IT', days: [6], period: 6 },
  // M. Abdullah
  { t: 'Abdullah', part: 'III', subj: 'CS B', days: [4], period: 2 },
  { t: 'Abdullah', part: 'V', subj: 'Botany', days: [2], period: 2 },
  { t: 'Abdullah', part: 'III', subj: 'Stat', days: [3], period: 3 },
  { t: 'Abdullah', part: 'III', subj: 'IT', days: [4], period: 3 },
  { t: 'Abdullah', part: 'VIII', subj: 'IT', days: [5], period: 5 },
  { t: 'Abdullah', part: 'V', subj: 'Zoology', days: [1], period: 6 },
  { t: 'Abdullah', part: 'VII', subj: 'Zoology', days: [3], period: 6 },
  { t: 'Abdullah', part: 'VIII', subj: 'Math', days: [4], period: 6 },
  { t: 'Abdullah', part: 'V', subj: 'English', days: [5], period: 6 },
  { t: 'Abdullah', part: 'VIII', subj: 'English', days: [6], period: 6 },
  // Iqra Fatima
  { t: 'Fatima', part: 'III', subj: 'CS A', days: [3], period: 2 },
  { t: 'Fatima', part: 'III', subj: 'Economics', days: [4], period: 2 },
  { t: 'Fatima', part: 'VII', subj: 'Stat', days: [4], period: 6 },
  { t: 'Fatima', part: 'VII', subj: 'Math', days: [5], period: 6 },
  { t: 'Fatima', part: 'V', subj: 'Urdu', days: [1], period: 6 },
  { t: 'Fatima', part: 'VIII', subj: 'Stat', days: [6], period: 6 },
  // Uzma Bano
  { t: 'Bano', part: 'III', subj: 'English', days: [3], period: 1 },
  { t: 'Bano', part: 'III', subj: 'Math', days: [4], period: 1 },
  { t: 'Bano', part: 'III', subj: 'Political Science', days: [3], period: 2 },
  { t: 'Bano', part: 'VII', subj: 'Physics', days: [3], period: 3 },
  { t: 'Bano', part: 'V', subj: 'Political Science', days: [1], period: 6 },
  { t: 'Bano', part: 'VIII', subj: 'Physics', days: [2], period: 6 },
  { t: 'Bano', part: 'VII', subj: 'Political Science', days: [4], period: 6 },
  { t: 'Bano', part: 'V', subj: 'Stat', days: [5], period: 6 },
  { t: 'Bano', part: 'VIII', subj: 'Political Science', days: [6], period: 6 },
  // Abdul Wahid
  { t: 'Wahid', part: 'III', subj: 'Zoology', days: [1], period: 1 },
  { t: 'Wahid', part: 'VIII', subj: 'Chemistry', days: [3], period: 3 },
  { t: 'Wahid', part: 'VII', subj: 'Botany', days: [5], period: 3 },
  { t: 'Wahid', part: 'V', subj: 'Economics', days: [4], period: 4 },
  { t: 'Wahid', part: 'III', subj: 'Physics', days: [2], period: 4 },
  { t: 'Wahid', part: 'V', subj: 'Chemistry', days: [1], period: 6 },
  { t: 'Wahid', part: 'VII', subj: 'Urdu', days: [4], period: 6 },
  { t: 'Wahid', part: 'VII', subj: 'Economics', days: [2], period: 6 },
  { t: 'Wahid', part: 'VIII', subj: 'Economics', days: [5], period: 6 },
  { t: 'Wahid', part: 'VIII', subj: 'Education', days: [6], period: 6 },
];

// ── Intermediate bookings: {t, course, prog, part(1|2), codes[], days, room} ──
// course: 'ISL' (Islamiat dept teachers) or 'THQ' (Arabic dept teachers —
// they teach THQ, a separate Intermediate course, not Islamiat).
// A code may be "X" (resolved via this booking's own prog/part) or "X:PROG"
// to override prog for just that one class (mixed-program combos).
const INTER = [
  // Ajmal (Islamiat dept, row labelled "Inter Part 1") — Islamiat
  { t: 'Ajmal', course: 'ISL', prog: 'FSC', part: 1, codes: ['M'], days: [1, 2], room: null },
  { t: 'Ajmal', course: 'ISL', prog: 'FSC', part: 1, codes: ['M0'], days: [3, 4], room: null },
  { t: 'Ajmal', course: 'ISL', prog: 'ICS', part: 1, codes: ['C2'], days: [5, 6], room: null },
  // NOTE: sheet says "C2+GS(5-6)" — "GS" does not match any live class/program.
  // Left out of the C2 booking above; GS itself is reported as unresolved.
  // Sami Ullah (Inter Part 1) — Islamiat
  { t: 'SamiUllah', course: 'ISL', prog: 'ICS', part: 1, codes: ['C'], days: [1, 2], room: '88' },
  { t: 'SamiUllah', course: 'ISL', prog: 'ICS', part: 1, codes: ['C1', 'C5'], days: [3, 4], room: '48' },
  { t: 'SamiUllah', course: 'ISL', prog: 'FSC', part: 1, codes: ['M1', 'M2'], days: [5, 6], room: '48' },
  // Munazza Qari (Inter Part 1) — Islamiat
  { t: 'Qari', course: 'ISL', prog: 'FSC', part: 1, codes: ['E', 'E0'], days: [1, 2], room: '48' },
  { t: 'Qari', course: 'ISL', prog: 'ICS', part: 1, codes: ['C4'], days: [3, 4], room: null },
  { t: 'Qari', course: 'ISL', prog: 'ICS', part: 1, codes: ['C3', 'C7'], days: [5, 6], room: null },
  // Ayube Sabir (Inter Part 1) — Islamiat
  { t: 'Sabir', course: 'ISL', prog: 'ARTS', part: 1, codes: ['A0', 'A1'], days: [1, 2], room: '46' },
  { t: 'Sabir', course: 'ISL', prog: 'ICS', part: 1, codes: ['C6', 'A2:ARTS'], days: [3, 4], room: '46' },
  { t: 'Sabir', course: 'ISL', prog: 'ICOM', part: 1, codes: ['ICOM', 'A3:ARTS'], days: [5, 6], room: '46' },
  // Zakria (Arabic dept, explicit P1/P2 = Part qualifier per line) — THQ
  { t: 'Zakria', course: 'THQ', prog: 'FSC', part: 2, codes: ['E0', 'M0'], days: [1, 2], room: '29' },
  { t: 'Zakria', course: 'THQ', prog: 'FSC', part: 1, codes: ['E', 'M'], days: [3, 4], room: '29' },
  { t: 'Zakria', course: 'THQ', prog: 'FSC', part: 1, codes: ['E0', 'M0'], days: [5, 6], room: '29' },
  // Abdul Hanan — THQ
  { t: 'Hanan', course: 'THQ', prog: 'ICOM', part: 1, codes: ['ICOM', 'A2:ARTS'], days: [1, 2], room: '50' },
  { t: 'Hanan', course: 'THQ', prog: 'FSC', part: 1, codes: ['M1'], days: [3, 4], room: '17' },
  { t: 'Hanan', course: 'THQ', prog: 'ARTS', part: 2, codes: ['A0', 'A1', 'A2'], days: [5, 6], room: '50' },
  // M. Abdullah — THQ
  { t: 'Abdullah', course: 'THQ', prog: 'ICS', part: 2, codes: ['C3', 'C4'], days: [1, 2], room: '65' },
  { t: 'Abdullah', course: 'THQ', prog: 'ARTS', part: 1, codes: ['A0', 'A1', 'A3'], days: [3, 4], room: '65' },
  { t: 'Abdullah', course: 'THQ', prog: 'ICS', part: 1, codes: ['C', 'C1'], days: [5, 6], room: '65' },
  // Iqra Fatima — THQ
  { t: 'Fatima', course: 'THQ', prog: 'ICS', part: 1, codes: ['C2', 'C3'], days: [1, 2], room: '51' },
  { t: 'Fatima', course: 'THQ', prog: 'FSC', part: 1, codes: ['M2', 'C7:ICS'], days: [3, 4], room: '51' },
  { t: 'Fatima', course: 'THQ', prog: 'FSC', part: 2, codes: ['M1', 'ICOM:ICOM'], days: [5, 6], room: '52' },
  // Uzma Bano — THQ
  { t: 'Bano', course: 'THQ', prog: 'FSC', part: 2, codes: ['M2', 'M3'], days: [1, 2], room: '52' },
  { t: 'Bano', course: 'THQ', prog: 'ICS', part: 2, codes: ['C2', 'C5'], days: [3, 4], room: '52' },
  { t: 'Bano', course: 'THQ', prog: 'ICS', part: 1, codes: ['C4', 'C5', 'C6'], days: [5, 6], room: '51' },
  // Abdul Wahid — THQ (days 1-2 blank in source — nothing to add there)
  { t: 'Wahid', course: 'THQ', prog: 'FSC', part: 2, codes: ['E', 'M'], days: [3, 4], room: '53' },
  { t: 'Wahid', course: 'THQ', prog: 'ICS', part: 2, codes: ['C', 'C1', 'C6'], days: [5, 6], room: '53' },
];

const TEACHER_NAME = {
  Ajmal: 'Dr. Hafiz Muhammad Ajmal', SamiUllah: 'Dr. Hafiz Sami Ullah',
  Qari: 'Munazza Qari', Sabir: 'Ayube Sabir', Zakria: 'Muhammad Zakria',
  Hanan: 'Abdul Hanan', Abdullah: 'M. Abdullah', Fatima: 'Iqra Fatima',
  Bano: 'Uzma Bano', Wahid: 'Abdul Wahid',
};
// Live shortCode has a typo/casing quirk for these two subject/part combos.
const BACH_SUBJ_FIX = { 'V:Political Science': 'Political Sceince', 'VIII:Math': 'MATH' };

const BACH_TS = {
  1: 'ts_bac_1', 2: 'ts_bac_2', 3: 'ts_bac_3',
  4: '1783958190920296_42', 5: '1787157647948505_130', 6: '1787157647956483_131',
};

async function main() {
  const keyPath = arg('key');
  const uid = arg('uid');
  if (!keyPath || !uid) {
    console.error('Usage: node apply_islamic_studies.js --key <sa.json> --uid <uid> [--confirm]');
    process.exit(1);
  }
  const serviceAccount = JSON.parse(fs.readFileSync(keyPath, 'utf8'));
  admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
  const docRef = admin.firestore().collection('users').doc(uid).collection('data').doc('timetable');

  const snap = await docRef.get();
  if (!snap.exists) throw new Error('Live document not found.');
  const raw = snap.data();
  const decode = (k) => { try { return JSON.parse(raw[k]); } catch { return raw[k]; } };

  const teachers = decode('teachers');
  const courses = decode('courses');
  const programs = decode('programs');
  const classes = decode('classes');
  const rooms = decode('rooms');
  let assignments = decode('assignments');
  let combinedRules = decode('combinedRules');

  const bachIsl = courses.find(c => c.name === 'Islamiat' && c.level === 1);
  const interIsl = courses.find(c => c.name === 'Islamiat' && c.level === 0);
  // Two duplicate "THQ" course records exist live (M-1 and THA-001) — old
  // broken data has THQ bookings scattered across BOTH. M-1 is the one to
  // keep (per user); THA-001's assignments/rules must ALSO be purged below
  // so its stale entries don't collide with the fresh M-1 ones.
  const interThq = courses.find(c => c.id === '1784352168235642_39');
  const interThqDupe = courses.find(c => c.id === '1787167743833774_24');
  if (!bachIsl || !interIsl) throw new Error('Islamiat course(s) not found live.');
  if (!interThq || !interThqDupe) throw new Error('THQ course(s) not found live.');
  const COURSE = { ISL: interIsl, THQ: interThq };

  const teacherByKey = (key) => {
    const name = TEACHER_NAME[key];
    const t = teachers.find(x => x.name.trim() === name);
    if (!t) throw new Error('Teacher not found: ' + name);
    return t;
  };
  const roomByName = (n) => n == null ? null : (rooms.find(r => r.name.trim() === n) || null);

  const bachProgFor = (part) => programs.find(p =>
      p.name === `BS Semester ${part}` || p.name.startsWith(`BS Semester ${part} (`));
  const bachClassFor = (part, subj) => {
    const prog = bachProgFor(part);
    if (!prog) return null;
    const fixed = BACH_SUBJ_FIX[`${part}:${subj}`] || subj;
    return classes.find(c => c.programId === prog.id &&
        c.shortCode.slice(c.shortCode.lastIndexOf('-') + 1).trim().toLowerCase() === fixed.toLowerCase());
  };
  const BBA_CLASS = classes.find(c => c.shortCode === 'BBA-');

  const interProgId = {};
  [['FSC1', 'F.Sc Part 1'], ['FSC2', 'F.Sc Part 2'], ['ICS1', 'ICS Part1'], ['ICS2', 'ICS Part 2'],
   ['ARTS1', 'Arts Part 1'], ['ARTS2', 'Arts Part 2'], ['ICOM1', 'ICOM Part 1'], ['ICOM2', 'ICOM Part 2']]
      .forEach(([k, name]) => { interProgId[k] = programs.find(p => p.name === name)?.id; });

  const interClassFor = (progKey, part, code) => {
    const pid = interProgId[`${progKey}${part}`];
    if (!pid) return null;
    if (progKey === 'ICOM') return classes.find(c => c.programId === pid); // single section
    return classes.find(c => c.programId === pid && c.name === code);
  };

  const unresolved = ['INTER Ajmal prog=ICS part=1 code=GS (days 5,6) — no matching class/program found, skipped'];
  let nextId = Date.now();
  const newId = () => String(nextId++) + '_isl';

  // ── Remove all prior INTERMEDIATE Islamiat + THQ (both THQ ids) allocations ──
  // (Bachelor untouched)
  const staleIds = new Set([interIsl.id, interThq.id, interThqDupe.id]);
  const beforeA = assignments.length, beforeR = combinedRules.length;
  assignments = assignments.filter(a => !staleIds.has(a.course.id));
  combinedRules = combinedRules.filter(r => !staleIds.has(r.courseId));
  const removedA = beforeA - assignments.length, removedR = beforeR - combinedRules.length;

  const newAssignments = [];
  const newRules = [];
  void bachIsl; void bachClassFor; void BBA_CLASS; void BACH_TS; void BACH; // Bachelor kept for reference, not applied

  // ── Intermediate: resolve each code, single = plain assignment, multi = combined rule ──
  for (const g of INTER) {
    const teacher = teacherByKey(g.t);
    const resolvedClasses = [];
    for (const code of g.codes) {
      let progKey = g.prog, bareCode = code;
      if (code.includes(':')) { const [c, p] = code.split(':'); bareCode = c; progKey = p; }
      const cls = interClassFor(progKey, g.part, bareCode === 'ICOM' ? null : bareCode);
      if (!cls) { unresolved.push(`INTER ${g.t} prog=${progKey} part=${g.part} code=${bareCode} (days ${g.days})`); continue; }
      resolvedClasses.push(cls);
    }
    if (resolvedClasses.length !== g.codes.length) continue; // logged above; skip whole group
    const room = roomByName(g.room);
    if (g.room && !room) unresolved.push(`ROOM "${g.room}" not found (${g.t} days ${g.days}) — left unassigned`);

    const course = COURSE[g.course];
    const ids = resolvedClasses.map(c => {
      newAssignments.push({
        id: newId(), teacher, course, classModel: c,
        startSlot: g.days[0], duration: g.days.length, timeSlotId: 'ts_int_6',
        customDays: g.days, roomId: room ? room.id : null, autoAssigned: false,
      });
      return c.id;
    });
    if (ids.length > 1) newRules.push({ id: newId(), courseId: course.id, classIds: ids });
  }

  // ── Dry-run summary ──────────────────────────────────────────────────────
  console.log('=== Islamic Studies (Intermediate only) rebuild — dry run ===');
  console.log(`Removing existing: ${removedA} assignments, ${removedR} combined rules (Intermediate Islamiat only)`);
  console.log(`Adding: ${newAssignments.length} assignments, ${newRules.length} combined rules`);
  console.log(`Unresolved (skipped, nothing written for these): ${unresolved.length}`);
  unresolved.forEach(u => console.log('  - ' + u));

  console.log('\n--- New Intermediate assignments ---');
  newAssignments.forEach(a =>
      console.log(`  [${a.course.name.padEnd(8)}] ${a.teacher.name.padEnd(28)} ${a.classModel.shortCode.padEnd(20)} days=${JSON.stringify(a.customDays).padEnd(12)} room=${a.roomId ? rooms.find(r => r.id === a.roomId)?.name : 'none'}`));
  console.log('\n--- New combined rules (Intermediate) ---');
  newRules.forEach(r => {
    const names = r.classIds.map(id => classes.find(c => c.id === id)?.shortCode || id).join(' + ');
    console.log(`  ${names}`);
  });

  if (!CONFIRM) {
    console.log('\nDry run only — nothing written. Re-run with --confirm to apply.');
    return;
  }

  assignments.push(...newAssignments);
  combinedRules.push(...newRules);

  await docRef.set({
    assignments: JSON.stringify(assignments),
    combinedRules: JSON.stringify(combinedRules),
  }, { merge: true });
  console.log('\nWritten to Firestore.');
}

main().catch(e => { console.error(e); process.exit(1); });
