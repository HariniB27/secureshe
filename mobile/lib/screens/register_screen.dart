import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../state/auth_state.dart';
import '../theme.dart';
import '../utils/json_utils.dart';
import '../utils/validation.dart';
import '../widgets/ss_ui.dart';

/// Two-step sign up from the design: personal info, then credentials,
/// then a welcome screen. Creates the account with POST /api/auth/register
/// and signs straight in.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  int _step = 1; // 1 personal, 2 credentials, 3 done
  bool _loading = false;
  String? _error;

  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void initState() {
    super.initState();
    for (final c in [_password, _confirm]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _email, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  void _back() {
    if (_step == 2) {
      setState(() {
        _step = 1;
        _error = null;
      });
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _next() async {
    setState(() => _error = null);

    if (_step == 1) {
      if (_name.text.trim().isEmpty) {
        setState(() => _error = 'Please enter your full name.');
        return;
      }
      if (_phone.text.trim().isEmpty) {
        setState(() => _error = 'Please enter your phone number.');
        return;
      }
      setState(() => _step = 2);
      return;
    }

    final email = _email.text.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _error = 'Please enter a valid email address.');
      return;
    }
    if (_password.text.length < kMinPasswordLength) {
      setState(() => _error = 'Password must be at least $kMinPasswordLength characters.');
      return;
    }
    if (_password.text != _confirm.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }

    setState(() => _loading = true);

    try {
      final response = await ApiService.register(
        name: _name.text.trim(),
        email: email,
        password: _password.text,
        phone: _phone.text.trim(),
      );

      if (!mounted) return;

      if (response.statusCode != 201) {
        setState(() {
          _loading = false;
          _error = errorMessage(response, fallback: 'Registration failed');
        });
        return;
      }

      // Sign in straight away so "Get Started" goes to Home.
      final loginError = await context.read<AuthState>().login(
            email: email,
            password: _password.text,
          );
      if (!mounted) return;

      setState(() {
        _loading = false;
        if (loginError == null) {
          _step = 3;
        } else {
          _error = 'Account created, but sign-in failed: $loginError';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Cannot reach the server. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ss;

    return PopScope(
      canPop: _step != 2,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: SSPage(
        body: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                child: Row(
                  children: [
                    if (_step < 3) ...[
                      SSIconButton(icon: Icons.arrow_back_rounded, onTap: _back),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _step == 3 ? 'All done!' : 'Create Account',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: c.foreground,
                            ),
                          ),
                          if (_step < 3)
                            Text(
                              'Step $_step of 2',
                              style: TextStyle(fontSize: 11, color: c.mutedForeground),
                            ),
                        ],
                      ),
                    ),
                    if (_step < 3) StepDots(step: _step, count: 2),
                  ],
                ),
              ),
              if (_step < 3) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: ThinProgress(value: _step / 2),
                ),
                const _BrandStrip(),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0.08, 0),
                        end: Offset.zero,
                      ).animate(anim),
                      child: child,
                    ),
                  ),
                  child: switch (_step) {
                    1 => _stepPersonal(context),
                    2 => _stepCredentials(context),
                    _ => _stepDone(context),
                  },
                ),
              ),
              if (_step < 3)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Already have an account?',
                      style: TextStyle(fontSize: 13, color: c.mutedForeground),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text(
                        'Sign In',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _heading(String title, String subtitle) {
    final c = context.ss;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: c.foreground),
        ),
        const SizedBox(height: 4),
        Text(subtitle, style: TextStyle(fontSize: 13, color: c.mutedForeground)),
      ],
    );
  }

  Widget _stepPersonal(BuildContext context) {
    return Column(
      key: const ValueKey('step1'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Personal Info', 'Tell us a bit about yourself'),
        const SizedBox(height: 20),
        SSTextField(
          controller: _name,
          label: 'Full Name',
          hint: 'e.g. Priya Sharma',
          icon: Icons.person_outline_rounded,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.name],
        ),
        const SizedBox(height: 20),
        SSTextField(
          controller: _phone,
          label: 'Phone Number',
          hint: '+91 98765 43210',
          icon: Icons.phone_outlined,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _next(),
          helper: 'Used for SOS alerts to your trusted circle',
          autofillHints: const [AutofillHints.telephoneNumber],
        ),
        if (_error != null) ...[
          const SizedBox(height: 20),
          MessageBanner(text: _error!),
        ],
        const SizedBox(height: 20),
        GradientButton(
          label: 'Continue',
          trailingIcon: Icons.arrow_forward_rounded,
          onPressed: _next,
        ),
      ],
    );
  }

  Widget _stepCredentials(BuildContext context) {
    final c = context.ss;
    final pw = _password.text;
    final confirm = _confirm.text;

    // Four steps, tied to the real minimum: below it the password is
    // rejected, so it is never shown as better than "Too short".
    final level = pw.length < 4
        ? 1
        : pw.length < kMinPasswordLength
            ? 2
            : pw.length < 12
                ? 3
                : 4;
    final strength = switch (level) {
      1 || 2 => 'Too short',
      3 => 'Good',
      _ => 'Strong',
    };

    Color? confirmBorder;
    if (confirm.isNotEmpty) {
      confirmBorder = confirm == pw ? AppColors.success : AppColors.destructive;
    }

    return Column(
      key: const ValueKey('step2'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Set Credentials', 'Secure your SecureShe account'),
        const SizedBox(height: 20),
        SSTextField(
          controller: _email,
          label: 'Email Address',
          hint: 'you@example.com',
          icon: Icons.mail_outline_rounded,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.email],
        ),
        const SizedBox(height: 20),
        SSTextField(
          controller: _password,
          label: 'Password',
          hint: 'Min. $kMinPasswordLength characters',
          icon: Icons.lock_outline_rounded,
          obscure: true,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.newPassword],
        ),
        if (pw.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 1; i <= 4; i++)
                Expanded(
                  child: Container(
                    height: 4,
                    margin: EdgeInsets.only(right: i < 4 ? 4 : 0),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      color: i <= level
                          ? (level == 1
                              ? AppColors.destructive
                              : level == 2
                                  ? AppColors.warning
                                  : AppColors.success)
                          : c.muted,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '$strength password',
            style: TextStyle(fontSize: 10, color: c.mutedForeground),
          ),
        ],
        const SizedBox(height: 20),
        SSTextField(
          controller: _confirm,
          label: 'Confirm Password',
          hint: 'Re-enter your password',
          icon: Icons.lock_outline_rounded,
          obscure: true,
          borderColor: confirmBorder,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _next(),
          helper: confirm.isNotEmpty && confirm == pw ? '✓ Passwords match' : null,
          helperColor: AppColors.success,
        ),
        if (_error != null) ...[
          const SizedBox(height: 20),
          MessageBanner(text: _error!),
        ],
        const SizedBox(height: 20),
        Text.rich(
          TextSpan(
            style: TextStyle(fontSize: 11, height: 1.6, color: c.mutedForeground),
            children: const [
              TextSpan(text: 'By creating an account you agree to our '),
              TextSpan(
                text: 'Terms of Service',
                style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600),
              ),
              TextSpan(text: ' and '),
              TextSpan(
                text: 'Privacy Policy',
                style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600),
              ),
              TextSpan(text: '.'),
            ],
          ),
        ),
        const SizedBox(height: 20),
        GradientButton(
          label: 'Create Account',
          trailingIcon: Icons.arrow_forward_rounded,
          loading: _loading,
          onPressed: _next,
        ),
      ],
    );
  }

  Widget _stepDone(BuildContext context) {
    final c = context.ss;
    final firstName = _name.text.trim().split(' ').first;

    const features = [
      ('🚨', 'One-tap SOS alerts', AppColors.destructive),
      ('🗺️', 'Safe route planner', AppColors.primary),
      ('👥', 'Trusted circle sharing', AppColors.warning),
    ];

    return Column(
      key: const ValueKey('step3'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 32),
        Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 600),
            curve: Curves.elasticOut,
            builder: (_, s, child) => Transform.scale(scale: s, child: child),
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.success.withValues(alpha: 0.12),
                border: Border.all(color: AppColors.success.withValues(alpha: 0.4), width: 2),
                boxShadow: [
                  BoxShadow(color: AppColors.success.withValues(alpha: 0.2), blurRadius: 40),
                ],
              ),
              child: const Icon(
                Icons.check_circle_outline_rounded,
                size: 48,
                color: AppColors.success,
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          "You're all set! 🎉",
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: c.foreground),
        ),
        const SizedBox(height: 8),
        Text(
          'Welcome to SecureShe, ${firstName.isEmpty ? 'friend' : firstName}!\n'
          'Your account has been created successfully.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, height: 1.6, color: c.mutedForeground),
        ),
        const SizedBox(height: 24),
        for (final (emoji, label, color) in features)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SSCard(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Text(emoji, style: const TextStyle(fontSize: 20)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.foreground,
                      ),
                    ),
                  ),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        GradientButton(
          label: 'Get Started',
          trailingIcon: Icons.arrow_forward_rounded,
          onPressed: () =>
              Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false),
        ),
      ],
    );
  }
}

class _BrandStrip extends StatelessWidget {
  const _BrandStrip();

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              gradient: AppColors.primaryGradient,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(color: AppColors.primary.withValues(alpha: 0.3), blurRadius: 28),
              ],
            ),
            child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 26),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SecureShe',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: c.foreground),
              ),
              Text(
                'Stay safe · Stay aware',
                style: TextStyle(fontSize: 11, color: c.mutedForeground),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
