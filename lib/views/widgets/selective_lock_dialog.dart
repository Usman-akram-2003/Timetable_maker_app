import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/class_model.dart';
import '../../models/education_level.dart';
import '../../viewmodels/data_entry_viewmodel.dart';
import '../../app_theme.dart';

class SelectiveLockDialog extends StatefulWidget {
  final DataEntryViewModel dataVm;
  const SelectiveLockDialog({super.key, required this.dataVm});
  @override
  State<SelectiveLockDialog> createState() => _SelectiveLockDialogState();
}

class _SelectiveLockDialogState extends State<SelectiveLockDialog> {
  final Set<String> _expandedProgramIds = {};

  bool _isLevelLocked(EducationLevel level) {
    final assignments = widget.dataVm.assignments.where((a) => a.classModel.level == level);
    if (assignments.isEmpty) return false;
    return assignments.every((a) => !a.autoAssigned);
  }

  bool _isProgramLocked(String programId) {
    final assignments = widget.dataVm.assignments.where((a) => a.classModel.programId == programId);
    if (assignments.isEmpty) return false;
    return assignments.every((a) => !a.autoAssigned);
  }

  bool _isClassLocked(String classId) {
    final assignments = widget.dataVm.assignments.where((a) => a.classModel.id == classId);
    if (assignments.isEmpty) return false;
    return assignments.every((a) => !a.autoAssigned);
  }

  Color _ts(bool isDark) => isDark ? AppTheme.textSecondary : AppTheme.lightTextSec;
  Color _tp(bool isDark) => isDark ? AppTheme.textPrimary   : AppTheme.lightText;
  Color _bd(bool isDark) => isDark ? AppTheme.divider       : AppTheme.lightDivider;
  Color _cardBg(bool isDark) => isDark ? AppTheme.bgMid     : const Color(0xFFF8FAFC);

  // ── Level card — icon chip + title + program count + lock switch ───────────
  Widget _buildLevelSection(EducationLevel level, String title, IconData icon, Color color) {
    final isDark   = Theme.of(context).brightness == Brightness.dark;
    final isLocked = _isLevelLocked(level);
    final programs = widget.dataVm.programs.where((p) => p.level == level).toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isLocked ? AppTheme.accentAmber.withValues(alpha: .06) : _cardBg(isDark),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isLocked ? AppTheme.accentAmber.withValues(alpha: .35) : _bd(isDark)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 36, height: 36,
              decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 18, color: color)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: GoogleFonts.plusJakartaSans(fontSize: 14, fontWeight: FontWeight.w800, color: _tp(isDark))),
            Text(programs.isEmpty ? 'No programs yet' : '${programs.length} program${programs.length == 1 ? '' : 's'} · locks the entire level',
                style: GoogleFonts.plusJakartaSans(fontSize: 11, color: _ts(isDark))),
          ])),
          Switch(
            value: isLocked,
            thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppTheme.accentAmber : null),
            onChanged: (val) {
              widget.dataVm.setLockStateForLevel(level, val);
              setState(() {});
            },
          ),
        ]),
        if (programs.isNotEmpty) ...[
          const SizedBox(height: 12),
          ...programs.map((p) => _buildProgramTile(p, color)),
        ],
      ]),
    );
  }

  // ── Program row — nested one level in, own lock switch + expandable classes ─
  Widget _buildProgramTile(ProgramGroup program, Color levelColor) {
    final isDark   = Theme.of(context).brightness == Brightness.dark;
    final isLocked = _isProgramLocked(program.id);
    final classes  = widget.dataVm.classes.where((c) => c.programId == program.id).toList();
    final expanded = _expandedProgramIds.contains(program.id);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: isLocked ? AppTheme.accentAmber.withValues(alpha: .05) : (isDark ? AppTheme.bgDeep : Colors.white),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: isLocked ? AppTheme.accentAmber.withValues(alpha: .3) : _bd(isDark)),
      ),
      child: Column(children: [
        Row(children: [
          if (classes.isNotEmpty)
            IconButton(
              icon: Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  size: 20, color: _ts(isDark)),
              onPressed: () => setState(() {
                if (expanded) { _expandedProgramIds.remove(program.id); }
                else { _expandedProgramIds.add(program.id); }
              }),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            )
          else
            const SizedBox(width: 32),
          Icon(Icons.subdirectory_arrow_right_rounded, size: 14, color: levelColor.withValues(alpha: .6)),
          const SizedBox(width: 8),
          Expanded(child: Text(program.name,
              style: GoogleFonts.plusJakartaSans(fontSize: 13, fontWeight: FontWeight.w700, color: _tp(isDark)))),
          Switch(
            value: isLocked,
            thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppTheme.accentAmber : null),
            onChanged: (val) {
              widget.dataVm.setLockStateForProgram(program.id, val);
              setState(() {});
            },
          ),
        ]),
        if (expanded && classes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 32, bottom: 8),
            child: Column(children: classes.map((c) => _buildClassRow(c, isDark)).toList()),
          ),
      ]),
    );
  }

  // ── Class row — innermost granularity ───────────────────────────────────────
  Widget _buildClassRow(ClassModel cls, bool isDark) {
    final isLocked = _isClassLocked(cls.id);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Icon(Icons.remove_rounded, size: 14, color: _ts(isDark)),
        const SizedBox(width: 4),
        Expanded(child: Text(cls.name,
            style: GoogleFonts.plusJakartaSans(fontSize: 12.5, color: _ts(isDark)))),
        Transform.scale(
          scale: .8,
          child: Switch(
            value: isLocked,
            thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppTheme.accentAmber : null),
            onChanged: (val) {
              widget.dataVm.setLockStateForClass(cls.id, val);
              setState(() {});
            },
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      backgroundColor: isDark ? AppTheme.bgCard : Colors.white,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Container(width: 40, height: 40,
                    decoration: BoxDecoration(
                        color: AppTheme.accentAmber.withValues(alpha: .12), borderRadius: BorderRadius.circular(11)),
                    child: const Icon(Icons.lock_person_rounded, size: 20, color: AppTheme.accentAmber)),
                const SizedBox(width: 12),
                Expanded(child: Text('Selective Lock',
                    style: GoogleFonts.plusJakartaSans(fontSize: 17, fontWeight: FontWeight.w800, color: _tp(isDark)))),
                IconButton(
                  icon: Icon(Icons.close_rounded, size: 20, color: _ts(isDark)),
                  onPressed: () => Navigator.pop(context),
                ),
              ]),
              const SizedBox(height: 6),
              Text('Lock an entire level, a single program, or one class to keep the GA from touching its existing schedule — it will only reshuffle whatever is left unlocked.',
                  style: GoogleFonts.plusJakartaSans(fontSize: 12, color: _ts(isDark), height: 1.5)),
              const SizedBox(height: 18),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(children: [
                    _buildLevelSection(EducationLevel.bachelors, 'Bachelors', Icons.account_balance_rounded, AppTheme.accentViolet),
                    _buildLevelSection(EducationLevel.intermediate, 'Intermediate', Icons.school_rounded, AppTheme.accentTeal),
                  ]),
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accentViolet,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  ),
                  onPressed: () => Navigator.pop(context),
                  child: Text('Done', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
