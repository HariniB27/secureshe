import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/auth_state.dart';
import '../state/contacts_state.dart';
import '../theme.dart';
import '../widgets/ss_ui.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Arrived here because the server ended the session: say so, once.
    final auth = context.read<AuthState>();
    if (auth.sessionExpired) {
      _error = 'Your session expired. Please sign in again.';
      auth.clearSessionNotice();
    }
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final email = _email.text.trim();
    final password = _password.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Please fill in all fields.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final error = await context.read<AuthState>().login(
          email: email,
          password: password,
        );

    if (!mounted) return;

    if (error != null) {
      setState(() {
        _loading = false;
        _error = error;
      });
      return;
    }

    final contacts = context.read<ContactsState>();
    await contacts.loadCached();
    contacts.refresh();

    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ss;

    return SSPage(
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: AutofillGroup(
          child: Column(
            children: [
              const SizedBox(height: 32),
              const _BrandHero(),
              const SizedBox(height: 24),
              SSCard(
                radius: 24,
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Welcome back',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: c.foreground,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Sign in to continue keeping yourself safe',
                      style: TextStyle(fontSize: 12, color: c.mutedForeground),
                    ),
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
                    const SizedBox(height: 16),
                    SSTextField(
                      controller: _password,
                      label: 'Password',
                      hint: 'Enter your password',
                      icon: Icons.lock_outline_rounded,
                      obscure: true,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _login(),
                      autofillHints: const [AutofillHints.password],
                    ),
                    // There is no email service yet, so there is no reset flow
                    // to link to. Say so instead of showing a dead button.
                    Padding(
                      padding: const EdgeInsets.only(top: 10, bottom: 16),
                      child: Text(
                        'Contact support to reset your password',
                        textAlign: TextAlign.right,
                        style: TextStyle(fontSize: 12, color: c.mutedForeground),
                      ),
                    ),
                    if (_error != null) ...[
                      MessageBanner(text: _error!),
                      const SizedBox(height: 16),
                    ],
                    GradientButton(
                      label: 'Sign In',
                      trailingIcon: Icons.arrow_forward_rounded,
                      loading: _loading,
                      onPressed: _login,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      "Don't have an account?",
                      style: TextStyle(fontSize: 13, color: c.mutedForeground),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pushNamed('/register'),
                      child: const Text(
                        'Sign Up',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
              const TagPill(
                text: 'Your password is stored hashed, never in plain text',
                color: AppColors.success,
                icon: Icons.circle,
                fontSize: 10,
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrandHero extends StatelessWidget {
  const _BrandHero();

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return Column(
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.7, end: 1),
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOut,
          builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              gradient: AppColors.primaryGradient,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.35),
                  blurRadius: 40,
                ),
              ],
            ),
            child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 34),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'SecureShe',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            color: c.foreground,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Your personal safety companion',
          style: TextStyle(fontSize: 13, color: c.mutedForeground),
        ),
      ],
    );
  }
}

