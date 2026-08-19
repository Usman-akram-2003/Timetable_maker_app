import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../viewmodels/data_entry_viewmodel.dart';
import '../../viewmodels/allocator_viewmodel.dart';
import '../../viewmodels/settings_viewmodel.dart';
import '../../viewmodels/theme_viewmodel.dart';
import '../../app_theme.dart';
import '../../utils/responsive.dart';
import 'data_entry_screen.dart';
import 'allocator_screen.dart';
import 'matrix_screen.dart';
import 'workload_screen.dart';
import 'settings_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Nav destination model
// ─────────────────────────────────────────────────────────────────────────────
class _NavDest {
  final IconData icon, selectedIcon;
  final String label;
  const _NavDest(this.icon, this.selectedIcon, this.label);
}

const _dests = [
  _NavDest(Icons.space_dashboard_outlined, Icons.space_dashboard,  'Overview'),
  _NavDest(Icons.library_add_outlined,     Icons.library_add,      'Data'),
  _NavDest(Icons.account_tree_outlined,    Icons.account_tree,     'Allocator'),
  _NavDest(Icons.grid_view_outlined,       Icons.grid_view,        'Schedule'),
  _NavDest(Icons.bar_chart_outlined,       Icons.bar_chart_rounded,'Workload'),
  _NavDest(Icons.settings_outlined,        Icons.settings_rounded, 'Settings'),
];

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  late final AnimationController _fadeCtrl;
  late final Animation<double>   _fadeAnim;
  Timer? _backupTimer;

  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 250));
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _fadeCtrl.forward();


    _screens = [
      _CommandCenter(onNavigate: (dashIdx, {dataEntryIdx}) {
        if (dataEntryIdx != null) {
          context.read<DataEntryViewModel>().setTargetTab(dataEntryIdx);
        }
        _switchTab(dashIdx);
      }),
      const DataEntryScreen(),
      AllocatorScreen(onNavigateToSchedule: () => _switchTab(3)),
      const MatrixScreen(),
      const WorkloadScreen(),
      const SettingsScreen(),

    ];

    // Silent safety net against the native Firestore crash found in this
    // app — a rotating local backup independent of the manual "Save Backup"
    // button, so a crash between manual backups can't lose everything since.
    Timer(const Duration(seconds: 10), _runAutoBackup);
    _backupTimer = Timer.periodic(const Duration(minutes: 15), (_) => _runAutoBackup());
  }

  void _runAutoBackup() {
    if (!mounted) return;
    final dataVm = context.read<DataEntryViewModel>();
    final allocVm = context.read<AllocatorViewModel>();
    final settingsVm = context.read<SettingsViewModel>();
    unawaited(dataVm.autoBackup(settingsVm.toJson(),
        allocatorData: allocVm.exportBackupData()));
  }

  @override
  void dispose() { _backupTimer?.cancel(); _fadeCtrl.dispose(); super.dispose(); }

  void _switchTab(int i) {
    if (i == _currentIndex) return;
    _fadeCtrl.reverse().then((_) {
      if (mounted) {
        setState(() => _currentIndex = i);
        _fadeCtrl.forward();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeVm = context.watch<ThemeViewModel>();
    final isDark  = themeVm.isDark;

    final body = Stack(children: [
      // IndexedStack keeps every tab's state alive across switches (half-typed
      // forms, scroll positions) instead of disposing the hidden screens.
      FadeTransition(opacity: _fadeAnim,
          child: IndexedStack(index: _currentIndex, children: _screens)),
      // One-step undo pill for the last risky multi-card operation
      // (make-space, force-assign, Fix Now, Suggest-Fix apply).
      Positioned(
        left: 0, right: 0, bottom: 16,
        child: Center(
          child: Consumer<DataEntryViewModel>(
            builder: (ctx, dataVm, _) {
              if (!dataVm.canUndo) return const SizedBox.shrink();
              return _UndoBanner(
                label: dataVm.undoLabel ?? '',
                onUndo: dataVm.undoLastChange,
              );
            },
          ),
        ),
      ),
    ]);

    return Scaffold(
      backgroundColor: isDark ? AppTheme.bgDeep : AppTheme.lightBg,
      body: Row(children: [
        _DesktopRail(
          isDark: isDark,
          selectedIndex: _currentIndex,
          onDestinationSelected: _switchTab,
        ),
        Expanded(child: body),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Desktop Navigation Rail
// ─────────────────────────────────────────────────────────────────────────────
class _DesktopRail extends StatelessWidget {
  final bool isDark;
  final int  selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  const _DesktopRail({required this.isDark, required this.selectedIndex,
      required this.onDestinationSelected});

  @override
  Widget build(BuildContext context) {
    final railBg = isDark ? AppTheme.bgMid : AppTheme.lightBgMid;
    final bdCol  = isDark ? AppTheme.divider : AppTheme.lightDivider;

    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: railBg,
        border: Border(right: BorderSide(color: bdCol)),
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .3 : .06),
            blurRadius: 16, offset: const Offset(4, 0))],
      ),
      child: Column(children: [
        // App logo header
        SizedBox(height: MediaQuery.paddingOf(context).top + 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            Container(width: 38, height: 38,
              decoration: BoxDecoration(gradient: AppTheme.heroGradient,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [BoxShadow(color: AppTheme.accentCyan.withValues(alpha: .35),
                      blurRadius: 12, offset: const Offset(0,4))]),
              child: const Icon(LucideIcons.table, color: Colors.white, size: 19)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Timetable', style: GoogleFonts.plusJakartaSans(
                  fontSize: 14, fontWeight: FontWeight.w800,
                  color: isDark ? AppTheme.textPrimary : AppTheme.lightText,
                  letterSpacing: -0.3)),
              Text('Maker', style: GoogleFonts.plusJakartaSans(
                  fontSize: 11, fontWeight: FontWeight.w500,
                  color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec)),
            ])),
          ]),
        ),
        const SizedBox(height: 28),
        Divider(color: bdCol, indent: 20, endIndent: 20, height: 1),
        const SizedBox(height: 12),
        // Nav items
        ...List.generate(_dests.length, (i) {
          final d   = _dests[i];
          final sel = selectedIndex == i;
          // Selected item is a solid filled pill (not a tint) — one
          // confident state instead of tint+border+dot competing for the
          // same signal.
          final fillCol = isDark ? AppTheme.accentBlue : const Color(0xFF151823);
          final txtCol = sel ? Colors.white
              : (isDark ? AppTheme.textSecondary : AppTheme.lightTextSec);
          final icnCol = sel ? Colors.white
              : (isDark ? AppTheme.textMuted : AppTheme.lightTextMut);

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
            child: GestureDetector(
              onTap: () => onDestinationSelected(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: sel ? fillCol : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: sel ? [BoxShadow(color: fillCol.withValues(alpha: .35),
                      blurRadius: 10, offset: const Offset(0, 4))] : null,
                ),
                child: Row(children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: KeyedSubtree(
                      key: ValueKey(sel),
                      child: d.label == 'Schedule'
                          ? Consumer<DataEntryViewModel>(
                              builder: (ctx, dataVm, _) {
                                final n = dataVm.countClashes();
                                final icon = Icon(sel ? d.selectedIcon : d.icon,
                                    color: icnCol, size: 20);
                                if (n == 0) return icon;
                                return Badge(
                                  label: Text(n > 9 ? '9+' : '$n'),
                                  backgroundColor: AppTheme.error,
                                  child: icon,
                                );
                              },
                            )
                          : Icon(sel ? d.selectedIcon : d.icon,
                              color: icnCol, size: 20),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Text(d.label, style: GoogleFonts.plusJakartaSans(
                      fontSize: 13, fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                      color: txtCol)),
                ]),
              ),
            ),
          );
        }),
        const Spacer(),
        Divider(color: bdCol, indent: 20, endIndent: 20, height: 1),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _ThemeToggleRail(isDark: isDark,
              onToggle: context.read<ThemeViewModel>().toggle),
        ),
        const SizedBox(height: 20),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Undo pill — appears after a make-space / force-assign / Fix Now /
// Suggest-Fix apply, until undone or superseded by the next such action.
// ─────────────────────────────────────────────────────────────────────────────
class _UndoBanner extends StatelessWidget {
  final String label;
  final VoidCallback onUndo;
  const _UndoBanner({required this.label, required this.onUndo});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.only(left: 16, right: 6, top: 6, bottom: 6),
    decoration: BoxDecoration(
      color: const Color(0xFF1E2D45),
      borderRadius: BorderRadius.circular(30),
      boxShadow: [
        BoxShadow(color: Colors.black.withValues(alpha: .35),
            blurRadius: 14, offset: const Offset(0, 4)),
      ],
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.check_circle_rounded, color: AppTheme.accentTeal, size: 16),
      const SizedBox(width: 8),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Text('Applied: $label',
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.plusJakartaSans(
                color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
      ),
      const SizedBox(width: 4),
      TextButton(
        onPressed: onUndo,
        style: TextButton.styleFrom(
            foregroundColor: AppTheme.accentCyan,
            padding: const EdgeInsets.symmetric(horizontal: 12)),
        child: Text('UNDO', style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w800, fontSize: 12.5)),
      ),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Theme Toggle — rail version (desktop, at bottom of sidebar)
// ─────────────────────────────────────────────────────────────────────────────
class _ThemeToggleRail extends StatelessWidget {
  final bool isDark;
  final VoidCallback onToggle;
  const _ThemeToggleRail({required this.isDark, required this.onToggle});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onToggle,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.bgCard : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: isDark ? AppTheme.divider : AppTheme.lightDivider),
      ),
      child: Row(children: [
        Icon(isDark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
            size: 16,
            color: isDark ? AppTheme.accentCyan : const Color(0xFFF59E0B)),
        const SizedBox(width: 10),
        Expanded(child: Text(isDark ? 'Dark Mode' : 'Light Mode',
            style: GoogleFonts.plusJakartaSans(
                fontSize: 12, fontWeight: FontWeight.w600,
                color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec))),
        Switch.adaptive(
          value: isDark,
          onChanged: (_) => onToggle(),
          // Always white thumb — visible on cyan track (dark) AND amber track (light)
          thumbColor: WidgetStateProperty.all(Colors.white),
          trackColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              // Dark mode ON → vivid cyan track
              return AppTheme.accentCyan;
            }
            // Light mode ON → warm amber track
            return const Color(0xFFF59E0B);
          }),
          trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ]),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Dashboard theme helpers
// ─────────────────────────────────────────────────────────────────────────────
extension _DashTh on BuildContext {
  bool get _dk  => Theme.of(this).brightness == Brightness.dark;
  Color get _tp => _dk ? AppTheme.textPrimary   : AppTheme.lightText;
  Color get _ts => _dk ? AppTheme.textSecondary : AppTheme.lightTextSec;
  Color get _dv => _dk ? AppTheme.divider       : AppTheme.lightDivider;


  BoxDecoration _solidC({double r = 18}) =>
      _dk ? AppTheme.solidCard(radius: r) : AppTheme.solidCardLight(radius: r);
}

// ─────────────────────────────────────────────────────────────────────────────
// Command Center (Dashboard Overview) — responsive
// ─────────────────────────────────────────────────────────────────────────────
class _CommandCenter extends StatelessWidget {
  final void Function(int dashIdx, {int? dataEntryIdx}) onNavigate;
  const _CommandCenter({required this.onNavigate});

  static const _amberGrad  = LinearGradient(colors: [Color(0xFFF59E0B), Color(0xFFD97706)]);
  static const _orangeGrad = LinearGradient(colors: [Color(0xFFF97316), Color(0xFFEA580C)]);
  static const _pinkGrad   = LinearGradient(colors: [Color(0xFFEC4899), Color(0xFFDB2777)]);
  static const _orange = Color(0xFFF97316);
  static const _pink   = Color(0xFFEC4899);

  @override
  Widget build(BuildContext context) {
    final hp = context.hPad;
    return Consumer2<DataEntryViewModel, AllocatorViewModel>(
      builder: (ctx, vm, allocVm, _) {
        final clashes = allocVm.lastError;
        final bool ready = vm.teachers.isNotEmpty && vm.courses.isNotEmpty &&
            vm.classes.isNotEmpty && vm.assignments.isNotEmpty;

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: ListView(
              padding: EdgeInsets.fromLTRB(hp, 56, hp, 32),
              children: [
                _header(ctx),
                const SizedBox(height: 28),
                _statGrid(ctx, vm),
                const SizedBox(height: 20),
                if (clashes != null) ...[_clashBanner(clashes), const SizedBox(height: 16)],
                IntrinsicHeight(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(flex: 16, child: _heroBanner(ready, vm, ctx)),
                    const SizedBox(width: 16),
                    Expanded(flex: 10, child: _howItWorks(ctx)),
                  ]),
                ),
                if (vm.assignments.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _summaryBar(ctx, vm),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header(BuildContext ctx) => Row(children: [
    Container(width: 52, height: 52,
        decoration: BoxDecoration(gradient: AppTheme.heroGradient,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [BoxShadow(color: AppTheme.accentCyan.withValues(alpha: .4),
                blurRadius: 18, offset: const Offset(0,6))]),
        child: const Icon(LucideIcons.table, color: Colors.white, size: 26)),
    const SizedBox(width: 14),
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Timetable Maker', style: GoogleFonts.plusJakartaSans(
          fontSize: 26, fontWeight: FontWeight.w800,
          color: ctx._tp, letterSpacing: -0.5)),
      Text('Academic Schedule Command Center', style: GoogleFonts.plusJakartaSans(
          fontSize: 13, color: ctx._ts, fontWeight: FontWeight.w500)),
    ]),
  ]);

  Widget _statGrid(BuildContext ctx, DataEntryViewModel vm) {
    final stats = [
      (LucideIcons.presentation, AppTheme.cyanGradient, AppTheme.accentCyan,  'Teachers',    vm.teachers.length,    1, 0),
      (LucideIcons.bookOpen,     AppTheme.tealGradient,  AppTheme.accentTeal,  'Courses',     vm.courses.length,     1, 1),
      (LucideIcons.folder,       _amberGrad,             AppTheme.accentAmber, 'Programs',    vm.programs.length,    1, 2),
      (LucideIcons.graduationCap,_orangeGrad,            _orange,              'Classes',     vm.classes.length,     1, 2),
      (LucideIcons.doorOpen,     _pinkGrad,              _pink,                'Rooms',       vm.rooms.length,       1, 3),
      (LucideIcons.checkSquare,  AppTheme.blueGradient,  AppTheme.accentBlue,  'Assignments', vm.assignments.length, 2, null),
    ];
    return AdaptiveGrid(
      cols: 3,
      children: stats.map((s) => _StatCard(
          icon: s.$1, glow: s.$3, label: s.$4, value: s.$5,
          highlight: s.$4 == 'Assignments',
          onTap: () => onNavigate(s.$6, dataEntryIdx: s.$7),)).toList(),
    );
  }

  Widget _clashBanner(String clashes) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: AppTheme.error.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.error.withValues(alpha: .4))),
    child: Row(children: [
      Container(width: 34, height: 34,
          decoration: BoxDecoration(color: AppTheme.error.withValues(alpha: .2),
              borderRadius: BorderRadius.circular(10)),
          child: const Icon(Icons.warning_amber_rounded, color: AppTheme.error, size: 18)),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Clash Detected', style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w800, color: AppTheme.error, fontSize: 13)),
        Text(clashes.split('\n').first, style: GoogleFonts.plusJakartaSans(
            color: AppTheme.error.withValues(alpha: .8), fontSize: 12),
            maxLines: 2, overflow: TextOverflow.ellipsis),
      ])),
    ]),
  );

  // Dark card with a single soft radial accent in the corner instead of a
  // full gradient fill — one deliberate glow reads calmer at this size than
  // color wall-to-wall, and it's the same "one accent, used once" idea the
  // stat grid's highlighted Assignments tile uses.
  Widget _heroBanner(bool ready, DataEntryViewModel vm, BuildContext ctx) {
    final glow = ready ? AppTheme.accentTeal : AppTheme.accentBlue;
    return Container(
      padding: const EdgeInsets.all(28),
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
                      glow.withValues(alpha: .35), glow.withValues(alpha: 0),
                    ])))),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(ready ? 'Ready to Generate' : 'Engine Standing By',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 19, fontWeight: FontWeight.w800,
                  color: Colors.white, letterSpacing: -0.3)),
          const SizedBox(height: 6),
          Text(ready
              ? 'All data loaded. Go to Allocator, run Clash Validator, view in Schedule.'
              : 'Add data in Manage Data, then assign slots in Allocator.',
              style: GoogleFonts.plusJakartaSans(fontSize: 12.5,
                  color: Colors.white.withValues(alpha: .65), height: 1.6)),
          if (ready) ...[
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 6, children: [
              _Pill('${vm.teachers.length} Teachers', AppTheme.accentCyan),
              _Pill('${vm.courses.length} Courses',   AppTheme.accentTeal),
              _Pill('${vm.assignments.length} Assigned', Colors.white),
              _Pill('${vm.rooms.length} Rooms',       AppTheme.accentAmber),
            ]),
          ],
          const SizedBox(height: 18),
          GestureDetector(
            onTap: () => onNavigate(2),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
              decoration: BoxDecoration(gradient: AppTheme.heroGradient,
                  borderRadius: BorderRadius.circular(10)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('Open Allocator', style: GoogleFonts.plusJakartaSans(
                    fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.white)),
                const SizedBox(width: 8),
                const Icon(Icons.arrow_forward_rounded, size: 15, color: Colors.white),
              ]),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _summaryBar(BuildContext ctx, DataEntryViewModel vm) {
    final auto   = vm.assignments.where((a) => a.autoAssigned).length;
    final manual = vm.assignments.length - auto;
    final unique = vm.assignments.map((a) => a.teacher.id).toSet().length;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: ctx._solidC(r: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 3, height: 14,
              decoration: BoxDecoration(gradient: AppTheme.blueGradient,
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 10),
          Text('Assignment Summary', style: GoogleFonts.plusJakartaSans(
              fontSize: 13, fontWeight: FontWeight.w700, color: ctx._tp)),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          _SumItem('Total',         '${vm.assignments.length}', AppTheme.accentBlue),
          _divL(ctx), _SumItem('Auto',   '$auto',   AppTheme.accentCyan),
          _divL(ctx), _SumItem('Manual', '$manual', AppTheme.accentBlue),
          _divL(ctx), _SumItem('Teachers Used', '$unique', AppTheme.accentTeal),
        ]),
      ]),
    );
  }

  Widget _divL(BuildContext ctx) => Container(
      width: 1, height: 32, color: ctx._dv, margin: const EdgeInsets.symmetric(horizontal: 12));

  Widget _howItWorks(BuildContext ctx) {
    final steps = [
      (LucideIcons.userPlus, AppTheme.accentCyan,  'Add faculty and courses'),
      (LucideIcons.clock,    AppTheme.accentAmber, 'Set up rooms and periods'),
      (LucideIcons.workflow, AppTheme.accentBlue,  'Assign slots in the Allocator'),
      (LucideIcons.listChecks, AppTheme.accentTeal,'Validate and view the matrix'),
    ];

    Widget stepTile(int i) {
      final s = steps[i];
      return Padding(
        padding: EdgeInsets.only(bottom: i == steps.length - 1 ? 0 : 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 24, height: 24,
              decoration: BoxDecoration(color: s.$2.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(7)),
              alignment: Alignment.center,
              child: Icon(s.$1, size: 13, color: s.$2)),
          const SizedBox(width: 10),
          Expanded(child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(s.$3, style: GoogleFonts.plusJakartaSans(
                color: ctx._ts, fontSize: 11.5, height: 1.4, fontWeight: FontWeight.w500)),
          )),
        ]),
      );
    }

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: ctx._dk ? AppTheme.bgCard : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: ctx._dk ? AppTheme.divider : const Color(0xFFE6E9F0)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: ctx._dk ? .3 : .04),
            blurRadius: 10, offset: const Offset(0, 6))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('How It Works', style: GoogleFonts.plusJakartaSans(
            fontSize: 12.5, fontWeight: FontWeight.w700, color: ctx._tp)),
        const SizedBox(height: 16),
        ...List.generate(steps.length, stepTile),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Stat Card
// ─────────────────────────────────────────────────────────────────────────────
class _StatCard extends StatelessWidget {
  final IconData icon;
  final Color glow; final String label; final int value;
  final VoidCallback onTap;
  // The one metric worth drawing the eye to (Assignments) renders as a
  // solid brand-gradient tile instead of a flat tint — a single deliberate
  // accent among six calm cards, not six competing colors.
  final bool highlight;
  const _StatCard({required this.icon, required this.glow, required this.label,
      required this.value, required this.onTap, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final onGrad = highlight ? Colors.white : null;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.toDouble()),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOut,
      builder: (_, v, __) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: highlight ? AppTheme.heroGradient : null,
            color: highlight ? null : (dark ? AppTheme.bgCard : Colors.white),
            border: highlight ? null : Border.all(
                color: dark ? AppTheme.divider : const Color(0xFFE6E9F0)),
            boxShadow: [BoxShadow(
                color: (highlight ? AppTheme.accentBlue : Colors.black)
                    .withValues(alpha: highlight ? .28 : (dark ? .3 : .04)),
                blurRadius: highlight ? 20 : 10, offset: const Offset(0, 6))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(width: 30, height: 30,
                decoration: BoxDecoration(
                    color: onGrad?.withValues(alpha: .2) ?? glow.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(9)),
                child: Icon(icon, color: onGrad ?? glow, size: 17)),
            const SizedBox(height: 18),
            Text(v.toInt().toString(), style: GoogleFonts.plusJakartaSans(
                fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5,
                color: onGrad ?? (dark ? AppTheme.textPrimary : AppTheme.lightText))),
            const SizedBox(height: 2),
            Text(label, style: GoogleFonts.plusJakartaSans(
                fontSize: 11, fontWeight: FontWeight.w600,
                color: onGrad?.withValues(alpha: .85) ??
                    (dark ? AppTheme.textSecondary : AppTheme.lightTextSec))),
          ]),
        ),
      ),
    );
  }
}

class _SumItem extends StatelessWidget {
  final String label, value; final Color color;
  const _SumItem(this.label, this.value, this.color);
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Expanded(child: Column(children: [
      Text(value, style: GoogleFonts.plusJakartaSans(
          fontSize: 22, fontWeight: FontWeight.w800, color: color)),
      const SizedBox(height: 2),
      Text(label, style: GoogleFonts.plusJakartaSans(
          fontSize: 10, fontWeight: FontWeight.w500,
          color: dark ? AppTheme.textSecondary : AppTheme.lightTextSec),
          textAlign: TextAlign.center),
    ]));
  }
}

class _Pill extends StatelessWidget {
  final String label; final Color color;
  const _Pill(this.label, this.color);
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: .15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: .25))),
      child: Text(label, style: GoogleFonts.plusJakartaSans(
          color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)));
}