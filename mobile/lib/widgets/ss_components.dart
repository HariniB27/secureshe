import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'ss_ui.dart';

// ====================================================================
// SOS button — press and hold for 3 seconds
// ====================================================================

class SOSHoldButton extends StatefulWidget {
  const SOSHoldButton({super.key, required this.onTriggered});

  final VoidCallback onTriggered;

  @override
  State<SOSHoldButton> createState() => _SOSHoldButtonState();
}

class _SOSHoldButtonState extends State<SOSHoldButton>
    with TickerProviderStateMixin {
  static const _holdDuration = Duration(seconds: 3);

  late final AnimationController _hold =
      AnimationController(vsync: this, duration: _holdDuration)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed) {
            HapticFeedback.heavyImpact();
            _hold.reset();
            widget.onTriggered();
          }
        });

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2500),
  )..repeat();

  bool get _holding => _hold.isAnimating;

  void _start() {
    HapticFeedback.mediumImpact();
    _hold.forward(from: 0);
    setState(() {});
  }

  void _cancel() {
    if (_hold.isAnimating) _hold.reverse();
    setState(() {});
  }

  @override
  void dispose() {
    _hold.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'SOS. Press and hold for 3 seconds to alert your emergency contacts.',
      child: GestureDetector(
        onTapDown: (_) => _start(),
        onTapUp: (_) => _cancel(),
        onTapCancel: _cancel,
        child: SizedBox(
          width: 220,
          height: 220,
          child: AnimatedBuilder(
            animation: Listenable.merge([_hold, _pulse]),
            builder: (context, _) {
              final p = _pulse.value;
              final holding = _holding;
              final speed = holding ? 3.0 : 1.0;
              final t1 = (p * speed) % 1.0;
              final t2 = ((p * speed) + 0.2) % 1.0;

              return Stack(
                alignment: Alignment.center,
                children: [
                  // Pulse rings
                  _ring(
                    scale: 1 + (holding ? 0.6 : 0.35) * t1,
                    opacity: (holding ? 0.5 : 0.25) * (1 - t1),
                  ),
                  _ring(
                    scale: 1 + (holding ? 1.1 : 0.65) * t2,
                    opacity: (holding ? 0.3 : 0.12) * (1 - t2),
                  ),
                  // Progress ring
                  CustomPaint(
                    size: const Size(220, 220),
                    painter: _ProgressRingPainter(_hold.value),
                  ),
                  // Button
                  AnimatedScale(
                    scale: holding ? 0.93 : 1,
                    duration: const Duration(milliseconds: 150),
                    child: Container(
                      width: 186,
                      height: 186,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [AppColors.destructive, AppColors.destructiveDark],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.destructive
                                .withValues(alpha: holding ? 0.7 : 0.5),
                            blurRadius: holding ? 64 : 52,
                          ),
                          const BoxShadow(
                            color: Colors.black38,
                            blurRadius: 28,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text(
                            'SOS',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 46,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 4,
                              height: 1,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            holding ? 'Keep holding…' : 'Hold 3s',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _ring({required double scale, required double opacity}) {
    return Transform.scale(
      scale: scale,
      child: Container(
        width: 190,
        height: 190,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.destructive.withValues(alpha: opacity.clamp(0.0, 1.0)),
        ),
      ),
    );
  }
}

class _ProgressRingPainter extends CustomPainter {
  _ProgressRingPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    const radius = 88.0;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = AppColors.destructive.withValues(alpha: 0.15),
    );

    if (progress > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..strokeCap = StrokeCap.round
          ..color = AppColors.destructive,
      );
    }
  }

  @override
  bool shouldRepaint(_ProgressRingPainter old) => old.progress != progress;
}

// ====================================================================
// Safety score ring card
// ====================================================================

Color safetyColor(int score) {
  if (score >= 75) return AppColors.success;
  if (score >= 50) return AppColors.warning;
  return AppColors.destructive;
}

String safetyLabel(int score) {
  if (score >= 75) return 'Safe';
  if (score >= 50) return 'Moderate';
  return 'Unsafe';
}

class ScoreRing extends StatelessWidget {
  const ScoreRing({
    super.key,
    required this.score,
    this.size = 96,
    this.stroke = 8,
    this.color,
    this.showOutOf = true,
  });

  final int? score;
  final double size;
  final double stroke;
  final Color? color;
  final bool showOutOf;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final value = score;
    final ringColor = color ?? (value == null ? c.mutedForeground : safetyColor(value));

    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: (value ?? 0) / 100),
        duration: const Duration(milliseconds: 1200),
        curve: Curves.easeOut,
        builder: (context, t, _) => CustomPaint(
          painter: _ScoreRingPainter(
            fraction: t,
            color: ringColor,
            track: c.isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE8DFF0),
            stroke: stroke,
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value == null ? '–' : '$value',
                  style: TextStyle(
                    fontSize: size * 0.25,
                    fontWeight: FontWeight.w900,
                    color: ringColor,
                    height: 1.1,
                  ),
                ),
                if (showOutOf)
                  Text(
                    '/ 100',
                    style: TextStyle(fontSize: 11, color: c.mutedForeground),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ScoreRingPainter extends CustomPainter {
  _ScoreRingPainter({
    required this.fraction,
    required this.color,
    required this.track,
    required this.stroke,
  });

  final double fraction;
  final Color color;
  final Color track;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - stroke / 2;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * fraction,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_ScoreRingPainter old) =>
      old.fraction != fraction || old.color != color || old.track != track;
}

/// "Safety Score" card on Home.
class SafetyScoreCard extends StatelessWidget {
  const SafetyScoreCard({
    super.key,
    required this.score,
    required this.location,
    this.reportsNearby,
    this.loading = false,
    this.onTap,
  });

  final int? score;
  final String location;
  final int? reportsNearby;
  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final value = score;

    return SSCard(
      radius: 24,
      padding: const EdgeInsets.all(20),
      onTap: onTap,
      child: Row(
        children: [
          loading && value == null
              ? const SizedBox(
                  width: 96,
                  height: 96,
                  child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
                )
              : ScoreRing(score: value),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (value != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: safetyColor(value).withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      safetyLabel(value),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: safetyColor(value),
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  'Safety Score',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: c.foreground,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.place_outlined, size: 12, color: c.mutedForeground),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        location,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: c.mutedForeground),
                      ),
                    ),
                  ],
                ),
                if (reportsNearby != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        reportsNearby == 0
                            ? Icons.verified_user_outlined
                            : Icons.warning_amber_rounded,
                        size: 12,
                        color: reportsNearby == 0
                            ? AppColors.success
                            : AppColors.warning,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          reportsNearby == 0
                              ? 'No recent reports within 2 km'
                              : '$reportsNearby recent report${reportsNearby == 1 ? '' : 's'} within 2 km',
                          style: TextStyle(
                            fontSize: 12,
                            color: reportsNearby == 0
                                ? AppColors.success
                                : AppColors.warning,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ====================================================================
// Alert card ("Nearby Alerts")
// ====================================================================

enum AlertKind { danger, warning, info, safe }

class AlertCard extends StatelessWidget {
  const AlertCard({
    super.key,
    required this.kind,
    required this.title,
    required this.time,
    this.description,
    this.distance,
    this.icon,
    this.onTap,
  });

  final AlertKind kind;
  final String title;
  final String? description;
  final String time;
  final String? distance;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final color = switch (kind) {
      AlertKind.danger => AppColors.destructive,
      AlertKind.warning => AppColors.warning,
      AlertKind.safe => AppColors.success,
      AlertKind.info => AppColors.primary,
    };
    final defaultIcon = switch (kind) {
      AlertKind.danger => Icons.error_outline_rounded,
      AlertKind.warning => Icons.warning_amber_rounded,
      AlertKind.safe => Icons.verified_user_outlined,
      AlertKind.info => Icons.place_outlined,
    };

    return SSCard(
      leftAccent: color,
      padding: const EdgeInsets.all(16),
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconTile(icon: icon ?? defaultIcon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: c.foreground,
                  ),
                ),
                if (description != null && description!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    description!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: c.mutedForeground),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  distance == null ? time : '$time  •  $distance away',
                  style: TextStyle(fontSize: 12, color: c.mutedForeground),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ====================================================================
// Vertical timeline (report progress, trip check-ins)
// ====================================================================

enum TimelineState { done, current, pending }

class TimelineEntry {
  const TimelineEntry({
    required this.title,
    required this.state,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final String? trailing;
  final TimelineState state;
}

class TimelineList extends StatelessWidget {
  const TimelineList({
    super.key,
    required this.entries,
    this.currentLabel = 'In Progress',
    this.compact = false,
  });

  final List<TimelineEntry> entries;
  final String currentLabel;

  /// Compact rows with a status pill on the right (trip check-ins).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return Column(
      children: [
        for (var i = 0; i < entries.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 32,
                  child: Column(
                    children: [
                      _dot(context, entries[i].state),
                      if (i < entries.length - 1)
                        Expanded(
                          child: Container(
                            width: 2,
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            color: entries[i].state == TimelineState.done
                                ? AppColors.success.withValues(alpha: 0.4)
                                : c.border,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      bottom: i == entries.length - 1 ? 0 : (compact ? 16 : 24),
                      top: 4,
                    ),
                    child: _content(context, entries[i]),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _dot(BuildContext context, TimelineState state) {
    final c = context.ss;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: switch (state) {
          TimelineState.done => AppColors.success.withValues(alpha: 0.18),
          TimelineState.current => AppColors.primary.withValues(alpha: 0.18),
          TimelineState.pending => c.muted,
        },
      ),
      child: Center(
        child: switch (state) {
          TimelineState.done => const Icon(
              Icons.check_circle_outline_rounded,
              size: 16,
              color: AppColors.success,
            ),
          TimelineState.current => Container(
              width: 12,
              height: 12,
              decoration: const BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
              ),
            ),
          TimelineState.pending => Icon(
              Icons.circle_outlined,
              size: compact ? 10 : 16,
              color: c.mutedForeground,
            ),
        },
      ),
    );
  }

  Widget _content(BuildContext context, TimelineEntry e) {
    final c = context.ss;
    final pending = e.state == TimelineState.pending;

    if (compact) {
      final (String pill, Color color) = switch (e.state) {
        TimelineState.done => ('Done', AppColors.success),
        TimelineState.current => ('Now', AppColors.primary),
        TimelineState.pending => ('Soon', c.mutedForeground),
      };
      return Opacity(
        opacity: pending ? 0.55 : 1,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: e.state == TimelineState.current
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: c.foreground,
                    ),
                  ),
                  if (e.subtitle != null)
                    Text(
                      e.subtitle!,
                      style: TextStyle(fontSize: 11, color: c.mutedForeground),
                    ),
                ],
              ),
            ),
            TagPill(text: pill, color: color, fontSize: 10),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.title,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: pending ? c.mutedForeground : c.foreground,
                    ),
                  ),
                  if (e.subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      e.subtitle!,
                      style: TextStyle(fontSize: 13, color: c.mutedForeground),
                    ),
                  ],
                ],
              ),
            ),
            if (e.trailing != null)
              Text(
                e.trailing!,
                style: TextStyle(fontSize: 11, color: c.mutedForeground),
              ),
          ],
        ),
        if (e.state == TimelineState.current) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
            ),
            child: Text(
              currentLabel,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ====================================================================
// Small stat tile (ETA / Distance / Safety)
// ====================================================================

class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return SSCard(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Column(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: c.foreground,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 10, color: c.mutedForeground)),
        ],
      ),
    );
  }
}

/// Avatar square with initials (profile, contacts).
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar({
    super.key,
    required this.initials,
    required this.color,
    this.size = 44,
    this.solid = false,
    this.online,
  });

  final String initials;
  final Color color;
  final double size;
  final bool solid;
  final bool? online;

  @override
  Widget build(BuildContext context) {
    final avatar = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.36),
        gradient: solid
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.primary, Color(0xFFE0107E)],
              )
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  color.withValues(alpha: 0.19),
                  color.withValues(alpha: 0.08),
                ],
              ),
        border: solid ? null : Border.all(color: color.withValues(alpha: 0.25), width: 1.5),
      ),
      child: Text(
        initials,
        style: TextStyle(
          fontSize: size * 0.3,
          fontWeight: FontWeight.w800,
          color: solid ? Colors.white : color,
          letterSpacing: -0.5,
        ),
      ),
    );

    if (online == null) return avatar;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          right: -2,
          bottom: -2,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: online! ? AppColors.success : context.ss.mutedForeground,
              border: Border.all(color: context.ss.cardSolid, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}

/// Recording timer text, mm:ss.
String formatClock(int seconds) {
  final m = (seconds ~/ 60).toString().padLeft(2, '0');
  final s = (seconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// Ticks once a second while mounted; for live timers.
class SecondTicker extends StatefulWidget {
  const SecondTicker({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  State<SecondTicker> createState() => _SecondTickerState();
}

class _SecondTickerState extends State<SecondTicker> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
