import 'package:flutter/material.dart';

// This app only ever runs as a Windows desktop window with a 1024×768
// minimum size (see window_manager setup in main.dart), so there is no
// mobile/tablet layout to support — these helpers keep their names (call
// sites read the same) but always use the desktop values.

// ─────────────────────────────────────────────────────────────────────────────
// Horizontal page padding
// ─────────────────────────────────────────────────────────────────────────────
extension RPad on BuildContext {
  double get hPad => 32;
  EdgeInsets get pagePad => EdgeInsets.symmetric(horizontal: hPad);
  EdgeInsets get pageInsets => EdgeInsets.fromLTRB(hPad, 56, hPad, 40);
}

// ─────────────────────────────────────────────────────────────────────────────
// Column builder — wraps children in rows of [cols].
// ─────────────────────────────────────────────────────────────────────────────
class AdaptiveGrid extends StatelessWidget {
  final List<Widget> children;
  final int cols;
  final double spacing;

  const AdaptiveGrid({
    super.key,
    required this.children,
    this.cols    = 4,
    this.spacing = 12,
  });

  @override
  Widget build(BuildContext context) {
    final rows = <List<Widget>>[];
    for (int i = 0; i < children.length; i += cols) {
      rows.add(children.sublist(i, (i + cols).clamp(0, children.length)));
    }
    return Column(
      children: rows.map((row) => Padding(
        padding: EdgeInsets.only(bottom: spacing),
        child: Row(
          children: row.asMap().entries.map((e) => Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: e.key < row.length - 1 ? spacing : 0),
              child: e.value,
            ),
          )).toList(),
        ),
      )).toList(),
    );
  }
}
