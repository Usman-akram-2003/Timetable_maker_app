import 'package:flutter_test/flutter_test.dart';
import 'package:timetable_maker_app/services/timetable_grid_import_service.dart';

void main() {
  group('resolveAmbiguousHours', () {
    test('resolves a real GGC header row, including the noon wraparound', () {
      final times = [
        (col: 3, label: '1 (08:00 - 08:40)', start: '08:00', end: '08:40'),
        (col: 5, label: '2 (08:40 - 09:20)', start: '08:40', end: '09:20'),
        (col: 7, label: '6 (11:20 - 12:00)', start: '11:20', end: '12:00'),
        (col: 9, label: '7+8 (12:00 - 01:00)', start: '12:00', end: '01:00'),
      ];
      final resolved = TimetableGridImportService.resolveAmbiguousHours(times);
      expect(resolved[0].start, '08:00');
      expect(resolved[2].end, '12:00');
      // The bug: "01:00" (meaning 1pm) must resolve to 13:00, not stay 01:00.
      expect(resolved[3].start, '12:00');
      expect(resolved[3].end, '13:00');
    });

    test('leaves an all-morning header untouched', () {
      final times = [
        (col: 0, label: '', start: '08:00', end: '08:45'),
        (col: 1, label: '', start: '08:45', end: '09:30'),
        (col: 2, label: '', start: '09:30', end: '10:15'),
      ];
      final resolved = TimetableGridImportService.resolveAmbiguousHours(times);
      expect(resolved.map((t) => t.start), ['08:00', '08:45', '09:30']);
      expect(resolved.map((t) => t.end), ['08:45', '09:30', '10:15']);
    });
  });

  group('detectLevel', () {
    test('Intermediate program names vote Intermediate', () {
      final classes = {
        (program: 'F.Sc Part 1', section: 'M'),
        (program: 'ICS Part 1', section: 'C1'),
      };
      expect(TimetableGridImportService.detectLevel(classes, ''), isTrue);
    });

    test('Bachelor program names vote Bachelors', () {
      final classes = {
        (program: 'BS Semester 1', section: 'CS A'),
        (program: 'BA Semester 3', section: 'A'),
      };
      expect(TimetableGridImportService.detectLevel(classes, ''), isFalse);
    });

    test('falls back to the title cell when no class name matches either convention', () {
      final classes = {(program: 'Unlabelled', section: 'X')};
      expect(TimetableGridImportService.detectLevel(classes, 'BS Timetable'), isFalse);
      expect(TimetableGridImportService.detectLevel(classes, 'GGC Timetable'), isTrue);
    });
  });

  group('parseCombinedLine', () {
    test('subject-then-teacher ordering, with a day range', () {
      final cell = TimetableGridImportService.parseCombinedLine('Isl Munazza Qari (1-2)');
      expect(cell, isNotNull);
      expect(cell!.subjectName, 'Islamiat');
      expect(cell.teacherName, 'Munazza Qari');
      expect(cell.days, [1, 2]);
    });

    test('teacher-then-subject ordering, with a parenthetical note', () {
      final cell = TimetableGridImportService
          .parseCombinedLine('Awan Qamar Ethics (For non-Muslim) (1-2)');
      expect(cell, isNotNull);
      expect(cell!.subjectName, 'Ethics');
      expect(cell.teacherName, 'Awan Qamar');
      expect(cell.days, [1, 2]);
    });

    test('a plain "Teacher\\nSubject" line has no day annotation and is not touched', () {
      expect(TimetableGridImportService.parseCombinedLine('Ahmad Shah'), isNull);
    });
  });

  group('looksLikeElectiveBlock', () {
    test('a real elective block (colon-majority, 3+ lines, no day annotation)', () {
      const cell = 'Edu A: Dr. Irfan   49\n'
          'Eco A: Robina Anwar   50\n'
          'Physical Edu B: Visiting S.P\n'
          'Civics A: Taimoor Khhan   51\n'
          'Sociology: Nabila Ikram   22\n'
          'Islamiat Elective (A): IslV2   59';
      expect(TimetableGridImportService.looksLikeElectiveBlock(cell), isTrue);
    });

    test('a regular two-line "Teacher\\nSubject" cell is not an elective block', () {
      expect(TimetableGridImportService.looksLikeElectiveBlock('Ahmad Shah\nChem'), isFalse);
    });

    test('a combined/split-slot cell (day annotations) is not an elective block', () {
      const cell = 'Isl Munazza Qari (1-2)\nAwan Qamar Ethics (1-2)\nTHQ M Zakariye (3-4)';
      expect(TimetableGridImportService.looksLikeElectiveBlock(cell), isFalse);
    });
  });

  group('parseElectiveBlockLines', () {
    test('parses every colon line, extracting trailing numeric rooms', () {
      const cell = 'Punjabi A: Amer Ghafar   51\n'
          'Geogrpahy: Qasim Ali   22\n'
          'Psychology: Atiq kamboh   Lib\n'
          'Physical Edu A M Fayyaz Saleemi   SP'; // no colon — must be skipped
      final entries = TimetableGridImportService.parseElectiveBlockLines(cell);
      expect(entries.length, 3);
      expect(entries[0].subjectName, 'Punjabi A');
      expect(entries[0].teacherName, 'Amer Ghafar');
      expect(entries[0].roomNo, '51');
      expect(entries[1].subjectName, 'Geogrpahy');
      expect(entries[1].roomNo, '22');
      // Non-numeric room label ("Lib") isn't extracted — stays part of the
      // teacher text, same limitation as the existing regular-cell parser.
      expect(entries[2].teacherName, 'Atiq kamboh   Lib');
      expect(entries[2].roomNo, '');
    });

    test('splits two entries packed onto one line by column padding', () {
      // Real cell content from FA+ ICS I Part 1-1.xlsx (period 3, row 2):
      // "Eco A:" and "Civics A:" share a \n-delimited line with no
      // separator other than whitespace padding.
      const line = 'Eco A: M. Iqbal                           125    '
          'Civics A: Kamran Naveed          131';
      final entries = TimetableGridImportService.parseElectiveBlockLines(line);
      expect(entries.length, 2);
      expect(entries[0].subjectName, 'Eco A');
      expect(entries[0].teacherName, 'M. Iqbal');
      expect(entries[0].roomNo, '125');
      expect(entries[1].subjectName, 'Civics A');
      expect(entries[1].teacherName, 'Kamran Naveed');
      expect(entries[1].roomNo, '131');
    });
  });

  group('real elective block from FA+ ICS I Part 1-1.xlsx', () {
    // Captured verbatim from the source file's row 2, periods 3-5 — used
    // to prove detection+parsing works on this exact real-world shape even
    // though the source file is no longer available on disk to re-probe.
    const period3 = 'Edu A: Ms. Sobia                         13\n'
        'Eco A: M. Iqbal                           125    Civics A: Kamran Naveed          131\n'
        'Civics B: Jamshed Faraz             132\n'
        'Islamiat  (A):Hafiz Samiullah       60         History M. Mukarram              Library\n';
    const period4 = 'Edu B: Ms. Sobia                 132\n'
        'Eco B: Robina Anwar            131\n'
        'Physical Edu A: M. Imran      S.P\n'
        'Civics C: Hussain Mohsin        58\n'
        'Sociology: Malik Iftikhar         28\n'
        'Islamiat Elective (B): Ayube Sabir Library';
    const period5 = 'Physical Edu B Qamar Javed   SP\n'
        'Punjabi A: Amer Ghafar         58\n'
        'Punjabi B:  Ahmad Nawaz     131\n'
        'Geogrpahy: Ahsan Jamal         22\n'
        'Arabic: M Ikhlaq                132\n'
        'Philosophy: Shazaib              60\n'
        'Psychology: Aleena Library\n'
        'Stat: Saeed Shah                  54\n'
        'Library Science: M. Raheel Library';

    test('all three period cells are detected as elective blocks', () {
      expect(TimetableGridImportService.looksLikeElectiveBlock(period3.trim()), isTrue);
      expect(TimetableGridImportService.looksLikeElectiveBlock(period4.trim()), isTrue);
      expect(TimetableGridImportService.looksLikeElectiveBlock(period5.trim()), isTrue);
    });

    test('the packed Eco A / Civics A line splits into two entries', () {
      final entries = TimetableGridImportService.parseElectiveBlockLines(period3);
      final subjects = entries.map((e) => e.subjectName).toList();
      expect(subjects, containsAll(['Edu A', 'Eco A', 'Civics A', 'Civics B']));
      final ecoA = entries.firstWhere((e) => e.subjectName == 'Eco A');
      expect(ecoA.teacherName, 'M. Iqbal');
      expect(ecoA.roomNo, '125');
      final civicsA = entries.firstWhere((e) => e.subjectName == 'Civics A');
      expect(civicsA.teacherName, 'Kamran Naveed');
      expect(civicsA.roomNo, '131');
    });

    test('period 5 skips the one colon-less line and parses the rest', () {
      final entries = TimetableGridImportService.parseElectiveBlockLines(period5);
      // "Physical Edu B Qamar Javed   SP" has no colon and is skipped.
      expect(entries.length, 8);
      expect(entries.any((e) => e.subjectName == 'Punjabi A'), isTrue);
      expect(entries.any((e) => e.subjectName == 'Stat'), isTrue);
    });
  });

  group('teacherNamesMatch', () {
    test('abbreviated first name matches the full name', () {
      expect(TimetableGridImportService.teacherNamesMatch('Muhammad Nawaz', 'M Nawaz'), isTrue);
      expect(TimetableGridImportService.teacherNamesMatch('Muhammad Nawaz', 'M. Nawaz'), isTrue);
    });

    test('a title prefix is ignored', () {
      expect(TimetableGridImportService.teacherNamesMatch('Muhammad Nawaz', 'Dr. M Nawaz'), isTrue);
    });

    test('same surname, different initial does not match', () {
      expect(TimetableGridImportService.teacherNamesMatch('Ahmad Khan', 'M Khan'), isFalse);
    });

    test('different surname does not match even with matching first name', () {
      expect(TimetableGridImportService.teacherNamesMatch('Muhammad Nawaz', 'Muhammad Ashraf'), isFalse);
    });

    test('exact match', () {
      expect(TimetableGridImportService.teacherNamesMatch('Ahmad Shah', 'Ahmad Shah'), isTrue);
    });
  });

  group('looksLikeDaysColumnLayout (BS-V/VII/VIII files)', () {
    test('a real BS-file header (period col immediately followed by "Days") is detected', () {
      final header = ['Subject', 'Semester', 'Room No',
          '0\r\n10:-00 - 11:00', 'Days',
          '1\r\n(11:30 - 12:30)', 'Days',
          '2\r\n(12:30 - 1:30)', 'Days',
          '3\r\n(1:30 - 2:30)', 'Days', ''];
      // Period 0's malformed "10:-00" time never matches the header-time
      // regex, so only cols 5, 7, 9 are ever passed in as periodCols.
      expect(TimetableGridImportService.looksLikeDaysColumnLayout(header, [5, 7, 9]), isTrue);
    });

    test('a regular FA/FSc-style header is not detected as this layout', () {
      final header = ['Class', '', 'Room', 'Section',
          '1 (08:00 - 08:40)', '2 (08:40 - 09:20)', '3 (09:20 - 10:00)'];
      expect(TimetableGridImportService.looksLikeDaysColumnLayout(header, [4, 5, 6]), isFalse);
    });
  });

  group('parseDaysColumnCell', () {
    test('splits a two-entry days cell into two ranges, aligned by position', () {
      const cell = '(1-3)\r\n\r\n\r\n\r\n\r\n(4-6)';
      final result = TimetableGridImportService.parseDaysColumnCell(cell);
      expect(result, [[1, 2, 3], [4, 5, 6]]);
    });

    test('a lone bare digit (no parens) is one single-day entry', () {
      expect(TimetableGridImportService.parseDaysColumnCell('\r\n1'), [[1]]);
    });

    test('a lone parenthesized digit is also one single-day entry', () {
      // Real cell from BS I (2026-30).xlsx: "(1-3)\r\n\r\n\r\n(4)\r\n\r\n"
      const cell = '(1-3)\r\n\r\n\r\n(4)\r\n\r\n';
      expect(TimetableGridImportService.parseDaysColumnCell(cell), [[1, 2, 3], [4]]);
    });

    test('a comma-combined range+day token parses to the union', () {
      // Real cell from the Stat row: "(1-2,5)".
      expect(TimetableGridImportService.parseDaysColumnCell('(1-2,5)'), [[1, 2, 5]]);
    });
  });

  group('parseDaysColumnBlock', () {
    test('teacher-then-subject with a trailing course code in parens', () {
      const block = 'Razzaq Ahmad (CHEM-346 +347)\n'
          'Chromatographic Techniques-I + Basic Chromatographic Techniques (Lab)';
      final cell = TimetableGridImportService.parseDaysColumnBlock(block);
      expect(cell, isNotNull);
      expect(cell!.teacherName, 'Razzaq Ahmad');
      expect(cell.subjectName,
          'Chromatographic Techniques-I + Basic Chromatographic Techniques (Lab)');
    });

    test('the recurring "CTI n (code) Tarjuma-e-Quran / room" pair', () {
      const block = 'CTI 5 (HQ-005) Tarjuma-e-Quran\nBasement';
      final cell = TimetableGridImportService.parseDaysColumnBlock(block);
      expect(cell, isNotNull);
      expect(cell!.teacherName, 'CTI 5');
      expect(cell.subjectName, 'Tarjuma-tul-Quran');
    });

    test('a single line with no teacher/subject boundary is skipped', () {
      expect(TimetableGridImportService.parseDaysColumnBlock('Some unparseable note'), isNull);
    });

    test('a trailing course code with NO parens is also stripped', () {
      // Real cell from BS I (2026-30).xlsx.
      const block = 'Taimoor Khan GCCE 101\nCivics and Community Engagement';
      final cell = TimetableGridImportService.parseDaysColumnBlock(block);
      expect(cell, isNotNull);
      expect(cell!.teacherName, 'Taimoor Khan');
    });

    test('a compound bare course code ("CODE1 / CODE2") is fully stripped', () {
      const block = 'Munazza Qari GISL-101 / GETH-101s\n'
          'Islamic Studies / Ethics (for Non-Muslims';
      final cell = TimetableGridImportService.parseDaysColumnBlock(block);
      expect(cell, isNotNull);
      expect(cell!.teacherName, 'Munazza Qari');
    });

    test('a short teacher identifier like "CTI 5" is not mistaken for a code', () {
      final cell = TimetableGridImportService.parseDaysColumnBlock(
          'CTI 6(CC-313)\nAnalysis of Algorithms');
      expect(cell, isNotNull);
      expect(cell!.teacherName, 'CTI 6');
    });
  });

  group('detectLevel on a real BS-file (sheet-name fallback signal)', () {
    test('bare department program names carry no signal — falls back to sheet name', () {
      final classes = {
        (program: 'Chemistry', section: 'V'),
        (program: 'Mathematics', section: 'VII'),
        (program: 'Urdu', section: 'VIII'),
      };
      // Real title cell for this file is just "Subject" (the header row
      // doubles as row 0, no separate title) — level only comes through
      // via the sheet/tab name, "BS-V Time Table".
      expect(TimetableGridImportService.detectLevel(classes, 'Subject BS-V Time Table'), isFalse);
    });
  });

  group('courseNamesMatch', () {
    test('a short form matches the full subject name in either direction', () {
      expect(TimetableGridImportService.courseNamesMatch('Mathematics', 'Math'), isTrue);
      expect(TimetableGridImportService.courseNamesMatch('Math', 'Mathematics'), isTrue);
    });

    test('short (<3 char) names only match exactly, never by prefix', () {
      expect(TimetableGridImportService.courseNamesMatch('PS', 'Pakistan Studies'), isFalse);
      expect(TimetableGridImportService.courseNamesMatch('PS', 'PS'), isTrue);
    });

    test('unrelated subjects do not match', () {
      expect(TimetableGridImportService.courseNamesMatch('Physics', 'Chemistry'), isFalse);
    });
  });
}
