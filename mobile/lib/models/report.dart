/// A report (complaint) as returned by /api/complaints/mine and /status.
class Report {
  Report({
    required this.id,
    required this.status,
    required this.description,
    required this.anonymous,
    required this.evidence,
    this.statusFlow = defaultStatusFlow,
    this.chainStatus = 'pending',
    this.chainCanRetry = false,
    this.statusOnChain,
    this.category,
    this.latitude,
    this.longitude,
    this.locationSource,
    this.locationText,
    this.createdAt,
    this.updatedAt,
    this.etherscanUrl,
    this.evidenceHash,
  });

  final String id;
  final String status;

  /// The steps a report moves through, in order. The server sends this with
  /// every report (`status_flow`) so the timeline always matches it;
  /// [defaultStatusFlow] is only a fallback for an older server.
  final List<String> statusFlow;

  /// State of the blockchain log: `pending`, `confirmed` or `failed`.
  final String chainStatus;
  final bool chainCanRetry;

  /// The status value last confirmed on the blockchain, if any.
  final String? statusOnChain;

  final String? category;
  final String description;
  final bool anonymous;
  final double? latitude;
  final double? longitude;
  final String? locationSource;

  /// What the reporter typed for "Where did this happen?".
  final String? locationText;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? etherscanUrl;
  final String? evidenceHash;

  /// IPFS gateway links, one per evidence file.
  final List<String> evidence;

  static const defaultStatusFlow = [
    'SUBMITTED',
    'UNDER_REVIEW',
    'INVESTIGATING',
    'ACTION_TAKEN',
    'RESOLVED',
  ];

  int get statusIndex {
    final i = statusFlow.indexOf(status.toUpperCase());
    return i < 0 ? 0 : i;
  }

  bool get resolved => status.toUpperCase() == 'RESOLVED';

  bool get chainConfirmed => chainStatus == 'confirmed';
  bool get chainFailed => chainStatus == 'failed';

  /// Heading and one-line description for a status code on the timeline.
  static String stepTitle(String code) => switch (code.toUpperCase()) {
        'SUBMITTED' => 'Report Submitted',
        'UNDER_REVIEW' => 'Under Review',
        'INVESTIGATING' => 'Investigation Started',
        'ACTION_TAKEN' => 'Action Taken',
        'RESOLVED' => 'Resolved',
        _ => _prettify(code),
      };

  static String stepDescription(String code) => switch (code.toUpperCase()) {
        'SUBMITTED' => 'Your report has been received',
        'UNDER_REVIEW' => 'Our team is reviewing your report',
        'INVESTIGATING' => 'Active investigation underway',
        'ACTION_TAKEN' => 'Appropriate action is being taken',
        'RESOLVED' => 'Issue has been resolved',
        _ => '',
      };

  static String _prettify(String code) => code
      .toLowerCase()
      .split('_')
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1))
      .join(' ');

  String get statusLabel => switch (status.toUpperCase()) {
        'SUBMITTED' => 'Submitted',
        'UNDER_REVIEW' => 'Under Review',
        'INVESTIGATING' => 'Under Investigation',
        'ACTION_TAKEN' => 'Action Taken',
        'RESOLVED' => 'Resolved',
        _ => _prettify(status),
      };

  String get categoryLabel => switch (category) {
        'harassment' => 'Harassment',
        'unsafe-area' => 'Unsafe Area',
        'suspicious' => 'Suspicious Activity',
        _ => 'Incident',
      };

  factory Report.fromJson(Map<String, dynamic> json) {
    DateTime? date(String key) {
      final v = json[key];
      return v is String ? DateTime.tryParse(v) : null;
    }

    final evidence = <String>[
      for (final e in (json['evidence'] as List? ?? const []))
        if (e is Map && e['url'] is String) e['url'] as String,
    ];
    if (evidence.isEmpty && json['ipfs_url'] is String) {
      evidence.add(json['ipfs_url'] as String);
    }

    final flow = [
      for (final s in (json['status_flow'] as List? ?? const []))
        if (s is String) s.toUpperCase(),
    ];

    return Report(
      id: json['complaint_id'] as String,
      status: json['status'] as String? ?? 'SUBMITTED',
      statusFlow: flow.isEmpty ? defaultStatusFlow : flow,
      chainStatus: json['chain_status'] as String? ??
          (json['etherscan_url'] != null ? 'confirmed' : 'pending'),
      chainCanRetry: json['chain_can_retry'] as bool? ?? false,
      statusOnChain: json['status_on_chain'] as String?,
      category: json['category'] as String?,
      description: json['description'] as String? ?? '',
      anonymous: json['anonymous'] as bool? ?? false,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      locationSource: json['location_source'] as String?,
      locationText: json['location_text'] as String?,
      createdAt: date('created_at'),
      updatedAt: date('updated_at'),
      etherscanUrl: json['etherscan_url'] as String?,
      evidenceHash: json['evidence_hash'] as String?,
      evidence: evidence,
    );
  }
}
