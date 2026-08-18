import 'dart:async';
import 'package:spreadsheet_decoder/spreadsheet_decoder.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Data classes returned by the parser
// ─────────────────────────────────────────────────────────────────────────────

class ParsedPeriod {
  final int    periodNumber;   // 1, 2, 3 …
  final String startTime;     // "08:00"
  final String endTime;       // "08:40"
  final String rawLabel;
  const ParsedPeriod({
    required this.periodNumber,
    required this.startTime,
    required this.endTime,
    required this.rawLabel,
  });
}

class ParsedCell {
  final String teacherName;
  final String subjectName;
  final String roomNo;
  // Explicit days from a "(1-2)"/"(3-4)" combined-slot annotation.
  // null = no annotation → occupies the full working week (see
  // TimetableGridImportScreen, which is where that default is applied).
  final List<int>? days;
  const ParsedCell({
    required this.teacherName,
    required this.subjectName,
    required this.roomNo,
    this.days,
  });
}

class ParsedAssignmentDraft {
  final String teacherName;
  final String subjectName;
  final String className;   // e.g. "F.Sc Part I - Section E"
  final String programName; // e.g. "F.Sc Part I"
  final String roomNo;
  final int    periodIndex; // 0-based index into periods list
  final List<int>? days;    // see ParsedCell.days
  const ParsedAssignmentDraft({
    required this.teacherName,
    required this.subjectName,
    required this.className,
    required this.programName,
    required this.roomNo,
    required this.periodIndex,
    this.days,
  });
}

// A multi-choice elective option within one ElectiveDraft — subject,
// teacher and (optional) room, e.g. "Punjabi A: Amer Ghafar  51".
class ParsedElectiveEntry {
  final String subjectName;
  final String teacherName;
  final String roomNo;
  const ParsedElectiveEntry({
    required this.subjectName,
    required this.teacherName,
    required this.roomNo,
  });
}

// One elective block: several ParsedElectiveEntry options offered in the
// same period, shared by every class the source cell's merge spans.
class ParsedElectiveDraft {
  final int                        periodIndex;
  final List<String>               classNames; // every class this block covers
  final List<ParsedElectiveEntry>  entries;
  const ParsedElectiveDraft({
    required this.periodIndex,
    required this.classNames,
    required this.entries,
  });
}

class TimetableGridImportResult {
  final List<ParsedPeriod>           periods;
  final List<String>                 teacherNames;
  final List<String>                 subjectNames;
  final List<({String program, String section})> classes;
  final List<String>                 roomNumbers;
  final List<ParsedAssignmentDraft>  assignments;
  final List<ParsedElectiveDraft>    electives;
  final List<String>                 warnings;
  final int                          totalCells;
  final int                          parsedCells;
  final String                       fileName;
  final bool                         isIntermediate; // vs Bachelors

  const TimetableGridImportResult({
    required this.periods,
    required this.teacherNames,
    required this.subjectNames,
    required this.classes,
    required this.roomNumbers,
    required this.assignments,
    required this.electives,
    required this.warnings,
    required this.totalCells,
    required this.parsedCells,
    required this.fileName,
    required this.isIntermediate,
  });
}

// Tracks one elective block while its merged cell's row-span is still being
// walked — accumulates every class row it covers until a different cell
// value (or a non-elective cell) in the same period column closes it out.
class _ActiveElective {
  final String rawText;
  final List<String> classNames = [];
  _ActiveElective(this.rawText);
}

// ─────────────────────────────────────────────────────────────────────────────
// Main service
// ─────────────────────────────────────────────────────────────────────────────

class TimetableGridImportService {
  // These prefixes appear in the "period 6" combined cells and are NOT
  // teacher-course entries — skip them.
  static const _skipPrefixes = [
    'isl', 'islamic', 'thq', 'tarjuma', 'ps ', 'pak st', 'physical edu',
    'phy edu', 'punjabi', 'eth', 'ethic', 'practicals',
  ];

  static bool _shouldSkip(String text) {
    final t = text.toLowerCase().trim();
    return _skipPrefixes.any((p) => t.startsWith(p));
  }

  // ── Core parser ─────────────────────────────────────────────────────────────

  static Future<TimetableGridImportResult> parseDecoder(
    SpreadsheetDecoder excel,
    String fileName,
    void Function(double, String) cb,
  ) async {
    // Find the best sheet (the one with actual data)
    SpreadsheetTable? bestSheet;
    String bestSheetName = '';
    int bestRows = 0;
    for (final entry in excel.tables.entries) {
      final s = entry.value;
      if ((s.maxRows) > bestRows) {
        bestRows = s.maxRows;
        bestSheet = s;
        bestSheetName = entry.key;
      }
    }
    if (bestSheet == null || bestRows == 0) {
      throw Exception('No data found in spreadsheet.');
    }

    final rows = List<List<dynamic>>.from(
      bestSheet.rows.map((r) => List<dynamic>.from(r)),
    );

    // ── Step 1: Find header row (contains period time labels) ─────────────────
    int headerRowIdx = -1;
    List<int> periodCols = []; // column indices of period cells
    List<ParsedPeriod> periods = [];

    for (int r = 0; r < rows.length && r < 10; r++) {
      final row = rows[r];
      final times = <({int col, String label, String start, String end})>[];

      for (int c = 0; c < row.length; c++) {
        final cell = row[c]?.toString().trim() ?? '';
        // Look for cells containing time patterns like "08:00" or "8:00".
        // The minute half tolerates an optional stray "-" right after the
        // colon (a real source-file typo: "10:-00" meaning "10:00") —
        // hour/minute are captured separately and rejoined below instead
        // of matching "hh:mm" as one literal substring, so the typo never
        // ends up embedded in the resolved time.
        final match = RegExp(r'(\d{1,2}):-?(\d{2})\s*[-–]\s*(\d{1,2}):-?(\d{2})').firstMatch(cell);
        if (match != null) {
          times.add((
            col: c,
            label: cell,
            start: '${match.group(1)}:${match.group(2)}',
            end: '${match.group(3)}:${match.group(4)}',
          ));
        }
      }

      if (times.length >= 3) {
        headerRowIdx = r;
        final resolved = resolveAmbiguousHours(times);
        for (int i = 0; i < resolved.length; i++) {
          periodCols.add(resolved[i].col);
          periods.add(ParsedPeriod(
            periodNumber: i + 1,
            startTime: resolved[i].start,
            endTime: resolved[i].end,
            rawLabel: resolved[i].label,
          ));
        }
        break;
      }
    }

    if (headerRowIdx == -1 || periodCols.isEmpty) {
      throw Exception(
        'Could not find period time headers.\n\n'
        'Expected rows like: "1 (08:00 - 08:40)" | "2 (08:40 - 09:20)" ...',
      );
    }

    // ── Step 2: Detect level (Intermediate vs Bachelors) ─────────────────────
    // The title cell alone is unreliable — many sheets don't label
    // themselves at all. The college's own naming convention is the real
    // signal: FA / ICS / Arts / F.Sc / I.Com programs are Intermediate;
    // BS / BA programs are Bachelors. Checked properly below, once every
    // class/program name in the sheet has been collected (Step 4). The
    // sheet/tab name is folded in as a fallback signal alongside the title
    // cell — some Bachelor sheets (e.g. "BS-V Time Table") only say "BS"
    // in the tab name, with every row/title cell just naming a department
    // ("Chemistry", "Urdu") that carries no level signal at all.
    final titleCell = rows.isNotEmpty ? (rows[0][0]?.toString() ?? '') : '';
    final titleSignal = '$titleCell $bestSheetName';

    final hRow = rows[headerRowIdx];

    // ── Step 3: Determine class column positions ──────────────────────────────
    // In GGC format: cols 0-3 are [Class name, (merged), Room No, Section]
    // We'll find "class" and "room" and "section" cols flexibly.
    // For simplicity: class label = col 0 (merge-filled), room = col 2 or 3, section = col 3
    int classCol   = 0;
    int roomCol    = -1;
    int sectionCol = -1;

    // Scan header row for column roles
    for (int c = 0; c < hRow.length && c < periodCols.first; c++) {
      final label = (hRow[c]?.toString() ?? '').toLowerCase().trim();
      if (label.contains('room')) roomCol = c;
      if (label.contains('sec'))  sectionCol = c;
    }
    // Fallback positions from observed files
    if (roomCol    == -1) roomCol    = 2;
    if (sectionCol == -1) sectionCol = periodCols.first - 1;

    // ── Step 4: Parse data rows ───────────────────────────────────────────────
    final warnings        = <String>[];
    final teacherNames    = <String>{};
    final subjectNames    = <String>{};
    final classSet        = <({String program, String section})>{};
    final roomNumbers     = <String>{};
    final assignments     = <ParsedAssignmentDraft>[];
    final electives       = <ParsedElectiveDraft>[];
    int totalCells = 0, parsedCells = 0;

    // Some Bachelor-semester sheets (e.g. GGC's "BS-V/VII/VIII" files) use
    // a completely different shape: rows are Subject+Semester (not
    // class+section), a period's days live in the NEXT column over instead
    // of an inline "(d-d)" annotation, and one cell can hold several
    // simultaneous teacher/lab-group entries. Detected by the header
    // literally labelling the column right after each period "Days".
    if (looksLikeDaysColumnLayout(hRow, periodCols)) {
      // Column layout isn't fixed even within this shape — a single-
      // semester file (e.g. "BS Semester I") has no per-row Semester
      // column at all (Subject, Room No. only), while a multi-semester
      // file (e.g. "BS-V/VII/VIII") has one (Subject, Semester, Room No.).
      // Detected the same way the regular layout finds its room/section
      // columns: scan the header cells before the first period column for
      // role keywords instead of assuming a fixed position.
      int semesterCol = -1;
      int daysRoomCol = -1;
      for (int c = 1; c < hRow.length && c < periodCols.first; c++) {
        final label = (hRow[c]?.toString() ?? '').toLowerCase().trim();
        if (label.contains('semester') || label.contains('sem')) semesterCol = c;
        if (label.contains('room')) daysRoomCol = c;
      }
      if (daysRoomCol == -1) {
        // No "Room" header found — fall back to whichever metadata column
        // isn't Semester (Subject is always col 0).
        daysRoomCol = semesterCol == 1 ? 2 : 1;
      }
      final counts = _parseDaysColumnRows(
        rows: rows,
        headerRowIdx: headerRowIdx,
        periodCols: periodCols,
        semesterCol: semesterCol,
        roomCol: daysRoomCol,
        teacherNames: teacherNames,
        subjectNames: subjectNames,
        classSet: classSet,
        roomNumbers: roomNumbers,
        assignments: assignments,
      );
      totalCells = counts.totalCells;
      parsedCells = counts.parsedCells;
    } else {
      // Carry-forward: in merged cells the class name only appears in the first row
      String carryClass   = '';
      String carrySection = '';
      String carryRoom    = '';

      // Elective blocks are also merged cells — one per period column,
      // spanning however many class rows the block covers. Keyed by period
      // index so independent blocks in different periods track separately.
      final activeElectives = <int, _ActiveElective>{};

      void finalizeElective(int period) {
        final active = activeElectives.remove(period);
        if (active == null) return;
        final entries = parseElectiveBlockLines(active.rawText);
        if (entries.isEmpty) return;
        electives.add(ParsedElectiveDraft(
          periodIndex: period,
          classNames:  List<String>.from(active.classNames),
          entries:     entries,
        ));
        for (final e in entries) {
          teacherNames.add(e.teacherName);
          subjectNames.add(e.subjectName);
          if (e.roomNo.isNotEmpty) roomNumbers.add(e.roomNo);
        }
      }

      for (int r = headerRowIdx + 1; r < rows.length; r++) {
        final row = rows[r];
        if (row.every((c) => c == null || c.toString().trim().isEmpty)) continue;

        // Update carry-forward values when non-empty
        final rawClass   = _cellStr(row, classCol);
        final rawSection = _cellStr(row, sectionCol);
        final rawRoom    = _cellStr(row, roomCol);

        if (rawClass.isNotEmpty)   carryClass   = rawClass;
        if (rawSection.isNotEmpty) carrySection = rawSection;
        if (rawRoom.isNotEmpty)    carryRoom    = rawRoom;

        // Some sheets (GGC's Arts rows again) leave the Sec column blank
        // for a whole block but still embed a per-row section marker
        // directly in each period cell's subject text — e.g. "Eng A0 51",
        // "Urdu  A0 51" repeat the SAME "A0" + room "51" across every
        // period column of one row, then "A1"/52, "A2"/53 for the next
        // rows. Without recovering it, every row in the block collapses
        // onto one class: three unrelated sections' teachers all land on
        // the SAME period of the SAME class, registering as false clashes,
        // and the token is left glued onto the subject ("Eng A0" instead
        // of "Eng"). Only attempted when the real Sec column has nothing
        // to say — a file that already has a real per-row section never
        // reaches this.
        var rowSection = carrySection;
        if (rowSection.isEmpty) {
          for (final p in periodCols) {
            final cellText = ((p < row.length ? row[p]?.toString() : null) ?? '')
                .split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).lastOrNull ?? '';
            final m = RegExp(r'\b([A-Za-z]\d{1,2})\s+\d{2,3}\s*$').firstMatch(cellText);
            if (m != null) { rowSection = m.group(1)!; break; }
          }
        }

        // Skip meta rows (total/summary)
        final secLower = rowSection.toLowerCase();
        if (secLower == 'g.s' || secLower == 'gs') continue;

        // Some real sheets (GGC's combined-shift Intermediate files, e.g.
        // "Arts-I + ICS Part-I") leave the merged Class column blank for
        // whole leading blocks of rows — the very first data row in
        // particular is routinely blank, since the Class cell is only
        // filled in wherever the *second* program named in the title
        // starts. With carryClass still '' at that point, _buildClassName
        // used to return '' and the row was dropped outright — real
        // teacher/subject data silently lost, not just mislabeled. Falling
        // back to the sheet's own title cell keeps the row (and gives it a
        // distinct, if generic, class) instead of discarding it; once a
        // real Class cell is seen later in the sheet, carryClass takes
        // over exactly as before.
        final effectiveClass = carryClass.isNotEmpty ? carryClass : _titleAsClassFallback(titleCell);

        // Build class label
        final classLabel = _buildClassName(effectiveClass, rowSection);
        if (classLabel.isEmpty) continue;

        final programLabel = _cleanProgram(effectiveClass);
        if (carryRoom.isNotEmpty) roomNumbers.add(carryRoom);

        classSet.add((program: programLabel, section: rowSection));

        // Parse each period cell
        for (int p = 0; p < periodCols.length; p++) {
          final col = periodCols[p];
          final raw = (col < row.length ? row[col]?.toString() : null) ?? '';
          final trimmed = raw.trim();

          // A blank cell under an already-open elective block is a
          // continuation row of that block's merge — record the class and
          // move on. A blank cell with no open block is just empty.
          if (trimmed.isEmpty) {
            activeElectives[p]?.classNames.add(classLabel);
            continue;
          }

          if (looksLikeElectiveBlock(trimmed)) {
            totalCells++;
            parsedCells++;
            final active = activeElectives[p];
            if (active != null && active.rawText != trimmed) {
              // A genuinely different block started — close out the old one.
              finalizeElective(p);
            }
            activeElectives
                .putIfAbsent(p, () => _ActiveElective(trimmed))
                .classNames
                .add(classLabel);
            continue;
          }

          // A regular (or day-split) cell here means any elective block that
          // was open for this period column has ended.
          finalizeElective(p);

          totalCells++;

          // A cell can have multiple entries separated by \n\n or just \n
          // Each entry is "Teacher Name\nSubject"
          final entries = _splitCellEntries(raw);
          for (final entry in entries) {
            final parsed = _parseCell(entry);
            if (parsed == null) continue;

            teacherNames.add(parsed.teacherName);
            subjectNames.add(parsed.subjectName);
            if (parsed.roomNo.isNotEmpty) roomNumbers.add(parsed.roomNo);

            assignments.add(ParsedAssignmentDraft(
              teacherName:  parsed.teacherName,
              subjectName:  parsed.subjectName,
              className:    classLabel,
              programName:  programLabel,
              roomNo:       parsed.roomNo.isNotEmpty ? parsed.roomNo : carryRoom,
              periodIndex:  p,
              days:         parsed.days,
            ));
            parsedCells++;
          }

          if (entries.isEmpty && trimmed.isNotEmpty) {
            warnings.add('Row ${r + 1}, P${p + 1}: Could not parse "${ raw.substring(0, raw.length.clamp(0, 40)) }"');
          }
        }

        await Future.delayed(Duration.zero); // yield to avoid blocking UI
      }

      // Any elective block still open at the bottom of the sheet (its merge
      // ran to the last row) never hit a closing cell — finalize them all.
      for (final p in activeElectives.keys.toList()) {
        finalizeElective(p);
      }
    }

    // Program names carry the real level signal — check every class's
    // program name (e.g. "FA", "ICS", "Arts", "F.Sc", "I.Com" → Intermediate;
    // "BS", "BA" → Bachelors), falling back to the title cell/sheet name
    // only if no class name matched either convention.
    final isIntermediate = detectLevel(classSet, titleSignal);

    return TimetableGridImportResult(
      periods:       periods,
      teacherNames:  teacherNames.toList()..sort(),
      subjectNames:  subjectNames.toList()..sort(),
      classes:       classSet.toList(),
      roomNumbers:   roomNumbers.where((r) => r.isNotEmpty).toList()..sort(),
      assignments:   assignments,
      electives:     electives,
      warnings:      warnings,
      totalCells:    totalCells,
      parsedCells:   parsedCells,
      fileName:      fileName,
      isIntermediate: isIntermediate,
    );
  }

  // ── Level detection ──────────────────────────────────────────────────────────

  static final _bachelorRe = RegExp(r'\bbs\b|\bba\b|bachelor');
  static final _interRe    = RegExp(r'\bfa\b|\bics\b|\barts\b|\bfsc\b|\bicom\b');

  /// Majority vote across every class's program name — one file can list
  /// several classes, and any single one matching the convention is a
  /// reliable signal, but voting guards against an odd stray match.
  static bool detectLevel(
      Set<({String program, String section})> classSet, String titleCell) {
    int bachVotes = 0, interVotes = 0;
    for (final cls in classSet) {
      final norm = cls.program.replaceAll('.', '').toLowerCase();
      if (_bachelorRe.hasMatch(norm)) bachVotes++;
      if (_interRe.hasMatch(norm)) interVotes++;
    }
    if (bachVotes != interVotes) return interVotes > bachVotes;

    // No class name matched either convention — fall back to the title cell.
    return !RegExp(r'\bBS\b|\bbachelor', caseSensitive: false).hasMatch(titleCell);
  }

  // ── Fuzzy identity matching ──────────────────────────────────────────────────
  // Source sheets routinely abbreviate names ("Muhammad Nawaz" → "M Nawaz")
  // and subjects ("Mathematics" → "Math") relative to however they're
  // spelled out in the app's existing data. Exact string equality alone
  // would spawn a duplicate teacher/course per variant instead of resolving
  // to the one that already exists — worse than cosmetic for a teacher: the
  // clash checker treats "M Nawaz" and "Muhammad Nawaz" as different people,
  // so a real double-booking between their sections goes undetected.

  /// True if [a] and [b] are the same personal name where the first (and
  /// any middle) name may be abbreviated to a single initial on either
  /// side, as long as the surname (last word) matches in full — "M Nawaz"
  /// / "Muhammad Nawaz" / "Dr. M. Nawaz" all match each other, but "A Khan"
  /// and "M Khan" correctly don't (different initial, same surname).
  static bool teacherNamesMatch(String a, String b) {
    String norm(String s) => s
        .replaceAll(RegExp(r'\b(dr|mr|mrs|ms|prof)\.?\b', caseSensitive: false), '')
        .replaceAll('.', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toLowerCase();
    final na = norm(a), nb = norm(b);
    if (na.isEmpty || nb.isEmpty) return false;
    if (na == nb) return true;

    final wa = na.split(' ');
    final wb = nb.split(' ');
    // Same word count required — "Muhammad Nawaz" vs "M Nawaz" both have
    // exactly two words, one of them abbreviated; a real word-count
    // mismatch (e.g. surname alone) isn't something these sheets do.
    if (wa.length != wb.length) return false;
    if (wa.last != wb.last) return false; // surname must match in full

    for (int i = 0; i < wa.length - 1; i++) { // -1: surname already checked
      final x = wa[i], y = wb[i];
      if (x == y) continue;
      if (x.length == 1 && y.startsWith(x)) continue;
      if (y.length == 1 && x.startsWith(y)) continue;
      return false;
    }
    return true;
  }

  /// True if [a] and [b] are the same subject where one name is a
  /// case-insensitive prefix of the other — "Math" / "Mathematics". Guarded
  /// to 3+ characters on both sides so a short code like "PS" can't
  /// accidentally latch onto an unrelated subject.
  static bool courseNamesMatch(String a, String b) {
    final na = a.trim().toLowerCase();
    final nb = b.trim().toLowerCase();
    if (na.length < 3 || nb.length < 3) return na == nb;
    return na == nb || na.startsWith(nb) || nb.startsWith(na);
  }

  // ── Cell helpers ─────────────────────────────────────────────────────────────

  static String _cellStr(List<dynamic> row, int col) {
    if (col < 0 || col >= row.length) return '';
    return row[col]?.toString().trim() ?? '';
  }

  /// Split a raw cell into individual teacher-course entries.
  /// Cells look like:
  ///   "Ahmad Shah\nChem"                         → 1 entry
  ///   "Isl Uzma Kanwal (1-2)\nTHQ CTI 2 (3-4)"  → 2 combined-slot entries
  ///   "M. Asif\nPhy A 134\n\nUmair\nPhy B 135"   → 2 entries
  static List<String> _splitCellEntries(String raw) {
    // Normalise line endings
    final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    // Split on blank lines first (double-newline groups)
    final blocks = text.split(RegExp(r'\n{2,}'));
    if (blocks.length > 1) {
      return blocks.map((b) => b.trim()).where((b) => b.isNotEmpty).toList();
    }
    // A combined/split-period cell packs several "Subject Teacher (d-d)"
    // entries one per line (no blank line between them) — every line
    // carrying its own day-range annotation is the signal, distinct from
    // the regular "Teacher\nSubject" two-line pair used everywhere else.
    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (lines.length > 1 && lines.every((l) => _combinedDayRe.hasMatch(l))) {
      return lines;
    }
    // Otherwise the whole cell is one entry
    return [text.trim()];
  }

  // ── Combined/split-period slot parsing ──────────────────────────────────────
  // Cells like "Isl Munazza Qari (1-2)" pack several subjects into ONE
  // period, each meeting only on its own day-range — day 1 = Monday.
  static final _combinedDayRe = RegExp(r'\((\d)\s*-\s*(\d)\)');
  static const _combinedSubjects = {
    'islamic': 'Islamic Studies', 'isl': 'Islamiat',
    'thq': 'THQ', 'tarjuma': 'Tarjuma-tul-Quran',
    'pak st': 'Pakistan Studies', 'ps': 'Pakistan Studies',
    'phy edu': 'Physical Education', 'phyedu': 'Physical Education',
    'physical edu': 'Physical Education',
    'punjabi': 'Punjabi', 'ethic': 'Ethics', 'eth': 'Ethics',
    'practicals': 'Practicals',
  };

  /// Parses one combined-slot line — the subject keyword can appear before
  /// OR after the teacher name (both orderings show up in real files), so
  /// it's located by keyword match rather than position, and whatever text
  /// remains (minus the day annotation and any other parenthetical note)
  /// is the teacher.
  static ParsedCell? parseCombinedLine(String line) {
    final dayMatch = _combinedDayRe.firstMatch(line);
    if (dayMatch == null) return null;
    final d1 = int.tryParse(dayMatch.group(1) ?? '');
    final d2 = int.tryParse(dayMatch.group(2) ?? '');
    if (d1 == null || d2 == null || d1 < 1 || d2 < d1) return null;

    var rest = ('${line.substring(0, dayMatch.start)} ${line.substring(dayMatch.end)}')
        .replaceAll(RegExp(r'\([^)]*\)'), ' ') // strip other notes e.g. "(For non-Muslim)"
        .trim();

    // A trailing room number (e.g. "PS Ahsan Jamal (1-2) 47") sits right
    // after the day annotation once it's stripped — pull it out before
    // subject/teacher splitting using the same convention as every other
    // room extraction in this file, or it's left glued onto the teacher
    // name ("Ahsan Jamal 47") instead of a real room: the room is lost,
    // and the corrupted name no longer fuzzy-matches the real teacher.
    var roomNo = '';
    final roomMatch = RegExp(r'\b(\d{2,3})\s*$').firstMatch(rest);
    if (roomMatch != null) {
      roomNo = roomMatch.group(1)!;
      rest = rest.substring(0, roomMatch.start).trim();
    }
    final lower = rest.toLowerCase();

    // Match the FULL word the keyword starts (\w* extension), not just the
    // keyword's own length — "ethic" matching inside "Ethics" must remove
    // the whole word, or the trailing "s" is left glued onto the teacher.
    String? subject;
    int matchStart = -1, matchEnd = -1;
    for (final entry in _combinedSubjects.entries) {
      final m = RegExp(r'\b' + RegExp.escape(entry.key) + r'\w*').firstMatch(lower);
      if (m != null && (matchStart == -1 || m.start < matchStart)) {
        matchStart = m.start; matchEnd = m.end; subject = entry.value;
      }
    }
    if (subject == null) return null; // unrecognised combined-slot subject

    final teacher = ('${rest.substring(0, matchStart)} ${rest.substring(matchEnd)}')
        .replaceAll(RegExp(r'\s+'), ' ').trim();
    if (teacher.isEmpty) return null;

    return ParsedCell(
      teacherName: teacher,
      subjectName: subject,
      roomNo: roomNo,
      days: List<int>.generate(d2 - d1 + 1, (i) => d1 + i),
    );
  }

  // ── Elective block parsing ──────────────────────────────────────────────────
  // A whole different cell shape from everything above: several alternate
  // "Subject: Teacher  Room" options packed into one merged cell, one per
  // line, offered simultaneously in that period — students pick one. No day
  // annotation at all (it's a full-week choice), which is what tells it
  // apart from a combined/split-slot cell.

  /// A cell counts as an elective block once it has several lines and most
  /// of them use the "Subject: Teacher" colon shape — a regular cell is at
  /// most a two-line "Teacher\nSubject" pair, so three-plus lines already
  /// rules that out, and requiring a colon majority avoids misreading an
  /// ordinary multi-teacher cell (blank-line separated, handled earlier by
  /// _splitCellEntries) as an elective block.
  static bool looksLikeElectiveBlock(String raw) {
    final lines = raw.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (lines.length < 3) return false;
    if (lines.any((l) => _combinedDayRe.hasMatch(l))) return false;
    final colonLines = lines.where((l) => l.contains(':')).length;
    return colonLines >= (lines.length / 2).ceil();
  }

  /// Two entries sometimes land on the same `\n`-delimited line, separated
  /// only by column padding (e.g. "Eco A: M. Iqbal   125    Civics A: Kamran
  /// Naveed   131") — split before each subsequent entry: 3+ spaces
  /// followed by a short word run and its own colon.
  static final _secondEntryRe = RegExp(r'\s{3,}(?=[A-Za-z][^:]{0,30}:)');

  /// Parses every recognisable "Subject: Teacher [Room]" line (or same-line
  /// packed entry) in a block. A segment without a colon has no reliable
  /// subject/teacher boundary and is skipped rather than guessed at.
  static List<ParsedElectiveEntry> parseElectiveBlockLines(String raw) {
    final out = <ParsedElectiveEntry>[];
    for (final rawLine in raw.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      for (final segment in line.split(_secondEntryRe)) {
        final colonIdx = segment.indexOf(':');
        if (colonIdx == -1) continue;

        final subject = segment.substring(0, colonIdx).trim();
        var rest = segment.substring(colonIdx + 1).trim();
        if (subject.isEmpty || rest.isEmpty) continue;

        var room = '';
        final roomMatch = RegExp(r'\b(\d{2,3})\s*$').firstMatch(rest);
        if (roomMatch != null) {
          room = roomMatch.group(1)!;
          rest = rest.substring(0, roomMatch.start).trim();
        }
        if (rest.isEmpty) continue;

        out.add(ParsedElectiveEntry(subjectName: subject, teacherName: rest, roomNo: room));
      }
    }
    return out;
  }

  // ── Bachelor-semester "Days column" layout ───────────────────────────────────
  // A different sheet shape (seen in GGC's "BS-V/VII/VIII" files): each row
  // is one Subject+Semester (not class+section), col 2 is the room, and
  // each period has TWO columns — the entries themselves, then a companion
  // column headed "Days" holding one day-range/day-number per entry
  // instead of an inline "(d-d)" annotation. One cell can also hold
  // several simultaneous teacher/lab-group entries (blank-line separated).

  /// True when most detected period columns are immediately followed by a
  /// header cell containing "day" — the regular GGC grid never labels a
  /// column that way, so this is a reliable, low-risk signal.
  static bool looksLikeDaysColumnLayout(List<dynamic> headerRow, List<int> periodCols) {
    if (periodCols.length < 2) return false;
    var matches = 0;
    for (final col in periodCols) {
      final next = col + 1 < headerRow.length ? (headerRow[col + 1]?.toString() ?? '') : '';
      if (next.toLowerCase().contains('day')) matches++;
    }
    return matches >= (periodCols.length / 2).ceil();
  }

  /// Parses one day-marker token — a plain range ("1-3"), a single day
  /// ("4"), or a comma-combined mix of both ("1-2,5" meaning days 1, 2 AND
  /// 5) — parens optional throughout, matching real file variance. Returns
  /// null if any comma-separated part doesn't parse, rather than guessing
  /// a partial set.
  static List<int>? _parseDayToken(String raw) {
    final cleaned = raw.replaceAll('(', '').replaceAll(')', '').trim();
    if (cleaned.isEmpty) return null;
    final days = <int>{};
    for (final part in cleaned.split(',')) {
      final p = part.trim();
      final range = RegExp(r'^(\d)\s*-\s*(\d)$').firstMatch(p);
      if (range != null) {
        final d1 = int.parse(range.group(1)!);
        final d2 = int.parse(range.group(2)!);
        if (d2 < d1) return null;
        for (int d = d1; d <= d2; d++) { days.add(d); }
        continue;
      }
      final single = RegExp(r'^(\d)$').firstMatch(p);
      if (single != null) { days.add(int.parse(single.group(1)!)); continue; }
      return null;
    }
    return days.isEmpty ? null : (days.toList()..sort());
  }

  /// Splits a "Days" companion-column cell into one day-list per content
  /// block, aligned by position with the same period's content cell
  /// (see [_splitCellEntries], reused here for both columns so blank-line
  /// blocks line up 1:1). A block with no parseable day marker returns
  /// null for that slot — callers treat null the same as everywhere else
  /// in this file: default to the full working week.
  static List<List<int>?> parseDaysColumnCell(String raw) =>
      _splitCellEntries(raw).map(_parseDayToken).toList();

  /// Parses one content block from this layout — typically "Teacher
  /// (code)\nCourse Title". No [_shouldSkip] filtering here: that list
  /// only exists to keep the FA/FSc combined-slot cell shape from being
  /// re-parsed as a generic cell, but in this layout subjects like
  /// "Tarjuma-e-Quran" or "Practicals" ARE the payload, not noise.
  // A trailing course-code token on the teacher line shows up both
  // parenthesized ("Razzaq Ahmad (CHEM-346 +347)") and bare ("Taimoor
  // Khan GCCE 101", "Munazza Qari GISL-101 / GETH-101s") — codes are
  // ALL-CAPS-prefixed ("GCCE", "CHEM", "MATH"), unlike Title-Case teacher
  // names, so a 2+ consecutive uppercase-letter run followed by digits is
  // a safe signal a name word never produces on its own.
  // Usually preceded by whitespace, but real cells are inconsistent — one
  // file has "IslV1  GISL-101" (spaced) elsewhere and "IslV1GISL-101"
  // (glued, no space at all) in another row of the very same column —
  // so a code run directly after a digit counts as a boundary too.
  static final _trailingCourseCodeRe =
      RegExp(r'(?:\s+|(?<=\d))[A-Z]{2,6}[-\s]?\d{2,4}[A-Za-z]?.*$');

  static String _stripCourseCode(String line) => line
      .replaceAll(RegExp(r'\([^)]*\)'), '')
      .replaceFirst(_trailingCourseCodeRe, '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static ParsedCell? parseDaysColumnBlock(String block) {
    final lines = block.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return null;

    // The recurring "CTI <n> (<code>) Tarjuma-e-Quran" + room-note pair —
    // same subject the FA/FSc parser already normalises via
    // _combinedSubjects; here the room sits on its own line instead of a
    // "(d-d)" annotation, so it's dropped rather than mistaken for a title.
    if (lines[0].toLowerCase().contains('tarjuma')) {
      final teacher = _stripCourseCode(lines[0]
          .replaceAll(RegExp(r'tarjuma[-\s]*e?[-\s]*quran', caseSensitive: false), ''));
      if (teacher.isEmpty) return null;
      return ParsedCell(teacherName: teacher, subjectName: 'Tarjuma-tul-Quran', roomNo: '');
    }

    // A single line can't be reliably split into teacher vs subject —
    // skip rather than guess, same philosophy as parseElectiveBlockLines.
    if (lines.length < 2) return null;

    final teacher = _stripCourseCode(lines[0]);
    final subject = lines.sublist(1).join(' ').trim();
    if (teacher.isEmpty || subject.isEmpty) return null;
    return ParsedCell(teacherName: teacher, subjectName: subject, roomNo: '');
  }

  /// Row loop for the Days-column layout — every row is self-contained
  /// (Subject+Semester+Room, no carry-forward merge cells), so this is
  /// simpler than the regular Step 4 loop it stands in for.
  static ({int totalCells, int parsedCells}) _parseDaysColumnRows({
    required List<List<dynamic>> rows,
    required int headerRowIdx,
    required List<int> periodCols,
    required int semesterCol, // -1 if this file has no per-row Semester column
    required int roomCol,
    required Set<String> teacherNames,
    required Set<String> subjectNames,
    required Set<({String program, String section})> classSet,
    required Set<String> roomNumbers,
    required List<ParsedAssignmentDraft> assignments,
  }) {
    var totalCells = 0, parsedCells = 0;
    for (int r = headerRowIdx + 1; r < rows.length; r++) {
      final row = rows[r];
      if (row.every((c) => c == null || c.toString().trim().isEmpty)) continue;

      final subjectDept = _cellStr(row, 0);
      final semester    = _cellStr(row, semesterCol); // '' when semesterCol == -1
      final room        = _cellStr(row, roomCol);
      if (subjectDept.isEmpty) continue; // no carry-forward in this layout

      // Same "Program - Section" convention _buildClassName uses for the
      // regular grid layout — the import screen's class-resolution step
      // recovers the section by splitting on " - ", so this has to match.
      final classLabel = semester.isEmpty ? subjectDept : '$subjectDept - $semester';
      classSet.add((program: subjectDept, section: semester));
      if (room.isNotEmpty) roomNumbers.add(room);

      for (int p = 0; p < periodCols.length; p++) {
        final col = periodCols[p];
        final daysCol = col + 1;
        final rawContent = (col < row.length ? row[col]?.toString() : null) ?? '';
        if (rawContent.trim().isEmpty) continue;
        final rawDays = (daysCol < row.length ? row[daysCol]?.toString() : null) ?? '';

        totalCells++;
        final contentBlocks = _splitCellEntries(rawContent);
        final dayLists = parseDaysColumnCell(rawDays);

        for (int i = 0; i < contentBlocks.length; i++) {
          final parsed = parseDaysColumnBlock(contentBlocks[i]);
          if (parsed == null) continue;

          teacherNames.add(parsed.teacherName);
          subjectNames.add(parsed.subjectName);

          assignments.add(ParsedAssignmentDraft(
            teacherName: parsed.teacherName,
            subjectName: parsed.subjectName,
            className:   classLabel,
            programName: subjectDept,
            roomNo:      room,
            periodIndex: p,
            days:        i < dayLists.length ? dayLists[i] : null,
          ));
        }
        if (contentBlocks.isNotEmpty) parsedCells++;
      }
    }
    return (totalCells: totalCells, parsedCells: parsedCells);
  }

  /// Parse one "Teacher\nSubject [RoomNo]" block.
  static ParsedCell? _parseCell(String block) {
    if (block.trim().isEmpty) return null;

    // Combined-slot entries (own day-range annotation) never span multiple
    // lines — check before the skip list, since these subjects are exactly
    // the ones _shouldSkip's prefixes were guarding against re-parsing badly.
    if (!block.contains('\n') && _combinedDayRe.hasMatch(block)) {
      return parseCombinedLine(block);
    }
    if (_shouldSkip(block)) return null;

    final lines = block.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return null;

    // If there's only one line it might be "V1\nComp" that got merged — treat as subject-only
    if (lines.length == 1) {
      // Could be a group-code shorthand like "EngV1", skip
      if (RegExp(r'^[A-Z][a-z]?[A-Z]\d').hasMatch(lines[0])) return null;
      return null; // can't determine teacher vs subject from 1 line
    }

    // lines[0] = teacher name (possibly with room), lines[1] = subject (+ room)
    String teacherRaw = lines[0];
    String subjectRaw = lines.length > 1 ? lines[1] : '';

    // Some cells swap the order (subject first, teacher second)
    // Heuristic: if lines[0] looks like a subject code + name without spaces, flip
    // We detect teacher names by presence of a space (first + last name)

    // Extract trailing room number from teacher or subject (e.g. "M. Asif  134")
    String roomNo = '';
    final roomMatch = RegExp(r'\b(\d{2,3})\s*$').firstMatch(subjectRaw);
    if (roomMatch != null) {
      roomNo     = roomMatch.group(1)!;
      subjectRaw = subjectRaw.substring(0, roomMatch.start).trim();
    }
    final roomMatchT = RegExp(r'\b(\d{2,3})\s*$').firstMatch(teacherRaw);
    if (roomMatchT != null && roomNo.isEmpty) {
      roomNo      = roomMatchT.group(1)!;
      teacherRaw  = teacherRaw.substring(0, roomMatchT.start).trim();
    }

    // A row-level section marker some sheets embed inline (e.g. "Eng A0",
    // after the room above has already been stripped off "Eng A0 51") —
    // see the row loop's rowSection recovery. Strip it here too, or it's
    // left glued onto the course name instead of the section it actually
    // is.
    subjectRaw = subjectRaw.replaceAll(RegExp(r'\s+[A-Za-z]\d{1,2}$'), '').trim();

    // Clean up shorthand subject codes like "EngV1 " → keep just subject name
    subjectRaw = _expandSubject(subjectRaw);

    final teacher = teacherRaw.trim();
    final subject = subjectRaw.trim();

    if (teacher.isEmpty || subject.isEmpty) return null;
    if (_shouldSkip(teacher) || _shouldSkip(subject)) return null;

    return ParsedCell(
      teacherName: teacher,
      subjectName: subject,
      roomNo:      roomNo,
    );
  }

  /// Expand common subject shorthand codes used in GGC files.
  static String _expandSubject(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'\bEngV\d\b'), 'English')
        .replaceAll(RegExp(r'\bIslV\d\b'), 'Islamic Studies')
        .replaceAll(RegExp(r'\bV\d\b'),    '')
        .replaceAll(RegExp(r'\(Even.*?\)', caseSensitive: false), '')
        .replaceAll(RegExp(r'\(Odd.*?\)',  caseSensitive: false), '')
        .trim();
    // Map common abbreviations
    const abbrev = {
      'Eng':   'English',
      'Math':  'Mathematics',
      'Phy':   'Physics',
      'Chem':  'Chemistry',
      'Bio':   'Biology',
      'Urdu':  'Urdu',
      'Comp':  'Computer',
      'Stat':  'Statistics',
      'Eco':   'Economics',
      'Isl':   'Islamic Studies',
      'Pak':   'Pakistan Studies',
    };
    for (final e in abbrev.entries) {
      if (cleaned == e.key) return e.value;
    }
    return cleaned;
  }

  static String _buildClassName(String classLabel, String section) {
    final cls = classLabel.replaceAll('\n', ' ').trim();
    final sec = section.trim();
    if (cls.isEmpty) return '';
    if (sec.isEmpty) return cls;
    return '$cls - $sec';
  }

  static String _cleanProgram(String raw) =>
      raw.replaceAll('\n', ' ').trim();

  // Strips the boilerplate every GGC sheet title shares ("Time Table
  // G.G.C. Sahiwal … w.e.f <date>") down to just the program descriptor in
  // the middle, e.g. "Time Table G.G.C. Sahiwal Arts-I + ICS Part-I (2026)
  // w.e.f 25 August 2026" → "Arts-I + ICS Part-I (2026)". Used only as a
  // last-resort class label when a row's own Class column was never filled.
  static String _titleAsClassFallback(String titleCell) {
    var t = titleCell;
    final wefIdx = t.toLowerCase().indexOf('w.e.f');
    if (wefIdx != -1) t = t.substring(0, wefIdx);
    t = t.replaceAll(RegExp(r'time\s*table', caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'g\.?\s*g\.?\s*c\.?\s*sahiwal', caseSensitive: false), '');
    return t.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // ── 12-hour → 24-hour resolution ────────────────────────────────────────────
  // Timetable headers write bare 12-hour clock with no AM/PM marker —
  // "08:00 - 08:40" for the morning, but "12:00 - 01:00" for noon-to-1pm
  // rather than "12:00 - 13:00". Periods run in strict chronological order
  // across the row, so walking the whole start/end sequence as one
  // monotonic clock and adding 12h the moment a hour would otherwise go
  // backward resolves it correctly without an AM/PM marker to read.
  static List<({int col, String label, String start, String end})>
      resolveAmbiguousHours(
          List<({int col, String label, String start, String end})> times) {
    var offset = 0;
    var lastMin = -1;

    int resolve(String hhmm) {
      final p = hhmm.split(':');
      final h = int.tryParse(p[0]) ?? 0;
      final m = p.length > 1 ? (int.tryParse(p[1]) ?? 0) : 0;
      final rawMin = (h % 12) * 60 + m;
      var candidate = rawMin + offset;
      if (candidate < lastMin) {
        offset += 12 * 60;
        candidate = rawMin + offset;
      }
      lastMin = candidate;
      return candidate;
    }

    String fmt(int mins) {
      final h = (mins ~/ 60).clamp(0, 23);
      final m = mins % 60;
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    }

    return times
        .map((t) => (col: t.col, label: t.label,
            start: fmt(resolve(t.start)), end: fmt(resolve(t.end))))
        .toList();
  }
}
