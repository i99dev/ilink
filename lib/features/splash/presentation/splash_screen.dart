import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../kernel/settings/app_settings.dart';

// Splash palette. Kept as top-level constants so dart format never
// wraps `Color(0xFF...)` across two lines (the hex auditor rejects a
// hex literal whose line lacks the `Color(` prefix).
const Color _kBgDeep = Color(0xFF050912);
const Color _kBgMid = Color(0xFF0A1F44);
const Color _kBgGlow = Color(0xFF14336B);
const Color _kAccentBlue = Color(0xFF5B8CFF);
const Color _kAccentTeal = Color(0xFF22D3A8);
const Color _kShimmerLight = Color(0xFFE6EEFF);
const Color _kShimmerMid = Color(0xFFB7D2FF);
const Color _kShimmerDeep = Color(0xFF7FB1FF);

/// Boot splash that brands I99DASH alongside the two partners that
/// produced and back the project (per the public attribution rule:
/// built by CubeTek, sponsored by QEV). The widget overlays itself on
/// top of [child] so the underlying gate keeps initialising in
/// parallel - when the animation finishes we fade the overlay out and
/// reveal [child] without a navigator transition.
///
/// Timeline (master controller, 5.0s):
///   0.00 - 0.55  backdrop + circuit traces fade in
///   0.10 - 0.60  iLINK mark scales in (overshoot) inside its glow
///   0.18 - 1.00  orbital rings sweep into place around the mark
///   0.30 - 0.70  wordmark letters cascade in
///   0.45 - 0.75  partnership badges slide in from opposite sides
///   0.55 - 0.80  energy beam draws between CubeTek and QEV
///   0.80 - 0.92  bottom caption fades up
///   0.40 - 1.00  ambient layer (rotating rings, beam particles,
///                breathing glow) - 2.0s of held richness before
///                the fade-out begins
class SplashGate extends ConsumerStatefulWidget {
  const SplashGate({
    super.key,
    required this.child,
    // 1.5s feels long enough for the brand to land, short enough that
    // it doesn't gate the user. Was 5s — the boot work that the splash
    // used to mask now finishes well before the splash itself, so the
    // long hold was wasted dwell time.
    this.totalDuration = const Duration(milliseconds: 1500),
  });

  final Widget child;
  final Duration totalDuration;

  @override
  ConsumerState<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends ConsumerState<SplashGate>
    with TickerProviderStateMixin {
  // Master timeline - drives staged entrances + the fade-out trigger.
  late final AnimationController _master;
  // Free-running ambient controller - rotating rings, particle drift,
  // glow breathing. Independent of [_master] so it keeps animating
  // smoothly during the hold without warping curve speeds.
  late final AnimationController _ambient;
  bool _dismissed = false;
  ProviderSubscription<AsyncValue<AppSettings>>? _settingsSub;

  @override
  void initState() {
    super.initState();
    _master = AnimationController(vsync: this, duration: widget.totalDuration)
      ..forward().whenComplete(_dismiss);
    _ambient = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
    // Also dismiss as soon as settings resolve — whichever of (timer
    // floor, settings ready) lands first wins. On a warm boot settings
    // hydrate in <100ms so the splash effectively becomes the
    // shortest-allowed-by-policy duration. On a cold boot (or first
    // launch) the 1.5s floor still applies via [_master].
    _settingsSub = ref.listenManual<AsyncValue<AppSettings>>(settingsProvider, (
      _,
      next,
    ) {
      if (next.hasValue) _dismiss();
    }, fireImmediately: true);
  }

  void _dismiss() {
    if (!mounted || _dismissed) return;
    setState(() => _dismissed = true);
  }

  @override
  void dispose() {
    _settingsSub?.close();
    _master.dispose();
    _ambient.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        IgnorePointer(
          ignoring: _dismissed,
          child: AnimatedOpacity(
            opacity: _dismissed ? 0 : 1,
            duration: const Duration(milliseconds: 520),
            curve: Curves.easeOut,
            child: _SplashContent(master: _master, ambient: _ambient),
          ),
        ),
      ],
    );
  }
}

class _SplashContent extends StatelessWidget {
  const _SplashContent({required this.master, required this.ambient});

  final Animation<double> master;
  final Animation<double> ambient;

  // Staged curves keyed off the master controller (0..1 over 5s).
  static const _backdrop = Interval(0.00, 0.55, curve: Curves.easeOutCubic);
  static const _markEnter = Interval(0.10, 0.60, curve: Curves.easeOutBack);
  static const _ringsEnter = Interval(0.18, 1.00, curve: Curves.easeOutCubic);
  static const _wordmarkEnter = Interval(0.30, 0.70, curve: Curves.easeOut);
  static const _partnerEnter = Interval(0.45, 0.75, curve: Curves.easeOutCubic);
  static const _beamDraw = Interval(0.55, 0.80, curve: Curves.easeInOut);
  static const _captionEnter = Interval(0.80, 0.92, curve: Curves.easeOut);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([master, ambient]),
      builder: (context, _) {
        final t = master.value;
        final a = ambient.value;
        return Material(
          color: Colors.transparent,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _AnimatedBackdrop(t: _backdrop.transform(t), ambient: a),
              CustomPaint(
                painter: _CircuitTracesPainter(
                  t: _backdrop.transform(t),
                  ambient: a,
                ),
              ),
              SafeArea(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Spacer(),
                    _Mark(
                      enter: _markEnter.transform(t),
                      ringEnter: _ringsEnter.transform(t),
                      ambient: a,
                    ),
                    const SizedBox(height: 32),
                    _Wordmark(t: _wordmarkEnter.transform(t), ambient: a),
                    const SizedBox(height: 48),
                    _PartnershipCard(
                      enter: _partnerEnter.transform(t),
                      beam: _beamDraw.transform(t),
                      ambient: a,
                    ),
                    const Spacer(),
                    _Caption(t: _captionEnter.transform(t)),
                    const SizedBox(height: 28),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AnimatedBackdrop extends StatelessWidget {
  const _AnimatedBackdrop({required this.t, required this.ambient});
  final double t;
  final double ambient;

  @override
  Widget build(BuildContext context) {
    // Deep navy -> near-black radial sweep that drifts on the ambient
    // clock. Center hue matches the launcher icon's
    // adaptive_icon_background (#0A1F44) so the icon "lifts" out of
    // the same color the OS painted milliseconds earlier.
    final angle = ambient * math.pi * 2;
    // DecoratedBox skips the layout pass that Container adds; the
    // Stack(fit: StackFit.expand) parent already supplies tight
    // constraints, so no Container sizing is needed.
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(
            math.cos(angle) * 0.18,
            -0.35 + math.sin(angle) * 0.05,
          ),
          radius: 1.4,
          colors: [
            _kBgGlow.withValues(alpha: t),
            _kBgMid.withValues(alpha: t),
            _kBgDeep,
          ],
          stops: const [0.0, 0.45, 1.0],
        ),
      ),
    );
  }
}

class _CircuitTracesPainter extends CustomPainter {
  _CircuitTracesPainter({required this.t, required this.ambient});
  final double t;
  final double ambient;

  // Reused across paints — paint objects are mutable, so we reset the
  // colour each frame and avoid 60 fps × 3-paint allocations.
  static final Paint _tracePaint = Paint()
    ..strokeWidth = 1.0
    ..style = PaintingStyle.stroke;
  static final Paint _nodePaint = Paint();
  static final Paint _pulsePaint = Paint();

  // Cached trace geometry. Deterministic on a fixed seed and only
  // depends on `size`, so we rebuild only when the canvas resizes.
  static Size? _cachedSize;
  static List<_Trace> _cachedTraces = const [];

  static List<_Trace> _tracesFor(Size size) {
    if (_cachedSize == size) return _cachedTraces;
    final rand = math.Random(7);
    final traces = <_Trace>[];
    for (var i = 0; i < 16; i++) {
      final y = rand.nextDouble() * size.height;
      const startX = -20.0;
      final endX = size.width + 20;
      final midX = startX + (endX - startX) * (0.3 + rand.nextDouble() * 0.4);
      final midY = y + (rand.nextBool() ? -1 : 1) * 32;
      final path = Path()
        ..moveTo(startX, y)
        ..lineTo(midX, y)
        ..lineTo(midX + 24, midY)
        ..lineTo(endX, midY);
      traces.add(_Trace(path, rand.nextDouble(), midX, y, midY));
    }
    _cachedSize = size;
    _cachedTraces = traces;
    return traces;
  }

  @override
  void paint(Canvas canvas, Size size) {
    _tracePaint.color = _kAccentBlue.withValues(alpha: 0.16 * t);
    _nodePaint.color = _kAccentTeal.withValues(alpha: 0.45 * t);
    _pulsePaint.color = _kShimmerDeep.withValues(alpha: 0.85 * t);

    final traces = _tracesFor(size);
    for (final trace in traces) {
      canvas.drawPath(trace.path, _tracePaint);
      canvas.drawCircle(Offset(trace.midX, trace.y), 2.2, _nodePaint);
      canvas.drawCircle(Offset(trace.midX + 24, trace.midY), 2.2, _nodePaint);
    }

    // Pulsing pings travelling along each trace - gives the static
    // backdrop continuous motion during the 2s hold.
    for (final trace in traces) {
      final phase = (ambient * 1.4 + trace.offset) % 1.0;
      final metrics = trace.path.computeMetrics().toList();
      if (metrics.isEmpty) continue;
      final metric = metrics.first;
      final tangent = metric.getTangentForOffset(metric.length * phase);
      if (tangent != null) {
        canvas.drawCircle(tangent.position, 3.0, _pulsePaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CircuitTracesPainter old) =>
      old.t != t || old.ambient != ambient;
}

class _Trace {
  const _Trace(this.path, this.offset, this.midX, this.y, this.midY);
  final Path path;
  final double offset;
  final double midX;
  final double y;
  final double midY;
}

class _Mark extends StatelessWidget {
  const _Mark({
    required this.enter,
    required this.ringEnter,
    required this.ambient,
  });
  final double enter;
  final double ringEnter;
  final double ambient;

  @override
  Widget build(BuildContext context) {
    final scale = 0.55 + 0.45 * enter.clamp(0.0, 1.0);
    final opacity = enter.clamp(0.0, 1.0);
    final breath = 0.5 + 0.5 * math.sin(ambient * math.pi * 2);
    return SizedBox(
      width: 240,
      height: 240,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Two counter-rotating orbital rings - draw a clean tech
          // aesthetic without overpowering the mark itself.
          CustomPaint(
            size: const Size(240, 240),
            painter: _OrbitPainter(
              progress: ringEnter,
              ambient: ambient,
              radius: 110,
              direction: 1,
              dashCount: 28,
              color: _kAccentBlue,
            ),
          ),
          CustomPaint(
            size: const Size(180, 180),
            painter: _OrbitPainter(
              progress: ringEnter,
              ambient: ambient,
              radius: 84,
              direction: -1,
              dashCount: 18,
              color: _kAccentTeal,
            ),
          ),
          Opacity(
            opacity: opacity,
            child: Transform.scale(
              scale: scale,
              child: Container(
                width: 132,
                height: 132,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: _kAccentBlue.withValues(
                        alpha: 0.55 * (0.6 + 0.4 * breath),
                      ),
                      blurRadius: 50 + 20 * breath,
                      spreadRadius: 4,
                    ),
                    BoxShadow(
                      color: _kAccentTeal.withValues(
                        alpha: 0.30 * (0.5 + 0.5 * breath),
                      ),
                      blurRadius: 90,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: ClipOval(
                  child: SvgPicture.asset(
                    'assets/branding/ilink_icon.svg',
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter({
    required this.progress,
    required this.ambient,
    required this.radius,
    required this.direction,
    required this.dashCount,
    required this.color,
  });

  final double progress;
  final double ambient;
  final double radius;
  final int direction;
  final int dashCount;
  final Color color;

  // Reused mutable paint — colour rebuilt per segment, but the same
  // object is recycled instead of allocating dashCount paints/frame.
  static final Paint _segPaint = Paint()
    ..strokeWidth = 1.6
    ..strokeCap = StrokeCap.round;
  static final Paint _headCorePaint = Paint();
  static final Paint _headGlowPaint = Paint()
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final spin = ambient * math.pi * 2 * direction;
    final segCount = (dashCount * progress).round();
    final segArc = (math.pi * 2) / dashCount;
    for (var i = 0; i < segCount; i++) {
      final a = spin + i * segArc;
      final fade = (i / dashCount);
      _segPaint.color = color.withValues(
        alpha: 0.15 + 0.55 * (1 - fade) * progress,
      );
      final p1 = center + Offset(math.cos(a) * radius, math.sin(a) * radius);
      final p2 =
          center +
          Offset(
            math.cos(a + segArc * 0.4) * radius,
            math.sin(a + segArc * 0.4) * radius,
          );
      canvas.drawLine(p1, p2, _segPaint);
    }

    // Glowing leading dot at the head of the rotation.
    final headAngle = spin;
    final headPos =
        center +
        Offset(math.cos(headAngle) * radius, math.sin(headAngle) * radius);
    _headCorePaint.color = color.withValues(alpha: 0.95 * progress);
    canvas.drawCircle(headPos, 3.5, _headCorePaint);
    _headGlowPaint.color = color.withValues(alpha: 0.25 * progress);
    canvas.drawCircle(headPos, 8.0, _headGlowPaint);
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter old) =>
      old.progress != progress || old.ambient != ambient;
}

class _Wordmark extends StatelessWidget {
  const _Wordmark({required this.t, required this.ambient});
  final double t;
  final double ambient;

  @override
  Widget build(BuildContext context) {
    const letters = ['I', '9', '9', 'D', 'A', 'S', 'H'];
    // Letter-by-letter cascade - each glyph fades + rises with its
    // own staggered offset.
    return Column(
      children: [
        ShaderMask(
          shaderCallback: (rect) {
            // Sweeping shimmer driven by the ambient clock.
            final shift = ambient;
            return LinearGradient(
              colors: const [
                _kShimmerLight,
                _kShimmerMid,
                _kShimmerDeep,
                _kShimmerMid,
                _kShimmerLight,
              ],
              stops: [
                (shift - 0.4).clamp(0.0, 1.0),
                (shift - 0.2).clamp(0.0, 1.0),
                shift.clamp(0.0, 1.0),
                (shift + 0.2).clamp(0.0, 1.0),
                (shift + 0.4).clamp(0.0, 1.0),
              ],
            ).createShader(rect);
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < letters.length; i++)
                _Letter(
                  glyph: letters[i],
                  progress: ((t - i * 0.07) / 0.4).clamp(0.0, 1.0),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Opacity(
          opacity: ((t - 0.6) / 0.4).clamp(0.0, 1.0),
          child: Text(
            'head-unit companion',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 4,
              color: Colors.white.withValues(alpha: 0.55),
            ),
          ),
        ),
      ],
    );
  }
}

class _Letter extends StatelessWidget {
  const _Letter({required this.glyph, required this.progress});
  final String glyph;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: progress,
      child: Transform.translate(
        offset: Offset(0, (1 - progress) * 14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Text(
            glyph,
            style: const TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.w800,
              letterSpacing: 4,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _PartnershipCard extends StatelessWidget {
  const _PartnershipCard({
    required this.enter,
    required this.beam,
    required this.ambient,
  });
  final double enter;
  final double beam;
  final double ambient;

  @override
  Widget build(BuildContext context) {
    final opacity = enter.clamp(0.0, 1.0);
    final slide = (1 - opacity) * 32;
    return Opacity(
      opacity: opacity,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.white.withValues(alpha: 0.06),
                Colors.white.withValues(alpha: 0.02),
              ],
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.10),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: _kBgGlow.withValues(alpha: 0.4),
                blurRadius: 28,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.translate(
                offset: Offset(-slide, 0),
                child: const _CubeTekBadge(),
              ),
              const SizedBox(width: 20),
              _EnergyBeam(progress: beam, ambient: ambient),
              const SizedBox(width: 20),
              Transform.translate(
                offset: Offset(slide, 0),
                child: const _QevBadge(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CubeTekBadge extends StatelessWidget {
  const _CubeTekBadge();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'BUILT BY',
          style: TextStyle(
            fontSize: 9,
            letterSpacing: 2.4,
            color: Colors.white.withValues(alpha: 0.55),
          ),
        ),
        const SizedBox(height: 10),
        SvgPicture.asset(
          'assets/branding/cubetek.svg',
          height: 24,
          colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
        ),
      ],
    );
  }
}

class _QevBadge extends StatelessWidget {
  const _QevBadge();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'SPONSORED BY',
          style: TextStyle(
            fontSize: 9,
            letterSpacing: 2.4,
            color: Colors.white.withValues(alpha: 0.55),
          ),
        ),
        const SizedBox(height: 6),
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: _kAccentBlue.withValues(alpha: 0.35),
                blurRadius: 14,
                spreadRadius: 1,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset(
              'assets/branding/qev.jpg',
              height: 40,
              width: 40,
              fit: BoxFit.cover,
            ),
          ),
        ),
      ],
    );
  }
}

class _EnergyBeam extends StatelessWidget {
  const _EnergyBeam({required this.progress, required this.ambient});
  final double progress;
  final double ambient;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 88,
      height: 40,
      child: CustomPaint(
        painter: _BeamPainter(progress: progress, ambient: ambient),
      ),
    );
  }
}

class _BeamPainter extends CustomPainter {
  _BeamPainter({required this.progress, required this.ambient});
  final double progress;
  final double ambient;

  // Reused across paints. Shader on _basePaint depends on size so we
  // rebuild only when size changes; colours are reset every frame.
  static final Paint _basePaint = Paint()..strokeWidth = 1.0;
  static Size? _shaderSize;
  static final Paint _particleCorePaint = Paint();
  static final Paint _particleGlowPaint = Paint()
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
  static final Paint _hubCorePaint = Paint();
  static final Paint _hubGlowPaint = Paint()
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final cy = size.height / 2;
    // Base line - draws across as `progress` increases.
    final lineEnd = size.width * progress;
    if (_shaderSize != size) {
      _basePaint.shader = LinearGradient(
        colors: [
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.45),
          Colors.white.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
      _shaderSize = size;
    }
    canvas.drawLine(Offset(0, cy), Offset(lineEnd, cy), _basePaint);

    if (progress < 0.5) return;

    // Three particles streaming along the beam at staggered phases -
    // gives the connection continuous motion during the hold.
    for (var i = 0; i < 3; i++) {
      final phase = (ambient * 1.6 + i * 0.33) % 1.0;
      final x = size.width * phase;
      final glow = math.sin(phase * math.pi);
      final color = i.isEven ? _kAccentTeal : _kShimmerDeep;
      _particleCorePaint.color = color.withValues(alpha: 0.95 * glow);
      canvas.drawCircle(Offset(x, cy), 3.0, _particleCorePaint);
      _particleGlowPaint.color = color.withValues(alpha: 0.45 * glow);
      canvas.drawCircle(Offset(x, cy), 9.0, _particleGlowPaint);
    }

    // Hub dot at center, breathing.
    final hubPulse = 0.5 + 0.5 * math.sin(ambient * math.pi * 2);
    _hubCorePaint.color = _kAccentTeal.withValues(alpha: 0.9 * hubPulse);
    canvas.drawCircle(Offset(size.width / 2, cy), 4.5, _hubCorePaint);
    _hubGlowPaint.color = _kAccentTeal.withValues(alpha: 0.35 * hubPulse);
    canvas.drawCircle(Offset(size.width / 2, cy), 11.0, _hubGlowPaint);
  }

  @override
  bool shouldRepaint(covariant _BeamPainter old) =>
      old.progress != progress || old.ambient != ambient;
}

class _Caption extends StatelessWidget {
  const _Caption({required this.t});
  final double t;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: t.clamp(0.0, 1.0),
      child: Transform.translate(
        offset: Offset(0, (1 - t.clamp(0.0, 1.0)) * 8),
        child: Text(
          'a CubeTek production - powered by the QEV community',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 0.4,
            color: Colors.white.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}
