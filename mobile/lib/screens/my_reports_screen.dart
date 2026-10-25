
import 'package:flutter/material.dart';

import '../models/report.dart';
import '../services/api_service.dart';
import '../utils/json_utils.dart';
import '../theme.dart';
import '../widgets/ss_ui.dart';

/// All of your reports, newest first. Opened from Profile and from the
/// password/biometric-locked archive.
class MyReportsScreen extends StatefulWidget {
  const MyReportsScreen({super.key});

  @override
  State<MyReportsScreen> createState() => _MyReportsScreenState();
}

class _MyReportsScreenState extends State<MyReportsScreen> {
  List<Report>? _reports;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final response = await ApiService.myComplaints();
      if (!mounted) return;
      if (response.statusCode != 200) {
        setState(() => _error = errorMessage(
              response,
              fallback: 'Could not load your reports (${response.statusCode}).',
            ));
        return;
      }
      final list = tryDecodeMap(response.body)?['complaints'];
      if (list is! List) {
        setState(() => _error = 'Server error, try again.');
        return;
      }
      setState(() {
        _error = null;
        _reports = list
            .map((e) => Report.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Cannot reach the server. Pull down to try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final reports = _reports;

    return SSPage(
      header: GlassHeader(
        title: 'My Reports',
        subtitle: reports == null ? null : '${reports.length} report${reports.length == 1 ? '' : 's'}',
        onBack: () => Navigator.of(context).pop(),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            if (_error != null) MessageBanner(text: _error!),
            if (reports == null && _error == null)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (reports != null && reports.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 64),
                child: Column(
                  children: [
                    Icon(Icons.description_outlined, size: 40, color: c.mutedForeground),
                    const SizedBox(height: 12),
                    Text('No reports yet',
                        style: TextStyle(fontWeight: FontWeight.w600, color: c.foreground)),
                    const SizedBox(height: 4),
                    Text('Reports you submit will appear here.',
                        style: TextStyle(fontSize: 12, color: c.mutedForeground)),
                  ],
                ),
              ),
            for (final r in reports ?? const <Report>[])
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: SSCard(
                  onTap: () async {
                    await Navigator.of(context).pushNamed('/report-status/${r.id}');
                    _load();
                  },
                  child: Row(
                    children: [
                      IconTile(
                        icon: switch (r.category) {
                          'unsafe-area' => Icons.place_outlined,
                          'suspicious' => Icons.visibility_outlined,
                          _ => Icons.error_outline_rounded,
                        },
                        color: r.category == 'unsafe-area'
                            ? AppColors.warning
                            : AppColors.destructive,
                        size: 40,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              r.categoryLabel,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: c.foreground,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${r.id} · ${formatDateTime(r.createdAt)}',
                              style: TextStyle(fontSize: 11, color: c.mutedForeground),
                            ),
                          ],
                        ),
                      ),
                      TagPill(
                        text: r.statusLabel,
                        fontSize: 10,
                        color: r.resolved
                            ? AppColors.success
                            : r.statusIndex == 0
                                ? AppColors.primary
                                : AppColors.warning,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
