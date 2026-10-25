import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';
import '../state/app_prefs.dart';
import '../state/auth_state.dart';
import '../state/contacts_state.dart';
import '../state/shell_controller.dart';
import '../state/trip_state.dart';
import '../theme.dart';
import '../widgets/ss_components.dart';
import '../widgets/ss_ui.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  int? _reportCount;
  ShellController? _shell;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shell = context.read<ShellController>();
    if (!identical(shell, _shell)) {
      _shell?.removeListener(_onShell);
      _shell = shell..addListener(_onShell);
      _onShell();
    }
  }

  @override
  void dispose() {
    _shell?.removeListener(_onShell);
    super.dispose();
  }

  // Refresh the report count whenever the Profile tab is opened.
  void _onShell() {
    if (_shell?.tab == ShellTab.profile) _loadReportCount();
  }

  Future<void> _loadReportCount() async {
    try {
      final response = await ApiService.myComplaints();
      if (response.statusCode != 200 || !mounted) return;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      setState(() => _reportCount = (data['complaints'] as List).length);
    } catch (_) {}
  }

  Future<void> _logout() async {
    final ok = await showSSSheet<bool>(
      context,
      builder: (ctx) {
        final c = ctx.ss;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.destructive.withValues(alpha: 0.12),
                  border: Border.all(color: AppColors.destructive.withValues(alpha: 0.25)),
                ),
                child: const Icon(Icons.logout_rounded, color: AppColors.destructive),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Log Out?',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.foreground),
            ),
            const SizedBox(height: 4),
            Text(
              "You'll need to sign in again to access SecureShe.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: c.mutedForeground),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: GradientButton(
                    label: 'Cancel',
                    variant: SSButtonVariant.outline,
                    height: 50,
                    fontSize: 14,
                    onPressed: () => Navigator.of(ctx).pop(false),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GradientButton(
                    label: 'Log Out',
                    variant: SSButtonVariant.danger,
                    height: 50,
                    fontSize: 14,
                    onPressed: () => Navigator.of(ctx).pop(true),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );

    if (ok != true || !mounted) return;

    final trip = context.read<TripState>();
    if (trip.active) await trip.end();
    if (!mounted) return;
    await context.read<ContactsState>().clear();
    if (!mounted) return;
    await context.read<AppPrefs>().clearAccountData();
    if (!mounted) return;
    await context.read<AuthState>().logout();
    if (!mounted) return;
    context.read<ShellController>().go(ShellTab.home);
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final auth = context.watch<AuthState>();
    final prefs = context.watch<AppPrefs>();
    final joined = auth.joinedAt;

    return SSPage(
      header: const GlassHeader(
        title: 'Profile',
        titleSize: 18,
        subtitle: 'Manage your account',
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        children: [
          // Profile card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: c.isDark
                    ? [
                        AppColors.primary.withValues(alpha: 0.15),
                        AppColors.primary.withValues(alpha: 0.05),
                        const Color(0xF21A1A24),
                      ]
                    : [
                        AppColors.primary.withValues(alpha: 0.12),
                        AppColors.primary.withValues(alpha: 0.06),
                        const Color(0xFFFFF5FC),
                      ],
                stops: const [0, 0.4, 1],
              ),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.of(context).pushNamed('/personal-info'),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          InitialsAvatar(
                            initials: auth.initials,
                            color: AppColors.primary,
                            size: 80,
                            solid: true,
                          ),
                          Positioned(
                            right: -4,
                            bottom: -4,
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: c.cardSolid,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: c.border),
                              ),
                              child: const Icon(Icons.edit_outlined,
                                  size: 14, color: AppColors.primary),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            auth.userName ?? 'Your name',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: c.foreground,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            auth.userEmail ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: c.mutedForeground),
                          ),
                          const SizedBox(height: 8),
                          TagPill(
                            text: joined == null
                                ? 'Signed in'
                                : 'Member since ${_monthYear(joined)}',
                            color: AppColors.success,
                            icon: Icons.shield_outlined,
                            fontSize: 10,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Divider(color: c.isDark ? c.border : AppColors.primary.withValues(alpha: 0.15)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _Stat(
                      value: '${prefs.safeTrips}',
                      label: 'Safe Trips',
                      color: AppColors.primary,
                    ),
                    _Stat(
                      value: _reportCount == null ? '–' : '$_reportCount',
                      label: 'Reports',
                      color: c.success,
                      onTap: () => Navigator.of(context).pushNamed('/my-reports'),
                    ),
                    _Stat(
                      value: '${prefs.sosAlerts}',
                      label: 'SOS Alerts',
                      color: c.warning,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          const SectionLabel('Account'),
          _MenuGroup(
            children: [
              _MenuRow(
                icon: Icons.person_outline_rounded,
                label: 'Personal Information',
                onTap: () => Navigator.of(context).pushNamed('/personal-info'),
              ),
              _MenuRow(
                icon: Icons.shield_outlined,
                label: 'Privacy & Security',
                onTap: () => Navigator.of(context).pushNamed('/privacy-security'),
              ),
              _MenuRow(
                icon: Icons.lock_outline_rounded,
                label: 'Evidence Archive',
                onTap: () => Navigator.of(context).pushNamed('/archive'),
              ),
              _MenuRow(
                icon: Icons.notifications_none_rounded,
                label: 'Notifications',
                trailing: SSToggle(
                  value: prefs.notificationsOn,
                  onChanged: prefs.setNotifications,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          const SectionLabel('Support'),
          _MenuGroup(
            children: [
              _MenuRow(
                icon: Icons.help_outline_rounded,
                label: 'Help Center',
                onTap: () => launchUrl(
                  Uri(scheme: 'mailto', path: 'support@secureshe.com', query: 'subject=Help'),
                ),
              ),
              _MenuRow(
                icon: Icons.lock_outline_rounded,
                label: 'Terms & Privacy',
                onTap: () => Navigator.of(context).pushNamed('/privacy-security'),
              ),
              _MenuRow(
                icon: Icons.star_border_rounded,
                label: 'Rate SecureShe',
                badge: 'New',
                onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Thanks! Ratings open once the app is in the stores.')),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'SecureShe v1.0.0 · Keeping you safe, always',
              style: TextStyle(fontSize: 11, color: c.mutedForeground),
            ),
          ),
          const SizedBox(height: 16),

          const SectionLabel('Appearance'),
          _MenuGroup(
            children: [
              _MenuRow(
                iconWidget: IconTile(
                  icon: prefs.darkMode ? Icons.nightlight_round : Icons.wb_sunny_outlined,
                  color: prefs.darkMode ? const Color(0xFF9B7BE8) : const Color(0xFFE09900),
                ),
                label: prefs.darkMode ? 'Night Mode' : 'Day Mode',
                sublabel: prefs.darkMode ? 'Switch to bright display' : 'Switch to dark display',
                onTap: prefs.toggleTheme,
                trailing: SSToggle(
                  value: !prefs.darkMode,
                  activeColor: const Color(0xFFFFBE0B),
                  onChanged: (_) => prefs.toggleTheme(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          Material(
            color: AppColors.destructive.withValues(alpha: 0.08),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: AppColors.destructive.withValues(alpha: 0.3)),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _logout,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.logout_rounded, size: 16, color: AppColors.destructive),
                    SizedBox(width: 8),
                    Text(
                      'Log Out',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.destructive,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _monthYear(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.year}';
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.color, this.onTap});

  final String value;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color),
            ),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 10, color: context.ss.mutedForeground)),
          ],
        ),
      ),
    );
  }
}

class _MenuGroup extends StatelessWidget {
  const _MenuGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return SSCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1) Divider(height: 1, color: c.border),
          ],
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.label,
    this.icon,
    this.iconWidget,
    this.sublabel,
    this.onTap,
    this.trailing,
    this.badge,
  });

  final String label;
  final IconData? icon;
  final Widget? iconWidget;
  final String? sublabel;
  final VoidCallback? onTap;
  final Widget? trailing;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            iconWidget ?? IconTile(icon: icon!, color: AppColors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.foreground),
                  ),
                  if (sublabel != null)
                    Text(sublabel!, style: TextStyle(fontSize: 11, color: c.mutedForeground)),
                ],
              ),
            ),
            if (badge != null) ...[
              TagPill(text: badge!, color: c.warning, fontSize: 10),
              const SizedBox(width: 8),
            ],
            trailing ?? Icon(Icons.chevron_right_rounded, size: 18, color: c.mutedForeground),
          ],
        ),
      ),
    );
  }
}
