import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'dart:async';
import '../../viewmodels/data_entry_viewmodel.dart';
import '../../viewmodels/allocator_viewmodel.dart';
import '../../models/class_model.dart';
import '../../models/course.dart';
import '../../models/room.dart';
import '../../models/time_slot.dart';
import '../../models/education_level.dart';
import '../../models/teacher.dart';
import '../../services/excel_import_service.dart';
import '../../app_theme.dart';
import '../../utils/responsive.dart';
import 'timetable_grid_import_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Theme-aware helpers (accessed by all widgets in this file)
// ─────────────────────────────────────────────────────────────────────────────
extension _Th on BuildContext {
  bool get _dark => Theme.of(this).brightness == Brightness.dark;

  // Flat card everywhere — a neutral border + plain shadow reads calmer
  // than a colored glow around every "Add X" panel, and matches the
  // Dashboard redesign's card language. The accent color argument is kept
  // (call sites still pass one) so nothing else has to change, it's just
  // no longer used to tint the shadow.
  BoxDecoration glowCard(Color c, {double radius = 18}) => solidCard(radius: radius);

  BoxDecoration solidCard({double radius = 12}) => _dark
      ? AppTheme.solidCard(radius: radius)
      : AppTheme.solidCardLight(radius: radius);

  void showErr(String msg) {
    ScaffoldMessenger.of(this).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.plusJakartaSans(color: Colors.white, fontWeight: FontWeight.w600)),
      backgroundColor: AppTheme.error,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }
}

class DataEntryScreen extends StatefulWidget {
  const DataEntryScreen({super.key});
  @override
  State<DataEntryScreen> createState() => _DataEntryScreenState();
}

class _DataEntryScreenState extends State<DataEntryScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 5, vsync: this);
    _tab.addListener(() {
      if (!_tab.indexIsChanging) {
        context.read<DataEntryViewModel>().setTargetTab(_tab.index);
      }
    });
  }
  @override
  void dispose() { _tab.dispose(); super.dispose(); }

  static const _tabs = [
    (LucideIcons.presentation,  'Teachers'),
    (LucideIcons.bookOpen,      'Courses'),
    (LucideIcons.graduationCap, 'Classes'),
    (LucideIcons.doorOpen,      'Rooms'),
    (LucideIcons.clock,         'Time Slots'),
  ];
  static const _colors = [
    AppTheme.accentCyan, AppTheme.accentBlue,
    Color(0xFFF97316), AppTheme.accentAmber, AppTheme.accentTeal,
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = context._dark;
    final hp = context.hPad;
    final vm = context.watch<DataEntryViewModel>();
    
    if (_tab.index != vm.targetDataEntryTab) {
      // Defer past this build — calling animateTo() (which marks the
      // TabController's listeners dirty) synchronously during build() throws
      // "setState() or markNeedsBuild() called during build".
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tab.index != vm.targetDataEntryTab) {
          _tab.animateTo(vm.targetDataEntryTab);
        }
      });
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(children: [
            const SizedBox(height: 40),
            _header(isDark, hp),
            const SizedBox(height: 20),
            _tabBar(isDark, hp),
            const SizedBox(height: 16),
            Expanded(child: TabBarView(controller: _tab, children: [
              _TeachersTab(), _CoursesTab(), _ClassesTab(), _RoomsTab(), _TimeSlotsTab(),
            ])),
          ]),
        ),
      ),
    );
  }

  Widget _header(bool isDark, double hp) => Padding(
    padding: EdgeInsets.symmetric(horizontal: hp),
    child: Row(children: [
      Container(width: 48, height: 48,
        decoration: BoxDecoration(gradient: AppTheme.cyanGradient,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: AppTheme.accentCyan.withValues(alpha: .35), blurRadius: 18, offset: const Offset(0,5))]),
        child: const Icon(LucideIcons.database, color: Colors.white, size: 22)),
      const SizedBox(width: 16),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Manage Data', style: GoogleFonts.plusJakartaSans(
            fontSize: 24, fontWeight: FontWeight.w800,
            color: isDark ? AppTheme.textPrimary : AppTheme.lightText,
            letterSpacing: -0.5)),
        Text('Add teachers, courses, classes, rooms and time slots',
            style: GoogleFonts.plusJakartaSans(fontSize: 13,
                color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec)),
      ])),
      const SizedBox(width: 12),
      _ImportMenuBtn(),
    ]),
  );

  Widget _tabBar(bool isDark, double hp) => Padding(
    padding: EdgeInsets.symmetric(horizontal: hp),
    child: AnimatedBuilder(
      animation: _tab,
      builder: (_, __) => Row(children: List.generate(_tabs.length, (i) {
        final sel = _tab.index == i;
        final col = _colors[i];
        final unselBg = isDark ? AppTheme.bgMid : const Color(0xFFF1F5F9);
        final unselBd = isDark ? AppTheme.divider : AppTheme.lightDivider;
        return Expanded(child: GestureDetector(
          onTap: () => _tab.animateTo(i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: EdgeInsets.only(right: i < 4 ? 8 : 0),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: sel ? col.withValues(alpha: .15) : unselBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: sel ? col : unselBd, width: sel ? 1.5 : 1.0)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(_tabs[i].$1,
                  color: sel ? col : (isDark ? AppTheme.textMuted : AppTheme.lightTextMut),
                  size: 18),
              const SizedBox(height: 4),
              Text(_tabs[i].$2, style: GoogleFonts.plusJakartaSans(
                  fontSize: 10, fontWeight: FontWeight.w700,
                  color: sel ? col : (isDark ? AppTheme.textMuted : AppTheme.lightTextMut))),
            ]),
          ),
        ));
      })),
    ),
  );
}

// ── TEACHERS ──────────────────────────────────────────────────────────────────
class _TeachersTab extends StatefulWidget {
  @override State<_TeachersTab> createState() => _TeachersTabState();
}
class _TeachersTabState extends State<_TeachersTab> {
  static const _col = AppTheme.accentCyan;
  final _dept = TextEditingController();
  String? _editingDept;
  
  final _n = TextEditingController();
  String? _selectedDept;
  String? _editingTeacherId;

  final Set<String> _open = {};
  final _search = TextEditingController();
  String _query = '';

  @override void dispose() { _dept.dispose(); _n.dispose(); _search.dispose(); super.dispose(); }

  void _submitDept() {
    if (_dept.text.trim().isEmpty) { context.showErr('Department Name cannot be empty'); return; }
    if (_editingDept == null) {
      context.read<DataEntryViewModel>().addDepartment(_dept.text); _dept.clear();
    } else {
      context.read<DataEntryViewModel>().updateDepartment(_editingDept!, _dept.text);
      _dept.clear(); setState(() => _editingDept = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<DataEntryViewModel>();
    final isDark = context._dark;
    
    // Ensure selected dept is valid
    if (_selectedDept != null && !vm.departments.contains(_selectedDept)) {
      _selectedDept = null;
    }
    if (_selectedDept == null && vm.departments.isNotEmpty) {
      _selectedDept = vm.departments.first;
    }
    
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 28), children: [
      Container(padding: const EdgeInsets.all(20),
        decoration: context.glowCard(_col, radius: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _bar('Add Department', _col, isDark), const SizedBox(height: 14),
          _Field(ctrl: _dept, label: 'Department Name', icon: LucideIcons.building2, color: _col,
              hint: 'Computer Science, Mathematics…',
              textInputAction: TextInputAction.done, onSubmitted: (_) => _submitDept()),
          const SizedBox(height: 16),
          _editingDept == null ? _AddBtn(color: _col, onTap: _submitDept)
              : _SaveCancelBtns(color: _col, onSave: _submitDept,
                  onCancel: () { _dept.clear(); setState(() => _editingDept = null); }),
        ])),
      const SizedBox(height: 16),
      Container(padding: const EdgeInsets.all(20),
        decoration: context.glowCard(_col, radius: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _bar('Add Teacher', _col, isDark), const SizedBox(height: 14),
          _Field(ctrl: _n, label: 'Teacher Name', icon: Icons.person_outline_rounded, color: _col,
              hint: 'Prof. Ali, Dr. Sarah…',
              formatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z .]'))]),
          const SizedBox(height: 12),
          Text('Department', style: GoogleFonts.plusJakartaSans(
              fontSize: 11.5, fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec)),
          const SizedBox(height: 7),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.bgMid : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: isDark ? AppTheme.divider : const Color(0xFFE2E8F0))
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _selectedDept,
                isExpanded: true,
                hint: Text(vm.departments.isEmpty ? 'Add a department first' : 'Select Department', style: GoogleFonts.plusJakartaSans(color: isDark ? AppTheme.textMuted : AppTheme.lightTextMut, fontSize: 13)),
                dropdownColor: isDark ? AppTheme.bgMid : Colors.white,
                icon: const Icon(Icons.arrow_drop_down_rounded, color: _col),
                items: vm.departments.map((d) => DropdownMenuItem(
                  value: d,
                  child: Text(d, style: GoogleFonts.plusJakartaSans(color: isDark ? AppTheme.textPrimary : AppTheme.lightText, fontSize: 14, fontWeight: FontWeight.w600)),
                )).toList(),
                onChanged: vm.departments.isEmpty ? null : (v) => setState(() => _selectedDept = v),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _editingTeacherId == null ? _AddBtn(color: _col, onTap: () {
            if (_n.text.trim().isEmpty) { context.showErr('Teacher Name cannot be empty'); return; }
            context.read<DataEntryViewModel>().addTeacher(_n.text, department: _selectedDept ?? '');
            _n.clear(); 
          }) : _SaveCancelBtns(color: _col, onSave: () {
            if (_n.text.trim().isEmpty) { context.showErr('Teacher Name cannot be empty'); return; }
            context.read<DataEntryViewModel>().updateTeacher(_editingTeacherId!, _n.text, department: _selectedDept ?? '');
            _n.clear(); setState(() => _editingTeacherId = null);
          }, onCancel: () { _n.clear(); setState(() => _editingTeacherId = null); }),
        ])),
      const SizedBox(height: 20),
      if (vm.departments.isEmpty && vm.teachers.isEmpty) Center(child: Padding(padding: const EdgeInsets.symmetric(vertical: 32),
        child: Text('Add a department and teacher above to get started',
            style: GoogleFonts.plusJakartaSans(
                color: isDark ? AppTheme.textMuted : AppTheme.lightTextMut, fontSize: 14))))
      else ...[
        _SearchBar(ctrl: _search, color: _col, hint: 'Search department or teacher…',
            onChanged: (v) => setState(() => _query = v.trim().toLowerCase())),
        const SizedBox(height: 16),
        Builder(builder: (ctx) {
          final q = _query;
          bool teacherMatches(Teacher t) => t.name.toLowerCase().contains(q);
          final matchedDepts = vm.departments.where((d) {
            if (q.isEmpty) return true;
            if (d.toLowerCase().contains(q)) return true;
            return vm.teachers.any((t) => t.department == d && teacherMatches(t));
          }).toList();
          final uncategorized = vm.teachers.where((t) => !vm.departments.contains(t.department)).toList();
          final matchedUncategorized = q.isEmpty ? uncategorized : uncategorized.where(teacherMatches).toList();

          if (q.isNotEmpty && matchedDepts.isEmpty && matchedUncategorized.isEmpty) {
            return Center(child: Padding(padding: const EdgeInsets.symmetric(vertical: 32),
              child: Text('No departments or teachers match "$_query"',
                  style: GoogleFonts.plusJakartaSans(
                      color: isDark ? AppTheme.textMuted : AppTheme.lightTextMut, fontSize: 14))));
          }

          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _countHeader('Departments', matchedDepts.length, _col, isDark),
            const SizedBox(height: 12),
            ...matchedDepts.map((d) {
              final deptNameMatches = q.isNotEmpty && d.toLowerCase().contains(q);
              final allTeachers = vm.teachers.where((t) => t.department == d).toList();
              final shownTeachers = q.isEmpty || deptNameMatches
                  ? allTeachers
                  : allTeachers.where(teacherMatches).toList();
              final open = q.isNotEmpty || _open.contains(d);
              return _DeptCard(dept: d, teachers: shownTeachers, open: open,
                onToggle: () => setState(() { if (_open.contains(d)) { _open.remove(d); } else { _open.add(d); } }),
                onEditDept: () { _dept.text = d; setState(() => _editingDept = d); },
                onDelDept: () => context.read<DataEntryViewModel>().removeDepartment(d),
                onEditTeacher: (t) { _n.text = t.name; setState(() { _editingTeacherId = t.id; _selectedDept = t.department; }); },
                onDelTeacher: (id) {
                  context.read<AllocatorViewModel>().purgeByTeacherId(id);
                  context.read<DataEntryViewModel>().removeTeacher(id);
                });
            }),
            if (matchedUncategorized.isNotEmpty) Builder(builder: (ctx) {
              final open = q.isNotEmpty || _open.contains('__uncategorized__');
              return _DeptCard(dept: 'Uncategorized', teachers: matchedUncategorized, open: open,
                isUncategorized: true,
                onToggle: () => setState(() { if (_open.contains('__uncategorized__')) { _open.remove('__uncategorized__'); } else { _open.add('__uncategorized__'); } }),
                onEditDept: () {}, onDelDept: () {},
                onEditTeacher: (t) { _n.text = t.name; setState(() { _editingTeacherId = t.id; _selectedDept = null; }); },
                onDelTeacher: (id) {
                  context.read<AllocatorViewModel>().purgeByTeacherId(id);
                  context.read<DataEntryViewModel>().removeTeacher(id);
                });
            }),
          ]);
        }),
      ],
      const SizedBox(height: 32),
    ]);
  }
}

class _DeptCard extends StatelessWidget {
  final String dept;
  final List<Teacher> teachers;
  final bool open;
  final bool isUncategorized;
  final VoidCallback onToggle;
  final VoidCallback onEditDept;
  final VoidCallback onDelDept;
  final void Function(Teacher t) onEditTeacher;
  final ValueChanged<String> onDelTeacher;

  const _DeptCard({required this.dept, required this.teachers, required this.open,
      this.isUncategorized = false, required this.onToggle,
      required this.onEditDept, required this.onDelDept, required this.onEditTeacher, required this.onDelTeacher});

  static const _col = AppTheme.accentCyan;

  @override
  Widget build(BuildContext context) {
    final isDark = context._dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: context.solidCard(radius: 16),
      child: Column(children: [
        GestureDetector(onTap: onToggle, child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(children: [
            Container(width: 38, height: 38,
              decoration: BoxDecoration(color: _col.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _col.withValues(alpha: .3))),
              child: const Center(child: Icon(LucideIcons.building2, color: _col, size: 18))),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(dept, style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w700, color: isDark ? AppTheme.textPrimary : AppTheme.lightText, fontSize: 14)),
              Text('${teachers.length} teacher${teachers.length == 1 ? '' : 's'}',
                  style: GoogleFonts.plusJakartaSans(fontSize: 12, color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec)),
            ])),
            if (!isUncategorized) ...[
              IconButton(icon: const Icon(Icons.edit_rounded, size: 18), color: AppTheme.accentTeal, onPressed: onEditDept, splashRadius: 16),
              IconButton(icon: const Icon(Icons.delete_outline_rounded, size: 18), color: AppTheme.error, onPressed: onDelDept, splashRadius: 16),
            ],
            Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: isDark ? AppTheme.textMuted : AppTheme.lightTextMut, size: 22),
          ]),
        )),
        if (open) ...[
          Divider(color: isDark ? AppTheme.divider : AppTheme.lightDivider, height: 1),
          ...teachers.map((t) => Container(
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: (isDark ? AppTheme.divider : AppTheme.lightDivider), width: .5))),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(children: [
              Container(width: 6, height: 6, decoration: const BoxDecoration(shape: BoxShape.circle, color: _col)),
              const SizedBox(width: 12),
              Expanded(child: Text(t.name, style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: isDark ? AppTheme.textPrimary : AppTheme.lightText, fontSize: 13))),
              IconButton(icon: const Icon(Icons.edit_rounded, size: 16), color: AppTheme.accentTeal, onPressed: () => onEditTeacher(t), splashRadius: 14),
              IconButton(icon: const Icon(Icons.close_rounded, size: 16), color: AppTheme.error, onPressed: () => onDelTeacher(t.id), splashRadius: 14),
            ]),
          )),
        ],
      ]),
    );
  }
}

// ── COURSES ───────────────────────────────────────────────────────────────────
class _CoursesTab extends StatefulWidget {
  @override State<_CoursesTab> createState() => _CoursesTabState();
}
class _CoursesTabState extends State<_CoursesTab> with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _tabCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() { _tabCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final vm    = context.watch<DataEntryViewModel>();
    final isDark = context._dark;
    final interCourses = vm.courses.where((c) => c.level == EducationLevel.intermediate).toList();
    final bachCourses  = vm.courses.where((c) => c.level == EducationLevel.bachelors).toList();

    // sub-tab pill strip
    final tabBar = Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.bgMid : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? AppTheme.divider : const Color(0xFFE2E8F0)),
      ),
      child: TabBar(
        controller: _tabCtrl,
        indicator: BoxDecoration(
          gradient: LinearGradient(colors: [
            AppTheme.accentBlue,
            AppTheme.accentBlue.withValues(alpha: .8),
          ]),
          borderRadius: BorderRadius.circular(11),
          boxShadow: [BoxShadow(color: AppTheme.accentBlue.withValues(alpha: .3), blurRadius: 8, offset: const Offset(0, 2))],
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        labelColor: Colors.white,
        unselectedLabelColor: isDark ? AppTheme.textMuted : AppTheme.lightTextMut,
        labelStyle: GoogleFonts.plusJakartaSans(fontSize: 12, fontWeight: FontWeight.w700),
        unselectedLabelStyle: GoogleFonts.plusJakartaSans(fontSize: 12, fontWeight: FontWeight.w600),
        tabs: [
          Tab(text: 'Intermediate  (${interCourses.length})'),
          Tab(text: "Bachelor's  (${bachCourses.length})"),
        ],
      ),
    );

    return Column(children: [
      tabBar,
      Expanded(child: TabBarView(
        controller: _tabCtrl,
        children: [
          _CourseForm(level: EducationLevel.intermediate, courses: interCourses),
          _CourseForm(level: EducationLevel.bachelors,   courses: bachCourses),
        ],
      )),
    ]);
  }
}

// ── Single-level course form + list ──────────────────────────────────────────
class _CourseForm extends StatefulWidget {
  final EducationLevel level;
  final List<Course> courses;
  const _CourseForm({required this.level, required this.courses});
  @override State<_CourseForm> createState() => _CourseFormState();
}
class _CourseFormState extends State<_CourseForm> {
  final _n = TextEditingController(), _c = TextEditingController();
  late int _creditHours;
  String? _editingId;
  final _search = TextEditingController();
  String _query = '';

  bool get _isInter => widget.level == EducationLevel.intermediate;

  @override
  void initState() {
    super.initState();
    _creditHours = _isInter ? 6 : 3;
  }

  @override
  void didUpdateWidget(_CourseForm old) {
    super.didUpdateWidget(old);
    // if we switch tabs, reset _creditHours default
    if (old.level != widget.level) {
      setState(() => _creditHours = _isInter ? 6 : 3);
    }
  }

  @override void dispose() { _n.dispose(); _c.dispose(); _search.dispose(); super.dispose(); }

  void _submitCourse() {
    if (_n.text.trim().isEmpty) { context.showErr('Course Name cannot be empty'); return; }
    if (_c.text.trim().isEmpty) { context.showErr('Course Code cannot be empty'); return; }
    if (!RegExp(r'^[A-Za-z]+-[0-9]+$').hasMatch(_c.text.trim())) {
      context.showErr('Course Code must look like CS-101 (letters, dash, numbers)');
      return;
    }
    if (_editingId == null) {
      final added = context.read<DataEntryViewModel>().addCourse(
          _n.text, _c.text, creditHours: _creditHours, level: widget.level);
      if (!added) {
        context.showErr('Duplicate course: ${_c.text.trim().toUpperCase()} already exists at this level');
        return;
      }
      _n.clear(); _c.clear();
      setState(() => _creditHours = _isInter ? 6 : 3);
    } else {
      final saved = context.read<DataEntryViewModel>().updateCourse(
          _editingId!, _n.text, _c.text, creditHours: _creditHours, level: widget.level);
      if (!saved) {
        context.showErr('Duplicate course: ${_c.text.trim().toUpperCase()} already exists at this level');
        return;
      }
      _n.clear(); _c.clear();
      setState(() { _editingId = null; _creditHours = _isInter ? 6 : 3; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context._dark;
    final accentColor = _isInter ? AppTheme.accentTeal : AppTheme.accentBlue;
    final query = _query;
    final filteredCourses = query.isEmpty
        ? widget.courses
        : widget.courses.where((c) =>
            c.name.toLowerCase().contains(query) || c.code.toLowerCase().contains(query)).toList();

    return _Shell(color: accentColor, formContent: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Level badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: accentColor.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: accentColor.withValues(alpha: .35)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_isInter ? LucideIcons.school : LucideIcons.landmark,
                size: 12, color: accentColor),
            const SizedBox(width: 5),
            Text(_isInter ? 'Intermediate' : "Bachelor's",
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 11, fontWeight: FontWeight.w700, color: accentColor)),
          ]),
        ),
        const SizedBox(height: 14),
        _Field(ctrl: _n, label: 'Course Name', icon: Icons.menu_book_outlined,
            color: accentColor, hint: _isInter ? 'Physics, English, Urdu…' : 'Data Structures…',
            formatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z ]'))]),
        const SizedBox(height: 12),
        _Field(ctrl: _c, label: 'Course Code', icon: Icons.tag_rounded,
            color: accentColor, hint: _isInter ? 'PHY-101, ENG-102…' : 'CS-201…',
            formatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9-]'))],
            textInputAction: TextInputAction.done, onSubmitted: (_) => _submitCourse()),
        const SizedBox(height: 14),
        // ── Credit Hours ──────────────────────────────────────────────────────
        Text('Credit Hours  (lectures / week)',
            style: GoogleFonts.plusJakartaSans(fontSize: 12, fontWeight: FontWeight.w600,
                color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec)),
        const SizedBox(height: 8),
        // Flexible 1–6 selector (default 6 for Inter, 3 for Bach)
        Row(children: List.generate(6, (i) {
          final h   = i + 1;
          final sel = _creditHours == h;
          return Expanded(child: GestureDetector(
            onTap: () => setState(() => _creditHours = h),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: EdgeInsets.only(right: i < 5 ? 6 : 0),
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: sel ? accentColor.withValues(alpha: .18)
                           : (isDark ? AppTheme.bgMid : const Color(0xFFF1F5F9)),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: sel ? accentColor
                             : (isDark ? AppTheme.divider : AppTheme.lightDivider),
                  width: sel ? 1.5 : 1.0)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('$h', style: GoogleFonts.plusJakartaSans(
                    fontSize: 15, fontWeight: FontWeight.w800,
                    color: sel ? accentColor
                               : (isDark ? AppTheme.textMuted : AppTheme.lightTextMut))),
                Text(h == 1 ? 'hr' : 'hrs', style: GoogleFonts.plusJakartaSans(
                    fontSize: 9, fontWeight: FontWeight.w600,
                    color: sel ? accentColor
                               : (isDark ? AppTheme.textMuted : AppTheme.lightTextMut))),
              ]),
            ),
          ));
        })),
        const SizedBox(height: 6),
        Text('$_creditHours lecture${_creditHours > 1 ? 's' : ''} per week will be scheduled for this course',
            style: GoogleFonts.plusJakartaSans(fontSize: 11,
                color: accentColor.withValues(alpha: .8),
                fontStyle: FontStyle.italic)),
        if (_isInter && _creditHours == 6)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Default for Intermediate (6 days × 1 lecture)',
                style: GoogleFonts.plusJakartaSans(fontSize: 10,
                    color: accentColor.withValues(alpha: .6),
                    fontStyle: FontStyle.italic)),
          ),
        const SizedBox(height: 16),
        _editingId == null ? _AddBtn(color: accentColor, onTap: _submitCourse)
            : _SaveCancelBtns(color: accentColor, onSave: _submitCourse, onCancel: () {
          _n.clear(); _c.clear();
          setState(() { _editingId = null; _creditHours = _isInter ? 6 : 3; });
        }),
      ]),
      searchBar: widget.courses.isEmpty ? null : _SearchBar(ctrl: _search, color: accentColor,
          hint: 'Search course name or code…', onChanged: (v) => setState(() => _query = v.trim().toLowerCase())),
      count: filteredCourses.length,
      label: _isInter ? 'intermediate courses' : "bachelor's courses",
      emptyMessage: query.isNotEmpty
          ? 'No courses match "$query"'
          : (_isInter
              ? 'No intermediate courses yet.\nAdd courses like Physics, English, Urdu, etc.'
              : "No bachelor's courses yet.\nAdd courses like Data Structures, Calculus, etc."),
      list: filteredCourses.isEmpty
          ? const SizedBox.shrink()
          : ListView.separated(
              shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
              itemCount: filteredCourses.length, separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final c = filteredCourses[i];
                return _Tile(
                  color: accentColor,
                  badge: c.code.length > 5 ? c.code.substring(0, 5) : c.code,
                  title: c.name,
                  subtitle: '${c.code}  ·  ${c.creditHours} credit hr${c.creditHours > 1 ? 's' : ''}',
                  onEdit: () {
                    _n.text = c.name; _c.text = c.code;
                    setState(() { _editingId = c.id; _creditHours = c.creditHours; });
                  },
                  onDelete: () {
                    context.read<AllocatorViewModel>().purgeByCourseId(c.id);
                    context.read<DataEntryViewModel>().removeCourse(c.id);
                  },
                );
              }),
    );
  }
}


// ── CLASSES ───────────────────────────────────────────────────────────────────
class _ClassesTab extends StatefulWidget {
  @override State<_ClassesTab> createState() => _ClassesTabState();
}
class _ClassesTabState extends State<_ClassesTab> {
  static const _col = Color(0xFFF97316);
  final _prog = TextEditingController();
  EducationLevel _level = EducationLevel.intermediate;
  String? _editingProgId;
  final Map<String, TextEditingController> _cc = {};
  final Set<String> _open = {};
  final _search = TextEditingController();
  String _query = '';
  @override void dispose() { _prog.dispose(); _search.dispose(); for (final c in _cc.values) { c.dispose(); } super.dispose(); }
  TextEditingController _ctrl(String pid) => _cc.putIfAbsent(pid, () => TextEditingController());

  void _submitProg() {
    if (_prog.text.trim().isEmpty) { context.showErr('Program Name cannot be empty'); return; }
    if (_editingProgId == null) {
      context.read<DataEntryViewModel>().addProgram(_prog.text, _level); _prog.clear();
    } else {
      context.read<DataEntryViewModel>().updateProgram(_editingProgId!, _prog.text, _level);
      _prog.clear(); setState(() { _editingProgId = null; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm  = context.watch<DataEntryViewModel>();
    final isDark = context._dark;
    final interProgs = vm.programs.where((p) => p.level == EducationLevel.intermediate).toList();
    final bachProgs  = vm.programs.where((p) => p.level == EducationLevel.bachelors).toList();
    final levelProgs = _level == EducationLevel.intermediate ? interProgs : bachProgs;
    final shownProgs = _query.isEmpty
        ? levelProgs
        : levelProgs.where((p) => p.name.toLowerCase().contains(_query)).toList();

    return ListView(padding: const EdgeInsets.symmetric(horizontal: 28), children: [
      // ── Level pill selector with counts ────────────────────────────────
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: _PillSelector(
          labels: ['Intermediate  (${interProgs.length})', 'Bachelors  (${bachProgs.length})'],
          icons: const [Icons.architecture_rounded, Icons.school_rounded],
          selected: _level == EducationLevel.intermediate ? 0 : 1,
          color: _col,
          isDark: isDark,
          onChanged: (i) => setState(() {
            _level = i == 0 ? EducationLevel.intermediate : EducationLevel.bachelors;
            _editingProgId = null;
            _prog.clear();
          }),
        ),
      ),
      // ── Add Program form ────────────────────────────────────────────
      Container(padding: const EdgeInsets.all(20),
        decoration: context.glowCard(_col, radius: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _bar('Add Program', _col, isDark), const SizedBox(height: 14),
          _Field(ctrl: _prog, label: 'Program Name', icon: LucideIcons.folder, color: _col,
              hint: 'BS Computer Science, 1st Year Science…',
              formatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z -]'))],
              textInputAction: TextInputAction.done, onSubmitted: (_) => _submitProg()),
          const SizedBox(height: 16),
          _editingProgId == null ? _AddBtn(color: _col, onTap: _submitProg)
              : _SaveCancelBtns(color: _col, onSave: _submitProg,
                  onCancel: () { _prog.clear(); setState(() { _editingProgId = null; }); }),
        ])),
      const SizedBox(height: 20),
      if (levelProgs.isNotEmpty) ...[
        _SearchBar(ctrl: _search, color: _col, hint: 'Search program name…',
            onChanged: (v) => setState(() => _query = v.trim().toLowerCase())),
        const SizedBox(height: 16),
      ],
      // ── Filtered program list ──────────────────────────────────────────
      if (shownProgs.isEmpty) Center(child: Padding(padding: const EdgeInsets.symmetric(vertical: 32),
        child: Text(_query.isNotEmpty
                ? 'No programs match "$_query"'
                : 'No ${_level == EducationLevel.intermediate ? 'Intermediate' : 'Bachelors'} programs yet',
            style: GoogleFonts.plusJakartaSans(
                color: isDark ? AppTheme.textMuted : AppTheme.lightTextMut, fontSize: 14))))
      else ...[
        _countHeader(_level == EducationLevel.intermediate ? 'Intermediate Programs' : "Bachelor's Programs",
            shownProgs.length, _col, isDark),
        const SizedBox(height: 12),
        ...shownProgs.map((p) {
          final cls  = vm.classesForProgram(p.id);
          final open = _open.contains(p.id);
          return _ProgCard(prog: p, classes: cls, open: open, ctrl: _ctrl(p.id),
            onToggle: () => setState(() { if (open) { _open.remove(p.id); } else { _open.add(p.id); } }),
            onAddCls: (n) => context.read<DataEntryViewModel>().addClass(p.id, n),
            onEditProg: () { _prog.text = p.name; setState(() { _editingProgId = p.id; _level = p.level; }); },
            onDelProg: () {
              final ids = context.read<DataEntryViewModel>().classIdsForProgram(p.id);
              context.read<AllocatorViewModel>().purgeByClassIds(ids);
              context.read<DataEntryViewModel>().removeProgram(p.id);
            },
            onEditCls: (id, n) => context.read<DataEntryViewModel>().updateClass(id, p.id, n),
            onDelCls: (id) {
              context.read<AllocatorViewModel>().purgeByClassId(id);
              context.read<DataEntryViewModel>().removeClass(id);
            });
        }),
      ],
      const SizedBox(height: 32),
    ]);
  }

}

class _ProgCard extends StatefulWidget {
  final ProgramGroup prog;
  final List<ClassModel> classes;
  final bool open;
  final TextEditingController ctrl;
  final VoidCallback onToggle;
  final ValueChanged<String> onAddCls;
  final VoidCallback onEditProg;
  final VoidCallback onDelProg;
  final void Function(String id, String name) onEditCls;
  final ValueChanged<String> onDelCls;

  const _ProgCard({required this.prog, required this.classes, required this.open,
      required this.ctrl, required this.onToggle, required this.onAddCls,
      required this.onEditProg, required this.onDelProg, required this.onEditCls, required this.onDelCls});

  @override
  State<_ProgCard> createState() => _ProgCardState();
}

class _ProgCardState extends State<_ProgCard> {
  static const _col = Color(0xFFF97316);
  String? _editingClsId;

  void _submitClass() {
    if (widget.ctrl.text.trim().isEmpty) { context.showErr('Class Name cannot be empty'); return; }
    if (_editingClsId == null) {
      widget.onAddCls(widget.ctrl.text);
    } else {
      widget.onEditCls(_editingClsId!, widget.ctrl.text);
      setState(() => _editingClsId = null);
    }
    widget.ctrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context._dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: context.solidCard(radius: 16),
      child: Column(children: [
        GestureDetector(onTap: widget.onToggle, child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(children: [
            Container(width: 38, height: 38,
              decoration: BoxDecoration(color: _col.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _col.withValues(alpha: .3))),
              child: const Center(child: Icon(LucideIcons.folder, color: _col, size: 18))),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.prog.name, style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w700,
                  color: isDark ? AppTheme.textPrimary : AppTheme.lightText,
                  fontSize: 14)),
              Text('${widget.classes.length} class${widget.classes.length == 1 ? '' : 'es'}',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 12,
                      color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec)),
            ])),
            IconButton(icon: const Icon(Icons.edit_rounded, size: 18),
                color: AppTheme.accentTeal,
                onPressed: widget.onEditProg, splashRadius: 16),
            IconButton(icon: const Icon(Icons.delete_outline_rounded, size: 18),
                color: AppTheme.error,
                onPressed: widget.onDelProg, splashRadius: 16),
            Icon(widget.open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                color: isDark ? AppTheme.textMuted : AppTheme.lightTextMut, size: 22),
          ]),
        )),
        if (widget.open) ...[
          Divider(color: isDark ? AppTheme.divider : AppTheme.lightDivider, height: 1),
          ...widget.classes.map((c) => Container(
            decoration: BoxDecoration(border: Border(bottom: BorderSide(
                color: (isDark ? AppTheme.divider : AppTheme.lightDivider), width: .5))),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(children: [
              Container(width: 6, height: 6,
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: _col)),
              const SizedBox(width: 12),
              Expanded(child: Text(c.name, style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w600,
                  color: isDark ? AppTheme.textPrimary : AppTheme.lightText,
                  fontSize: 13))),
              IconButton(icon: const Icon(Icons.edit_rounded, size: 16),
                  color: AppTheme.accentTeal,
                  onPressed: () { widget.ctrl.text = c.name; setState(() => _editingClsId = c.id); }, splashRadius: 14),
              IconButton(icon: const Icon(Icons.close_rounded, size: 16),
                  color: AppTheme.error,
                  onPressed: () => widget.onDelCls(c.id), splashRadius: 14),
            ]),
          )),
          Padding(padding: const EdgeInsets.all(14), child: Row(children: [
            Expanded(child: _Field(ctrl: widget.ctrl, label: _editingClsId == null ? 'Add Class e.g. Semester-I, Section A' : 'Edit Class',
                icon: _editingClsId == null ? Icons.add_circle_outline_rounded : Icons.edit_rounded, color: _col,
                formatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z -]'))],
                textInputAction: TextInputAction.done, onSubmitted: (_) => _submitClass())),
            const SizedBox(width: 10),
            if (_editingClsId != null) ...[
              GestureDetector(
                onTap: () { widget.ctrl.clear(); setState(() => _editingClsId = null); },
                child: Container(width: 44, height: 44,
                  decoration: BoxDecoration(color: Colors.transparent, borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _col.withValues(alpha: .5))),
                  child: const Icon(Icons.close_rounded, color: _col, size: 22))),
              const SizedBox(width: 10),
            ],
            GestureDetector(
              onTap: _submitClass,
              child: Container(width: 44, height: 44,
                decoration: BoxDecoration(color: _col, borderRadius: BorderRadius.circular(12),
                  boxShadow: [BoxShadow(color: _col.withValues(alpha: .35), blurRadius: 10, offset: const Offset(0,3))]),
                child: Icon(_editingClsId == null ? Icons.add_rounded : Icons.check_rounded, color: Colors.white, size: 22))),
          ])),
        ],
      ]),
    );
  }
}

// ── ROOMS ─────────────────────────────────────────────────────────────────────
class _RoomsTab extends StatefulWidget {
  @override State<_RoomsTab> createState() => _RoomsTabState();
}
class _RoomsTabState extends State<_RoomsTab> {
  final _n = TextEditingController(), _cap = TextEditingController();
  RoomType _type = RoomType.room;
  String? _editingId;
  final _search = TextEditingController();
  String _query = '';
  @override void dispose() { _n.dispose(); _cap.dispose(); _search.dispose(); super.dispose(); }

  void _submitRoom() {
    if (_n.text.trim().isEmpty) { context.showErr('Room Name cannot be empty'); return; }
    if (_editingId == null) {
      context.read<DataEntryViewModel>().addRoom(_n.text, _type, capacity: int.tryParse(_cap.text));
      _n.clear(); _cap.clear();
    } else {
      context.read<DataEntryViewModel>().updateRoom(_editingId!, _n.text, _type, capacity: int.tryParse(_cap.text));
      _n.clear(); _cap.clear(); setState(() { _editingId = null; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<DataEntryViewModel>();
    final isDark = context._dark;
    final roomCount  = vm.rooms.where((r) => r.type == RoomType.room).length;
    final hallCount  = vm.rooms.where((r) => r.type == RoomType.hall).length;
    final otherCount = vm.rooms.where((r) => r.type == RoomType.other).length;
    final typeRooms  = vm.rooms.where((r) => r.type == _type).toList()
      ..sort((a, b) {
        // Ascending order — numeric room names sort by value (so "2" comes
        // before "10"), any legacy non-numeric names fall back to A-Z after.
        final an = int.tryParse(a.name);
        final bn = int.tryParse(b.name);
        if (an != null && bn != null) return an.compareTo(bn);
        if (an != null) return -1;
        if (bn != null) return 1;
        return a.name.compareTo(b.name);
      });
    final shownRooms = _query.isEmpty
        ? typeRooms
        : typeRooms.where((r) => r.name.toLowerCase().contains(_query)).toList();

    return _Shell(color: AppTheme.accentAmber,
      formContent: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Field(ctrl: _n,   label: 'Room / Hall Name',       icon: LucideIcons.doorOpen,   color: AppTheme.accentAmber, hint: '41, 102, 305…',
            formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))]),
        const SizedBox(height: 12),
        _Field(ctrl: _cap, label: 'Capacity (optional)',    icon: Icons.people_outline_rounded,  color: AppTheme.accentAmber, hint: '40', kt: TextInputType.number,
            formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
            textInputAction: TextInputAction.done, onSubmitted: (_) => _submitRoom()),
        const SizedBox(height: 14),
        Text('Type', style: GoogleFonts.plusJakartaSans(fontSize: 12, fontWeight: FontWeight.w600,
            color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec)),
        const SizedBox(height: 10),
        _PillSelector(
          labels: ['Room  ($roomCount)', 'Hall  ($hallCount)', 'Other  ($otherCount)'],
          icons:  const [LucideIcons.doorOpen, LucideIcons.building, LucideIcons.shapes],
          selected: _type == RoomType.room ? 0 : _type == RoomType.hall ? 1 : 2,
          color: AppTheme.accentAmber,
          isDark: isDark,
          onChanged: (i) => setState(() =>
              _type = i == 0 ? RoomType.room : i == 1 ? RoomType.hall : RoomType.other),
        ),
        const SizedBox(height: 16),
        _editingId == null ? _AddBtn(color: AppTheme.accentAmber, onTap: _submitRoom)
            : _SaveCancelBtns(color: AppTheme.accentAmber, onSave: _submitRoom,
                onCancel: () { _n.clear(); _cap.clear(); setState(() { _editingId = null; }); }),
      ]),
      searchBar: vm.rooms.isEmpty ? null : _SearchBar(ctrl: _search, color: AppTheme.accentAmber,
          hint: 'Search room name…', onChanged: (v) => setState(() => _query = v.trim().toLowerCase())),
      count: shownRooms.length, label: '${_type == RoomType.room ? 'Rooms' : _type == RoomType.hall ? 'Halls' : 'Other'} (${shownRooms.length})',
      emptyMessage: _query.isNotEmpty ? 'No rooms match "$_query"' : null,
      list: ListView.separated(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
        itemCount: shownRooms.length, separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) { final r = shownRooms[i]; return _Tile(
          color: AppTheme.accentAmber, badge: r.typeLabel.substring(0,1),
          title: r.name, subtitle: '${r.typeLabel}${r.capacity != null ? '  ·  ${r.capacity} seats' : ''}',
          onEdit: () { _n.text = r.name; _cap.text = r.capacity?.toString() ?? ''; setState(() { _editingId = r.id; _type = r.type; }); },
          onDelete: () => context.read<DataEntryViewModel>().removeRoom(r.id)); }));
  }

}

// ── TIME SLOTS ────────────────────────────────────────────────────────────────
class _TimeSlotsTab extends StatefulWidget {
  @override State<_TimeSlotsTab> createState() => _TimeSlotsTabState();
}
class _TimeSlotsTabState extends State<_TimeSlotsTab> {
  final _ns = TextEditingController(), _ne = TextEditingController();
  EducationLevel _level = EducationLevel.intermediate;
  @override void dispose() { _ns.dispose(); _ne.dispose(); super.dispose(); }

  void _submitTimeSlot() {
    if (_ns.text.trim().isEmpty) { context.showErr('Start Time cannot be empty'); return; }
    if (_ne.text.trim().isEmpty) { context.showErr('End Time cannot be empty'); return; }
    context.read<DataEntryViewModel>().addTimeSlot(_ns.text.trim(), _ne.text.trim(), _level);
    _ns.clear(); _ne.clear();
  }

  @override
  Widget build(BuildContext context) {
    final vm     = context.watch<DataEntryViewModel>();
    final isDark = context._dark;
    
    // Filter by level, ordered by period so each card can validate against
    // the period right before it (catches a 12-hour time left unconverted on
    // just one card even when that card's own start/end look internally fine).
    final slots = vm.timeSlots.where((t) => t.level == _level).toList()
      ..sort((a, b) => a.period.compareTo(b.period));

    return Stack(children: [
      ListView(padding: const EdgeInsets.fromLTRB(28, 0, 28, 120), children: [
        // ── Level pill selector with counts ─────────────────────────────────
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: _PillSelector(
            labels: [
              'Intermediate  (${vm.timeSlots.where((t) => t.level == EducationLevel.intermediate).length})',
              'Bachelors  (${vm.timeSlots.where((t) => t.level == EducationLevel.bachelors).length})',
            ],
            selected: _level == EducationLevel.intermediate ? 0 : 1,
            color: AppTheme.accentTeal,
            isDark: isDark,
            onChanged: (i) => setState(() =>
                _level = i == 0 ? EducationLevel.intermediate : EducationLevel.bachelors),
          ),
        ),
        ...slots.asMap().entries.map((entry) => _TSCard(key: ValueKey(entry.value.id), slot: entry.value,
          prevEndTime: entry.key > 0 ? slots[entry.key - 1].endTime : null,
          onUpdate:    (s, e) => context.read<DataEntryViewModel>().updateTimeSlot(entry.value.id, startTime: s, endTime: e),
          onDelete:    ()     => context.read<DataEntryViewModel>().removeTimeSlot(entry.value.id))),
        // Add slot card
        Container(padding: const EdgeInsets.all(18),
          decoration: context.glowCard(AppTheme.accentTeal, radius: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _bar('Add Time Slot', AppTheme.accentTeal, isDark), const SizedBox(height: 14),
            Row(children: [
              Expanded(child: _TF(ctrl: _ns, label: 'Start Time', color: AppTheme.accentTeal)),
              const SizedBox(width: 12),
              Expanded(child: _TF(ctrl: _ne, label: 'End Time',   color: AppTheme.accentTeal,
                  textInputAction: TextInputAction.done, onSubmitted: (_) => _submitTimeSlot())),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: _submitTimeSlot,
                child: Container(width: 48, height: 48,
                  decoration: BoxDecoration(color: AppTheme.accentTeal, borderRadius: BorderRadius.circular(12),
                    boxShadow: [BoxShadow(color: AppTheme.accentTeal.withValues(alpha: .35), blurRadius: 10, offset: const Offset(0,3))]),
                  child: const Icon(Icons.add_rounded, color: Colors.white, size: 24))),
            ]),
          ])),
        const SizedBox(height: 16),
      ]),
      // Save button
      Positioned(left: 0, right: 0, bottom: 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(28, 12, 28, 16),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.bgDeep : AppTheme.lightBg,
            border: Border(top: BorderSide(
                color: isDark ? AppTheme.divider : AppTheme.lightDivider, width: .5))),
          child: GestureDetector(
            onTap: () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Time slots saved!', style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w600, color: Colors.white)),
              backgroundColor: AppTheme.accentTeal, behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              margin: const EdgeInsets.all(16))),
            child: Container(height: 50,
              decoration: BoxDecoration(gradient: AppTheme.tealGradient,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [BoxShadow(color: AppTheme.accentTeal.withValues(alpha: .4),
                      blurRadius: 14, offset: const Offset(0,4))]),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.save_rounded, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Text('Save Time Slots', style: GoogleFonts.plusJakartaSans(
                    fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
              ]))))),
    ]);
  }

}


class _TSCard extends StatefulWidget {
  final TimeSlot slot;
  final String? prevEndTime;
  final void Function(String, String) onUpdate;
  final VoidCallback onDelete;
  const _TSCard({super.key, required this.slot, this.prevEndTime, required this.onUpdate, required this.onDelete});
  @override State<_TSCard> createState() => _TSCardState();
}
class _TSCardState extends State<_TSCard> {
  late final TextEditingController _s, _e;
  @override void initState() {
    super.initState();
    _s  = TextEditingController(text: widget.slot.startTime);
    _e  = TextEditingController(text: widget.slot.endTime);
  }

  @override
  void didUpdateWidget(covariant _TSCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.slot.id != widget.slot.id) {
      _s.text  = widget.slot.startTime;
      _e.text  = widget.slot.endTime;
    }
  }

  @override void dispose() { _s.dispose(); _e.dispose(); super.dispose(); }

  // Parses "HH:mm" (24-hour) to minutes since midnight, or null if unparseable.
  static int? _mins(String t) {
    final p = t.split(':');
    if (p.length != 2) return null;
    final h = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }

  // Catches the classic "typed 12-hour time without converting to 24-hour"
  // mistake (e.g. "1:00" meant as 1 PM but parsed as 1 AM) before it corrupts
  // the whole Schedule Matrix's time axis. Checks both that this card's own
  // end comes after its start, AND that its start doesn't fall before the
  // previous period's end — the latter catches a 12-hour time left on just
  // one of two adjacent cards even when that card looks fine in isolation.
  bool get _rangeInvalid {
    final s = _mins(_s.text);
    final e = _mins(_e.text);
    if (s == null || e == null) return false;
    if (e <= s) return true;
    final prevEnd = widget.prevEndTime == null ? null : _mins(widget.prevEndTime!);
    if (prevEnd != null && s < prevEnd) return true;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context._dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: context.solidCard(radius: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 34, height: 34,
            decoration: BoxDecoration(color: AppTheme.accentTeal.withValues(alpha: .15),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: AppTheme.accentTeal.withValues(alpha: .3))),
            child: Center(child: Text('P${widget.slot.period}', style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w800, color: AppTheme.accentTeal, fontSize: 11)))),
          const SizedBox(width: 12),
          Text('Period ${widget.slot.period}', style: GoogleFonts.plusJakartaSans(
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.textPrimary : AppTheme.lightText,
              fontSize: 14)),
          const Spacer(),
          IconButton(icon: Icon(Icons.delete_outline_rounded,
              color: isDark ? AppTheme.textMuted : AppTheme.lightTextMut, size: 18),
              onPressed: widget.onDelete, splashRadius: 16),
        ]),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _TF(ctrl: _s, label: 'Start', color: AppTheme.accentTeal,
              error: _rangeInvalid,
              helperText: _rangeInvalid ? '24-hr format — e.g. 13:00 for 1 PM' : null,
              onChanged: (_) { widget.onUpdate(_s.text, _e.text); setState(() {}); })),
          const SizedBox(width: 10),
          Expanded(child: _TF(ctrl: _e, label: 'End', color: AppTheme.accentTeal,
              error: _rangeInvalid,
              helperText: _rangeInvalid ? '24-hr format — e.g. 13:00 for 1 PM' : null,
              textInputAction: TextInputAction.done,
              onChanged: (_) { widget.onUpdate(_s.text, _e.text); setState(() {}); })),
        ]),
      ]));
  }
}

// ── Shared tiny widgets ────────────────────────────────────────────────────────
Widget _bar(String t, Color c, bool isDark) => Row(children: [
  Container(width: 3, height: 16,
      decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
  const SizedBox(width: 9),
  Text(t, style: GoogleFonts.plusJakartaSans(fontSize: 14, fontWeight: FontWeight.w700, color: c)),
]);

Widget _countHeader(String label, int count, Color color, bool isDark) =>
    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(label, style: GoogleFonts.plusJakartaSans(
          fontSize: 16, fontWeight: FontWeight.w700,
          color: isDark ? AppTheme.textPrimary : AppTheme.lightText)),
      Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: .3))),
        child: Text('$count', style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w700, color: color, fontSize: 12))),
    ]);

// ── Shared gradient pill selector ────────────────────────────────────────────
// Mirrors the Courses tab's TabBar pill style for any 2-3 option selector.
class _PillSelector extends StatelessWidget {
  final List<String> labels;
  final List<IconData?> icons;
  final int selected;
  final Color color;
  final bool isDark;
  final ValueChanged<int> onChanged;

  const _PillSelector({
    required this.labels,
    required this.selected,
    required this.color,
    required this.isDark,
    required this.onChanged,
    this.icons = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.bgMid : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? AppTheme.divider : const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: List.generate(labels.length, (i) {
          final sel = selected == i;
          final icon = i < icons.length ? icons[i] : null;
          return Expanded(
            child: GestureDetector(
              onTap: () => onChanged(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: sel
                    ? BoxDecoration(
                        gradient: LinearGradient(colors: [
                          color,
                          color.withValues(alpha: .8),
                        ]),
                        borderRadius: BorderRadius.circular(11),
                        boxShadow: [BoxShadow(
                          color: color.withValues(alpha: .3),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        )],
                      )
                    : BoxDecoration(borderRadius: BorderRadius.circular(11)),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  if (icon != null) ...[
                    Icon(icon, size: 14,
                        color: sel ? Colors.white
                            : (isDark ? AppTheme.textMuted : AppTheme.lightTextMut)),
                    const SizedBox(width: 5),
                  ],
                  Text(labels[i],
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 12,
                      fontWeight: sel ? FontWeight.w700 : FontWeight.w600,
                      color: sel ? Colors.white
                          : (isDark ? AppTheme.textMuted : AppTheme.lightTextMut),
                    ),
                  ),
                ]),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _Shell extends StatelessWidget {
  final Color color;
  final Widget formContent;
  final int count;
  final String label;
  final Widget list;
  final Widget? searchBar;
  final String? emptyMessage;
  const _Shell({required this.color, required this.formContent,
      required this.count, required this.label, required this.list,
      this.searchBar, this.emptyMessage});

  @override
  Widget build(BuildContext ctx) {
    final isDark = ctx._dark;
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 28), children: [
      Container(padding: const EdgeInsets.all(22),
        decoration: ctx.glowCard(color, radius: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _bar('Add New', color, isDark),
          const SizedBox(height: 16),
          formContent,
        ])),
      const SizedBox(height: 20),
      if (searchBar != null) ...[searchBar!, const SizedBox(height: 16)],
      if (count > 0) ...[
        _countHeader(label, count, color, isDark),
        const SizedBox(height: 12),
        list,
      ] else if (emptyMessage != null) Center(child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(emptyMessage!, textAlign: TextAlign.center, style: GoogleFonts.plusJakartaSans(
            fontSize: 13, color: isDark ? AppTheme.textMuted : AppTheme.lightTextMut)))),
    ]);
  }
}

class _Tile extends StatelessWidget {
  final Color color;
  final String badge, title, subtitle;
  final VoidCallback onDelete;
  final VoidCallback? onEdit;
  const _Tile({required this.color, required this.badge,
      required this.title, required this.subtitle, required this.onDelete, this.onEdit});

  @override
  Widget build(BuildContext ctx) {
    final isDark = ctx._dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: ctx.solidCard(radius: 12),
      child: Row(children: [
        Container(width: 40, height: 40,
          decoration: BoxDecoration(color: color.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: color.withValues(alpha: .3))),
          child: Center(child: Text(badge, style: GoogleFonts.plusJakartaSans(
              fontWeight: FontWeight.w800, color: color, fontSize: 11)))),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: GoogleFonts.plusJakartaSans(
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.textPrimary : AppTheme.lightText,
              fontSize: 14)),
          if (subtitle.isNotEmpty) Text(subtitle, style: GoogleFonts.plusJakartaSans(
              color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec,
              fontSize: 12)),
        ])),
        if (onEdit != null)
          IconButton(icon: Icon(Icons.edit_rounded,
              color: AppTheme.accentTeal, size: 18),
              onPressed: onEdit, splashRadius: 18),
        IconButton(icon: Icon(Icons.delete_outline_rounded,
            color: AppTheme.error, size: 18),
            onPressed: onDelete, splashRadius: 18),
      ]));
  }
}

class _Field extends StatelessWidget {
  final TextEditingController ctrl;
  final String label;
  final IconData icon;
  final Color color;
  final String? hint;
  final TextInputType? kt;
  final List<TextInputFormatter>? formatters;
  // Enter key behavior: defaults to advancing focus to the next field
  // (native Flutter behavior — no FocusNode wiring needed). Pass
  // `textInputAction: TextInputAction.done` + `onSubmitted` on the last
  // field of a form to submit it instead.
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  const _Field({required this.ctrl, required this.label, required this.icon,
      required this.color, this.hint, this.kt, this.formatters,
      this.textInputAction, this.onSubmitted});

  @override
  Widget build(BuildContext ctx) {
    final isDark  = ctx._dark;
    final fillCol = isDark ? AppTheme.bgMid : Colors.white;
    final bdCol   = isDark ? AppTheme.divider : const Color(0xFFE2E8F0);
    final txtCol  = isDark ? AppTheme.textPrimary : AppTheme.lightText;
    final lblCol  = isDark ? AppTheme.textSecondary : AppTheme.lightTextSec;
    // Label sits above the field (not floating inside it) — matches the
    // small bold section labels used everywhere else on this screen,
    // and reads less like a bare generic form input.
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: GoogleFonts.plusJakartaSans(
          fontSize: 11.5, fontWeight: FontWeight.w700, color: lblCol)),
      const SizedBox(height: 7),
      TextField(
        controller: ctrl,
        keyboardType: kt ?? TextInputType.text,
        inputFormatters: formatters,
        textInputAction: textInputAction ?? TextInputAction.next,
        onSubmitted: onSubmitted,
        style: GoogleFonts.plusJakartaSans(fontSize: 14, color: txtCol),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: GoogleFonts.plusJakartaSans(color: lblCol.withValues(alpha: .5), fontSize: 13),
          prefixIconConstraints: const BoxConstraints.tightFor(width: 46, height: 28),
          prefixIcon: Padding(padding: const EdgeInsets.only(left: 10),
              child: Container(width: 26, height: 26,
                  decoration: BoxDecoration(color: color.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(8)),
                  child: Icon(icon, color: color, size: 13))),
          filled: true, fillColor: fillCol,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: bdCol)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: bdCol)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: color, width: 1.5)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14)),
      ),
    ]);
  }
}

class _SearchBar extends StatelessWidget {
  final TextEditingController ctrl;
  final String hint;
  final Color color;
  final ValueChanged<String> onChanged;
  const _SearchBar({required this.ctrl, required this.hint, required this.color, required this.onChanged});

  @override
  Widget build(BuildContext ctx) {
    final isDark  = ctx._dark;
    final fillCol = isDark ? AppTheme.bgMid : Colors.white;
    final bdCol   = isDark ? AppTheme.divider : const Color(0xFFE2E8F0);
    final txtCol  = isDark ? AppTheme.textPrimary : AppTheme.lightText;
    final lblCol  = isDark ? AppTheme.textMuted : AppTheme.lightTextMut;
    return TextField(
      controller: ctrl,
      onChanged: onChanged,
      style: GoogleFonts.plusJakartaSans(fontSize: 14, color: txtCol),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.plusJakartaSans(color: lblCol.withValues(alpha: .7), fontSize: 13),
        prefixIcon: Icon(LucideIcons.search, color: lblCol, size: 18),
        suffixIcon: ctrl.text.isEmpty ? null : IconButton(
          icon: Icon(Icons.close_rounded, color: lblCol, size: 18),
          onPressed: () { ctrl.clear(); onChanged(''); },
          splashRadius: 16),
        filled: true, fillColor: fillCol,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: bdCol)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: bdCol)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: color, width: 1.5)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)));
  }
}

class _AddBtn extends StatelessWidget {
  final Color color;
  final VoidCallback onTap;
  const _AddBtn({required this.color, required this.onTap});
  @override
  Widget build(BuildContext ctx) => GestureDetector(onTap: onTap,
    child: Container(height: 48,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: color.withValues(alpha: .35), blurRadius: 14, offset: const Offset(0,4))]),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.add_rounded, color: Colors.white, size: 20),
        const SizedBox(width: 8),
        Text('Add', style: GoogleFonts.plusJakartaSans(
            fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
      ])));
}

class _SaveCancelBtns extends StatelessWidget {
  final Color color;
  final VoidCallback onSave;
  final VoidCallback onCancel;
  const _SaveCancelBtns({required this.color, required this.onSave, required this.onCancel});
  @override
  Widget build(BuildContext ctx) => Row(children: [
    Expanded(child: GestureDetector(onTap: onCancel,
      child: Container(height: 48,
        decoration: BoxDecoration(color: Colors.transparent, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: .5))),
        child: Center(child: Text('Cancel', style: GoogleFonts.plusJakartaSans(
            fontSize: 14, fontWeight: FontWeight.w700, color: color)))))),
    const SizedBox(width: 12),
    Expanded(child: GestureDetector(onTap: onSave,
      child: Container(height: 48,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(color: color.withValues(alpha: .35), blurRadius: 14, offset: const Offset(0,4))]),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.check_rounded, color: Colors.white, size: 20),
          const SizedBox(width: 8),
          Text('Save', style: GoogleFonts.plusJakartaSans(
              fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
        ])))),
  ]);
}

class _TF extends StatelessWidget {
  final TextEditingController ctrl;
  final String label;
  final Color color;
  final ValueChanged<String>? onChanged;
  final String? helperText;
  final bool error;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  const _TF({required this.ctrl, required this.label, required this.color, this.onChanged, this.helperText, this.error = false,
      this.textInputAction, this.onSubmitted});

  @override
  Widget build(BuildContext ctx) {
    final isDark  = ctx._dark;
    final fillCol = isDark ? AppTheme.bgMid : Colors.white;
    final bdCol   = error ? AppTheme.error : (isDark ? AppTheme.divider : const Color(0xFFE2E8F0));
    final txtCol  = isDark ? AppTheme.textPrimary : AppTheme.lightText;
    final lblCol  = isDark ? AppTheme.textMuted : AppTheme.lightTextMut;
    return TextField(
      controller: ctrl, onChanged: onChanged,
      textInputAction: textInputAction ?? TextInputAction.next,
      onSubmitted: onSubmitted,
      style: GoogleFonts.plusJakartaSans(fontSize: 13, color: txtCol),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.plusJakartaSans(fontSize: 11, color: lblCol),
        helperText: helperText,
        helperStyle: GoogleFonts.plusJakartaSans(fontSize: 9, color: error ? AppTheme.error : lblCol),
        filled: true, fillColor: fillCol,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: bdCol)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: bdCol)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: error ? AppTheme.error : color, width: 1.5))));
  }
}

// ── IMPORT MENU BUTTON ────────────────────────────────────────────────────────
// One button embedding both import paths — Excel (raw data) and Timetable
// (grid import) — as a dropdown, instead of two separate buttons competing
// for header space.
class _ImportMenuBtn extends StatelessWidget {
  static const _col = AppTheme.accentBlue;

  void _openExcel(BuildContext context) => showDialog(
      context: context, barrierDismissible: false, builder: (_) => _ImportDialog());

  void _openTimetable(BuildContext context) => showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => Dialog(
        backgroundColor: context._dark ? const Color(0xFF0F172A) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: SizedBox(
          width: 720,
          height: 600,
          child: TimetableGridImportScreen(
            onImportComplete: () => Navigator.of(dialogCtx).pop(),
          ),
        ),
      ));

  @override
  Widget build(BuildContext context) {
    final isDark = context._dark;
    return PopupMenuButton<int>(
      offset: const Offset(0, 46),
      color: isDark ? AppTheme.bgCard : Colors.white,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: isDark ? AppTheme.divider : const Color(0xFFE6E9F0))),
      onSelected: (v) => v == 0 ? _openExcel(context) : _openTimetable(context),
      itemBuilder: (_) => [
        _menuItem(0, LucideIcons.upload, AppTheme.accentTeal, 'Import Excel', 'Raw teacher/course/room data', isDark),
        _menuItem(1, LucideIcons.table, _col, 'Import Timetable', 'A full timetable grid from a sheet', isDark),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _col.withValues(alpha: isDark ? .15 : .10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _col.withValues(alpha: .4), width: 1.2),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(LucideIcons.upload, size: 18, color: _col),
          const SizedBox(width: 8),
          Text('Import', style: GoogleFonts.plusJakartaSans(
              fontSize: 12, fontWeight: FontWeight.w700, color: _col)),
          const SizedBox(width: 4),
          const Icon(LucideIcons.chevronDown, size: 16, color: _col),
        ]),
      ),
    );
  }

  PopupMenuItem<int> _menuItem(int value, IconData icon, Color col, String title, String subtitle, bool isDark) =>
      PopupMenuItem<int>(value: value, child: Row(children: [
        Container(width: 32, height: 32,
            decoration: BoxDecoration(color: col.withValues(alpha: .12), borderRadius: BorderRadius.circular(9)),
            child: Icon(icon, size: 16, color: col)),
        const SizedBox(width: 12),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: GoogleFonts.plusJakartaSans(fontSize: 13, fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.textPrimary : AppTheme.lightText)),
          Text(subtitle, style: GoogleFonts.plusJakartaSans(fontSize: 10.5,
              color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec)),
        ]),
      ]));
}

// ── IMPORT DIALOG ─────────────────────────────────────────────────────────────
enum _ImportPhase { options, picking, importing, done }

class _ImportDialog extends StatefulWidget {
  @override State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  static const _col = AppTheme.accentTeal;
  _ImportPhase _phase = _ImportPhase.options;
  bool _optDept = true, _optTeach = true, _optCourse = true;
  bool _optClass = true;
  bool _optRoom = true;
  double _progress = 0;
  String _step = 'Preparing…';
  DateTime? _startTime;
  ImportResult? _result;
  Timer? _simTimer;

  // Simulates smooth bar movement during the web worker compute phase
  void _startSimulatedProgress(double from, double to) {
    _simTimer?.cancel();
    double current = from;
    _simTimer = Timer.periodic(const Duration(milliseconds: 200), (t) {
      if (!mounted || current >= to) { t.cancel(); return; }
      current = (current + 0.01).clamp(0.0, to);
      setState(() => _progress = current);
    });
  }

  @override
  void dispose() { _simTimer?.cancel(); super.dispose(); }

  String get _pct => '${(_progress * 100).toStringAsFixed(0)}%';
  String get _remaining {
    if (_startTime == null || _progress < 0.05) return 'Calculating…';
    final elapsedMs = DateTime.now().difference(_startTime!).inMilliseconds;
    if (elapsedMs < 100) return 'Calculating…';
    final totalMs = elapsedMs / _progress;
    final remMs = totalMs * (1 - _progress);
    if (remMs < 500) return 'Almost done!';
    return '~${(remMs / 1000).ceil()}s remaining';
  }

  Future<void> _startImport() async {
    setState(() => _phase = _ImportPhase.picking);
    final options = ImportOptions(
        departments: _optDept, teachers: _optTeach,
        courses: _optCourse, classes: _optClass, rooms: _optRoom);
    try {
      final data = await ExcelImportService.pickAndParse(
        options: options,
        onProgress: (p, s) {
          if (!mounted) return;
          _simTimer?.cancel();
          setState(() {
            if (_phase == _ImportPhase.picking) {
              _phase = _ImportPhase.importing;
              _startTime = DateTime.now();
            }
            _progress = p; _step = s;
          });
          // During the long compute phase (0.2 → 0.95), simulate smooth movement
          if (p >= 0.2 && p < 0.9) _startSimulatedProgress(p, 0.88);
        },
      );
      _simTimer?.cancel();
      if (!mounted) return;
      if (data == null) { setState(() => _phase = _ImportPhase.options); return; }

      // Show snackbars for any missing sheets
      for (final w in data.warnings) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(w, style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
          backgroundColor: AppTheme.accentAmber, behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          margin: const EdgeInsets.all(16), duration: const Duration(seconds: 4),
        ));
      }

      final result = context.read<DataEntryViewModel>().bulkImport(data);
      setState(() { _result = result; _phase = _ImportPhase.done; });
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Import failed: $e', style: GoogleFonts.plusJakartaSans(color: Colors.white)),
        backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context._dark;
    return Dialog(
      backgroundColor: isDark ? AppTheme.bgMid : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: _phase == _ImportPhase.options ? _buildOptions(isDark)
                : _phase == _ImportPhase.done ? _buildDone(isDark)
                : _buildProgress(isDark),
          ),
        ),
      ),
    );
  }

  // ── Phase 1: Options ───────────────────────────────────────────────────────
  Widget _buildOptions(bool isDark) => Column(key: const ValueKey('options'),
    mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        Container(width: 40, height: 40,
          decoration: BoxDecoration(color: _col.withValues(alpha: .15), borderRadius: BorderRadius.circular(11)),
          child: const Icon(LucideIcons.upload, color: _col, size: 22)),
        const SizedBox(width: 14),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Import from Excel', style: GoogleFonts.plusJakartaSans(fontSize: 16, fontWeight: FontWeight.w800,
              color: isDark ? AppTheme.textPrimary : AppTheme.lightText)),
          Text('Select what to import', style: GoogleFonts.plusJakartaSans(fontSize: 12,
              color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec)),
        ]),
      ]),
      const SizedBox(height: 20),
      _optTile(LucideIcons.building2, 'Departments', _optDept, (v) => setState(() => _optDept = v!), isDark),
      _optTile(Icons.person_outline_rounded, 'Teachers / Lecturers', _optTeach, (v) => setState(() => _optTeach = v!), isDark),
      _optTile(Icons.menu_book_rounded, 'Courses', _optCourse, (v) => setState(() => _optCourse = v!), isDark),
      _optTile(Icons.school_rounded, 'Programs & Classes', _optClass, (v) => setState(() => _optClass = v!), isDark),
      _optTile(LucideIcons.doorOpen, 'Rooms', _optRoom, (v) => setState(() => _optRoom = v!), isDark),
      const SizedBox(height: 20),
      Row(children: [
        Expanded(child: GestureDetector(onTap: () => Navigator.of(context).pop(),
          child: Container(height: 44,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12),
                border: Border.all(color: isDark ? AppTheme.divider : AppTheme.lightDivider)),
            child: Center(child: Text('Cancel', style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w700, fontSize: 13,
                color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec)))))),
        const SizedBox(width: 12),
        Expanded(child: GestureDetector(onTap: _startImport,
          child: Container(height: 44,
            decoration: BoxDecoration(gradient: AppTheme.tealGradient,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [BoxShadow(color: _col.withValues(alpha: .35), blurRadius: 10, offset: const Offset(0,3))]),
            child: Center(child: Text('Select File', style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w700, color: Colors.white, fontSize: 13)))))),
      ]),
    ]);

  Widget _optTile(IconData icon, String label, bool val, ValueChanged<bool?> onChange, bool isDark) =>
    Container(margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: val ? _col.withValues(alpha: .07) : (isDark ? AppTheme.bgDeep : const Color(0xFFF8FAFC)),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: val ? _col.withValues(alpha: .35) : (isDark ? AppTheme.divider : AppTheme.lightDivider)),
      ),
      child: CheckboxListTile(
        value: val, onChanged: onChange, dense: true,
        activeColor: _col, checkColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(children: [
          Icon(icon, size: 16, color: val ? _col : (isDark ? AppTheme.textMuted : AppTheme.lightTextMut)),
          const SizedBox(width: 10),
          Text(label, style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, fontSize: 13,
              color: isDark ? AppTheme.textPrimary : AppTheme.lightText)),
        ]),
      ));

  // ── Phase 2: Progress ──────────────────────────────────────────────────────
  Widget _buildProgress(bool isDark) => Column(key: const ValueKey('progress'),
    mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(_phase == _ImportPhase.picking ? 'Select your Excel file…' : 'Importing Data',
          style: GoogleFonts.plusJakartaSans(fontSize: 16, fontWeight: FontWeight.w800,
              color: isDark ? AppTheme.textPrimary : AppTheme.lightText)),
      Text(_phase == _ImportPhase.picking ? 'The file picker should open automatically'
          : _step, style: GoogleFonts.plusJakartaSans(fontSize: 12,
              color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec)),
      const SizedBox(height: 24),
      if (_phase == _ImportPhase.importing) ...[
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(_pct, style: GoogleFonts.plusJakartaSans(fontSize: 22, fontWeight: FontWeight.w800, color: _col)),
          Text(_remaining, style: GoogleFonts.plusJakartaSans(fontSize: 12,
              color: isDark ? AppTheme.textMuted : AppTheme.lightTextMut)),
        ]),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (_, c) => Stack(children: [
          Container(height: 14, width: c.maxWidth,
            decoration: BoxDecoration(color: isDark ? AppTheme.bgDeep : const Color(0xFFE8F4F3),
                borderRadius: BorderRadius.circular(7))),
          AnimatedContainer(duration: const Duration(milliseconds: 200),
            height: 14, width: c.maxWidth * _progress.clamp(0, 1),
            decoration: BoxDecoration(gradient: AppTheme.tealGradient,
                borderRadius: BorderRadius.circular(7),
                boxShadow: [BoxShadow(color: _col.withValues(alpha: .4), blurRadius: 6)])),
        ])),
        const SizedBox(height: 8),
        Text(_step, style: GoogleFonts.plusJakartaSans(fontSize: 11,
            color: isDark ? AppTheme.textMuted : AppTheme.lightTextMut)),
      ] else
        LinearProgressIndicator(color: _col, backgroundColor: _col.withValues(alpha: .15),
            borderRadius: BorderRadius.circular(4)),
      const SizedBox(height: 20),
      Align(alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: () { setState(() => _phase = _ImportPhase.options); Navigator.of(context).pop(); },
          child: Text('Cancel', style: GoogleFonts.plusJakartaSans(color: AppTheme.error, fontWeight: FontWeight.w600)))),
    ]);

  // ── Phase 3: Done ──────────────────────────────────────────────────────────
  Widget _buildDone(bool isDark) {
    final r = _result!;
    return Column(key: const ValueKey('done'),
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(width: 40, height: 40,
            decoration: BoxDecoration(color: _col.withValues(alpha: .15), borderRadius: BorderRadius.circular(11)),
            child: const Icon(Icons.check_circle_outline_rounded, color: _col, size: 22)),
          const SizedBox(width: 14),
          Text('Import Complete!', style: GoogleFonts.plusJakartaSans(fontSize: 16, fontWeight: FontWeight.w800,
              color: isDark ? AppTheme.textPrimary : AppTheme.lightText)),
        ]),
        const SizedBox(height: 20),
        _doneRow(LucideIcons.building2, r.departments, 'departments', AppTheme.accentCyan, isDark),
        _doneRow(Icons.person_outline_rounded, r.teachers, 'teachers', _col, isDark),
        _doneRow(Icons.menu_book_rounded, r.courses, 'courses', AppTheme.accentBlue, isDark),
        _doneRow(Icons.school_rounded, r.classes, 'classes', AppTheme.accentTeal, isDark),
        _doneRow(LucideIcons.doorOpen, r.rooms, 'rooms', Colors.orange, isDark),
        const SizedBox(height: 20),
        SizedBox(width: double.infinity, child: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Container(height: 46, decoration: BoxDecoration(gradient: AppTheme.tealGradient,
              borderRadius: BorderRadius.circular(12)),
            child: Center(child: Text('Done', style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w700, color: Colors.white, fontSize: 14)))))),
      ]);
  }

  Widget _doneRow(IconData icon, int count, String label, Color col, bool isDark) =>
    Padding(padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Container(width: 32, height: 32,
          decoration: BoxDecoration(color: col.withValues(alpha: .12), borderRadius: BorderRadius.circular(8)),
          child: Icon(icon, size: 16, color: col)),
        const SizedBox(width: 12),
        Text('$count', style: GoogleFonts.plusJakartaSans(fontSize: 15, fontWeight: FontWeight.w800, color: col)),
        const SizedBox(width: 6),
        Text(label, style: GoogleFonts.plusJakartaSans(fontSize: 13, fontWeight: FontWeight.w600,
            color: isDark ? AppTheme.textPrimary : AppTheme.lightText)),
        Text(' imported', style: GoogleFonts.plusJakartaSans(fontSize: 12,
            color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec)),
      ]));
}


