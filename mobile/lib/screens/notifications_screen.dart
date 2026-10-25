import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_prefs.dart';
import '../theme.dart';
import '../widgets/ss_ui.dart';

/// Things that happened on this phone: SOS sent, new reports near you,
/// leaving your route, trips completed, reports submitted, flags added.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final prefs = context.watch<AppPrefs>();
    final items = prefs.notifications;
    final unread = prefs.unreadCount;

    return SSPage(
      header: GlassHeader(
        title: 'Notifications',
        subtitle: unread > 0 ? '$unread unread' : null,
        onBack: () => Navigator.of(context).pop(),
        trailing: unread > 0
            ? TextButton(
                onPressed: prefs.markAllRead,
                child: const Text(
                  'Mark all read',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              )
            : null,
      ),
      body: items.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: c.card,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: c.border),
                    ),
                    child: Icon(Icons.notifications_none_rounded,
                        size: 28, color: c.mutedForeground),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'All caught up!',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.foreground),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    prefs.notificationsOn
                        ? 'No new notifications'
                        : 'Notifications are off in Profile',
                    style: TextStyle(fontSize: 12, color: c.mutedForeground),
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final n = items[i];
                final (Color color, IconData icon) = switch (n.type) {
                  'danger' => (AppColors.destructive, Icons.error_outline_rounded),
                  'warning' => (AppColors.warning, Icons.warning_amber_rounded),
                  'success' => (AppColors.success, Icons.shield_outlined),
                  _ => (AppColors.primary, Icons.notifications_none_rounded),
                };

                return Dismissible(
                  key: ValueKey(n.id),
                  direction: DismissDirection.endToStart,
                  onDismissed: (_) => prefs.dismiss(n.id),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: color.withValues(alpha: 0.25)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        IconTile(icon: icon, color: color),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      n.title,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: n.read ? FontWeight.w500 : FontWeight.w700,
                                        color: c.foreground,
                                      ),
                                    ),
                                  ),
                                  if (!n.read)
                                    Container(
                                      width: 8,
                                      height: 8,
                                      margin: const EdgeInsets.only(left: 8),
                                      decoration:
                                          BoxDecoration(color: color, shape: BoxShape.circle),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                n.message,
                                style: TextStyle(
                                  fontSize: 11,
                                  height: 1.5,
                                  color: c.mutedForeground,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                timeAgo(n.time),
                                style: TextStyle(fontSize: 10, color: c.mutedForeground),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        GestureDetector(
                          onTap: () => prefs.dismiss(n.id),
                          child: Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: c.input,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(Icons.close_rounded, size: 12, color: c.mutedForeground),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
