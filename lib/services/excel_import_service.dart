import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:io' show File;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:file_picker/file_picker.dart';
import 'package:spreadsheet_decoder/spreadsheet_decoder.dart';

class ImportOptions {
  final bool departments, teachers, courses, classes, rooms;
  const ImportOptions({
    this.departments = true,
    this.teachers = true,
    this.courses = true,
    this.classes = true,
    this.rooms = true,
  });
}

class ImportResult {
  final int departments, teachers, courses, classes, rooms;
  final List<String> warnings;
  const ImportResult({
    required this.departments,
    required this.teachers,
    required this.courses,
    required this.classes,
    required this.rooms,
    required this.warnings,
  });
}

class ImportData {
  final List<String> departments;
  final List<({String name, String department})> teachers;
  final List<({String name, String code, int creditHours, String level})> courses;
  final List<({String program, String className, String level})> classes;
  final List<({String name})> rooms;
  final List<String> warnings;
  const ImportData({
    required this.departments,
    required this.teachers,
    required this.courses,
    required this.classes,
    required this.rooms,
    required this.warnings,
  });
}

typedef ProgressCallback = void Function(double progress, String step);

class ExcelImportService {
  static Future<ImportData?> pickAndParse({
    ImportOptions options = const ImportOptions(),
    ProgressCallback? onProgress,
  }) async {
    final cb = onProgress ?? (_, __) {};

    try {
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

      // ── Detect unsupported old .xls (BIFF) format ──────────────────────────
      // Only .xlsx and .ods are ZIP-based and can be decoded by spreadsheet_decoder.
      // Old binary .xls cannot be parsed — tell the user to convert it first.
      if (fileName.endsWith('.xls') && !fileName.endsWith('.xlsx')) {
        throw Exception(
          'Old .xls format is not supported.\n\n'
          'To fix: Open the file in Excel → File → Save As → '
          'choose "Excel Workbook (*.xlsx)" → import the new .xlsx file.',
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
          throw Exception('Cannot read file: both bytes and path are null.');
        }
      }

      cb(0.1, 'Decoding spreadsheet…');
      await Future.delayed(const Duration(milliseconds: 30));

      SpreadsheetDecoder decoder;
      try {
        decoder = SpreadsheetDecoder.decodeBytes(bytes, update: false);
      } catch (e) {
        // Give a friendlier message for the common ZIP/format error
        final msg = e.toString();
        if (msg.contains('Central Directory') || msg.contains('ZipException') || msg.contains('FormatException')) {
          throw Exception(
            'Could not read "$fileName".\n\n'
            'Make sure the file is saved as .xlsx (not the old .xls format).\n'
            'In Excel: File → Save As → Excel Workbook (*.xlsx).',
          );
        }
        throw Exception('Could not decode spreadsheet: $e');
      }

      cb(0.2, 'Scanning sheets…');
      await Future.delayed(const Duration(milliseconds: 16));

      final parsed = await _parseAsync(decoder, options, cb);

      cb(1.0, 'Complete!');
      return parsed;
    } catch (e) {
      cb(1.0, 'Error: $e');
      rethrow;
    }
  }


  // ── Core parser ─────────────────────────────────────────────────────────────
  static Future<ImportData> _parseAsync(
      SpreadsheetDecoder excel, ImportOptions options, ProgressCallback cb) async {
    final warnings = <String>[];
    final depts = <String>[];
    final teachers = <({String name, String department})>[];
    final courses = <({String name, String code, int creditHours, String level})>[];
    final classes = <({String program, String className, String level})>[];
    final rooms = <({String name})>[];

    // ── Helpers ───────────────────────────────────────────────────────────────
    List<String> rowStrs(List<dynamic> row) =>
        row.map((c) => c?.toString().toLowerCase().trim() ?? '').toList();

    String getStr(List<dynamic> row, int c) =>
        (c < 0 || c >= row.length) ? '' : (row[c]?.toString().trim() ?? '');

    // Find the column index matching any of the candidate strings (partial match ok)
    int findCol(List<String> headers, List<String> candidates) {
      // Exact match first
      for (final cand in candidates) {
        final i = headers.indexOf(cand);
        if (i != -1) return i;
      }
      // Partial match
      for (final cand in candidates) {
        for (var i = 0; i < headers.length; i++) {
          if (headers[i].contains(cand)) return i;
        }
      }
      return -1;
    }

    // Scan up to 20 rows in a sheet to find the best header row.
    // Returns (headerRowIndex, headerStrings) or null.
    (int, List<String>)? findHeader(SpreadsheetTable sheet, List<String> sigCols) {
      if (sheet.rows.isEmpty) return null;
      int bestRow = -1, bestScore = 0;
      List<String> bestH = [];
      final limit = math.min(20, sheet.rows.length);
      for (int r = 0; r < limit; r++) {
        final h = rowStrs(sheet.rows[r]);
        int score = 0;
        for (final sig in sigCols) {
          if (h.any((c) => c.isNotEmpty && c.contains(sig))) score++;
        }
        if (score > bestScore) {
          bestScore = score;
          bestRow = r;
          bestH = h;
        }
      }
      return bestScore > 0 ? (bestRow, bestH) : null;
    }

    // Find the best sheet by signature columns, with optional name hints for bonus score
    ({SpreadsheetTable sheet, int hRow, List<String> headers})? bestSheet(
        List<String> sigCols, List<String> nameHints) {
      SpreadsheetTable? best;
      int bestHRow = -1;
      List<String> bestH = [];
      int highScore = 0;

      for (final entry in excel.tables.entries) {
        final sheetName = entry.key.toLowerCase().trim();
        final sheet = entry.value;
        if (sheet.rows.isEmpty) continue;

        final header = findHeader(sheet, sigCols);
        if (header == null) continue;

        final (hRow, h) = header;
        int score = 0;
        if (nameHints.any((n) => sheetName.contains(n))) score += 5;
        for (final sig in sigCols) {
          if (h.any((c) => c.isNotEmpty && c.contains(sig))) score += 2;
        }
        if (score > highScore) {
          highScore = score;
          best = sheet;
          bestHRow = hRow;
          bestH = h;
        }
      }
      return highScore > 0 && best != null
          ? (sheet: best, hRow: bestHRow, headers: bestH)
          : null;
    }

    void addDept(String name) {
      final n = name.trim();
      if (n.isNotEmpty && !depts.contains(n)) depts.add(n);
    }

    // ── Smart department cleaner ───────────────────────────────────────────────
    // Handles:
    //   "HOD Arabic"          → ["Arabic"]
    //   "Pol. Sc HOD"         → ["Pol. Sc"]
    //   "HOD Botany / Biology" → ["Botany", "Biology"]
    //   "Arabic+Urdu"         → ["Arabic", "Urdu"]
    //   "Arabic / Urdu"       → ["Arabic", "Urdu"]
    List<String> cleanDepts(String raw) {
      if (raw.trim().isEmpty) return [];
      var cleaned = raw.trim();
      // Remove HOD/HoD/hod from anywhere in the string, along with surrounding spaces/dots/dashes
      cleaned = cleaned.replaceAll(RegExp(r'\bhod\b[\s\.\-]*|[\s\.\-]*\bhod\b', caseSensitive: false), '').trim();
      // Split on either '/' or '+'
      return cleaned
          .split(RegExp(r'[/+]'))
          .map((p) => p.trim())
          .where((p) => p.isNotEmpty)
          .toList();
    }

    // ── Departments (25%) ──────────────────────────────────────────────────────
    cb(0.25, 'Parsing Departments…');
    await Future.delayed(const Duration(milliseconds: 16));

    if (options.departments) {
      // Try a dedicated departments sheet first
      final dRes = bestSheet(
          ['department', 'dept', 'faculty'],
          ['departments', 'dept', 'department', 'faculty', 'faculties']);
      if (dRes != null) {
        final c = findCol(dRes.headers,
            ['department', 'department name', 'faculty', 'name', 'dept']);
        for (var i = dRes.hRow + 1; i < dRes.sheet.rows.length; i++) {
          for (final d in cleanDepts(getStr(dRes.sheet.rows[i], c))) { addDept(d); }
          if (i % 200 == 0) await Future.delayed(Duration.zero);
        }
      }
      // Auto-extract from any sheet's "course" / "department" column
      // (staff lists use "course" to mean the teacher's subject/department)
      for (final entry in excel.tables.entries) {
        final sheet = entry.value;
        final header = findHeader(sheet, ['course', 'subject', 'department', 'dept']);
        if (header == null) continue;
        final (hRow, h) = header;
        final c = findCol(h, [
          'department', 'dept', 'department name',
          'course', 'subject', 'discipline', 'faculty'
        ]);
        if (c < 0) continue;
        for (var i = hRow + 1; i < sheet.rows.length; i++) {
          for (final d in cleanDepts(getStr(sheet.rows[i], c))) { addDept(d); }
          if (i % 200 == 0) await Future.delayed(Duration.zero);
        }
      }
    }

    // ── Teachers (50%) ────────────────────────────────────────────────────────
    cb(0.50, 'Parsing Teachers…');
    await Future.delayed(const Duration(milliseconds: 16));

    if (options.teachers) {
      bool foundAny = false;
      final seenNames = <String>{};

      for (final entry in excel.tables.entries) {
        final sheet = entry.value;
        final header =
            findHeader(sheet, ['teacher', 'name', 'faculty', 'staff', 'instructor']);
        if (header == null) continue;
        final (hRow, h) = header;

        final nc = findCol(h, [
          'teacher name', "teacher's name", 'name', 'full name',
          'teacher', 'instructor', 'faculty', 'staff'
        ]);
        if (nc < 0) continue;

        // "course" column in staff lists = the teacher's subject/department
        final dc = findCol(h, [
          'course', 'subject', 'department', 'dept', 'discipline'
        ]);

        foundAny = true;
        for (var i = hRow + 1; i < sheet.rows.length; i++) {
          var n = getStr(sheet.rows[i], nc);
          if (n.isEmpty) continue;
          // Strip leading serial numbers like "1." "1 " "01."
          n = n.replaceAll(RegExp(r'^\d+[\s\.]+'), '').trim();
          if (n.isEmpty) continue;

          final nameKey = n.toLowerCase();
          if (seenNames.contains(nameKey)) continue; // deduplicate across sheets
          seenNames.add(nameKey);

          // Clean the dept/course field: strip "HOD", split on "/"
          final rawDept = dc >= 0 ? getStr(sheet.rows[i], dc) : '';
          final deptList = cleanDepts(rawDept);

          // Add all extracted dept names to the global dept list
          if (options.departments) {
            for (final d in deptList) { addDept(d); }
          }

          // Store teacher with all departments joined e.g. "Botany / Biology"
          final deptLabel = deptList.join(' / ');
          teachers.add((name: n, department: deptLabel));

          if (i % 200 == 0) await Future.delayed(Duration.zero);
        }
      }
      if (!foundAny) {
        warnings.add(
            'Teachers not found — no sheet has a "Teacher Name" or "Name" column.');
      }
    }

    // ── Courses (90%) ─────────────────────────────────────────────────────────
    cb(0.90, 'Parsing Courses…');
    await Future.delayed(const Duration(milliseconds: 16));

    if (options.courses) {
      final res = bestSheet(
          ['course name', 'subject name', 'credit', 'course code', 'level', 'intermediate', 'bachelor'],
          ['courses', 'course', 'subjects', 'subject', 'data', 'curriculum']);
      if (res != null) {
        final nc = findCol(res.headers, [
          'course name', 'cname', 'name', 'subject name', 'course', 'subject', 'title'
        ]);
        final cc = findCol(res.headers,
            ['course code', 'coursecode', 'ccode', 'cc', 'code', 'subject code', 'short code']);
        final cr = findCol(res.headers, [
          'credit hours', 'creditHours', 'crhr', 'cr', 'ch', 'credits', 'credit', 'hours', 'credit hour'
        ]);
        final lc = findCol(res.headers, [
          'level', 'type', 'education level', 'class level', 'intermediate', 'bachelor',
          'programme', 'program', 'category'
        ]);

        // Helper: map a cell value to 'intermediate' or 'bachelors'
        String parseLevel(String raw) {
          final v = raw.toLowerCase().trim();
          if (v == 'i' || v == 'int' || v == 'inter' || v == 'intermediate' ||
              v == 'fsc' || v == 'f.sc' || v == 'ics' || v == 'icom' ||
              v == 'hssc' || v == 'h.s.s.c') { return 'intermediate'; }
          if (v == 'b' || v == 'bach' || v == 'bachelor' || v == 'bachelors' ||
              v == 'bs' || v == 'bsc' || v == 'b.s' || v == 'b.sc' ||
              v == 'degree' || v == 'honors') { return 'bachelors'; }
          return ''; // unknown — will be imported as both or defaulted later
        }

        for (var i = res.hRow + 1; i < res.sheet.rows.length; i++) {
          final n = getStr(res.sheet.rows[i], nc);
          if (n.isEmpty) continue;
          final raw = cc >= 0 ? getStr(res.sheet.rows[i], cc) : '';
          final code = raw.isNotEmpty
              ? raw
              : n.substring(0, math.min(n.length, 6)).toUpperCase();
          final c =
              int.tryParse(cr >= 0 ? getStr(res.sheet.rows[i], cr) : '') ?? 3;
          final lvl = lc >= 0 ? parseLevel(getStr(res.sheet.rows[i], lc)) : '';
          courses.add((name: n, code: code, creditHours: c.clamp(1, 6), level: lvl));
          if (i % 200 == 0) await Future.delayed(Duration.zero);
        }
      } else {
        warnings.add(
            'Courses not found — add a sheet with columns: "Course Name", "Code", "Credit Hours", "Level".');
      }
    }

    // ── Classes (95%) ──────────────────────────────────────────────────────────
    cb(0.95, 'Parsing Classes…');
    await Future.delayed(const Duration(milliseconds: 16));

    if (options.classes) {
      // Helper: same level parser as courses
      String parseLevel(String raw) {
        final v = raw.toLowerCase().trim();
        if (v == 'i' || v == 'int' || v == 'inter' || v == 'intermediate' ||
            v == 'fsc' || v == 'f.sc' || v == 'ics' || v == 'icom' ||
            v == 'hssc' || v == 'h.s.s.c') { return 'intermediate'; }
        if (v == 'b' || v == 'bach' || v == 'bachelor' || v == 'bachelors' ||
            v == 'bs' || v == 'bsc' || v == 'b.s' || v == 'b.sc' ||
            v == 'degree' || v == 'honors') { return 'bachelors'; }
        return '';
      }

      final res = bestSheet(
          ['program', 'class', 'section', 'level'],
          ['classes', 'class', 'sections', 'section', 'programmes', 'programs']);
      if (res != null) {
        final pc = findCol(res.headers, [
          'program name', 'program', 'programme', 'prog', 'department', 'faculty'
        ]);
        final clc = findCol(res.headers, [
          'class name', 'class', 'section', 'section name', 'name'
        ]);
        final lc = findCol(res.headers, [
          'level', 'type', 'education level', 'class level',
          'intermediate', 'bachelor', 'programme', 'category'
        ]);

        if (pc >= 0 && clc >= 0) {
          for (var i = res.hRow + 1; i < res.sheet.rows.length; i++) {
            final prog = getStr(res.sheet.rows[i], pc);
            final cls  = getStr(res.sheet.rows[i], clc);
            if (prog.isEmpty || cls.isEmpty) continue;
            final lvl = lc >= 0 ? parseLevel(getStr(res.sheet.rows[i], lc)) : '';
            classes.add((program: prog, className: cls, level: lvl));
            if (i % 200 == 0) await Future.delayed(Duration.zero);
          }
        } else {
          warnings.add(
              'Classes not found — add a sheet with columns: "Program Name", "Class Name", "Level".');
        }
      }
    }

    // ── Rooms (98%) ────────────────────────────────────────────────────────────
    cb(0.98, 'Parsing Rooms…');
    await Future.delayed(const Duration(milliseconds: 16));

    if (options.rooms) {
      final res = bestSheet(
          ['room', 'hall', 'lab', 'room no'],
          ['rooms', 'room', 'halls', 'labs']);
      if (res != null) {
        final rnc = findCol(res.headers, [
          'room no', 'room name', 'room', 'room number', 'name', 'hall', 'lab'
        ]);

        if (rnc >= 0) {
          for (var i = res.hRow + 1; i < res.sheet.rows.length; i++) {
            final name = getStr(res.sheet.rows[i], rnc);
            if (name.isEmpty) continue;
            rooms.add((name: name));
            if (i % 200 == 0) await Future.delayed(Duration.zero);
          }
        } else {
          warnings.add('Rooms not found — add a sheet with a "Room No" column.');
        }
      }
    }

    return ImportData(
      departments: depts,
      teachers: teachers,
      courses: courses,
      classes: classes,
      rooms: rooms,
      warnings: warnings,
    );
  }
}
