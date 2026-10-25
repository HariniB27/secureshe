/// A report (complaint) as returned by /api/complaints/mine and /status.
class Report {
  Report({
    required this.id,
    required this.status,
    required this.description,
    required this.anonymous,
    required this.evidence,
    this.category,
    this.latitude,
    this.longitude,
    this.locationSource,
    this.createdAt,
    this.updatedAt,
    this.etherscanUrl,
    this.evidenceHash,
  });

  final String id;
  final String status;
  final String? category;
  final String description;
  final bool anonymous;
  final double? latitude;
  final double? longitude;
  final String? locationSource;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? etherscanUrl;
  final String? evidenceHash;

  /// IPFS gateway links, one per evidence file.
  final List<String> evidence;

  /// Must match STATUS_FLOW in app/routes/complaints.py.
  static const statusFlow = [
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

  String get statusLabel => switch (status.toUpperCase()) {
        'SUBMITTED' => 'Submitted',
        'UNDER_REVIEW' => 'Under Review',
        'INVESTIGATING' => 'Under Investigation',
        'ACTION_TAKEN' => 'Action Taken',
        'RESOLVED' => 'Resolved',
        _ => status,
      };

  String get categoryLabel => switch (category) {
        'harassment' => 'Harassment',
        'unsafe-area' => 'Unsafe Area',
        'suspicious' => 'Suspicious Activity',
        _ => 'Incident',
      };

  factory Report.fromJson(Map<String, dynamic> json) {
    DateTime? date(String key) {
      final v = json[key] as String?;
      return v == null ? null : DateTime.tryParse(v);
    }

    final evidence = <String>[
      for (final e in (json['evidence'] as List? ?? const []))
        if (e is Map && e['url'] is String) e['url'] as String,
    ];
    if (evidence.isEmpty && json['ipfs_url'] is String) {
      evidence.add(json['ipfs_url'] as String);
    }

    return Report(
      id: json['complaint_id'] as String,
      status: json['status'] as String? ?? 'SUBMITTED',
      category: json['category'] as String?,
      description: json['description'] as String? ?? '',
      anonymous: json['anonymous'] as bool? ?? false,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      locationSource: json['location_source'] as String?,
      createdAt: date('created_at'),
      updatedAt: date('updated_at'),
      etherscanUrl: json['etherscan_url'] as String?,
      evidenceHash: json['evidence_hash'] as String?,
      evidence: evidence,
    );
  }
}
