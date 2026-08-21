import 'package:flutter/material.dart';

/// Splash screen shown while Firebase/prefs are booting.
///
/// [progress] (0..1) is driven by the caller from real startup steps — the
/// bar animates toward whatever value it's given, it never runs on its own
/// fixed timer. [status] is optional step text under the tagline.
class SplashScreen extends StatefulWidget {
  const SplashScreen({
    super.key,
    required this.progress,
    this.status,
    this.tagline = 'CLASH-FREE ACADEMIC SCHEDULING',
    this.footer = 'Government Graduate College Okara',
  });

  final double progress;
  final String? status;
  final String tagline;
  final String footer;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  static const _ground = Color(0xFF0F172A);
  static const _cyan = Color(0xFF22D3EE);
  static const _muted = Color(0xFF94A3B8);
  static const _footerGrey = Color(0xFF475569);

  late final AnimationController _c;
  late final Animation<double> _markScale;
  late final Animation<double> _markFade;
  late final Animation<double> _titleFade;
  late final Animation<double> _titleSlide;
  late final Animation<double> _taglineFade;

  @override
  void initState() {
    super.initState();
    // Fixed, short intro reveal for the mark/title — purely decorative, not
    // a stand-in for real loading progress (that's widget.progress below).
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..forward();

    _markFade = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.00, 0.35, curve: Curves.easeOut),
    );
    _markScale = Tween<double>(begin: 0.86, end: 1.0).animate(
      CurvedAnimation(
        parent: _c,
        curve: const Interval(0.00, 0.50, curve: Curves.easeOutBack),
      ),
    );
    _titleFade = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.30, 0.65, curve: Curves.easeOut),
    );
    _titleSlide = Tween<double>(begin: 14, end: 0).animate(
      CurvedAnimation(
        parent: _c,
        curve: const Interval(0.30, 0.65, curve: Curves.easeOutCubic),
      ),
    );
    _taglineFade = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.44, 0.80, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 620;
    final markSize = compact ? 132.0 : 172.0;

    return Scaffold(
      backgroundColor: _ground,
      body: Stack(
        children: [
          const Positioned.fill(
            child: CustomPaint(painter: _BackdropPainter()),
          ),
          Center(
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: _markFade.value,
                      child: Transform.scale(
                        scale: _markScale.value,
                        child: SizedBox(
                          width: markSize,
                          height: markSize,
                          child: CustomPaint(
                            painter: _ConsoleMarkPainter(reveal: _c.value),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: compact ? 30 : 42),
                    Opacity(
                      opacity: _titleFade.value,
                      child: Transform.translate(
                        offset: Offset(0, _titleSlide.value),
                        child: Text(
                          'Timetable Maker',
                          style: TextStyle(
                            fontSize: compact ? 34 : 46,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Opacity(
                      opacity: _taglineFade.value,
                      child: Text(
                        widget.tagline,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: compact ? 11 : 13,
                          fontWeight: FontWeight.w400,
                          color: _muted,
                          letterSpacing: 2.6,
                        ),
                      ),
                    ),
                    SizedBox(height: compact ? 30 : 40),
                    SizedBox(
                      width: compact ? 180 : 220,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: widget.progress.clamp(0.0, 1.0)),
                          duration: const Duration(milliseconds: 350),
                          curve: Curves.easeOut,
                          builder: (context, value, _) => LinearProgressIndicator(
                            value: value,
                            minHeight: 3,
                            backgroundColor: Colors.white.withValues(alpha: 0.10),
                            valueColor: const AlwaysStoppedAnimation<Color>(_cyan),
                          ),
                        ),
                      ),
                    ),
                    if (widget.status != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        widget.status!,
                        style: const TextStyle(fontSize: 11, color: _footerGrey),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: compact ? 24 : 38,
            child: AnimatedBuilder(
              animation: _taglineFade,
              builder: (context, child) =>
                  Opacity(opacity: _taglineFade.value * 0.9, child: child),
              child: Text(
                widget.footer,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: _footerGrey,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Faint grid + drifting accent bars behind the mark.
class _BackdropPainter extends CustomPainter {
  const _BackdropPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.045)
      ..strokeWidth = 1;

    const step = 120.0;
    for (double y = step; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (double x = step; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }

    // Ghosted schedule bars, echoing the mark's rows.
    final bar = Paint()..color = const Color(0xFF22D3EE).withValues(alpha: 0.05);
    void ghost(double x, double y, double w) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, w, 22),
          const Radius.circular(11),
        ),
        bar,
      );
    }

    ghost(size.width * 0.06, size.height * 0.14, size.width * 0.16);
    ghost(size.width * 0.06, size.height * 0.19, size.width * 0.16);
    ghost(size.width * 0.76, size.height * 0.79, size.width * 0.16);
    ghost(size.width * 0.76, size.height * 0.84, size.width * 0.16);
  }

  @override
  bool shouldRepaint(covariant _BackdropPainter oldDelegate) => false;
}

/// The console mark, drawn to match app_icon.svg exactly.
/// [reveal] 0..1 staggers the four rows in.
class _ConsoleMarkPainter extends CustomPainter {
  _ConsoleMarkPainter({required this.reveal});

  final double reveal;

  static const _cyan = Color(0xFF22D3EE);

  @override
  void paint(Canvas canvas, Size size) {
    // Source artwork is a 230x230 square; scale to fit.
    final s = size.width / 230.0;
    Offset p(double x, double y) => Offset(x * s, y * s);
    Rect r(double x, double y, double w, double h) =>
        Rect.fromLTWH(x * s, y * s, w * s, h * s);

    // Nested frames
    canvas.drawRRect(
      RRect.fromRectAndRadius(r(21, 21, 188, 188), Radius.circular(39 * s)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 * s
        ..color = Colors.white.withValues(alpha: 0.18),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(r(31, 31, 168, 168), Radius.circular(31 * s)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0 * s
        ..color = _cyan.withValues(alpha: 0.25),
    );

    // Brackets
    Paint bracket(double opacity) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 13 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = Colors.white.withValues(alpha: opacity);

    canvas.drawPath(
      Path()
        ..moveTo(p(82, 54).dx, p(82, 54).dy)
        ..lineTo(p(54, 54).dx, p(54, 54).dy)
        ..lineTo(p(54, 176).dx, p(54, 176).dy)
        ..lineTo(p(82, 176).dx, p(82, 176).dy),
      bracket(1.0),
    );
    canvas.drawPath(
      Path()
        ..moveTo(p(148, 54).dx, p(148, 54).dy)
        ..lineTo(p(176, 54).dx, p(176, 54).dy)
        ..lineTo(p(176, 176).dx, p(176, 176).dy)
        ..lineTo(p(148, 176).dx, p(148, 176).dy),
      bracket(0.4),
    );

    // Four rows: cyan track + white block at varying offsets.
    // Each row eases in on its own slice of [reveal].
    const rows = <List<double>>[
      // y, trackOpacity, blockX, blockOpacity
      [70, 1.00, 67, 1.00],
      [96, 0.55, 112, 0.85],
      [122, 0.55, 88, 0.85],
      [148, 0.30, 136, 0.70],
    ];

    for (var i = 0; i < rows.length; i++) {
      final start = 0.10 + i * 0.07;
      final t = ((reveal - start) / 0.22).clamp(0.0, 1.0);
      if (t <= 0) continue;
      final eased = Curves.easeOutCubic.transform(t);

      final row = rows[i];
      final y = row[0], trackO = row[1], blockX = row[2], blockO = row[3];

      // Track grows from the left edge.
      final trackW = 96 * eased;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            r(67, y, trackW, 17), Radius.circular(8.5 * s)),
        Paint()..color = _cyan.withValues(alpha: trackO),
      );

      // Block fades in slightly behind its track.
      final bt = ((eased - 0.35) / 0.65).clamp(0.0, 1.0);
      if (bt > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              r(blockX, y, 27, 17), Radius.circular(8.5 * s)),
          Paint()..color = Colors.white.withValues(alpha: blockO * bt),
        );
      }
    }

    // Side pins
    canvas.drawCircle(p(59, 115), 4 * s, Paint()..color = _cyan);
    canvas.drawCircle(
      p(171, 115),
      4 * s,
      Paint()..color = _cyan.withValues(alpha: 0.5),
    );
  }

  @override
  bool shouldRepaint(covariant _ConsoleMarkPainter oldDelegate) =>
      oldDelegate.reveal != reveal;
}
