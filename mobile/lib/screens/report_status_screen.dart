import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/report.dart';
import '../services/api_service.dart';
import '../services/routing_service.dart';
import '../theme.dart';
import '../widgets/ss_components.dart';
import '../widgets/ss_ui.dart';

/// One report's progress, details, evidence links and on-chain proof.
class ReportStatusScreen extends StatefulWidget {
  const ReportStatusScreen({super.key, required this.complaintId});

  final String complaintId;

  @override
  State<ReportStatusScreen> createState() => _ReportStatusScreenState();
}

class _ReportStatusScreenState extends State<ReportStatusScreen> {
  Report? _report;
  String? _placeName;
  bool _loading = true;
  String? _error;

  static const _steps = [
    ('Report Submitted', 'Your report has been received'),
    ('Under Review', 'Our team is reviewing your report'),
    ('Investigation Started', 'Active investigation underway'),
    ('Action Taken', 'Appropriate action is being taken'),
    ('Resolved', 'Issue has been resolved'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await ApiService.complaintStatus(widget.complaintId);
      if (!mounted) return;
      if (response.statusCode != 200) {
        setState(() {
          _loading = false;
          _error = response.statusCode == 404
              ? 'Report not found.'
              : 'Could not load this report (${response.statusCode}).';
        });
        return;
      }
      final report = Report.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
      setState(() {
        _report = report;
        _loading = false;
      });

      if (report.latitude != null && report.longitude != null) {
        final name = await RoutingService().placeName(
          LatLng(report.latitude!, report.longitude!),
        );
        if (mounted) setState(() => _placeName = name);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Cannot reach the server. Pull down to try again.';
      });
    }
  }

  void _copyId() {
    Clipboard.setData(ClipboardData(text: widget.complaintId));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Report ID copied')),
    );
  }

  Future<void> _open(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  void _back() {
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
    } else {
      nav.pushReplacementNamed('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SSPage(
      header: GlassHeader(
        title: 'Report Status',
        subtitle: widget.complaintId,
        onBack: _back,
        trailing: SSIconButton(
          icon: Icons.copy_rounded,
          tooltip: 'Copy report ID',
          onTap: _copyId,
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? ListView(
                    padding: const EdgeInsets.all(20),
                    children: [MessageBanner(text: _error!)],
                  )
                : _content(context, _report!),
      ),
    );
  }

  Widget _content(BuildContext context, Report r) {
    final c = context.ss;
    final current = r.statusIndex;
    final justSubmitted = current == 0 &&
        r.createdAt != null &&
        DateTime.now().difference(r.createdAt!.toLocal()).inMinutes < 10;

    final (Color statusColor, String statusPill) = r.resolved
        ? (AppColors.success, 'Resolved')
        : current == 0
            ? (AppColors.primary, 'Received')
            : (AppColors.warning, 'In Progress');

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      children: [
        if (justSubmitted) ...[
          SSCard(
            radius: 24,
            padding: const EdgeInsets.all(20),
            borderColor: AppColors.success.withValues(alpha: 0.3),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.success.withValues(alpha: 0.15), c.card],
            ),
            child: Column(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: AppColors.success.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check_circle_outline_rounded,
                      size: 28, color: AppColors.success),
                ),
                const SizedBox(height: 12),
                Text(
                  'Report Submitted!',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.foreground),
                ),
                const SizedBox(height: 4),
                Text(
                  r.evidence.isEmpty
                      ? 'Your report is saved and will be reviewed.'
                      : 'Your report and ${r.evidence.length} evidence '
                          'file${r.evidence.length == 1 ? '' : 's'} are saved.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: c.mutedForeground),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.success,
                    shape: const StadiumBorder(),
                  ),
                  onPressed: () =>
                      Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false),
                  child: const Text('Go to Home'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],

        // Status
        SSCard(
          radius: 24,
          padding: const EdgeInsets.all(20),
          borderColor: AppColors.primary.withValues(alpha: 0.25),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.primary.withValues(alpha: 0.12), c.card],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Current Status',
                            style: TextStyle(fontSize: 11, color: c.mutedForeground)),
                        const SizedBox(height: 2),
                        Text(
                          r.statusLabel,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: c.foreground,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TagPill(text: statusPill, color: statusColor),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                r.resolved
                    ? 'This report has been resolved. Thank you for helping keep others safe.'
                    : 'Your report is with the safety team. Pull down to check for updates.',
                style: TextStyle(fontSize: 12, height: 1.6, color: c.mutedForeground),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Details
        SSCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Report Details',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c.foreground)),
              const SizedBox(height: 12),
              _row('Type', r.categoryLabel),
              _row(
                'Location',
                r.latitude == null
                    ? 'Not given'
                    : (_placeName ??
                        '${r.latitude!.toStringAsFixed(4)}, ${r.longitude!.toStringAsFixed(4)}'),
              ),
              _row('Submitted', formatDateTime(r.createdAt)),
              _row('Anonymous', r.anonymous ? 'Yes' : 'No'),
              _row('Evidence', r.evidence.isEmpty ? 'None' : '${r.evidence.length} file(s)'),
              if (r.description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  r.description,
                  style: TextStyle(fontSize: 12, height: 1.5, color: c.mutedForeground),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),

        Text('Progress Timeline',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.foreground)),
        const SizedBox(height: 16),
        TimelineList(
          entries: [
            for (var i = 0; i < _steps.length; i++)
              TimelineEntry(
                title: _steps[i].$1,
                subtitle: _steps[i].$2,
                trailing: i == 0
                    ? _short(r.createdAt)
                    : (i == current && i > 0 ? _short(r.updatedAt) : (i > current ? 'Pending' : null)),
                state: r.resolved || i < current
                    ? TimelineState.done
                    : i == current
                        ? TimelineState.current
                        : TimelineState.pending,
              ),
          ],
        ),
        const SizedBox(height: 24),

        Row(
          children: [
            Expanded(
              child: GradientButton(
                label: r.evidence.isEmpty ? 'No Evidence' : 'View Evidence',
                icon: Icons.download_rounded,
                variant: SSButtonVariant.outline,
                height: 50,
                fontSize: 13,
                onPressed: r.evidence.isEmpty ? null : () => _showEvidence(r),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: GradientButton(
                label: 'Blockchain',
                icon: Icons.open_in_new_rounded,
                variant: SSButtonVariant.outline,
                height: 50,
                fontSize: 13,
                onPressed: r.etherscanUrl == null ? null : () => _open(r.etherscanUrl!),
              ),
            ),
          ],
        ),
        if (r.etherscanUrl == null) ...[
          const SizedBox(height: 8),
          Text(
            'Blockchain logging did not complete for this report. The report '
            'and evidence are still saved.',
            style: TextStyle(fontSize: 11, color: c.mutedForeground),
          ),
        ],
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
          ),
          child: Text.rich(
            TextSpan(
              style: TextStyle(fontSize: 12, height: 1.6, color: c.mutedForeground),
              children: const [
                TextSpan(text: 'Need help? Contact our support at '),
                TextSpan(
                  text: 'support@secureshe.com',
                  style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String? _short(DateTime? t) {
    if (t == null) return null;
    final s = formatDateTime(t);
    final parts = s.split(' · ');
    final date = parts.first.split(',').first; // "Mar 28"
    return parts.length > 1 ? '$date, ${parts[1]}' : date;
  }

  Widget _row(String label, String value) {
    final c = context.ss;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: c.mutedForeground)),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.foreground),
            ),
          ),
        ],
      ),
    );
  }

  void _showEvidence(Report r) {
    showSSSheet<void>(
      context,
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetTitle(
            title: 'Evidence',
            subtitle: 'Stored on IPFS. Opens in your browser.',
          ),
          for (var i = 0; i < r.evidence.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SSCard(
                onTap: () => _open(r.evidence[i]),
                child: Row(
                  children: [
                    const IconTile(icon: Icons.attach_file_rounded, color: AppColors.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Evidence file ${i + 1}',
                        style: TextStyle(fontWeight: FontWeight.w600, color: ctx.ss.foreground),
                      ),
                    ),
                    Icon(Icons.open_in_new_rounded, size: 16, color: ctx.ss.mutedForeground),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
