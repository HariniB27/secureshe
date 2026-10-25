import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../state/app_prefs.dart';
import '../state/auth_state.dart';
import '../state/contacts_state.dart';
import '../state/shell_controller.dart';
import '../state/trip_state.dart';
import '../theme.dart';
import '../utils/json_utils.dart';
import '../utils/validation.dart';
import '../widgets/ss_components.dart';
import '../widgets/ss_ui.dart';

/// Privacy & Security. Everything here works for real; options the backend
/// doesn't support yet are shown as "Soon" and can't be switched on.
class PrivacySecurityScreen extends StatefulWidget {
  const PrivacySecurityScreen({super.key});

  @override
  State<PrivacySecurityScreen> createState() => _PrivacySecurityScreenState();
}

class _PrivacySecurityScreenState extends State<PrivacySecurityScreen> {
  String? _toast;

  void _showToast(String message) {
    setState(() => _toast = message);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && _toast == message) setState(() => _toast = null);
    });
  }

  Future<void> _toggleBiometric(AppPrefs prefs, bool value) async {
    if (value) {
      final auth = LocalAuthentication();
      try {
        if (!await auth.isDeviceSupported()) {
          _showToast('This device has no Face ID or fingerprint set up');
          return;
        }
        final ok = await auth.authenticate(localizedReason: 'Turn on biometric unlock');
        if (!ok) return;
      } catch (_) {
        _showToast('Biometrics are not available here');
        return;
      }
    }
    await prefs.setBiometricLock(value);
    _showToast(value ? 'SecureShe will ask for Face ID / fingerprint' : 'Biometric lock off');
  }

  Future<void> _copyMyData() async {
    final auth = context.read<AuthState>();
    final prefs = context.read<AppPrefs>();
    final contacts = context.read<ContactsState>().contacts;

    List<dynamic> reports = [];
    try {
      final response = await ApiService.myComplaints();
      final data = response.statusCode == 200 ? tryDecodeMap(response.body) : null;
      final list = data?['complaints'];
      if (list is List) reports = list;
    } catch (_) {}

    final export = {
      'account': {
        'name': auth.userName,
        'email': auth.userEmail,
        'phone': auth.userPhone,
        'joined': auth.joinedAt?.toIso8601String(),
      },
      'stored_on_this_phone': prefs.personalExtras,
      'trusted_contacts': contacts.map((c) => c.toJson()).toList(),
      'reports': reports,
    };

    await Clipboard.setData(
      ClipboardData(text: const JsonEncoder.withIndent('  ').convert(export)),
    );
    _showToast('Your data was copied to the clipboard');
  }

  void _privacyPolicy() {
    showSSSheet<void>(
      context,
      builder: (ctx) {
        final c = ctx.ss;
        Widget point(String title, String body) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(fontWeight: FontWeight.w700, color: c.foreground)),
                  const SizedBox(height: 2),
                  Text(body,
                      style: TextStyle(fontSize: 12, height: 1.5, color: c.mutedForeground)),
                ],
              ),
            );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetTitle(title: 'What we collect'),
            point('Account', 'Your name, email, phone and a hashed password.'),
            point('Reports',
                'What you write, the location, and evidence files (stored on IPFS, with a '
                'fingerprint logged on the Sepolia blockchain).'),
            point('Public map',
                'Other people only see a report\'s approximate area (about 100 m) and time. '
                'Never your name or what you wrote.'),
            point('Trusted circle', 'Names and numbers you add, used only for SOS.'),
            point('On this phone only',
                'Birthday, gender, city and health details, notifications and settings.'),
          ],
        );
      },
    );
  }

  void _changePassword() {
    showSSSheet<void>(context, builder: (_) => const _ChangePasswordSheet());
  }

  void _deleteAccount() {
    showSSSheet<void>(context, builder: (_) => const _DeleteAccountSheet());
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final prefs = context.watch<AppPrefs>();

    final checks = [
      ('Password', true),
      ('Biometric', prefs.biometricLock),
      ('Anonymous', prefs.anonymousReports),
      ('Circle', context.watch<ContactsState>().contacts.isNotEmpty),
    ];
    final score = 40 + 20 * checks.skip(1).where((x) => x.$2).length;

    return SSPage(
      header: GlassHeader(
        title: 'Privacy & Security',
        titleSize: 17,
        onBack: () => Navigator.of(context).pop(),
        trailing: const TagPill(
          text: 'Secure',
          color: AppColors.success,
          icon: Icons.shield_outlined,
          fontSize: 10,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          if (_toast != null) ...[
            MessageBanner(text: _toast!, color: AppColors.success, icon: Icons.check_rounded),
            const SizedBox(height: 12),
          ],

          // Score
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: c.border),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.primary.withValues(alpha: 0.12),
                  c.isDark ? const Color(0xF21A0E32) : c.cardSolid,
                ],
              ),
            ),
            child: Row(
              children: [
                ScoreRing(
                  score: score,
                  size: 64,
                  stroke: 5,
                  color: AppColors.primary,
                  showOutOf: false,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Security Score',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700, color: c.foreground)),
                      const SizedBox(height: 2),
                      Text(
                        score == 100
                            ? 'Everything we can protect is on'
                            : 'Turn on the items below to reach 100',
                        style: TextStyle(fontSize: 11, color: c.mutedForeground),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final (label, done) in checks)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: done
                                    ? AppColors.success.withValues(alpha: 0.15)
                                    : c.input,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: done
                                      ? AppColors.success.withValues(alpha: 0.3)
                                      : c.border,
                                ),
                              ),
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                  color: done ? AppColors.success : c.mutedForeground,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          const SectionLabel('Account Security'),
          _Section(children: [
            _ArrowRow(
              icon: Icons.key_rounded,
              color: AppColors.primary,
              label: 'Change Password',
              description: 'At least $kMinPasswordLength characters',
              onTap: _changePassword,
            ),
            _ToggleRow(
              icon: Icons.fingerprint_rounded,
              color: AppColors.lavender,
              label: 'Biometric Lock',
              description: 'Face ID / fingerprint when opening the app',
              value: prefs.biometricLock,
              onChanged: (v) => _toggleBiometric(prefs, v),
            ),
            const _SoonRow(
              icon: Icons.smartphone_rounded,
              color: AppColors.warning,
              label: 'Two-Factor Authentication',
              description: 'A code by SMS when you sign in',
            ),
          ]),
          const SizedBox(height: 20),

          const SectionLabel('Location Privacy'),
          _Section(children: [
            _ToggleRow(
              icon: Icons.place_outlined,
              color: AppColors.success,
              label: 'Include Location When Sharing',
              description: 'Adds a map link when you share a trip by text',
              value: prefs.shareLocationWithCircle,
              onChanged: (v) {
                prefs.setShareLocation(v);
                _showToast('Location sharing updated');
              },
            ),
            _InfoRow(
              icon: Icons.sos_rounded,
              color: c.warning,
              label: 'Location During SOS',
              description: 'Always sent, so your circle can find you',
            ),
            const _SoonRow(
              icon: Icons.visibility_off_outlined,
              color: AppColors.primary,
              label: 'Stealth Mode',
              description: 'Hide that you are using SecureShe',
            ),
          ]),
          const SizedBox(height: 20),

          const SectionLabel('Data & Privacy'),
          _Section(children: [
            _ArrowRow(
              icon: Icons.visibility_outlined,
              color: AppColors.primary,
              label: 'Privacy Policy',
              description: 'What we collect and who can see it',
              onTap: _privacyPolicy,
            ),
            _ArrowRow(
              icon: Icons.download_rounded,
              color: AppColors.success,
              label: 'Copy My Data',
              description: 'Your account, contacts and reports as text',
              onTap: _copyMyData,
            ),
          ]),
          const SizedBox(height: 20),

          const SectionLabel('Danger Zone'),
          _Section(children: [
            _ToggleRow(
              icon: Icons.visibility_off_outlined,
              color: AppColors.destructive,
              label: 'Anonymous Reports',
              description: 'Turn "Report anonymously" on by default',
              value: prefs.anonymousReports,
              danger: true,
              onChanged: (v) {
                prefs.setAnonymousReports(v);
                _showToast(v ? 'New reports start anonymous' : 'Anonymous by default off');
              },
            ),
            _ArrowRow(
              icon: Icons.delete_outline_rounded,
              color: AppColors.destructive,
              label: 'Delete Account',
              description: 'Permanently remove your account and data',
              danger: true,
              onTap: _deleteAccount,
            ),
          ]),
          const SizedBox(height: 16),
          Center(
            child: Text(
              '🔒 Passwords are hashed · Evidence is fingerprinted on-chain · v1.0.0',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: c.mutedForeground),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SSCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1) Divider(height: 1, color: context.ss.border),
          ],
        ],
      ),
    );
  }
}

class _RowBase extends StatelessWidget {
  const _RowBase({
    required this.icon,
    required this.color,
    required this.label,
    required this.trailing,
    this.description,
    this.danger = false,
    this.onTap,
    this.dim = false,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String? description;
  final Widget trailing;
  final bool danger;
  final VoidCallback? onTap;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return InkWell(
      onTap: onTap,
      child: Opacity(
        opacity: dim ? 0.55 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              IconTile(icon: icon, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: danger ? AppColors.destructive : c.foreground,
                      ),
                    ),
                    if (description != null)
                      Text(description!,
                          style: TextStyle(fontSize: 11, color: c.mutedForeground)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              trailing,
            ],
          ),
        ),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.onChanged,
    this.description,
    this.danger = false,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return _RowBase(
      icon: icon,
      color: color,
      label: label,
      description: description,
      danger: danger,
      onTap: () => onChanged(!value),
      trailing: SSToggle(
        value: value,
        onChanged: onChanged,
        activeColor: danger ? AppColors.destructive : AppColors.primary,
      ),
    );
  }
}

class _ArrowRow extends StatelessWidget {
  const _ArrowRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
    this.description,
    this.danger = false,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String? description;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return _RowBase(
      icon: icon,
      color: color,
      label: label,
      description: description,
      danger: danger,
      onTap: onTap,
      trailing: Icon(Icons.chevron_right_rounded, size: 18, color: context.ss.mutedForeground),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.color,
    required this.label,
    this.description,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String? description;

  @override
  Widget build(BuildContext context) {
    return _RowBase(
      icon: icon,
      color: color,
      label: label,
      description: description,
      trailing: const TagPill(text: 'On', color: AppColors.success, fontSize: 10),
    );
  }
}

class _SoonRow extends StatelessWidget {
  const _SoonRow({
    required this.icon,
    required this.color,
    required this.label,
    this.description,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String? description;

  @override
  Widget build(BuildContext context) {
    return _RowBase(
      icon: icon,
      color: color,
      label: label,
      description: description,
      dim: true,
      trailing: TagPill(text: 'Soon', color: context.ss.mutedForeground, fontSize: 10),
    );
  }
}

class _ChangePasswordSheet extends StatefulWidget {
  const _ChangePasswordSheet();

  @override
  State<_ChangePasswordSheet> createState() => _ChangePasswordSheetState();
}

class _ChangePasswordSheetState extends State<_ChangePasswordSheet> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _saving = false;
  bool _done = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final c in [_current, _next, _confirm]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [_current, _next, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _valid =>
      _current.text.isNotEmpty &&
      _next.text.length >= kMinPasswordLength &&
      _next.text == _confirm.text;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await context.read<AuthState>().changePassword(_current.text, _next.text);
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _saving = false;
        _error = error;
      });
      return;
    }
    setState(() => _done = true);
    await Future.delayed(const Duration(milliseconds: 1400));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ss;

    if (_done) {
      return Column(
        children: [
          const SizedBox(height: 16),
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.success.withValues(alpha: 0.15),
              border: Border.all(color: AppColors.success.withValues(alpha: 0.3)),
            ),
            child: const Icon(Icons.check_rounded, size: 32, color: AppColors.success),
          ),
          const SizedBox(height: 12),
          Text('Password updated!',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.foreground)),
          const SizedBox(height: 24),
        ],
      );
    }

    final n = _next.text.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetTitle(title: 'Change Password'),
        SSTextField(controller: _current, label: 'Current Password', obscure: true, hint: '••••••••'),
        const SizedBox(height: 14),
        SSTextField(controller: _next, label: 'New Password', obscure: true, hint: '••••••••'),
        const SizedBox(height: 14),
        SSTextField(
          controller: _confirm,
          label: 'Confirm New Password',
          obscure: true,
          hint: '••••••••',
          borderColor: _confirm.text.isEmpty
              ? null
              : (_confirm.text == _next.text ? AppColors.success : AppColors.destructive),
        ),
        if (n > 0) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < 4; i++)
                Expanded(
                  child: Container(
                    height: 4,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      color: n >= (i + 1) * 2
                          ? (i < 2 ? AppColors.warning : AppColors.success)
                          : c.muted,
                    ),
                  ),
                ),
              Text(
                n < 4 ? 'Weak' : n < 8 ? 'Fair' : 'Strong',
                style: TextStyle(fontSize: 10, color: c.mutedForeground),
              ),
            ],
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 14),
          MessageBanner(text: _error!),
        ],
        const SizedBox(height: 20),
        GradientButton(
          label: 'Update Password',
          loading: _saving,
          onPressed: _valid ? _save : null,
        ),
      ],
    );
  }
}

class _DeleteAccountSheet extends StatefulWidget {
  const _DeleteAccountSheet();

  @override
  State<_DeleteAccountSheet> createState() => _DeleteAccountSheetState();
}

class _DeleteAccountSheetState extends State<_DeleteAccountSheet> {
  final _password = TextEditingController();
  bool _deleting = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (_password.text.isEmpty) {
      setState(() => _error = 'Enter your password to confirm.');
      return;
    }
    setState(() {
      _deleting = true;
      _error = null;
    });

    final trip = context.read<TripState>();
    final contacts = context.read<ContactsState>();
    final prefs = context.read<AppPrefs>();
    final shell = context.read<ShellController>();
    final error = await context.read<AuthState>().deleteAccount(_password.text);
    if (!mounted) return;

    if (error != null) {
      setState(() {
        _deleting = false;
        _error = error;
      });
      return;
    }

    if (trip.active) await trip.end();
    await contacts.clear();
    await prefs.clearAccountData();
    shell.go(ShellTab.home);
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.destructive.withValues(alpha: 0.12),
              border: Border.all(color: AppColors.destructive.withValues(alpha: 0.3)),
            ),
            child: const Icon(Icons.warning_amber_rounded, size: 28, color: AppColors.destructive),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Delete Account?',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.foreground),
        ),
        const SizedBox(height: 6),
        Text.rich(
          TextSpan(
            style: TextStyle(fontSize: 13, height: 1.5, color: c.mutedForeground),
            children: const [
              TextSpan(
                text: 'This permanently erases your profile, reports and trusted circle '
                    'from our database. Evidence fingerprints already written to the '
                    'blockchain, and files already pinned to IPFS, cannot be deleted. This ',
              ),
              TextSpan(
                text: 'cannot be undone.',
                style: TextStyle(color: AppColors.destructive, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        SSTextField(
          controller: _password,
          label: 'Password',
          obscure: true,
          hint: 'Enter your password to confirm',
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          MessageBanner(text: _error!),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: GradientButton(
                label: 'Cancel',
                variant: SSButtonVariant.outline,
                height: 50,
                fontSize: 14,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: GradientButton(
                label: 'Delete',
                variant: SSButtonVariant.danger,
                height: 50,
                fontSize: 14,
                loading: _deleting,
                onPressed: _delete,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
