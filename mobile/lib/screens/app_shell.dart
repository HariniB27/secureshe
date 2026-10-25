import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/shell_controller.dart';
import '../theme.dart';
import 'circle_screen.dart';
import 'home_screen.dart';
import 'map_screen.dart';
import 'profile_screen.dart';
import 'report_screen.dart';

/// The five main tabs with the design's glass bottom bar:
/// Home · Report · Map · Circle · Profile.
class AppShell extends StatefulWidget {
  const AppShell({super.key, this.initialTab});

  final ShellTab? initialTab;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  @override
  void initState() {
    super.initState();
    final start = widget.initialTab;
    if (start != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => context.read<ShellController>().go(start),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tab = context.watch<ShellController>().tab;

    return PopScope(
      // Back on another tab goes to Home first, instead of leaving the app.
      canPop: tab == ShellTab.home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.read<ShellController>().go(ShellTab.home);
      },
      child: Scaffold(
        backgroundColor: context.ss.screen,
        extendBody: true,
        body: IndexedStack(
          index: tab.index,
          children: const [
            HomeScreen(),
            ReportScreen(),
            MapScreen(),
            CircleScreen(),
            ProfileScreen(),
          ],
        ),
        bottomNavigationBar: const _BottomNav(),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav();

  static const _items = [
    (ShellTab.home, Icons.home_outlined, Icons.home_rounded, 'Home'),
    (ShellTab.report, Icons.description_outlined, Icons.description_rounded, 'Report'),
    (ShellTab.map, Icons.place_outlined, Icons.place_rounded, 'Map'),
    (ShellTab.circle, Icons.people_outline_rounded, Icons.people_rounded, 'Circle'),
    (ShellTab.profile, Icons.person_outline_rounded, Icons.person_rounded, 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final current = context.watch<ShellController>().tab;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: c.navBar,
            border: Border(top: BorderSide(color: c.border)),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 58,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  for (final (tab, icon, activeIcon, label) in _items)
                    _NavItem(
                      icon: icon,
                      activeIcon: activeIcon,
                      label: label,
                      active: tab == current,
                      onTap: () => context.read<ShellController>().go(tab),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.primary : context.ss.mutedForeground;

    return Semantics(
      selected: active,
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: 64,
          height: 52,
          decoration: BoxDecoration(
            color: active ? AppColors.primary.withValues(alpha: 0.1) : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedScale(
                scale: active ? 1.08 : 1,
                duration: const Duration(milliseconds: 200),
                child: Icon(active ? activeIcon : icon, size: 22, color: color),
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.2,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
