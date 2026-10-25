import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/contacts_state.dart';
import '../state/trip_state.dart';
import '../theme.dart';
import '../widgets/ss_components.dart';
import '../widgets/ss_ui.dart';

/// Trusted Circle: the people alerted on SOS (Sreshta's /api/sos/contacts),
/// plus the active trip when there is one.
class CircleScreen extends StatefulWidget {
  const CircleScreen({super.key});

  @override
  State<CircleScreen> createState() => _CircleScreenState();
}

class _CircleScreenState extends State<CircleScreen> {
  bool _editing = false;

  Future<void> _call(TrustedContact contact) async {
    if (!await launchUrl(Uri(scheme: 'tel', path: contact.phone)) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not call ${contact.name}.')),
      );
    }
  }

  Future<void> _remove(TrustedContact contact) async {
    final ok = await showSSSheet<bool>(
      context,
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitle(
            title: 'Remove ${contact.name}?',
            subtitle: 'They will no longer get your SOS alerts.',
          ),
          GradientButton(
            label: 'Remove',
            variant: SSButtonVariant.danger,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
          const SizedBox(height: 10),
          GradientButton(
            label: 'Cancel',
            variant: SSButtonVariant.outline,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final error = await context.read<ContactsState>().remove(contact);
    if (error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  void _add() {
    showSSSheet<void>(context, builder: (_) => const _AddContactSheet());
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final state = context.watch<ContactsState>();
    final contacts = state.contacts;
    final trip = context.watch<TripState>();

    return SSPage(
      header: GlassHeader(
        title: 'Trusted Circle',
        titleSize: 18,
        subtitle: '${contacts.length} of ${ContactsState.maxContacts} trusted contacts',
      ),
      body: RefreshIndicator(
        onRefresh: state.refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          children: [
            if (trip.active) ...[
              _TripCard(trip: trip),
              const SizedBox(height: 20),
            ],
            Row(
              children: [
                const Icon(Icons.how_to_reg_outlined, size: 16, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Emergency Contacts',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: c.foreground,
                    ),
                  ),
                ),
                if (contacts.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(() => _editing = !_editing),
                    child: Text(
                      _editing ? 'Done' : 'Edit',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (state.error != null) ...[
              MessageBanner(text: state.error!, color: AppColors.warning),
              const SizedBox(height: 10),
            ],
            if (state.loading && contacts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            for (final contact in contacts)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: SSCard(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      InitialsAvatar(initials: contact.initials, color: contact.color),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              contact.name,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: c.foreground,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              contact.phone,
                              style: TextStyle(fontSize: 11, color: c.mutedForeground),
                            ),
                          ],
                        ),
                      ),
                      if (_editing)
                        SSIconButton(
                          icon: Icons.delete_outline_rounded,
                          iconColor: AppColors.destructive,
                          background: AppColors.destructive.withValues(alpha: 0.1),
                          borderColor: Colors.transparent,
                          tooltip: 'Remove',
                          onTap: () => _remove(contact),
                        )
                      else
                        SSIconButton(
                          icon: Icons.phone_rounded,
                          iconColor: AppColors.primary,
                          background: AppColors.primary.withValues(alpha: 0.1),
                          borderColor: Colors.transparent,
                          tooltip: 'Call ${contact.name}',
                          onTap: () => _call(contact),
                        ),
                    ],
                  ),
                ),
              ),
            if (contacts.length < ContactsState.maxContacts) ...[
              const SizedBox(height: 4),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: _add,
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: c.border, width: 2),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const IconTile(icon: Icons.add_rounded, color: AppColors.primary),
                        const SizedBox(width: 10),
                        Text(
                          'Add Contact',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: c.foreground,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.destructive.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.destructive.withValues(alpha: 0.2)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.destructive),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        style: TextStyle(fontSize: 12, color: c.mutedForeground),
                        children: contacts.isEmpty
                            ? const [
                                TextSpan(
                                  text: 'Add at least one contact so an SOS can reach someone.',
                                ),
                              ]
                            : [
                                const TextSpan(text: 'During an SOS, all '),
                                TextSpan(
                                  text: '${contacts.length} '
                                      'contact${contacts.length == 1 ? '' : 's'}',
                                  style: TextStyle(
                                    color: c.foreground,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const TextSpan(
                                  text: ' will be immediately alerted with your live location.',
                                ),
                              ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TripCard extends StatelessWidget {
  const _TripCard({required this.trip});

  final TripState trip;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return SSCard(
      radius: 24,
      borderColor: AppColors.success.withValues(alpha: 0.3),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [AppColors.success.withValues(alpha: 0.1), c.card, c.card],
      ),
      onTap: () => Navigator.of(context).pushNamed('/trip'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Active Trip', style: TextStyle(fontSize: 11, color: c.mutedForeground)),
                    const SizedBox(height: 2),
                    Text(
                      'To ${trip.destinationName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: c.foreground,
                      ),
                    ),
                  ],
                ),
              ),
              TagPill(
                text: trip.offRoute ? 'Off Route' : 'On Track',
                color: trip.offRoute ? AppColors.warning : AppColors.success,
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: trip.fractionDone.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: c.muted,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.schedule_rounded, size: 14, color: c.mutedForeground),
              const SizedBox(width: 6),
              Text(
                'ETA: ${formatDuration(trip.eta)}',
                style: TextStyle(fontSize: 12, color: c.foreground),
              ),
              const Spacer(),
              const Text(
                'View Details →',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AddContactSheet extends StatefulWidget {
  const _AddContactSheet();

  @override
  State<_AddContactSheet> createState() => _AddContactSheetState();
}

class _AddContactSheetState extends State<_AddContactSheet> {
  final _name = TextEditingController();
  final _phone = TextEditingController(text: '+91 ');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    // The server needs international format: + then digits only.
    final phone = '+${_phone.text.replaceAll(RegExp(r'[^0-9]'), '')}';

    if (name.isEmpty) {
      setState(() => _error = 'Enter a name.');
      return;
    }
    if (phone.length < 8) {
      setState(() => _error = 'Enter the number with country code, e.g. +91 98765 43210.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final error = await context.read<ContactsState>().add(name, phone);
    if (!mounted) return;

    if (error == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetTitle(
          title: 'Add Trusted Contact',
          subtitle: 'They\'ll be texted your location during an SOS',
        ),
        SSTextField(
          controller: _name,
          label: 'Name',
          hint: 'e.g. Mom',
          icon: Icons.person_outline_rounded,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 16),
        SSTextField(
          controller: _phone,
          label: 'Phone (with country code)',
          hint: '+91 98765 43210',
          icon: Icons.phone_outlined,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _save(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          MessageBanner(text: _error!),
        ],
        const SizedBox(height: 20),
        GradientButton(label: 'Add Contact', loading: _saving, onPressed: _save),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: context.ss.mutedForeground)),
        ),
      ],
    );
  }
}
