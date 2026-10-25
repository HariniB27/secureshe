import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/sos_service.dart';
import '../state/app_prefs.dart';
import '../state/contacts_state.dart';
import '../theme.dart';
import '../widgets/ss_ui.dart';

enum _Phase { countdown, sending, sent, failed }

/// Shown after holding the SOS button. Counts down 3 seconds (cancel any
/// time), then alerts the trusted circle: through the server when online,
/// or by SMS straight from the phone when not.
class SosConfirmScreen extends StatefulWidget {
  const SosConfirmScreen({super.key});

  @override
  State<SosConfirmScreen> createState() => _SosConfirmScreenState();
}

class _SosConfirmScreenState extends State<SosConfirmScreen>
    with SingleTickerProviderStateMixin {
  _Phase _phase = _Phase.countdown;
  int _countdown = 3;
  Timer? _timer;
  String _status = '';
  SosResult? _result;

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void initState() {
    super.initState();
    HapticFeedback.heavyImpact();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_countdown <= 1) {
        t.cancel();
        _send();
      } else {
        HapticFeedback.selectionClick();
        setState(() => _countdown--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    _timer?.cancel();
    if (_phase != _Phase.countdown) return;

    setState(() {
      _phase = _Phase.sending;
      _status = 'Getting your location…';
    });

    final result = await SosService.send(
      onStatus: (s) {
        if (mounted) setState(() => _status = s);
      },
    );

    if (!mounted) return;

    final prefs = context.read<AppPrefs>();
    if (result.sent) {
      await prefs.recordSos();
      await prefs.notify(
        type: 'danger',
        title: 'SOS alert sent',
        message: result.message,
      );
    }

    if (!mounted) return;
    setState(() {
      _result = result;
      _phase = result.sent ? _Phase.sent : _Phase.failed;
    });
  }

  void _cancel() {
    _timer?.cancel();
    Navigator.of(context).pop();
  }

  Future<void> _call112() async {
    await launchUrl(Uri(scheme: 'tel', path: '112'));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _phase != _Phase.sending,
      child: SSPage(
        body: switch (_phase) {
          _Phase.sent => _sentView(context),
          _Phase.failed => _failedView(context),
          _ => _confirmView(context),
        },
      ),
    );
  }

  Widget _confirmView(BuildContext context) {
    final c = context.ss;
    final sending = _phase == _Phase.sending;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Align(
            alignment: Alignment.centerRight,
            child: sending
                ? const SizedBox(height: 40)
                : SSIconButton(icon: Icons.close_rounded, onTap: _cancel),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 8),
                _PulsingSos(animation: _pulse),
                const SizedBox(height: 32),
                Text(
                  'Emergency SOS',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: c.foreground,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: 280,
                  child: Text(
                    'This will alert all your emergency contacts with your '
                    'current location and send distress signals.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, height: 1.6, color: c.mutedForeground),
                  ),
                ),
                const SizedBox(height: 32),
                if (sending)
                  Column(
                    children: [
                      const SizedBox(
                        width: 40,
                        height: 40,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: AppColors.destructive,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(_status, style: TextStyle(fontSize: 13, color: c.mutedForeground)),
                    ],
                  )
                else ...[
                  Text(
                    '$_countdown',
                    style: const TextStyle(
                      fontSize: 72,
                      fontWeight: FontWeight.w900,
                      height: 1,
                      color: AppColors.destructive,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Sending in $_countdown second${_countdown == 1 ? '' : 's'}',
                    style: TextStyle(fontSize: 12, color: c.mutedForeground),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: 320,
                    child: Column(
                      children: [
                        GradientButton(
                          label: 'Send Now',
                          icon: Icons.phone_in_talk_rounded,
                          variant: SSButtonVariant.danger,
                          onPressed: _send,
                        ),
                        const SizedBox(height: 12),
                        GradientButton(
                          label: 'Cancel',
                          variant: SSButtonVariant.outline,
                          onPressed: _cancel,
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _sentView(BuildContext context) {
    final c = context.ss;
    final contacts = context.watch<ContactsState>().contacts;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ScaleTransition(
              scale: Tween(begin: 1.0, end: 1.08).animate(
                CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
              ),
              child: Container(
                width: 112,
                height: 112,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.success.withValues(alpha: 0.15),
                ),
                child: Center(
                  child: Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.success.withValues(alpha: 0.25),
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      size: 40,
                      color: AppColors.success,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'SOS Alert Sent!',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: c.foreground),
            ),
            const SizedBox(height: 12),
            Text(
              _result?.message ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, height: 1.6, color: c.mutedForeground),
            ),
            if (contacts.isNotEmpty) ...[
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.success.withValues(alpha: 0.3)),
                ),
                child: Column(
                  children: [
                    Text(
                      'NOTIFIED',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: c.mutedForeground,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        for (final contact in contacts)
                          TagPill(text: contact.name, color: AppColors.success),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 32),
            GradientButton(
              label: 'Call Emergency (112)',
              icon: Icons.phone_rounded,
              variant: SSButtonVariant.danger,
              onPressed: _call112,
            ),
            const SizedBox(height: 12),
            GradientButton(
              label: 'Back to Home',
              variant: SSButtonVariant.outline,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _failedView(BuildContext context) {
    final c = context.ss;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.destructive.withValues(alpha: 0.15),
              ),
              child: const Icon(
                Icons.error_outline_rounded,
                size: 44,
                color: AppColors.destructive,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Alert not sent',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: c.foreground),
            ),
            const SizedBox(height: 12),
            Text(
              _result?.message ?? 'Something went wrong.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, height: 1.6, color: c.mutedForeground),
            ),
            const SizedBox(height: 32),
            GradientButton(
              label: 'Call Emergency (112)',
              icon: Icons.phone_rounded,
              variant: SSButtonVariant.danger,
              onPressed: _call112,
            ),
            const SizedBox(height: 12),
            GradientButton(
              label: 'Try Again',
              icon: Icons.refresh_rounded,
              onPressed: () {
                setState(() => _phase = _Phase.countdown);
                _send();
              },
            ),
            const SizedBox(height: 12),
            GradientButton(
              label: 'Close',
              variant: SSButtonVariant.outline,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

class _PulsingSos extends StatelessWidget {
  const _PulsingSos({required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 176,
      height: 176,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final t = animation.value;
          final t2 = (t + 0.2) % 1.0;
          return Stack(
            alignment: Alignment.center,
            children: [
              for (final (v, max, alpha) in [(t, 0.5, 0.4), (t2, 0.8, 0.25)])
                Transform.scale(
                  scale: 1 + max * v,
                  child: Container(
                    width: 176,
                    height: 176,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.destructive.withValues(alpha: alpha * (1 - v) * 0.5),
                    ),
                  ),
                ),
              child!,
            ],
          );
        },
        child: Container(
          width: 144,
          height: 144,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: AppColors.dangerGradient,
            boxShadow: [
              BoxShadow(
                color: AppColors.destructive.withValues(alpha: 0.6),
                blurRadius: 60,
              ),
              const BoxShadow(color: Colors.black38, blurRadius: 32, offset: Offset(0, 8)),
            ],
          ),
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline_rounded, size: 48, color: Colors.white),
              SizedBox(height: 4),
              Text(
                'S O S',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
