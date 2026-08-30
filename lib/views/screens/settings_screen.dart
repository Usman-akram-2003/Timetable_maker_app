import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
  import '../../viewmodels/settings_viewmodel.dart';
  import '../../viewmodels/theme_viewmodel.dart';
  import '../../viewmodels/data_entry_viewmodel.dart';
  import '../../viewmodels/auth_viewmodel.dart';
  import '../../viewmodels/allocator_viewmodel.dart';
  import '../../models/time_slot_lock.dart';
  import '../../models/combined_rule.dart';
  import '../../models/education_level.dart';
  import '../../models/course.dart';
  import '../../models/class_model.dart';
  import '../../models/time_slot.dart';
  import '../../models/shift_rule.dart';
  import '../../app_theme.dart';
  import '../../utils/responsive.dart';
  import '../widgets/selective_lock_dialog.dart';
  import '../widgets/search_dropdown.dart';

extension _StTh on BuildContext {
  bool  get _dk => Theme.of(this).brightness == Brightness.dark;
  Color get _tp => _dk ? AppTheme.textPrimary    : AppTheme.lightText;
  Color get _ts => _dk ? AppTheme.textSecondary  : AppTheme.lightTextSec;
  Color get _bg => _dk ? AppTheme.bgCard         : Colors.white;
  Color get _bd => _dk ? AppTheme.divider        : AppTheme.lightDivider;
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final vm      = context.watch<SettingsViewModel>();
    final themeVm = context.watch<ThemeViewModel>();
    final dataVm  = context.watch<DataEntryViewModel>();
    final hp      = context.hPad;
    final isDark  = context._dk;
    final locked  = vm.scheduleLocked;
    final hasRules = dataVm.timeSlotLocks.isNotEmpty || dataVm.combinedRules.isNotEmpty;
    final canRun  = hasRules && !locked;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: EdgeInsets.fromLTRB(hp, 44, hp, 40),
            children: [

              // ── Header ─────────────────────────────────────────────────
              Row(children: [
                Container(width: 48, height: 48,
                  decoration: BoxDecoration(
                    gradient: AppTheme.tealGradient,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [BoxShadow(color: AppTheme.accentTeal.withValues(alpha: .4),
                        blurRadius: 18, offset: const Offset(0, 5))]),
                  child: const Icon(LucideIcons.settings2, color: Colors.white, size: 24)),
                const SizedBox(width: 16),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Settings', style: GoogleFonts.plusJakartaSans(
                      fontSize: 24, fontWeight: FontWeight.w800,
                      color: context._tp, letterSpacing: -0.5)),
                  Text('The controls that matter most, up front',
                      style: GoogleFonts.plusJakartaSans(fontSize: 13, color: context._ts)),
                ]),
              ]),

              const SizedBox(height: 24),

              // ── Hero: Schedule Lock ──────────────────────────────────────
              _ScheduleLockHero(vm: vm),

              const SizedBox(height: 16),

              // ── Two gradient stat-sliders ─────────────────────────────────
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _GradientStatSlider(
                  icon: LucideIcons.calendarDays,
                  gradient: const [AppTheme.accentCyan, Color(0xFF0891B2)],
                  value: '${vm.workingDays}',
                  label: 'WORKING DAYS / WEEK',
                  sliderValue: vm.workingDays.toDouble(),
                  min: 5, max: 6, divisions: 1,
                  onChanged: (v) => vm.setWorkingDays(v.round()),
                ),
                const SizedBox(width: 14),
                _GradientStatSlider(
                  icon: LucideIcons.ruler,
                  gradient: const [Color(0xFFF97316), Color(0xFFEA580C)],
                  value: '${vm.workloadTolerance.toStringAsFixed(2)}h',
                  label: 'BALANCED TOLERANCE',
                  sliderValue: vm.workloadTolerance,
                  min: 0, max: 3, divisions: 12,
                  onChanged: (v) => vm.setWorkloadTolerance(v),
                ),
              ]),

              const SizedBox(height: 16),

              // ── List card: Dark Mode, Schedule Quality, 3 accordions ───────
              _card(context, padding: EdgeInsets.zero, child: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
                  child: _ToggleRow(
                    icon: isDark ? LucideIcons.moon : LucideIcons.sun,
                    iconColor: AppTheme.accentCyan,
                    title: 'Dark Mode',
                    subtitle: isDark ? 'Dark theme is active' : 'Light theme is active',
                    value: isDark,
                    context: context,
                    onChanged: (_) => themeVm.toggle(),
                  ),
                ),
                Divider(color: context._bd, height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Container(width: 34, height: 34,
                          decoration: BoxDecoration(color: AppTheme.accentAmber.withValues(alpha: .12),
                              borderRadius: BorderRadius.circular(10)),
                          child: const Icon(LucideIcons.zap, size: 17, color: AppTheme.accentAmber)),
                      const SizedBox(width: 14),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Schedule Quality', style: GoogleFonts.plusJakartaSans(
                            fontSize: 13, fontWeight: FontWeight.w700, color: context._tp)),
                        Text('Higher quality takes more time to generate', style: GoogleFonts.plusJakartaSans(
                            fontSize: 11, color: context._ts)),
                      ])),
                    ]),
                    const SizedBox(height: 12),
                    Row(children: [
                      _QualityChip('Fast',    50,  200, vm, context),
                      const SizedBox(width: 8),
                      _QualityChip('Normal',  300, 600, vm, context),
                      const SizedBox(width: 8),
                      _QualityChip('Best',    600, 1500, vm, context),
                    ]),
                  ]),
                ),
                Divider(color: context._bd, height: 1),
                _CollapsibleSection(
                  flush: true, showDivider: true,
                  icon: LucideIcons.clock,
                  label: 'Time Slot Constraints',
                  color: locked ? const Color(0xFFEF4444) : AppTheme.accentAmber,
                  badgeCount: dataVm.timeSlotLocks.length,
                  lockedMessage: locked
                      ? 'Schedule is locked. Unlock in settings to modify constraints.'
                      : null,
                  child: const _TimeSlotLocksSection(),
                ),
                _CollapsibleSection(
                  flush: true, showDivider: true,
                  icon: LucideIcons.link2,
                  label: 'Combined Courses',
                  color: locked ? const Color(0xFFEF4444) : AppTheme.accentBlue,
                  badgeCount: dataVm.combinedRules.length,
                  lockedMessage: locked
                      ? 'Schedule is locked. Unlock in settings to modify combined courses.'
                      : null,
                  child: const _CombinedCoursesSection(),
                ),
                Builder(builder: (ctx) {
                  final existingClassIds = dataVm.classes.map((c) => c.id).toSet();
                  final activeShiftRules = dataVm.shiftRules
                      .where((r) => existingClassIds.contains(r.classId)).length;
                  return _CollapsibleSection(
                    flush: true, showDivider: false,
                    icon: LucideIcons.sunMoon,
                    label: 'Manage Shifts',
                    color: const Color(0xFFF97316),
                    badgeCount: activeShiftRules,
                    child: const _ManageShiftsSection(),
                  );
                }),
              ])),

              const SizedBox(height: 14),

              // ── Re-Apply All Rules ─────────────────────────────────────────
              GestureDetector(
                onTap: canRun ? () {
                  final moved = context.read<DataEntryViewModel>().reApplyAllRules();
                  final msg = moved > 0
                      ? 'Re-applied! $moved assignment${moved == 1 ? "" : "s"} updated.'
                      : 'All assignments already satisfy the current rules.';
                  final color = moved > 0 ? const Color(0xFF16A34A) : const Color(0xFF0284C7);
                  _showStyledSnackBar(context, msg, color);
                } : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    gradient: canRun ? AppTheme.tealGradient : null,
                    color: canRun ? null : const Color(0xFF6B7280).withValues(alpha: .15),
                    boxShadow: canRun ? [BoxShadow(
                        color: AppTheme.accentTeal.withValues(alpha: .35),
                        blurRadius: 14, offset: const Offset(0, 5))] : null,
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(LucideIcons.refreshCw, color: canRun ? Colors.white : Colors.grey, size: 17),
                    const SizedBox(width: 8),
                    Text('Re-Apply All Constraints & Combined Rules',
                        style: GoogleFonts.plusJakartaSans(
                            color: canRun ? Colors.white : Colors.grey,
                            fontWeight: FontWeight.w700, fontSize: 13.5)),
                  ]),
                ),
              ),

              const SizedBox(height: 16),

              // ── Sync to Student App ─────────────────────────────────────
              Builder(builder: (ctx) {
                final v = ctx.watch<DataEntryViewModel>();
                final n = v.syncAll ? v.classes.length : v.syncClassIds.length;
                return _CollapsibleSection(
                  icon: LucideIcons.filter,
                  label: 'Sync Selection',
                  color: AppTheme.accentTeal,
                  badgeCount: n,
                  child: const _SyncSelectionSection(),
                );
              }),

              const SizedBox(height: 14),

              const _PublishCard(),

              const SizedBox(height: 16),

              // ── Account list card ───────────────────────────────────────
              _card(context, padding: EdgeInsets.zero, child: Column(children: [
                Builder(builder: (context) {
                  final email = context.watch<AuthViewModel>().currentUser?.email;
                  if (email == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                    child: Row(children: [
                      Icon(LucideIcons.mail, size: 17, color: context._ts),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(email,
                            style: GoogleFonts.plusJakartaSans(
                                fontSize: 13.5, fontWeight: FontWeight.w600,
                                color: context._tp)),
                      ),
                    ]),
                  );
                }),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                  child: Row(children: [
                    Expanded(child: const _BackupBtn()),
                    const SizedBox(width: 10),
                    Expanded(child: const _RestoreBtn()),
                  ]),
                ),
              ])),

              const SizedBox(height: 10),

              GestureDetector(
                onTap: () => context.read<AuthViewModel>().signOut(),
                child: Container(
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    gradient: const LinearGradient(colors: [Color(0xFFEF4444), Color(0xFFDC2626)]),
                    boxShadow: [BoxShadow(color: const Color(0xFFEF4444).withValues(alpha: .3), blurRadius: 12, offset: const Offset(0, 4))],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(LucideIcons.logOut, color: Colors.white, size: 17),
                      const SizedBox(width: 8),
                      Text('Sign Out',
                          style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.bold, fontSize: 13.5,
                              color: Colors.white)),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // ── Danger Zone ────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.error.withValues(alpha: .3)),
                  color: AppTheme.error.withValues(alpha: .04),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Icon(LucideIcons.triangleAlert, size: 14, color: AppTheme.error),
                    const SizedBox(width: 8),
                    Text('DANGER ZONE', style: GoogleFonts.plusJakartaSans(
                        fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: .4, color: AppTheme.error)),
                  ]),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => _confirmReset(context, vm),
                        child: Container(
                          height: 46,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: context._bd),
                            color: context._bg,
                          ),
                          child: Text('Reset to Defaults',
                              style: GoogleFonts.plusJakartaSans(
                                  fontWeight: FontWeight.w700, fontSize: 13,
                                  color: context._tp)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => _confirmClearData(context),
                        child: Container(
                          height: 46,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppTheme.error.withValues(alpha: .5)),
                            color: AppTheme.error.withValues(alpha: .08),
                          ),
                          child: Text('Clear All Data',
                              style: GoogleFonts.plusJakartaSans(
                                  fontWeight: FontWeight.w700, fontSize: 13,
                                  color: AppTheme.error)),
                        ),
                      ),
                    ),
                  ]),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Hero: Schedule Lock — dark card + one soft radial glow, matching the
// Dashboard's own hero-banner treatment (the app's single most impactful
// toggle earns the same visual weight as the Dashboard's headline card).
class _ScheduleLockHero extends StatelessWidget {
  final SettingsViewModel vm;
  const _ScheduleLockHero({required this.vm});

  @override
  Widget build(BuildContext context) {
    final locked = vm.scheduleLocked;
    final glow = locked ? AppTheme.error : AppTheme.success;
    return Container(
      padding: const EdgeInsets.all(22),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: const Color(0xFF12172A),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .25),
            blurRadius: 24, offset: const Offset(0, 10))],
      ),
      child: Stack(children: [
        Positioned(top: -70, right: -70,
            child: Container(width: 220, height: 220,
                decoration: BoxDecoration(shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [
                      glow.withValues(alpha: .4), glow.withValues(alpha: 0),
                    ])))),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 44, height: 44,
                decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(color: Colors.white.withValues(alpha: .12))),
                child: Icon(locked ? LucideIcons.lock : LucideIcons.lockOpen,
                    color: Colors.white, size: 20)),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Schedule Lock', style: GoogleFonts.plusJakartaSans(
                  fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white)),
              const SizedBox(height: 2),
              Text(
                locked
                    ? 'Locked — no edits, GA or settings changes allowed'
                    : 'Unlocked — assignments and settings can be changed',
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 12, color: Colors.white.withValues(alpha: .6)),
              ),
            ])),
            Switch(
              value: locked,
              onChanged: vm.setScheduleLocked,
              activeThumbColor: Colors.white,
              activeTrackColor: AppTheme.error,
              inactiveThumbColor: Colors.white,
              inactiveTrackColor: Colors.white.withValues(alpha: .2),
            ),
          ]),
          const SizedBox(height: 14),
          if (!locked)
            GestureDetector(
              onTap: () {
                final dataVm = context.read<DataEntryViewModel>();
                showDialog(context: context, builder: (_) => SelectiveLockDialog(dataVm: dataVm));
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(99)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(LucideIcons.lockKeyhole, size: 13, color: Colors.white.withValues(alpha: .85)),
                  const SizedBox(width: 7),
                  Text('Customize Selective Locks', style: GoogleFonts.plusJakartaSans(
                      fontSize: 11.5, fontWeight: FontWeight.w600, color: Colors.white.withValues(alpha: .85))),
                  const SizedBox(width: 4),
                  Icon(LucideIcons.chevronRight, size: 13, color: Colors.white.withValues(alpha: .6)),
                ]),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                  color: AppTheme.error.withValues(alpha: .18),
                  borderRadius: BorderRadius.circular(10)),
              child: Row(children: [
                const Icon(LucideIcons.shield, color: Colors.white, size: 14),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  'Running GA, adding/removing assignments, and changing constraints are all blocked.',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 11, color: Colors.white.withValues(alpha: .9), height: 1.4),
                )),
              ]),
            ),
        ]),
      ]),
    );
  }
}

// ── Gradient stat-slider — bold colored card carrying its own live value
// AND the control that changes it (Working Days / Balanced Tolerance).
class _GradientStatSlider extends StatelessWidget {
  final IconData icon;
  final List<Color> gradient;
  final String value, label;
  final double sliderValue, min, max;
  final int divisions;
  final ValueChanged<double> onChanged;
  const _GradientStatSlider({
    required this.icon, required this.gradient, required this.value, required this.label,
    required this.sliderValue, required this.min, required this.max, required this.divisions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: gradient, begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: gradient.first.withValues(alpha: .3),
            blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Container(width: 30, height: 30,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: .2), borderRadius: BorderRadius.circular(9)),
            child: Icon(icon, size: 15, color: Colors.white)),
        const SizedBox(height: 12),
        Text(value, style: GoogleFonts.plusJakartaSans(
            fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white)),
        Text(label, style: GoogleFonts.plusJakartaSans(
            fontSize: 9.5, fontWeight: FontWeight.w700, color: Colors.white.withValues(alpha: .85), letterSpacing: .3)),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: Colors.white,
            inactiveTrackColor: Colors.white.withValues(alpha: .28),
            thumbColor: Colors.white,
            overlayColor: Colors.white.withValues(alpha: .15),
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          ),
          child: Slider(
            value: sliderValue.clamp(min, max),
            min: min, max: max, divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ]),
    ),
  );
}

Widget _card(BuildContext ctx, {required Widget child, EdgeInsetsGeometry padding = const EdgeInsets.all(18)}) => Container(
  padding: padding,
  decoration: BoxDecoration(
    color: ctx._bg,
    borderRadius: BorderRadius.circular(18),
    border: Border.all(color: ctx._bd),
    boxShadow: [BoxShadow(
        color: Colors.black.withValues(alpha: ctx._dk ? .18 : .04),
        blurRadius: 12, offset: const Offset(0, 4))],
  ),
  child: child,
);

void _showStyledSnackBar(BuildContext context, String msg, Color color) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg, style: GoogleFonts.plusJakartaSans(
        fontWeight: FontWeight.w600, color: Colors.white, fontSize: 13)),
    backgroundColor: color, behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    margin: const EdgeInsets.all(16), duration: const Duration(seconds: 4),
  ));
}

// ── Sync Selection ─────────────────────────────────────────────────────────
// Which classes get included the next time "Sync to Student App" runs.
// Unchecking a class also drops any teacher/room from the published data
// unless another still-selected class uses them — so an unused teacher or
// an empty room never shows up in the student app.
class _SyncSelectionSection extends StatelessWidget {
  const _SyncSelectionSection();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<DataEntryViewModel>();
    final tp = context._tp;
    final ts = context._ts;
    final isDark = context._dk;

    if (vm.classes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Icon(LucideIcons.info, size: 16, color: ts),
          const SizedBox(width: 8),
          Expanded(child: Text('No classes yet. Add classes in the Data tab first.',
              style: GoogleFonts.plusJakartaSans(fontSize: 12, color: ts))),
        ]),
      );
    }

    final allClassIds = vm.classes.map((c) => c.id).toSet();
    final selected = vm.syncAll ? allClassIds : vm.syncClassIds;

    void apply(Set<String> next) {
      if (next.length == allClassIds.length) {
        vm.setSyncSelection(syncAll: true, classIds: const {});
      } else {
        vm.setSyncSelection(syncAll: false, classIds: next);
      }
    }

    final byProgram = <String, List<ClassModel>>{};
    for (final c in vm.classes) {
      final progName = vm.programs.where((p) => p.id == c.programId).firstOrNull?.name ?? 'Other';
      byProgram.putIfAbsent(progName, () => []).add(c);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.accentTeal.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.accentTeal.withValues(alpha: .25)),
        ),
        child: Row(children: [
          const Icon(LucideIcons.info, size: 14, color: AppTheme.accentTeal),
          const SizedBox(width: 8),
          Expanded(child: Text(
            "Uncheck classes/sections you don't want students to see (e.g. unused or empty sections). "
            "Their teachers and rooms are hidden too, unless another selected class still uses them.",
            style: GoogleFonts.plusJakartaSans(fontSize: 11, color: AppTheme.accentTeal, height: 1.5),
          )),
        ]),
      ),
      Row(children: [
        Text('${selected.length} of ${allClassIds.length} selected',
            style: GoogleFonts.plusJakartaSans(fontSize: 11.5, fontWeight: FontWeight.w600, color: ts)),
        const Spacer(),
        GestureDetector(
          onTap: () => apply(allClassIds),
          child: Text('Select All',
              style: GoogleFonts.plusJakartaSans(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppTheme.accentTeal)),
        ),
      ]),
      const SizedBox(height: 10),
      for (final entry in byProgram.entries)
        Builder(builder: (_) {
          final progClasses = entry.value..sort((a, b) => a.name.compareTo(b.name));
          final progIds = progClasses.map((c) => c.id).toSet();
          final allIn = progIds.every(selected.contains);
          final someIn = !allIn && progIds.any(selected.contains);

          void toggleProgram() {
            final next = {...selected};
            allIn ? next.removeAll(progIds) : next.addAll(progIds);
            apply(next);
          }

          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              GestureDetector(
                onTap: toggleProgram,
                child: Row(children: [
                  Icon(
                    allIn ? Icons.check_box_rounded : someIn ? Icons.indeterminate_check_box_rounded : Icons.check_box_outline_blank_rounded,
                    size: 16, color: (allIn || someIn) ? AppTheme.accentTeal : ts,
                  ),
                  const SizedBox(width: 6),
                  Text(entry.key,
                      style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w700, fontSize: 12.5, color: (allIn || someIn) ? tp : ts)),
                ]),
              ),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: progClasses.map((c) {
                final isSel = selected.contains(c.id);
                return GestureDetector(
                  onTap: () {
                    final next = {...selected};
                    isSel ? next.remove(c.id) : next.add(c.id);
                    apply(next);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: isSel
                          ? AppTheme.accentTeal.withValues(alpha: isDark ? .18 : .1)
                          : (isDark ? AppTheme.bgCard : const Color(0xFFF1F5F9)),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: isSel ? AppTheme.accentTeal.withValues(alpha: .4) : context._bd),
                    ),
                    child: Text(c.name,
                        style: GoogleFonts.plusJakartaSans(
                            fontSize: 11.5, fontWeight: FontWeight.w600, color: isSel ? AppTheme.accentTeal : ts)),
                  ),
                );
              }).toList()),
            ]),
          );
        }),
    ]);
  }
}

// ── Sync to Student App ───────────────────────────────────────────────────
class _PublishCard extends StatefulWidget {
  const _PublishCard();
  @override
  State<_PublishCard> createState() => _PublishCardState();
}

class _PublishCardState extends State<_PublishCard> {
  DateTime? _lastPublished;
  bool _loadingTs = true;
  bool _publishing = false;

  @override
  void initState() {
    super.initState();
    _refreshTimestamp();
  }

  Future<void> _refreshTimestamp() async {
    final ts = await context.read<DataEntryViewModel>().lastPublishedAt();
    if (!mounted) return;
    setState(() { _lastPublished = ts; _loadingTs = false; });
  }

  String get _label {
    if (_loadingTs) return 'Checking last sync…';
    if (_lastPublished == null) return 'Never synced to the student app.';
    final d = DateTime.now().difference(_lastPublished!);
    final rel = d.inMinutes < 1 ? 'just now'
        : d.inMinutes < 60 ? '${d.inMinutes} min ago'
        : d.inHours < 24 ? '${d.inHours} h ago'
        : '${d.inDays} d ago';
    return 'Last synced: $rel';
  }

  @override
  Widget build(BuildContext context) {
    return _card(context, child: Row(children: [
      Container(width: 34, height: 34,
          decoration: BoxDecoration(color: AppTheme.accentTeal.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(10)),
          child: const Icon(LucideIcons.smartphone, size: 17, color: AppTheme.accentTeal)),
      const SizedBox(width: 14),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Sync to Student App', style: GoogleFonts.plusJakartaSans(
            fontSize: 13, fontWeight: FontWeight.w700, color: context._tp)),
        Text(_label, style: GoogleFonts.plusJakartaSans(fontSize: 11, color: context._ts)),
      ])),
      const SizedBox(width: 10),
      GestureDetector(
        onTap: _publishing ? null : () async {
          setState(() => _publishing = true);
          try {
            await context.read<DataEntryViewModel>().publishForStudents();
            if (!context.mounted) return;
            _showStyledSnackBar(context, 'Timetable synced to the student app!', AppTheme.success);
            await _refreshTimestamp();
          } catch (e) {
            if (!context.mounted) return;
            _showStyledSnackBar(context, 'Sync failed: $e', AppTheme.error);
          } finally {
            if (mounted) setState(() => _publishing = false);
          }
        },
        child: Container(
          height: 38, padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            gradient: _publishing ? null : AppTheme.tealGradient,
            color: _publishing ? const Color(0xFF6B7280).withValues(alpha: .15) : null,
          ),
          child: _publishing
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text('Sync Now', style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w700, fontSize: 12.5, color: Colors.white)),
        ),
      ),
    ]));
  }
}

void _confirmReset(BuildContext ctx, SettingsViewModel vm) {
  showDialog(
    context: ctx,
    builder: (c) => AlertDialog(
      backgroundColor: ctx._bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Reset to Defaults?', style: GoogleFonts.plusJakartaSans(
          fontWeight: FontWeight.w800, color: ctx._tp)),
      content: Text('All preferences will return to factory settings.',
          style: GoogleFonts.plusJakartaSans(color: ctx._ts, fontSize: 13)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c),
            child: Text('Cancel',
                style: GoogleFonts.plusJakartaSans(color: ctx._ts))),
        TextButton(
          onPressed: () { vm.resetToDefaults(); Navigator.pop(c); },
          child: Text('Reset', style: GoogleFonts.plusJakartaSans(
              color: AppTheme.error, fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );
}

void _confirmClearData(BuildContext ctx) {
  showDialog(
    context: ctx,
    builder: (c) => AlertDialog(
      backgroundColor: ctx._bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Clear All Data?', style: GoogleFonts.plusJakartaSans(
          fontWeight: FontWeight.w800, color: ctx._tp)),
      content: Text('This will permanently delete all teachers, courses, classes, rooms, and assignments. Settings will not be changed. This action cannot be undone.',
          style: GoogleFonts.plusJakartaSans(color: ctx._ts, fontSize: 13)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c),
            child: Text('Cancel',
                style: GoogleFonts.plusJakartaSans(color: ctx._ts))),
        TextButton(
          onPressed: () {
            ctx.read<DataEntryViewModel>().clearAllData();
            ctx.read<AllocatorViewModel>().clearSchedule();
            Navigator.pop(c);
            ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
              content: Text('All data has been cleared', style: GoogleFonts.plusJakartaSans(color: Colors.white, fontWeight: FontWeight.w500)),
              backgroundColor: AppTheme.accentTeal,
              behavior: SnackBarBehavior.floating,
            ));
          },
          child: Text('Clear Data', style: GoogleFonts.plusJakartaSans(
              color: AppTheme.error, fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );
}

// ── Toggle row ────────────────────────────────────────────────────────────────
class _ToggleRow extends StatelessWidget {
  final IconData icon; final Color iconColor;
  final String title, subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final BuildContext context;
  const _ToggleRow({required this.icon, required this.iconColor,
      required this.title, required this.subtitle, required this.value,
      required this.onChanged, required this.context});
  @override
  Widget build(BuildContext ctx) => Row(children: [
    Container(width: 36, height: 36,
        decoration: BoxDecoration(
            color: iconColor.withValues(alpha: .1), borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, size: 18, color: iconColor)),
    const SizedBox(width: 14),
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: GoogleFonts.plusJakartaSans(
          fontSize: 13, fontWeight: FontWeight.w700, color: onChanged == null ? context._ts : context._tp)),
      Text(subtitle, style: GoogleFonts.plusJakartaSans(
          fontSize: 11, color: context._ts)),
    ])),
    Switch(
      value: value, onChanged: onChanged,
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? iconColor : null),
    ),
  ]);
}

// ── Quality chip preset ───────────────────────────────────────────────────────
class _QualityChip extends StatelessWidget {
  final String label;
  final int pop, gen;
  final SettingsViewModel vm;
  final BuildContext ctx;
  const _QualityChip(this.label, this.pop, this.gen, this.vm, this.ctx);

  bool get _selected => vm.gaPop == pop && vm.gaGen == gen;

  @override
  Widget build(BuildContext context) {
    final col = _selected ? AppTheme.accentAmber : AppTheme.accentAmber.withValues(alpha: .4);
    return Expanded(child: GestureDetector(
      onTap: () { vm.setGaPop(pop); vm.setGaGen(gen); },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 44,
        decoration: BoxDecoration(
          color: _selected ? AppTheme.accentAmber.withValues(alpha: .15) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: col, width: _selected ? 1.5 : 1),
        ),
        alignment: Alignment.center,
        child: Text(label, style: GoogleFonts.plusJakartaSans(
            fontSize: 13, fontWeight: FontWeight.w700,
            color: _selected ? AppTheme.accentAmber : ctx._ts)),
      ),
    ));
  }
}

// ── Collapsible accordion section ─────────────────────────────────────────────
class _CollapsibleSection extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color color;
  final int badgeCount;
  final Widget child;
  final String? lockedMessage;
  // When embedded inside a shared outer card (the Scheduling Rules category
  // groups 3 of these into one card) this drops its own card chrome and
  // relies on the parent's border/shadow instead — showDivider then draws
  // the line separating it from the next accordion.
  final bool flush;
  final bool showDivider;
  const _CollapsibleSection({
    required this.icon,
    required this.label,
    required this.color,
    required this.badgeCount,
    required this.child,
    this.lockedMessage,
    this.flush = false,
    this.showDivider = false,
  });
  @override
  State<_CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<_CollapsibleSection>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late final AnimationController _ctrl;
  late final Animation<double> _rot;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        duration: const Duration(milliseconds: 240), vsync: this);
    _rot  = Tween<double>(begin: 0, end: 0.5).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    _expanded ? _ctrl.forward() : _ctrl.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context._dk;
    final bg     = isDark ? AppTheme.bgCard : Colors.white;
    final bd     = isDark ? AppTheme.divider : AppTheme.lightDivider;
    final tp     = isDark ? AppTheme.textPrimary : AppTheme.lightText;

    return Container(
      decoration: widget.flush ? null : BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: bd),
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .18 : .04),
            blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Column(
        children: [
          // ── Tappable header ──────────────────────────────────────────────────
          InkWell(
            onTap: _toggle,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              child: Row(children: [
                Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(
                      color: widget.color.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(9)),
                  child: Icon(widget.icon, size: 17, color: widget.color)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(widget.label,
                      style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w800,
                          fontSize: 14, color: tp)),
                ),
                // Badge showing active item count
                if (widget.badgeCount > 0) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                        color: widget.color.withValues(alpha: .15),
                        borderRadius: BorderRadius.circular(20)),
                    child: Text('${widget.badgeCount}',
                        style: GoogleFonts.plusJakartaSans(
                            fontSize: 11, fontWeight: FontWeight.w800,
                            color: widget.color)),
                  ),
                  const SizedBox(width: 8),
                ],
                // Animated chevron
                RotationTransition(
                  turns: _rot,
                  child: Icon(LucideIcons.chevronDown,
                      color: widget.color, size: 20),
                ),
              ]),
            ),
          ),
          // ── Animated body ────────────────────────────────────────────────────
          SizeTransition(
            sizeFactor: _fade,
            alignment: Alignment.topCenter,
            child: Column(
              children: [
                Divider(color: bd, height: 1),
                if (widget.lockedMessage != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444).withValues(alpha: .08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: .3)),
                      ),
                      child: Row(children: [
                        const Icon(LucideIcons.lock, color: Color(0xFFEF4444), size: 16),
                        const SizedBox(width: 10),
                        Expanded(child: Text(
                          widget.lockedMessage!,
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12, color: const Color(0xFFEF4444), fontWeight: FontWeight.w600),
                        )),
                      ]),
                    ),
                  ),
                IgnorePointer(
                  ignoring: widget.lockedMessage != null,
                  child: Opacity(
                    opacity: widget.lockedMessage != null ? 0.6 : 1.0,
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: widget.child,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (widget.flush && widget.showDivider) Divider(color: bd, height: 1),
        ],
      ),
    );
  }
}

// ── Time Slot Locks Section ──────────────────────────────────────────────────
class _TimeSlotLocksSection extends StatefulWidget {
  const _TimeSlotLocksSection();
  @override
  State<_TimeSlotLocksSection> createState() => _TimeSlotLocksSectionState();
}

class _TimeSlotLocksSectionState extends State<_TimeSlotLocksSection> {
  Course? _selCourse;
  EducationLevel _selLevel = EducationLevel.intermediate;
  ClassModel? _selClass;
  TimeSlot? _selSlot;

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<DataEntryViewModel>();
    final isDark = context._dk;

    // Filtered lists — everything follows the selected level
    final availableCourses = vm.courses.where((c) => c.level == _selLevel).toList();
    final availableClasses = vm.classes.where((c) => c.level == _selLevel).toList();
    final availableSlots = vm.timeSlots.where((t) => t.level == _selLevel).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Add New Lock', style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w700, fontSize: 13, color: context._tp)),
        const SizedBox(height: 12),
        
        // Form
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // Level
            _buildDrop<EducationLevel>(
              hint: 'Select Level',
              value: _selLevel,
              items: EducationLevel.values,
              labelBuilder: (l) => l.name.toUpperCase(),
              onChanged: (v) {
                setState(() {
                  _selLevel = v!;
                  _selCourse = null;
                  _selClass = null;
                  _selSlot = null;
                });
              },
            ),
            // Course — level-filtered, type-to-search
            _searchDrop<Course>(
              key: ValueKey('lockCourse_${_selLevel.name}_${_selCourse?.id ?? ''}'),
              hint: 'Select Course',
              width: 320,
              value: _selCourse,
              items: availableCourses,
              labelBuilder: (c) => '${c.code} — ${c.name}',
              onChanged: (v) => setState(() => _selCourse = v),
            ),
            // Class (Optional) — level-filtered, type-to-search
            _searchDrop<ClassModel?>(
              key: ValueKey('lockClass_${_selLevel.name}_${_selClass?.id ?? 'all'}'),
              hint: 'All ${_selLevel.name} Classes',
              width: 260,
              value: _selClass,
              items: [null, ...availableClasses],
              labelBuilder: (c) {
                if (c == null) return 'All ${_selLevel.name} Classes';
                final progName = vm.programs.where((p) => p.id == c.programId).firstOrNull?.name ?? 'Unknown';
                return '$progName - ${c.name}';
              },
              onChanged: (v) => setState(() => _selClass = v),
            ),
            // Slot
            _buildDrop<TimeSlot>(
              hint: 'Select Slot',
              value: _selSlot,
              items: availableSlots,
              labelBuilder: (s) => 'P${s.period} (${TimeSlot.format12(s.startTime)}-${TimeSlot.format12(s.endTime)})',
              onChanged: (v) => setState(() => _selSlot = v),
            ),
            
            // Add Button
            ElevatedButton.icon(
              onPressed: (_selCourse == null || _selSlot == null) ? null : () {
                final cName = _selClass == null ? null : '${vm.programs.where((p) => p.id == _selClass!.programId).firstOrNull?.name ?? "Unknown"} - ${_selClass!.name}';
                final lock = TimeSlotLock(
                  id: DateTime.now().microsecondsSinceEpoch.toString(),
                  courseId: _selCourse!.id,
                  courseCode: _selCourse!.code,
                  classId: _selClass?.id,
                  className: cName,
                  level: _selLevel,
                  timeSlotId: _selSlot!.id,
                  timeSlotLabel: 'P${_selSlot!.period} (${TimeSlot.format12(_selSlot!.startTime)}-${TimeSlot.format12(_selSlot!.endTime)})',
                );
                final log = vm.addTimeSlotLock(lock);
                setState(() { _selCourse = null; _selSlot = null; });

                final moved   = log.where((l) => l.startsWith('Moved')).length;
                final skipped = log.where((l) => l.startsWith('Skipped')).length;
                String msg; Color color;
                if (moved > 0 && skipped == 0) {
                  msg   = '✅ Locked! $moved assignment${moved == 1 ? '' : 's'} moved to ${lock.timeSlotLabel}.';
                  color = const Color(0xFF16A34A);
                } else if (moved > 0) {
                  msg   = '⚠️ Partially applied — $moved moved, $skipped skipped (clash).';
                  color = const Color(0xFFD97706);
                } else if (skipped > 0) {
                  msg   = '⚠️ Rule saved but could not move assignments — clashes detected. Run GA to resolve.';
                  color = const Color(0xFFD97706);
                } else {
                  msg   = '✅ Constraint saved. Run GA to apply it to the schedule.';
                  color = const Color(0xFF16A34A);
                }
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(msg, style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w600, color: Colors.white, fontSize: 13)),
                  backgroundColor: color, behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  margin: const EdgeInsets.all(16), duration: const Duration(seconds: 5),
                ));
              },
              icon: const Icon(LucideIcons.plus, size: 16, color: Colors.white),
              label: Text('Lock', style: GoogleFonts.plusJakartaSans(color: Colors.white, fontWeight: FontWeight.w700)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accentAmber,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                elevation: 0,
              ),
            ),
          ],
        ),
        
        const SizedBox(height: 24),
        Divider(color: context._bd, height: 1),
        const SizedBox(height: 16),
        
        Row(
          children: [
            Text('Active Locks', style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w700, fontSize: 13, color: context._tp)),
            const Spacer(),
            TextButton.icon(
              onPressed: () {
                vm.snapshotForUndo('Fix Pinned Duplicates');
                final log = vm.resyncTimeSlotLocks();
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(
                    log.isEmpty
                        ? 'Nothing to fix — no locked or duplicate-pinned courses found.'
                        : '${log.length} card${log.length == 1 ? '' : 's'} unpinned and moved back onto a clash-free day — run Fix Now / GA to finalise.',
                    style: GoogleFonts.plusJakartaSans(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12),
                  ),
                  backgroundColor: log.isEmpty ? AppTheme.accentTeal : AppTheme.accentAmber,
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ));
              },
              icon: const Icon(LucideIcons.refreshCw, size: 15),
              label: Text('Fix Pinned Duplicates', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 12)),
            ),
          ],
        ),
        Text(
          'Re-applies your locks, and — for ANY course, not just locked ones — '
          'finds a teacher\'s pinned sections of the same course in the same '
          'period that landed on identical days by mistake, and spreads them '
          'onto different days automatically.',
          style: GoogleFonts.plusJakartaSans(fontSize: 11, color: context._ts, height: 1.4),
        ),
        const SizedBox(height: 12),

        if (vm.timeSlotLocks.isEmpty)
          Text('No locks configured. The GA will randomly assign all slots.',
              style: GoogleFonts.plusJakartaSans(fontSize: 12, color: context._ts))
        else
          ...vm.timeSlotLocks.map((lock) => Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF2A2A35) : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context._bd),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.lock, size: 14, color: AppTheme.accentAmber),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${lock.courseCode} — ${lock.className ?? "All ${lock.level.name}"} → ${lock.timeSlotLabel}',
                    style: GoogleFonts.plusJakartaSans(fontSize: 12, color: context._tp, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  icon: Icon(LucideIcons.x, size: 16, color: AppTheme.error),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  splashRadius: 16,
                  onPressed: () => vm.removeTimeSlotLock(lock.id),
                ),
              ],
            ),
          )),
      ],
    );
  }

  Widget _buildDrop<T>({
    required String hint,
    required T? value,
    required List<T> items,
    required String Function(T) labelBuilder,
    required ValueChanged<T?> onChanged,
  }) {
    final isDark = context._dk;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E26) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context._bd),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          hint: Text(hint, style: GoogleFonts.plusJakartaSans(fontSize: 12, color: context._ts)),
          dropdownColor: context._bg,
          icon: Icon(LucideIcons.chevronDown, size: 16, color: context._ts),
          style: GoogleFonts.plusJakartaSans(fontSize: 13, color: context._tp, fontWeight: FontWeight.w500),
          items: items.map((item) => DropdownMenuItem<T>(
            value: item,
            child: Text(labelBuilder(item)),
          )).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  // Type-to-search dropdown (native DropdownMenu filter — arrows + Enter work).
  Widget _searchDrop<T>({
    required Key key,
    required String hint,
    required T? value,
    required List<T> items,
    required String Function(T) labelBuilder,
    required ValueChanged<T?> onChanged,
    double width = 260,
  }) {
    final isDark = context._dk;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: context._bd),
    );
    return DropdownMenu<T>(
      key: key,
      width: width,
      initialSelection: value,
      hintText: hint,
      requestFocusOnTap: true,
      enableFilter: true,
      menuHeight: 320,
      textStyle: GoogleFonts.plusJakartaSans(
          fontSize: 13, color: context._tp, fontWeight: FontWeight.w500),
      trailingIcon: Icon(LucideIcons.chevronDown, size: 16, color: context._ts),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        constraints: const BoxConstraints(maxHeight: 44),
        hintStyle:
            GoogleFonts.plusJakartaSans(fontSize: 12, color: context._ts),
        filled: true,
        fillColor: isDark ? const Color(0xFF1E1E26) : Colors.white,
        border: border,
        enabledBorder: border,
      ),
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(context._bg),
        maximumSize: const WidgetStatePropertyAll(Size(420, 320)),
      ),
      dropdownMenuEntries: items
          .map((i) => DropdownMenuEntry<T>(value: i, label: labelBuilder(i)))
          .toList(),
      onSelected: onChanged,
    );
  }
}

// ── Combined Courses Section ──────────────────────────────────────────────────
class _CombinedCoursesSection extends StatefulWidget {
  const _CombinedCoursesSection();
  @override
  State<_CombinedCoursesSection> createState() => _CombinedCoursesSectionState();
}

class _CombinedCoursesSectionState extends State<_CombinedCoursesSection> {
  Course? _selCourse;
  final Set<String> _selClassIds = {};

  Widget _combineButton(BuildContext context, DataEntryViewModel vm) {
    return ElevatedButton.icon(
      onPressed: (_selCourse == null || _selClassIds.length < 2) ? null : () {
        final rule = CombinedClassRule(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          courseId: _selCourse!.id,
          classIds: _selClassIds.toList(),
        );
        final log = vm.addCombinedRule(rule);

        // Rejected outright (no allocation yet, or a teacher mismatch) —
        // nothing was saved, so leave the course/class selection as-is and
        // just surface why, instead of clearing the form like a success.
        if (log.isNotEmpty && log.first.startsWith('ERROR:')) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(log.first.substring('ERROR: '.length),
                style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white, fontSize: 13)),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 6),
          ));
          return;
        }

        setState(() { _selCourse = null; _selClassIds.clear(); });

        // Show result snackbar
        final mergedCount = log.where((l) => l.startsWith('Moved') || l.startsWith('Created')).length;
        final skippedCount = log.where((l) => l.startsWith('Skipped')).length;

        String msg;
        Color color;
        if (mergedCount > 0 && skippedCount == 0) {
          msg = '✅ Combined! $mergedCount assignment${mergedCount == 1 ? '' : 's'} automatically aligned to a shared slot.';
          color = const Color(0xFF16A34A);
        } else if (mergedCount > 0 && skippedCount > 0) {
          msg = '⚠️ Partially combined — $mergedCount aligned, $skippedCount skipped (slot clash in sibling class).';
          color = const Color(0xFFD97706);
        } else if (skippedCount > 0) {
          msg = '⚠️ Rule saved, but could not auto-align: slot already occupied in combined classes. '
              'Run GA to resolve automatically.';
          color = const Color(0xFFD97706);
        } else {
          msg = '✅ Combined course rule saved. Run GA to assign a shared slot.';
          color = const Color(0xFF16A34A);
        }

        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg,
              style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w600, color: Colors.white, fontSize: 13)),
          backgroundColor: color,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 5),
        ));
      },
      icon: const Icon(LucideIcons.plus, size: 16, color: Colors.white),
      label: Text('Combine', style: GoogleFonts.plusJakartaSans(color: Colors.white, fontWeight: FontWeight.w700)),
      style: ElevatedButton.styleFrom(
        backgroundColor: AppTheme.accentBlue,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        elevation: 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<DataEntryViewModel>();
    final isDark = context._dk;

    // Course list is grouped Intermediate-then-Bachelor (level tagged in the
    // label) so the two don't blur together in search; picking a course
    // scopes the class picker to that same level — same pattern the
    // Allocator's Class/Course fields already use.
    final sortedCourses = vm.courses.toList()
      ..sort((a, b) {
        final lv = a.level.index.compareTo(b.level.index);
        return lv != 0 ? lv : a.name.compareTo(b.name);
      });
    final classesForCourse = _selCourse == null
        ? const <ClassModel>[]
        : vm.classes.where((c) => c.level == _selCourse!.level).toList();

    final courseField = SearchDropdown<Course>(
      label: 'Search Course',
      icon: LucideIcons.bookOpen,
      value: _selCourse,
      color: AppTheme.accentBlue,
      items: sortedCourses,
      itemLabel: (c) => '${c.name} · ${c.level.label}',
      onChanged: (v) => setState(() { _selCourse = v; _selClassIds.clear(); }),
    );
    final classField = _ClassMultiSelectField(
      classes: classesForCourse,
      vm: vm,
      enabled: _selCourse != null,
      selectedIds: _selClassIds,
      onChanged: (ids) => setState(() { _selClassIds..clear()..addAll(ids); }),
    );
    final addBtn = _combineButton(context, vm);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Add Combined Course', style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w700, fontSize: 13, color: context._tp)),
        const SizedBox(height: 4),
        Text('Merge multiple classes into a single GA timeslot', style: GoogleFonts.plusJakartaSans(
            fontSize: 11, color: context._ts)),
        const SizedBox(height: 12),

        LayoutBuilder(builder: (_, box) {
          final wide = box.maxWidth > 720;
          if (wide) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: courseField),
              const SizedBox(width: 12),
              Expanded(child: classField),
              const SizedBox(width: 12),
              Padding(padding: const EdgeInsets.only(top: 4), child: addBtn),
            ]);
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            courseField,
            const SizedBox(height: 12),
            classField,
            const SizedBox(height: 12),
            addBtn,
          ]);
        }),

        const SizedBox(height: 24),
        Divider(color: context._bd, height: 1),
        const SizedBox(height: 16),

        Text('Active Combinations', style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w700, fontSize: 13, color: context._tp)),
        const SizedBox(height: 12),

        if (vm.combinedRules.isEmpty)
          Text('No combined courses configured.',
              style: GoogleFonts.plusJakartaSans(fontSize: 12, color: context._ts))
        else
          ...vm.combinedRules.map((rule) {
            final course = vm.courses.where((c) => c.id == rule.courseId).firstOrNull;
            final classNames = rule.classIds.map((cId) {
              final c = vm.classes.where((x) => x.id == cId).firstOrNull;
              if (c == null) return 'Unknown';
              final prog = vm.programs.where((p) => p.id == c.programId).firstOrNull?.name ?? 'Unknown';
              return '$prog - ${c.name}';
            }).join(', ');

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF2A2A35) : const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: context._bd),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.link2, size: 14, color: AppTheme.accentBlue),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${course?.name ?? "Unknown"} → $classNames',
                      style: GoogleFonts.plusJakartaSans(fontSize: 12, color: context._tp, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    icon: Icon(LucideIcons.x, size: 16, color: AppTheme.error),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    splashRadius: 16,
                    onPressed: () => vm.removeCombinedRule(rule.id),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }
}

// Combined Courses' class multi-select: search + checkbox list opened from a
// text-field-styled tappable box, matching SearchDropdown's look. Unlike
// SearchDropdown this stays open across multiple picks, so it's its own
// small dialog rather than an Autocomplete (which closes on first select).
class _ClassMultiSelectField extends StatelessWidget {
  final List<ClassModel> classes;
  final DataEntryViewModel vm;
  final bool enabled;
  final Set<String> selectedIds;
  final ValueChanged<Set<String>> onChanged;
  const _ClassMultiSelectField({
    required this.classes, required this.vm, required this.enabled,
    required this.selectedIds, required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = context._dk;
    final label = !enabled
        ? 'Select a course first'
        : selectedIds.isEmpty
            ? 'Search classes'
            : '${selectedIds.length} class${selectedIds.length == 1 ? '' : 'es'} selected';

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: enabled ? () => showDialog(
        context: context,
        builder: (_) => _ClassPickerDialog(classes: classes, vm: vm, selectedIds: selectedIds, onChanged: onChanged),
      ) : null,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: 'Classes',
          labelStyle: GoogleFonts.plusJakartaSans(color: context._ts, fontSize: 12),
          prefixIcon: Icon(LucideIcons.users, color: context._ts, size: 18),
          suffixIcon: Icon(LucideIcons.search, color: context._ts, size: 18),
          filled: true, fillColor: isDark ? AppTheme.bgMid : const Color(0xFFF8FAFC),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: context._bd)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: context._bd)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
        child: Text(label, style: GoogleFonts.plusJakartaSans(
            fontSize: 14, color: selectedIds.isNotEmpty ? AppTheme.accentBlue : context._tp)),
      ),
    );
  }
}

class _ClassPickerDialog extends StatefulWidget {
  final List<ClassModel> classes;
  final DataEntryViewModel vm;
  final Set<String> selectedIds;
  final ValueChanged<Set<String>> onChanged;
  const _ClassPickerDialog({
    required this.classes, required this.vm, required this.selectedIds, required this.onChanged,
  });
  @override
  State<_ClassPickerDialog> createState() => _ClassPickerDialogState();
}

class _ClassPickerDialogState extends State<_ClassPickerDialog> {
  late final Set<String> _selected = {...widget.selectedIds};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.classes.where((c) {
      if (_query.isEmpty) return true;
      final prog = widget.vm.programs.where((p) => p.id == c.programId).firstOrNull?.name ?? '';
      return '$prog ${c.name}'.toLowerCase().contains(_query.toLowerCase());
    }).toList();

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 420, maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('Select Classes', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, fontSize: 15, color: context._tp)),
              const Spacer(),
              if (_selected.isNotEmpty)
                GestureDetector(
                  onTap: () => setState(() => _selected.clear()),
                  child: Text('Clear', style: GoogleFonts.plusJakartaSans(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.accentBlue)),
                ),
            ]),
            const SizedBox(height: 12),
            TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              style: GoogleFonts.plusJakartaSans(fontSize: 13, color: context._tp),
              decoration: InputDecoration(
                hintText: 'Search class or program…',
                hintStyle: GoogleFonts.plusJakartaSans(fontSize: 12, color: context._ts),
                prefixIcon: Icon(LucideIcons.search, size: 16, color: context._ts),
                isDense: true,
                filled: true, fillColor: context._dk ? AppTheme.bgMid : const Color(0xFFF8FAFC),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context._bd)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context._bd)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.accentBlue, width: 1.5)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: filtered.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text('No matches', style: GoogleFonts.plusJakartaSans(fontSize: 12, color: context._ts)))
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final c = filtered[i];
                        final prog = widget.vm.programs.where((p) => p.id == c.programId).firstOrNull?.name ?? 'Unknown';
                        final isSel = _selected.contains(c.id);
                        return InkWell(
                          onTap: () => setState(() => isSel ? _selected.remove(c.id) : _selected.add(c.id)),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(children: [
                              Icon(isSel ? LucideIcons.checkSquare : LucideIcons.square, size: 16, color: isSel ? AppTheme.accentBlue : context._ts),
                              const SizedBox(width: 10),
                              Expanded(child: Text('$prog - ${c.name}', style: GoogleFonts.plusJakartaSans(fontSize: 13, color: context._tp))),
                            ]),
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton(
                onPressed: () { widget.onChanged(_selected); Navigator.pop(context); },
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentBlue, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                child: Text('Done (${_selected.length})', style: GoogleFonts.plusJakartaSans(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Manage Shifts Section
// ─────────────────────────────────────────────────────────────────────────────

class _ManageShiftsSection extends StatelessWidget {
  const _ManageShiftsSection();

  static const _morningColor = Color(0xFFF97316);
  static const _eveningColor = AppTheme.accentBlue;

  @override
  Widget build(BuildContext context) {
    final vm     = context.watch<DataEntryViewModel>();
    final isDark = context._dk;
    final tp     = context._tp;
    final ts     = context._ts;

    final bachPrograms = vm.programs
        .where((p) => p.level == EducationLevel.bachelors)
        .toList();
    final bachClasses = vm.classes
        .where((c) => c.level == EducationLevel.bachelors)
        .toList();

    if (bachPrograms.isEmpty || bachClasses.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Icon(LucideIcons.info, size: 16, color: ts),
          const SizedBox(width: 8),
          Expanded(child: Text(
            'No Bachelors programs found. Add programs and classes in the Data tab first.',
            style: GoogleFonts.plusJakartaSans(fontSize: 12, color: ts),
          )),
        ]),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Info banner
      Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: _morningColor.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _morningColor.withValues(alpha: .25)),
        ),
        child: Row(children: [
          const Icon(LucideIcons.info, size: 14, color: _morningColor),
          const SizedBox(width: 8),
          Expanded(child: Text(
            'Morning = P1–P3 (08:00–11:00)   Evening = P4–P6 (11:00–14:00)\n'
            'Unassigned classes are auto-split (first half → Morning, second half → Evening). '
            'Tap the active chip to revert a class to auto.',
            style: GoogleFonts.plusJakartaSans(fontSize: 11, color: _morningColor, height: 1.5),
          )),
        ]),
      ),

      // Programs + classes list
      for (final prog in bachPrograms) ...[
        () {
          final progClasses = bachClasses
              .where((c) => c.programId == prog.id)
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name));
          if (progClasses.isEmpty) return const SizedBox.shrink();

          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(prog.name,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 13, fontWeight: FontWeight.w700, color: tp)),
            ),
            ...progClasses.map((cls) {
              final effectiveShift = vm.shiftForClass(cls.id);
              final isManual  = vm.shiftRules.any((r) => r.classId == cls.id);
              final isMorning = effectiveShift == ShiftType.morning;
              final isEvening = effectiveShift == ShiftType.evening;

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(cls.name,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12, fontWeight: FontWeight.w600, color: tp)),
                    if (!isManual)
                      Text('auto',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 10, color: ts, fontStyle: FontStyle.italic)),
                  ])),
                  const SizedBox(width: 10),
                  // Morning chip
                  _ShiftChip(
                    label: 'Morning', icon: LucideIcons.sun,
                    active: isMorning, activeColor: _morningColor,
                    isDark: isDark,
                    onTap: () {
                      final vm2 = context.read<DataEntryViewModel>();
                      if (isMorning && isManual) {
                        vm2.clearShiftRule(cls.id);
                      } else {
                        vm2.setShiftRule(cls.id, cls.name, ShiftType.morning);
                      }
                    },
                  ),
                  const SizedBox(width: 6),
                  // Evening chip
                  _ShiftChip(
                    label: 'Evening', icon: LucideIcons.moon,
                    active: isEvening, activeColor: _eveningColor,
                    isDark: isDark,
                    onTap: () {
                      final vm2 = context.read<DataEntryViewModel>();
                      if (isEvening && isManual) {
                        vm2.clearShiftRule(cls.id);
                      } else {
                        vm2.setShiftRule(cls.id, cls.name, ShiftType.evening);
                      }
                    },
                  ),
                ]),
              );
            }),
            const SizedBox(height: 8),
            Divider(color: context._bd, height: 1),
            const SizedBox(height: 12),
          ]);
        }(),
      ],
    ]);
  }
}

class _ShiftChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active, isDark;
  final Color activeColor;
  final VoidCallback onTap;

  const _ShiftChip({
    required this.label, required this.icon,
    required this.active, required this.activeColor,
    required this.isDark, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ts = context._ts;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active
              ? activeColor.withValues(alpha: .18)
              : (isDark ? Colors.white.withValues(alpha: .05) : Colors.grey.withValues(alpha: .08)),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? activeColor : Colors.transparent, width: 1.5),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: active ? activeColor : ts),
          const SizedBox(width: 4),
          Text(label,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 11, fontWeight: FontWeight.w600,
              color: active ? activeColor : ts)),
        ]),
      ),
    );
  }
}

// ── BACKUP / RESTORE BUTTONS ──────────────────────────────────────────────────
class _BackupBtn extends StatelessWidget {
  const _BackupBtn();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dataVm = context.read<DataEntryViewModel>();
    final settingsVm = context.read<SettingsViewModel>();
    const col = AppTheme.accentTeal;
    return GestureDetector(
      onTap: () async {
        try {
          final allocatorVm = context.read<AllocatorViewModel>();
          await dataVm.exportBackup(settingsVm.toJson(),
              allocatorData: allocatorVm.exportBackupData());
          if (context.mounted) {
            _showStyledSnackBar(context, 'Backup saved successfully!', AppTheme.success);
          }
        } catch (e) {
          if (context.mounted) {
            _showStyledSnackBar(context, 'Failed to save backup: $e', AppTheme.error);
          }
        }
      },
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: col.withValues(alpha: isDark ? .15 : .10),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: col.withValues(alpha: .4), width: 1.2),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(LucideIcons.download, size: 18, color: col),
          const SizedBox(width: 8),
          Text('Backup Data', style: GoogleFonts.plusJakartaSans(
              fontSize: 14, fontWeight: FontWeight.bold, color: col)),
        ]),
      ),
    );
  }
}

// Waits until [notifier] stops firing notifyListeners() for [quiet], so
// callers don't proceed while a ChangeNotifier is still mid-update from an
// async source (e.g. a Firestore snapshot listener still settling). Capped
// by [maxWait] in case notifications never quiet down for some reason.
Future<void> _waitForQuiet(
  ChangeNotifier notifier, {
  // A restored dataset doesn't settle in one shot: elective-conflict eviction
  // and combined-rule reapplication can each re-save and re-trigger the
  // Firestore listener in their own follow-up round, several seconds apart
  // for a large backup. The quiet window has to be wide enough to survive
  // the gaps between those rounds, not just the first pause.
  Duration quiet = const Duration(seconds: 3),
  Duration maxWait = const Duration(seconds: 25),
}) async {
  final completer = Completer<void>();
  Timer? debounce;
  void onChange() {
    debounce?.cancel();
    debounce = Timer(quiet, () {
      if (!completer.isCompleted) completer.complete();
    });
  }
  notifier.addListener(onChange);
  onChange(); // start the quiet window even if nothing fires again
  final maxTimer = Timer(maxWait, () {
    if (!completer.isCompleted) completer.complete();
  });
  try {
    await completer.future;
  } finally {
    notifier.removeListener(onChange);
    debounce?.cancel();
    maxTimer.cancel();
  }
}

class _RestoreBtn extends StatelessWidget {
  const _RestoreBtn();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dataVm = context.read<DataEntryViewModel>();
    final settingsVm = context.read<SettingsViewModel>();
    final allocatorVm = context.read<AllocatorViewModel>();
    const col = AppTheme.accentCyan;
    return GestureDetector(
      onTap: () async {
        // Show a non-dismissible progress dialog for the whole restore —
        // large backups can take a while to parse + write to Firestore,
        // and previously the only feedback was to reopen the app.
        bool dialogShown = false;
        void showProgress(String message) {
          if (!context.mounted) return;
          if (dialogShown) return;
          dialogShown = true;
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (_) => PopScope(
              canPop: false,
              child: AlertDialog(
                content: Row(children: [
                  const SizedBox(
                      width: 22, height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5)),
                  const SizedBox(width: 16),
                  Expanded(child: Text(message)),
                ]),
              ),
            ),
          );
        }
        void closeProgress() {
          if (dialogShown && context.mounted) {
            Navigator.of(context, rootNavigator: true).pop();
            dialogShown = false;
          }
        }

        showProgress('Restoring backup…');
        try {
          final decoded = await dataVm.importBackup();
          final settingsData = decoded['settings'];
          if (settingsData != null) {
            settingsVm.importSettings(settingsData as Map<String, dynamic>);
          }
          final allocatorData = decoded['allocator'];
          if (allocatorData != null) {
            await allocatorVm.importBackup(allocatorData as Map<String, dynamic>);
          }
          // Firestore's snapshot listener applies the restored data
          // asynchronously and can fire more than once while a large backup
          // settles (an optimistic local echo, then the server-confirmed
          // state) — a fixed delay risks closing the dialog while dataVm is
          // still mid-update, showing partial counts. Instead wait until
          // dataVm's notifications go quiet for a bit, capped by a timeout.
          await _waitForQuiet(dataVm);
          closeProgress();
          if (context.mounted) {
            _showStyledSnackBar(context, 'Backup restored successfully!', AppTheme.success);
          }
        } catch (e) {
          closeProgress();
          if (context.mounted) {
            _showStyledSnackBar(context, 'Failed to restore backup: $e', AppTheme.error);
          }
        }
      },
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: col.withValues(alpha: isDark ? .15 : .10),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: col.withValues(alpha: .4), width: 1.2),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(LucideIcons.upload, size: 18, color: col),
          const SizedBox(width: 8),
          Text('Restore Data', style: GoogleFonts.plusJakartaSans(
              fontSize: 14, fontWeight: FontWeight.bold, color: col)),
        ]),
      ),
    );
  }
}

