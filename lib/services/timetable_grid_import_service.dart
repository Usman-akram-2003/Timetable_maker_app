import 'dart:async';
import 'dart:typed_data';
import 'dart:io' show File;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:file_picker/file_picker.dart';
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
  const ParsedCell({
    required this.teacherName,
    required this.subjectName,
    required this.roomNo,
  });
}

class ParsedAssignmentDraft {
  final String teacherName;
  final String subjectName;
  final String className;   // e.g. "F.Sc Part I - Section E"
  final String programName; // e.g. "F.Sc Part I"
  final String roomNo;
  final int    periodIndex; // 0-based index into periods list
  const ParsedAssignmentDraft({
    required this.teacherName,
    required this.subjectName,
    required this.className,
    required this.programName,
    required this.roomNo,
    required this.periodIndex,
  });
}

class TimetableGridImportResult {
  final List<ParsedPeriod>           periods;
  final List<String>                 teacherNames;
  final List<String>                 subjectNames;
  final List<({String program, String section})> classes;
  final List<String>                 roomNumbers;
  final List<ParsedAssignmentDraft>  assignments;
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
    required this.warnings,
    required this.totalCells,
    required this.parsedCells,
    required this.fileName,
    required this.isIntermediate,
  });
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

  /// Opens a file picker, parses the picked file and returns the result.
  /// Returns null if user cancelled or file is unreadable.
  static Future<TimetableGridImportResult?> pickAndParse({
    void Function(double, String)? onProgress,
  }) async {
    final cb = onProgress ?? (_, __) {};

    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'xls', 'ods'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;

    cb(0.05, 'Reading file…');
    await Future.delayed(const Duration(milliseconds: 30));

    final file = result.files.first;
    final fileName = file.name.toLowerCase();

    if (fileName.endsWith('.xls') && !fileName.endsWith('.xlsx')) {
      throw Exception(
        'Old .xls format is not supported.\n\n'
        'Open the file in Excel → File → Save As → Excel Workbook (*.xlsx).',
      );
    }

    final Uint8List bytes;
    if (kIsWeb) {
      if (file.bytes == null) throw Exception('File bytes are null on web.');
      bytes = file.bytes!;
    } else {
      if (file.bytes != null) {
        bytes = file.bytes!;
      } else if (file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      } else {
        throw Exception('Cannot read file.');
      }
    }

    cb(0.1, 'Decoding spreadsheet…');
    await Future.delayed(const Duration(milliseconds: 30));

    SpreadsheetDecoder decoder;
    try {
      decoder = SpreadsheetDecoder.decodeBytes(bytes, update: false);
    } catch (e) {
      throw Exception('Could not decode spreadsheet: $e');
    }

    cb(0.2, 'Parsing timetable grid…');
    await Future.delayed(const Duration(milliseconds: 16));

    final parsed = await _parse(decoder, file.name, cb);
    cb(1.0, 'Complete!');
    return parsed;
  }

  // ── Core parser ─────────────────────────────────────────────────────────────

  static Future<TimetableGridImportResult> _parse(
    SpreadsheetDecoder excel,
    String fileName,
    void Function(double, String) cb,
  ) async {
    // Find the best sheet (the one with actual data)
    SpreadsheetTable? bestSheet;
    int bestRows = 0;
    for (final entry in excel.tables.entries) {
      final s = entry.value;
      if ((s.maxRows) > bestRows) {
        bestRows = s.maxRows;
        bestSheet = s;
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
        // Look for cells containing time patterns like "08:00" or "8:00"
        final match = RegExp(r'(\d{1,2}:\d{2})\s*[-–]\s*(\d{1,2}:\d{2})').firstMatch(cell);
        if (match != null) {
          times.add((col: c, label: cell, start: match.group(1)!, end: match.group(2)!));
        }
      }

      if (times.length >= 3) {
        headerRowIdx = r;
        for (int i = 0; i < times.length; i++) {
          periodCols.add(times[i].col);
          periods.add(ParsedPeriod(
            periodNumber: i + 1,
            startTime: _normalizeTime(times[i].start),
            endTime: _normalizeTime(times[i].end),
            rawLabel: times[i].label,
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
    final titleCell = rows.isNotEmpty ? (rows[0][0]?.toString() ?? '') : '';
    final isIntermediate = !RegExp(r'\bBS\b|\bbachelor', caseSensitive: false).hasMatch(titleCell);

    // ── Step 3: Determine class column positions ──────────────────────────────
    // In GGC format: cols 0-3 are [Class name, (merged), Room No, Section]
    // We'll find "class" and "room" and "section" cols flexibly.
    // For simplicity: class label = col 0 (merge-filled), room = col 2 or 3, section = col 3
    int classCol   = 0;
    int roomCol    = -1;
    int sectionCol = -1;

    // Scan header row for column roles
    final hRow = rows[headerRowIdx];
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
    int totalCells = 0, parsedCells = 0;

    // Carry-forward: in merged cells the class name only appears in the first row
    String carryClass   = '';
    String carrySection = '';
    String carryRoom    = '';

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

      // Skip meta rows (total/summary)
      final secLower = carrySection.toLowerCase();
      if (secLower == 'g.s' || secLower == 'gs') continue;

      // Build class label
      final classLabel = _buildClassName(carryClass, carrySection);
      if (classLabel.isEmpty) continue;

      final programLabel = _cleanProgram(carryClass);
      if (carryRoom.isNotEmpty) roomNumbers.add(carryRoom);

      classSet.add((program: programLabel, section: carrySection));

      // Parse each period cell
      for (int p = 0; p < periodCols.length; p++) {
        final col = periodCols[p];
        if (col >= row.length) continue;
        final raw = row[col]?.toString() ?? '';
        if (raw.trim().isEmpty) continue;

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
          ));
          parsedCells++;
        }

        if (entries.isEmpty && raw.trim().isNotEmpty) {
          warnings.add('Row ${r + 1}, P${p + 1}: Could not parse "${ raw.substring(0, raw.length.clamp(0, 40)) }"');
        }
      }

      await Future.delayed(Duration.zero); // yield to avoid blocking UI
    }

    return TimetableGridImportResult(
      periods:       periods,
      teacherNames:  teacherNames.toList()..sort(),
      subjectNames:  subjectNames.toList()..sort(),
      classes:       classSet.toList(),
      roomNumbers:   roomNumbers.where((r) => r.isNotEmpty).toList()..sort(),
      assignments:   assignments,
      warnings:      warnings,
      totalCells:    totalCells,
      parsedCells:   parsedCells,
      fileName:      fileName,
      isIntermediate: isIntermediate,
    );
  }

  // ── Cell helpers ─────────────────────────────────────────────────────────────

  static String _cellStr(List<dynamic> row, int col) {
    if (col < 0 || col >= row.length) return '';
    return row[col]?.toString().trim() ?? '';
  }

  /// Split a raw cell into individual teacher-course entries.
  /// Cells look like:
  ///   "Ahmad Shah\nChem"                         → 1 entry
  ///   "Isl Uzma Kanwal (1-2)\nTHQ CTI 2 (3-4)"  → skip both (Isl/THQ)
  ///   "M. Asif\nPhy A 134\n\nUmair\nPhy B 135"   → 2 entries
  static List<String> _splitCellEntries(String raw) {
    // Normalise line endings
    final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    // Split on blank lines first (double-newline groups)
    final blocks = text.split(RegExp(r'\n{2,}'));
    if (blocks.length > 1) {
      return blocks.map((b) => b.trim()).where((b) => b.isNotEmpty).toList();
    }
    // Otherwise the whole cell is one entry
    return [text.trim()];
  }

  /// Parse one "Teacher\nSubject [RoomNo]" block.
  static ParsedCell? _parseCell(String block) {
    if (block.trim().isEmpty) return null;
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

  static String _normalizeTime(String t) {
    final parts = t.split(':');
    if (parts.length != 2) return t;
    final h = parts[0].padLeft(2, '0');
    final m = parts[1].padLeft(2, '0');
    return '$h:$m';
  }
}
