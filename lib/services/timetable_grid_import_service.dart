import 'dart:typed_data';
import 'dart:io' show File;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:file_picker/file_picker.dart';
import 'package:spreadsheet_decoder/spreadsheet_decoder.dart';
import 'timetable_grid_import_core.dart';

export 'timetable_grid_import_core.dart';

/// Opens a file picker, parses the picked file and returns the result.
/// Returns null if user cancelled or file is unreadable.
///
/// Split out from [TimetableGridImportService] (now in
/// timetable_grid_import_core.dart) so the parser itself has zero Flutter
/// dependencies and can run from a plain `dart run` script — this is the
/// only part of the whole file that needs file_picker/flutter/foundation.
Future<TimetableGridImportResult?> pickAndParseTimetableFile({
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

  final parsed = await TimetableGridImportService.parseDecoder(decoder, file.name, cb);
  cb(1.0, 'Complete!');
  return parsed;
}
