import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
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
    final vm     = context.watch<SettingsViewModel>();
    final themeVm = context.watch<ThemeViewModel>();
    final hp     = context.hPad;
    final isDark = context._dk;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: EdgeInsets.fromLTRB(hp, 56, hp, 40),
            children: [

              // ── Header ─────────────────────────────────────────────────────
              Row(children: [
                Container(width: 48, height: 48,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                        colors: [Color(0xFF6366F1), Color(0xFF4F46E5)]),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [BoxShadow(
                        color: const Color(0xFF6366F1).withValues(alpha: .35),
                        blurRadius: 18, offset: const Offset(0, 5))]),
                  child: const Icon(Icons.settings_rounded, color: Colors.white, size: 24)),
                const SizedBox(width: 16),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Settings', style: GoogleFonts.plusJakartaSans(
                      fontSize: 24, fontWeight: FontWeight.w800,
                      color: context._tp, letterSpacing: -0.5)),
                  Text('Customise your timetable preferences',
                      style: GoogleFonts.plusJakartaSans(fontSize: 13, color: context._ts)),
                ]),
              ]),

              const SizedBox(height: 28),

              // ── Schedule Lock ───────────────────────────────────────────────
              _card(context, child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: vm.scheduleLocked
                      ? LinearGradient(colors: [
                          const Color(0xFFEF4444).withValues(alpha: .08),
                          const Color(0xFFDC2626).withValues(alpha: .04),
                        ])
                      : null,
                ),
                child: Column(children: [
                  _ToggleRow(
                    icon: vm.scheduleLocked ? Icons.lock_rounded : Icons.lock_open_rounded,
                    iconColor: vm.scheduleLocked ? const Color(0xFFEF4444) : context._ts,
                    title: 'Schedule Lock',
                    subtitle: vm.scheduleLocked
                        ? 'Schedule is locked — no edits, GA or settings changes allowed'
                        : 'Unlock — assignments and settings can be changed',
                    value: vm.scheduleLocked,
                    context: context,
                    onChanged: (v) => vm.setScheduleLocked(v),
                  ),
                  if (!vm.scheduleLocked) ...[
                    const SizedBox(height: 8),
                    Divider(color: context._bd.withValues(alpha: .5), height: 1),
                    InkWell(
                      onTap: () {
                        final dataVm = context.read<DataEntryViewModel>();
                        showDialog(context: context, builder: (_) => SelectiveLockDialog(dataVm: dataVm));
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        child: Row(children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: AppTheme.accentAmber.withValues(alpha: .15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.lock_person_rounded, color: AppTheme.accentAmber, size: 16),
                          ),
                          const SizedBox(width: 12),
                          Expanded(child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Customize Selective Locks', style: GoogleFonts.plusJakartaSans(fontSize: 13, fontWeight: FontWeight.w700, color: context._tp)),
                              const SizedBox(height: 2),
                              Text('Lock specific classes, programs, or levels to preserve their assignments', style: GoogleFonts.plusJakartaSans(fontSize: 11, color: context._ts)),
                            ],
                          )),
                          Icon(Icons.chevron_right_rounded, color: context._ts, size: 18),
                        ]),
                      ),
                    ),
                  ],
                  if (vm.scheduleLocked) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444).withValues(alpha: .08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: .3)),
                      ),
                      child: Row(children: [
                        const Icon(Icons.shield_rounded, color: Color(0xFFEF4444), size: 14),
                        const SizedBox(width: 8),
                        Expanded(child: Text(
                          'Running GA, adding/removing assignments, and changing constraints are all blocked.',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 11, color: const Color(0xFFEF4444), height: 1.4),
                        )),
                      ]),
                    ),
                  ],
                ]),
              )),

              const SizedBox(height: 20),

              // ── Appearance ─────────────────────────────────────────────────
              _SectionLabel('Appearance', Icons.palette_rounded, AppTheme.accentViolet, context),
              const SizedBox(height: 12),
              _card(context, child: _ToggleRow(
                icon: isDark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                iconColor: AppTheme.accentViolet,
                title: 'Dark Mode',
                subtitle: isDark ? 'Dark theme is active' : 'Light theme is active',
                value: isDark,
                context: context,
                onChanged: (_) => themeVm.toggle(),
              )),

              const SizedBox(height: 20),

              // ── Timetable Preferences ───────────────────────────────────────
              _SectionLabel('Timetable Preferences', Icons.calendar_month_rounded,
                  AppTheme.accentCyan, context),
              const SizedBox(height: 12),
              _card(context, child: Column(children: [
                _SliderRow(
                  icon: Icons.today_rounded,
                  iconColor: AppTheme.accentCyan,
                  title: 'Working Days per Week',
                  subtitle: _dayRangeLabel(vm.workingDays),
                  value: vm.workingDays.toDouble(),
                  min: 5, max: 6, divisions: 1,
                  color: AppTheme.accentCyan,
                  onChanged: (v) => vm.setWorkingDays(v.round()),
                  context: context,
                ),
              ])),

              const SizedBox(height: 20),

              // ── Timetable Generation Speed ──────────────────────────────────
              _SectionLabel('Generation Speed', Icons.speed_rounded,
                  AppTheme.accentAmber, context),
              const SizedBox(height: 12),
              _card(context, child: Column(children: [
                // Quality presets as simple chips
                Row(children: [
                  Expanded(child: Text('Schedule Quality',
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 13, fontWeight: FontWeight.w700,
                          color: context._tp))),
                ]),
                const SizedBox(height: 4),
                Text('Higher quality takes more time to generate',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 11.5, color: context._ts)),
                const SizedBox(height: 14),
                Row(children: [
                  _QualityChip('Fast',    50,  200, vm, context),
                  const SizedBox(width: 8),
                  _QualityChip('Normal',  300, 600, vm, context),
                  const SizedBox(width: 8),
                  _QualityChip('Best',    600, 1500, vm, context),
                ]),
              ])),

              const SizedBox(height: 28),

              // ── Time Slot Constraints (collapsible) ────────────────────────────
              _CollapsibleSection(
                icon: Icons.lock_clock_rounded,
                label: 'Time Slot Constraints',
                color: context.watch<SettingsViewModel>().scheduleLocked
                    ? const Color(0xFFEF4444)
                    : AppTheme.accentAmber,
                badgeCount: context.watch<DataEntryViewModel>().timeSlotLocks.length,
                lockedMessage: context.watch<SettingsViewModel>().scheduleLocked
                    ? 'Schedule is locked. Unlock in settings to modify constraints.'
                    : null,
                child: const _TimeSlotLocksSection(),
              ),

              const SizedBox(height: 16),

              // ── Combined Courses (collapsible) ─────────────────────────────────
              _CollapsibleSection(
                icon: Icons.link_rounded,
                label: 'Combined Courses',
                color: context.watch<SettingsViewModel>().scheduleLocked
                    ? const Color(0xFFEF4444)
                    : AppTheme.accentViolet,
                badgeCount: context.watch<DataEntryViewModel>().combinedRules.length,
                lockedMessage: context.watch<SettingsViewModel>().scheduleLocked
                    ? 'Schedule is locked. Unlock in settings to modify combined courses.'
                    : null,
                child: const _CombinedCoursesSection(),
              ),

              const SizedBox(height: 16),

              // ── Manage Shifts (collapsible) ────────────────────────────────────
              Builder(builder: (ctx) {
                final deVm = ctx.watch<DataEntryViewModel>();
                final existingClassIds = deVm.classes.map((c) => c.id).toSet();
                final activeShiftRules = deVm.shiftRules
                    .where((r) => existingClassIds.contains(r.classId))
                    .length;
                return _CollapsibleSection(
                  icon: Icons.wb_twilight_rounded,
                  label: 'Manage Shifts',
                  color: const Color(0xFFF97316),
                  badgeCount: activeShiftRules,
                  child: const _ManageShiftsSection(),
                );
              }),

              const SizedBox(height: 20),

              // ── Re-Apply All Rules ─────────────────────────────────────────────
              Builder(builder: (ctx) {
                final deVm = ctx.watch<DataEntryViewModel>();
                final locked = ctx.watch<SettingsViewModel>().scheduleLocked;
                final hasRules = deVm.timeSlotLocks.isNotEmpty || deVm.combinedRules.isNotEmpty;
                final canRun = hasRules && !locked;
                return GestureDetector(
                  onTap: canRun ? () {
                    final moved = ctx.read<DataEntryViewModel>().reApplyAllRules();
                    final msg = moved > 0
                        ? 'Re-applied! $moved assignment${moved == 1 ? "" : "s"} updated.'
                        : 'All assignments already satisfy the current rules.';
                    final color = moved > 0 ? const Color(0xFF16A34A) : const Color(0xFF0284C7);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(msg, style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w600, color: Colors.white, fontSize: 13)),
                      backgroundColor: color, behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      margin: const EdgeInsets.all(16), duration: const Duration(seconds: 5),
                    ));
                  } : null,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: canRun ? const LinearGradient(
                          colors: [Color(0xFF7C3AED), Color(0xFF4F46E5)]) : null,
                      color: canRun ? null : const Color(0xFF6B7280).withValues(alpha: .15),
                      boxShadow: canRun ? [BoxShadow(
                          color: const Color(0xFF7C3AED).withValues(alpha: .35),
                          blurRadius: 14, offset: const Offset(0, 5))] : null,
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.sync_rounded, color: canRun ? Colors.white : Colors.grey, size: 20),
                      const SizedBox(width: 8),
                      Text('Re-Apply All Constraints & Combined Rules',
                          style: GoogleFonts.plusJakartaSans(
                              color: canRun ? Colors.white : Colors.grey,
                              fontWeight: FontWeight.w700, fontSize: 14)),
                    ]),
                  ),
                );
              }),

              const SizedBox(height: 28),

              // ── Account ───────────────────────────────────────────────────────
              _SectionLabel('Account', Icons.manage_accounts_rounded,
                  AppTheme.accentTeal, context),
              const SizedBox(height: 12),
              Builder(builder: (context) {
                final email = context.watch<AuthViewModel>().currentUser?.email;
                if (email == null) return const SizedBox.shrink();
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: context._bg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: context._bd, width: 1.2),
                  ),
                  child: Row(children: [
                    Icon(Icons.email_rounded, size: 20, color: context._ts),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(email,
                          style: GoogleFonts.plusJakartaSans(
                              fontSize: 14, fontWeight: FontWeight.w600,
                              color: context._tp)),
                    ),
                  ]),
                );
              }),
              Row(
                children: [
                  Expanded(child: const _BackupBtn()),
                  const SizedBox(width: 12),
                  Expanded(child: const _RestoreBtn()),
                ],
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () => context.read<AuthViewModel>().signOut(),
                child: Container(
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: const LinearGradient(colors: [Color(0xFFEF4444), Color(0xFFDC2626)]),
                    boxShadow: [BoxShadow(color: const Color(0xFFEF4444).withValues(alpha: .3), blurRadius: 12, offset: const Offset(0, 4))],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.logout_rounded, color: Colors.white, size: 20),
                      const SizedBox(width: 8),
                      Text('Sign Out',
                          style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.bold, fontSize: 14,
                              color: Colors.white)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 28),

              // ── Reset ───────────────────────────────────────────────────────
              Row(children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => _confirmReset(context, vm),
                    child: Container(
                      height: 50,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
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
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    onTap: () => _confirmClearData(context),
                    child: Container(
                      height: 50,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppTheme.error.withValues(alpha: .4)),
                        color: AppTheme.error.withValues(alpha: .05),
                      ),
                      child: Text('Clear All Data',
                          style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.w700, fontSize: 13,
                              color: AppTheme.error)),
                    ),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _card(BuildContext ctx, {required Widget child}) => Container(
    padding: const EdgeInsets.all(18),
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

  static String _dayRangeLabel(int days) {
    const ends = ['', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return 'Mon – ${ends[days.clamp(1, 6)]}  ($days days)';
  }

  static void _confirmReset(BuildContext ctx, SettingsViewModel vm) {
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

  static void _confirmClearData(BuildContext ctx) {
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
}

// ── Section label ─────────────────────────────────────────────────────────────
class _SectionLabel extends StatelessWidget {
  final String text; final IconData icon;
  final Color color; final BuildContext ctx;
  const _SectionLabel(this.text, this.icon, this.color, this.ctx);
  @override
  Widget build(BuildContext context) => Row(children: [
    Container(width: 30, height: 30,
        decoration: BoxDecoration(
            color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(8)),
        child: Icon(icon, size: 16, color: color)),
    const SizedBox(width: 10),
    Text(text, style: GoogleFonts.plusJakartaSans(
        fontWeight: FontWeight.w800, fontSize: 14, color: ctx._tp)),
  ]);
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

// ── Slider row ────────────────────────────────────────────────────────────────
class _SliderRow extends StatelessWidget {
  final IconData icon; final Color iconColor, color;
  final String title, subtitle;
  final double value, min, max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final BuildContext context;
  const _SliderRow({required this.icon, required this.iconColor,
      required this.title, required this.subtitle, required this.value,
      required this.min, required this.max, required this.divisions,
      required this.color, required this.onChanged, required this.context});
  @override
  Widget build(BuildContext ctx) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        Container(width: 36, height: 36,
            decoration: BoxDecoration(
                color: iconColor.withValues(alpha: .1), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 18, color: iconColor)),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: GoogleFonts.plusJakartaSans(
              fontSize: 13, fontWeight: FontWeight.w700, color: context._tp)),
          Text(subtitle, style: GoogleFonts.plusJakartaSans(
              fontSize: 11, color: context._ts)),
        ])),
      ]),
      SliderTheme(
        data: SliderTheme.of(ctx).copyWith(
          activeTrackColor: color,
          inactiveTrackColor: color.withValues(alpha: .15),
          thumbColor: color,
          overlayColor: color.withValues(alpha: .15),
          trackHeight: 3,
        ),
        child: Slider(
          value: value.clamp(min, max),
          min: min, max: max, divisions: divisions,
          onChanged: onChanged,
        ),
      ),
    ],
  );
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
  const _CollapsibleSection({
    required this.icon,
    required this.label,
    required this.color,
    required this.badgeCount,
    required this.child,
    this.lockedMessage,
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
      decoration: BoxDecoration(
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
                  child: Icon(Icons.keyboard_arrow_down_rounded,
                      color: widget.color, size: 22),
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
                        const Icon(Icons.lock_rounded, color: Color(0xFFEF4444), size: 16),
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
              labelBuilder: (s) => 'P${s.period} (${s.startTime}-${s.endTime})',
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
                  timeSlotLabel: 'P${_selSlot!.period} (${_selSlot!.startTime}-${_selSlot!.endTime})',
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
              icon: const Icon(Icons.add, size: 16, color: Colors.white),
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
              icon: const Icon(Icons.sync_rounded, size: 15),
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
                Icon(Icons.lock_rounded, size: 14, color: AppTheme.accentAmber),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${lock.courseCode} — ${lock.className ?? "All ${lock.level.name}"} → ${lock.timeSlotLabel}',
                    style: GoogleFonts.plusJakartaSans(fontSize: 12, color: context._tp, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close_rounded, size: 16, color: AppTheme.error),
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
          icon: Icon(Icons.arrow_drop_down, color: context._ts),
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
      trailingIcon: Icon(Icons.arrow_drop_down, color: context._ts),
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

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<DataEntryViewModel>();
    final isDark = context._dk;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Add Combined Course', style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w700, fontSize: 13, color: context._tp)),
        const SizedBox(height: 4),
        Text('Merge multiple classes into a single GA timeslot', style: GoogleFonts.plusJakartaSans(
            fontSize: 11, color: context._ts)),
        const SizedBox(height: 12),
        
        // Form
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // Course
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E26) : Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: context._bd),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<Course>(
                  value: _selCourse,
                  hint: Text('Select Course', style: GoogleFonts.plusJakartaSans(fontSize: 12, color: context._ts)),
                  dropdownColor: context._bg,
                  icon: Icon(Icons.arrow_drop_down, color: context._ts),
                  style: GoogleFonts.plusJakartaSans(fontSize: 13, color: context._tp, fontWeight: FontWeight.w500),
                  items: vm.courses.map((c) => DropdownMenuItem<Course>(
                    value: c,
                    child: Text(c.name),
                  )).toList(),
                  onChanged: (v) => setState(() { _selCourse = v; _selClassIds.clear(); }),
                ),
              ),
            ),
            
            // Classes Checkbox Dropdown
            if (_selCourse != null)
              Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E1E26) : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: context._bd),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: null,
                    hint: Text('${_selClassIds.length} Classes Selected', style: GoogleFonts.plusJakartaSans(fontSize: 12, color: _selClassIds.isNotEmpty ? AppTheme.accentViolet : context._ts)),
                    dropdownColor: context._bg,
                    icon: Icon(Icons.arrow_drop_down, color: context._ts),
                    items: vm.classes.map((c) {
                      final progName = vm.programs.where((p) => p.id == c.programId).firstOrNull?.name ?? 'Unknown';
                      final formattedName = '$progName - ${c.name}';
                      final isSelected = _selClassIds.contains(c.id);
                      return DropdownMenuItem<String>(
                        value: c.id,
                        child: Row(
                          children: [
                            Icon(isSelected ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded, color: isSelected ? AppTheme.accentViolet : context._ts, size: 18),
                            const SizedBox(width: 8),
                            Text(formattedName, style: GoogleFonts.plusJakartaSans(fontSize: 13, color: context._tp)),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          if (_selClassIds.contains(val)) { _selClassIds.remove(val); }
                          else { _selClassIds.add(val); }
                        });
                      }
                    },
                  ),
                ),
              ),
            
            // Add Button
            ElevatedButton.icon(
              onPressed: (_selCourse == null || _selClassIds.length < 2) ? null : () {
                final rule = CombinedClassRule(
                  id: DateTime.now().microsecondsSinceEpoch.toString(),
                  courseId: _selCourse!.id,
                  classIds: _selClassIds.toList(),
                );
                final log = vm.addCombinedRule(rule);
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
              icon: const Icon(Icons.add, size: 16, color: Colors.white),
              label: Text('Combine', style: GoogleFonts.plusJakartaSans(color: Colors.white, fontWeight: FontWeight.w700)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accentViolet,
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
                  Icon(Icons.link_rounded, size: 14, color: AppTheme.accentViolet),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${course?.name ?? "Unknown"} → $classNames',
                      style: GoogleFonts.plusJakartaSans(fontSize: 12, color: context._tp, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close_rounded, size: 16, color: AppTheme.error),
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

// ─────────────────────────────────────────────────────────────────────────────
// Manage Shifts Section
// ─────────────────────────────────────────────────────────────────────────────

class _ManageShiftsSection extends StatelessWidget {
  const _ManageShiftsSection();

  static const _morningColor = Color(0xFFF97316);
  static const _eveningColor = Color(0xFF6366F1);

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
          Icon(Icons.info_outline_rounded, size: 16, color: ts),
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
          const Icon(Icons.info_outline_rounded, size: 14, color: _morningColor),
          const SizedBox(width: 8),
          Expanded(child: Text(
            '☀️ Morning = P1–P3 (08:00–11:00)   🌙 Evening = P4–P6 (11:00–14:00)\n'
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
                    label: 'Morning', emoji: '☀️',
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
                    label: 'Evening', emoji: '🌙',
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
  final String label, emoji;
  final bool active, isDark;
  final Color activeColor;
  final VoidCallback onTap;

  const _ShiftChip({
    required this.label, required this.emoji,
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
          Text(emoji, style: const TextStyle(fontSize: 12)),
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
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Backup saved successfully!')));
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to save backup: $e')));
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
          const Icon(Icons.download_rounded, size: 20, color: col),
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
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Backup restored successfully!')));
          }
        } catch (e) {
          closeProgress();
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to restore backup: $e')));
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
          const Icon(Icons.restore_rounded, size: 20, color: col),
          const SizedBox(width: 8),
          Text('Restore Data', style: GoogleFonts.plusJakartaSans(
              fontSize: 14, fontWeight: FontWeight.bold, color: col)),
        ]),
      ),
    );
  }
}

