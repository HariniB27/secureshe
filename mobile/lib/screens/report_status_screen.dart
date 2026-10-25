import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/report.dart';
import '../services/api_service.dart';
import '../services/routing_service.dart';
import '../theme.dart';
import '../utils/json_utils.dart';
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
  bool _retrying = false;
  Timer? _poll;
  int _polls = 0;

  // The blockchain write finishes a little after the report is saved, so
  // while something is still waiting we re-check every few seconds (for a
  // few minutes at most) instead of making the person pull to refresh.
  static const _pollEvery = Duration(seconds: 6);
  static const _maxPolls = 50;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  bool _waitingOnChain(Report r) =>
      r.chainStatus == 'pending' || (r.chainConfirmed && r.statusOnChain != r.status);

  void _schedulePoll() {
    _poll?.cancel();
    final r = _report;
    if (r == null || !_waitingOnChain(r) || _polls >= _maxPolls) return;
    _poll = Timer(_pollEvery, () {
      _polls++;
      if (mounted) _load(silent: true);
    });
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final response = await ApiService.complaintStatus(widget.complaintId);
      if (!mounted) return;
      final data = response.statusCode == 200 ? tryDecodeMap(response.body) : null;
      if (data == null) {
        if (silent) return _schedulePoll();
        setState(() {
          _loading = false;
          _error = response.statusCode == 404
              ? 'Report not found.'
              : errorMessage(response,
                  fallback: 'Could not load this report (${response.statusCode}).');
        });
        return;
      }
      final report = Report.fromJson(data);
      setState(() {
        _report = report;
        _loading = false;
        _error = null;
      });
      _schedulePoll();

      if (_placeName == null && report.latitude != null && report.longitude != null) {
        final name = await RoutingService().placeName(
          LatLng(report.latitude!, report.longitude!),
        );
        if (mounted) setState(() => _placeName = name);
      }
    } catch (_) {
      if (!mounted) return;
      if (silent) return _schedulePoll();
      setState(() {
        _loading = false;
        _error = 'Cannot reach the server. Pull down to try again.';
      });
    }
  }

  Future<void> _retryChain() async {
    setState(() => _retrying = true);
    try {
      final response = await ApiService.retryChain(widget.complaintId);
      if (!mounted) return;
      // 202 = started again; 409 = it is already confirmed / being confirmed.
      if (response.statusCode != 202 && response.statusCode != 409) {
        _snack(errorMessage(response, fallback: 'Could not retry. Try again in a moment.'));
      }
      _polls = 0;
      await _load(silent: true);
    } catch (_) {
      if (mounted) _snack('Cannot reach the server. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _share(BuildContext buttonContext, Report r) async {
    final chain = r.etherscanUrl ??
        (r.chainFailed ? 'not recorded yet' : 'being confirmed');
    final text = [
      'SecureShe report ${r.id}',
      if (r.evidenceHash != null) 'Evidence hash (SHA-256): ${r.evidenceHash}',
      'Blockchain: $chain',
    ].join('\n');

    // iPads need to know where to anchor the share sheet.
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: text,
          subject: 'SecureShe report ${r.id}',
          sharePositionOrigin: origin,
        ),
      );
    } catch (_) {
      if (mounted) _snack('Could not open the share sheet.');
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
                r.locationText ??
                    (r.latitude == null
                        ? 'Not given'
                        : (_placeName ??
                            '${r.latitude!.toStringAsFixed(4)}, ${r.longitude!.toStringAsFixed(4)}')),
              ),
              if (r.locationText != null && r.latitude != null)
                _row(
                  'Map pin',
                  _placeName ??
                      '${r.latitude!.toStringAsFixed(4)}, ${r.longitude!.toStringAsFixed(4)}',
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
            for (var i = 0; i < r.statusFlow.length; i++)
              TimelineEntry(
                title: Report.stepTitle(r.statusFlow[i]),
                subtitle: Report.stepDescription(r.statusFlow[i]),
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
              child: Builder(
                builder: (buttonContext) => GradientButton(
                  label: 'Share',
                  icon: Icons.ios_share_rounded,
                  variant: SSButtonVariant.outline,
                  height: 50,
                  fontSize: 13,
                  onPressed: () => _share(buttonContext, r),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _chainCard(r),
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

  /// The honest state of the blockchain record: waiting, confirmed, or failed
  /// (with a Retry button when the server says a retry is possible).
  Widget _chainCard(Report r) {
    final c = context.ss;

    final (IconData icon, Color color, String title, String body) = switch (r.chainStatus) {
      'confirmed' => (
          Icons.verified_outlined,
          AppColors.success,
          'Confirmed on the blockchain',
          r.etherscanUrl == null
              ? 'The record is on the Sepolia test network. The transaction link '
                  "isn't available for this report."
              : 'A fingerprint of your evidence is permanently recorded on the '
                  'Sepolia test network.',
        ),
      'failed' => (
          Icons.error_outline_rounded,
          AppColors.destructive,
          'Blockchain logging failed',
          'Your report and evidence are saved, but the blockchain record could '
              'not be written. You can try again.',
        ),
      _ => (
          Icons.hourglass_top_rounded,
          AppColors.warning,
          'Pending confirmation',
          'Your report and evidence are saved. Waiting for the blockchain to '
              'confirm the record, which usually takes under a minute.',
        ),
    };

    final statusSyncing = r.chainConfirmed && r.statusOnChain != r.status;

    return SSCard(
      borderColor: color.withValues(alpha: 0.3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconTile(icon: icon, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700, color: c.foreground)),
                    const SizedBox(height: 4),
                    Text(body,
                        style: TextStyle(fontSize: 12, height: 1.5, color: c.mutedForeground)),
                    if (statusSyncing) ...[
                      const SizedBox(height: 4),
                      Text('Your latest status is being added to the record.',
                          style: TextStyle(fontSize: 11, color: c.mutedForeground)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (r.etherscanUrl != null) ...[
            const SizedBox(height: 12),
            GradientButton(
              label: 'View on Etherscan',
              icon: Icons.open_in_new_rounded,
              variant: SSButtonVariant.outline,
              height: 46,
              fontSize: 13,
              onPressed: () => _open(r.etherscanUrl!),
            ),
          ],
          if (r.chainFailed && r.chainCanRetry) ...[
            const SizedBox(height: 12),
            GradientButton(
              label: 'Retry',
              icon: Icons.refresh_rounded,
              height: 46,
              fontSize: 13,
              loading: _retrying,
              onPressed: _retrying ? null : _retryChain,
            ),
          ],
        ],
      ),
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
