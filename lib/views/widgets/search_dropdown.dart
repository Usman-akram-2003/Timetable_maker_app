import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../app_theme.dart';

/// Searchable dropdown: typing in the field filters the entries in a compact,
/// field-width popup — so long teacher/course/class lists don't need scrolling
/// to find one, and what you type stays visible while you type it.
class SearchDropdown<T extends Object> extends StatelessWidget {
  final String label; final IconData icon; final T? value;
  final Color color; final List<T> items; final String Function(T) itemLabel;
  final ValueChanged<T?> onChanged;
  // When true, shows a clear (×) button once a value is picked, for optional
  // fields (e.g. Room) where the user needs a way back to "none".
  final bool allowClear;
  const SearchDropdown({super.key, required this.label, required this.icon, required this.value,
    required this.color, required this.items, required this.itemLabel, required this.onChanged,
    this.allowClear = false});

  @override
  Widget build(BuildContext context) {
    final isDark  = Theme.of(context).brightness == Brightness.dark;
    final fillCol = isDark ? AppTheme.bgMid         : const Color(0xFFF8FAFC);
    final bdCol   = isDark ? AppTheme.divider       : AppTheme.lightDivider;
    final txtCol  = isDark ? AppTheme.textPrimary   : AppTheme.lightText;
    final lblCol  = isDark ? AppTheme.textMuted     : AppTheme.lightTextMut;
    final dropBg  = isDark ? AppTheme.bgCard        : Colors.white;

    return LayoutBuilder(builder: (context, constraints) {
      final fieldWidth = constraints.maxWidth;
      return Autocomplete<T>(
        initialValue: TextEditingValue(text: value != null ? itemLabel(value as T) : ''),
        displayStringForOption: itemLabel,
        optionsBuilder: (v) {
          if (v.text.isEmpty) return items;
          final q = v.text.toLowerCase();
          return items.where((i) => itemLabel(i).toLowerCase().contains(q));
        },
        onSelected: onChanged,
        fieldViewBuilder: (context, ctrl, focusNode, onSubmitted) => TextField(
          controller: ctrl, focusNode: focusNode,
          style: GoogleFonts.plusJakartaSans(fontSize: 14, color: txtCol),
          decoration: InputDecoration(
              labelText: label,
              labelStyle: GoogleFonts.plusJakartaSans(color: lblCol, fontSize: 12),
              prefixIcon: Icon(icon, color: lblCol, size: 18),
              suffixIcon: allowClear
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        icon: Icon(LucideIcons.x, color: lblCol, size: 16),
                        onPressed: () { ctrl.clear(); onChanged(null); },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        splashRadius: 14,
                      ),
                      const SizedBox(width: 8),
                      Icon(LucideIcons.search, color: lblCol, size: 18),
                      const SizedBox(width: 12),
                    ])
                  : Icon(LucideIcons.search, color: lblCol, size: 18),
              filled: true, fillColor: fillCol,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: bdCol)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: bdCol)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: color, width: 1.5)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16)),
        ),
        optionsViewBuilder: (context, onSelected, options) {
          final list = options.toList();
          return Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 4, borderRadius: BorderRadius.circular(14), color: dropBg,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: 260, maxWidth: fieldWidth),
                child: list.isEmpty
                    ? Padding(padding: const EdgeInsets.all(16),
                        child: Text('No matches', style: GoogleFonts.plusJakartaSans(
                            color: lblCol, fontSize: 13)))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        shrinkWrap: true,
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final opt = list[i];
                          return InkWell(
                            onTap: () => onSelected(opt),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              child: Text(itemLabel(opt), style: GoogleFonts.plusJakartaSans(
                                  fontSize: 14, color: txtCol)),
                            ),
                          );
                        },
                      ),
              ),
            ),
          );
        },
      );
    });
  }
}
