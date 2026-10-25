import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../services/api_service.dart';
import '../services/location_service.dart';
import '../services/routing_service.dart';
import '../state/app_prefs.dart';
import '../state/shell_controller.dart';
import '../theme.dart';
import '../utils/json_utils.dart';
import '../widgets/ss_components.dart';
import '../widgets/ss_ui.dart';
import 'location_picker_screen.dart';

/// Report Incident: what happened → details → evidence → submit.
///
/// Submits to POST /api/complaints/submit with the incident type, the
/// anonymous choice, the location (GPS or a pin you place) and up to 5
/// evidence files, which go to IPFS with their hash logged on-chain.
class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key, this.standalone = false});

  /// True when opened on its own (not as the Report tab), so back closes it.
  final bool standalone;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _IncidentType {
  const _IncidentType(this.id, this.label, this.description, this.icon, this.color);

  final String id;
  final String label;
  final String description;
  final IconData icon;
  final Color color;
}

const _incidentTypes = [
  _IncidentType(
    'harassment',
    'Harassment',
    'Verbal, physical, or sexual harassment',
    Icons.error_outline_rounded,
    AppColors.destructive,
  ),
  _IncidentType(
    'unsafe-area',
    'Unsafe Area',
    'Poorly lit, isolated, or dangerous zone',
    Icons.place_outlined,
    AppColors.warning,
  ),
  _IncidentType(
    'suspicious',
    'Suspicious Activity',
    'Unusual behaviour or threat',
    Icons.visibility_outlined,
    AppColors.destructive,
  ),
];

class _ReportScreenState extends State<ReportScreen> {
  static const _maxFiles = 5;

  int _step = 1;
  String? _type;
  final _details = TextEditingController();
  late bool _anonymous = context.read<AppPrefs>().anonymousReports;

  /// "Where did this happen?" as typed. Sent as location_text; it never
  /// moves the map pin by itself (see _findOnMap).
  final _where = TextEditingController();
  bool _searchingPlace = false;

  /// The quick places from the design. They are labels only: OpenStreetMap
  /// has several candidates for each of them on campus, so none can be
  /// pinned to one verified coordinate and none carries one.
  static const _quickPlaces = ['VIT Gate', 'Hostel Block A', 'Library', 'Parking Lot'];

  LatLng? _location;
  String? _locationSource; // gps | manual
  String _locationName = 'Finding your location…';
  bool _locating = false;

  final List<EvidenceDraft> _attachments = [];
  bool _submitting = false;
  String? _error;

  ShellController? _shell;

  @override
  void initState() {
    super.initState();
    _useCurrentLocation();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shell = context.read<ShellController>();
    if (!identical(shell, _shell)) {
      _shell?.removeListener(_checkPendingEvidence);
      _shell = shell..addListener(_checkPendingEvidence);
      _checkPendingEvidence();
    }
  }

  @override
  void dispose() {
    _shell?.removeListener(_checkPendingEvidence);
    _details.dispose();
    _where.dispose();
    super.dispose();
  }

  /// Picks up audio/video recorded on Home ("report with this").
  void _checkPendingEvidence() {
    final shell = _shell;
    if (shell == null || shell.pendingEvidence == null) return;
    if (!widget.standalone && shell.tab != ShellTab.report) return;

    final evidence = shell.takePendingEvidence();
    if (evidence == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        if (_attachments.length < _maxFiles) _attachments.add(evidence);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Recording attached. Choose what happened to continue.')),
      );
    });
  }

  // ------------------------------------------------------------------
  // Location
  // ------------------------------------------------------------------

  Future<void> _useCurrentLocation() async {
    setState(() {
      _locating = true;
      _locationName = 'Finding your location…';
    });

    final problem = await LocationService.ensurePermission();
    if (problem != null) {
      if (!mounted) return;
      setState(() {
        _locating = false;
        _locationName = '$problem Pick the spot on the map instead.';
      });
      return;
    }

    final fix = await LocationService.quickFix();
    if (!mounted) return;

    if (fix == null) {
      setState(() {
        _locating = false;
        _locationName = 'Could not get your location. Pick it on the map.';
      });
      return;
    }

    final point = LatLng(fix.latitude, fix.longitude);
    setState(() {
      _location = point;
      _locationSource = 'gps';
      _locating = false;
      _locationName = 'Your current location';
    });
    _nameLocation(point);
  }

  Future<void> _pickOnMap() async {
    final picked = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(builder: (_) => LocationPickerScreen(initialCenter: _location)),
    );
    if (picked == null || !mounted) return;

    setState(() {
      _location = picked;
      _locationSource = 'manual';
      _locationName = 'Pinned location';
    });
    _nameLocation(picked);
  }

  /// Looks the typed place up and offers matches to pin. It only ever
  /// proposes: the pin (and your GPS fix) changes when you pick a result,
  /// never by itself.
  Future<void> _findOnMap() async {
    final query = _where.text.trim();
    if (query.isEmpty) return;

    setState(() => _searchingPlace = true);
    try {
      final results = await RoutingService().searchPlaces(query, near: _location);
      if (!mounted) return;
      if (results.isEmpty) {
        _snack('No matching place found. Pick it on the map instead.');
        return;
      }

      final picked = await showSSSheet<PlaceResult>(
        context,
        builder: (ctx) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetTitle(
              title: 'Place the pin here?',
              subtitle: 'Choose a match, or close this to keep your current pin.',
            ),
            for (final p in results.take(5))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SSCard(
                  onTap: () => Navigator.of(ctx).pop(p),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.name,
                          style: TextStyle(fontWeight: FontWeight.w600, color: ctx.ss.foreground)),
                      const SizedBox(height: 2),
                      Text(p.detail,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: ctx.ss.mutedForeground)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );

      if (picked == null || !mounted) return;
      setState(() {
        _location = picked.point;
        _locationSource = 'manual';
        _locationName = picked.name;
      });
    } catch (_) {
      if (mounted) _snack('Could not search for places right now.');
    } finally {
      if (mounted) setState(() => _searchingPlace = false);
    }
  }

  Future<void> _nameLocation(LatLng point) async {
    final name = await RoutingService().placeName(point);
    if (name != null && mounted && _location == point) {
      setState(() => _locationName = name);
    }
  }

  // ------------------------------------------------------------------
  // Evidence
  // ------------------------------------------------------------------

  bool _roomFor(int count) {
    if (_attachments.length + count <= _maxFiles) return true;
    _snack('You can attach up to $_maxFiles files per report.');
    return false;
  }

  Future<void> _takePhoto() async {
    if (!_roomFor(1)) return;
    try {
      final photo = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );
      if (photo == null) return;
      final bytes = await photo.readAsBytes();
      if (!mounted) return;
      setState(() => _attachments.add(
            EvidenceDraft(bytes: bytes, filename: photo.name, kind: EvidenceKind.photo),
          ));
    } catch (_) {
      _snack('Could not open the camera.');
    }
  }

  Future<void> _pickFromGallery() async {
    if (!_roomFor(1)) return;
    try {
      final remaining = _maxFiles - _attachments.length;
      final picker = ImagePicker();
      // The multi-picker needs a limit of at least 2; with one slot left,
      // use the single picker instead.
      final files = remaining >= 2
          ? await picker.pickMultipleMedia(limit: remaining, imageQuality: 85)
          : [
              if (await picker.pickMedia(imageQuality: 85) case final XFile f) f,
            ];
      if (files.isEmpty) return;

      final drafts = <EvidenceDraft>[];
      for (final f in files.take(_maxFiles - _attachments.length)) {
        final lower = f.name.toLowerCase();
        final isVideo = ['.mp4', '.mov', '.m4v', '.3gp', '.webm'].any(lower.endsWith);
        drafts.add(EvidenceDraft(
          bytes: await f.readAsBytes(),
          filename: f.name,
          kind: isVideo ? EvidenceKind.video : EvidenceKind.photo,
        ));
      }
      if (!mounted) return;
      setState(() => _attachments.addAll(drafts));
    } catch (_) {
      _snack('Could not open your gallery.');
    }
  }

  Future<void> _recordAudio() async {
    if (!_roomFor(1)) return;
    final clip = await showSSSheet<EvidenceDraft>(
      context,
      builder: (_) => const _AudioRecordSheet(),
    );
    if (clip != null && mounted) setState(() => _attachments.add(clip));
  }

  Future<void> _pasteText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _snack('Clipboard is empty. Copy something first.');
      return;
    }
    setState(() {
      _details.text = _details.text.trim().isEmpty
          ? text
          : '${_details.text.trim()}\n\n$text';
    });
    _snack('Pasted into the description.');
  }

  // ------------------------------------------------------------------
  // Submit
  // ------------------------------------------------------------------

  void _goToStep(int step) {
    if (step == 3 && _details.text.trim().isEmpty) {
      setState(() => _error = 'Please describe what happened.');
      return;
    }
    setState(() {
      _error = null;
      _step = step;
    });
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final response = await ApiService.submitComplaint(
        description: _details.text.trim(),
        category: _type,
        anonymous: _anonymous,
        lat: _location?.latitude,
        lng: _location?.longitude,
        locationSource: _locationSource,
        locationText: _where.text,
        files: [
          for (final a in _attachments) (bytes: a.bytes, filename: a.filename),
        ],
      );

      if (!mounted) return;

      // The body isn't always JSON (an HTML 500 page, a proxy message), so
      // decoding is its own step and never throws.
      final data = tryDecodeMap(response.body);
      final id = data?['complaint_id'];

      if (response.statusCode != 201 || id is! String) {
        setState(() {
          _submitting = false;
          _error = response.statusCode == 201
              ? 'Server error, try again.'
              : errorMessage(
                  response,
                  fallback: 'Submission failed (server returned ${response.statusCode}).',
                );
        });
        return;
      }

      await context.read<AppPrefs>().notify(
            type: 'info',
            title: 'Report submitted',
            message: 'Your report $id was received and will be reviewed.',
          );

      if (!mounted) return;
      _reset();
      Navigator.of(context).pushNamed('/report-status/$id');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Cannot reach the server. Check your connection and try again.';
      });
    }
  }

  void _reset() {
    setState(() {
      _step = 1;
      _type = null;
      _details.clear();
      _where.clear();
      _attachments.clear();
      _submitting = false;
      _error = null;
      _anonymous = context.read<AppPrefs>().anonymousReports;
    });
    _useCurrentLocation();
  }

  void _back() {
    if (_step > 1) {
      setState(() {
        _step--;
        _error = null;
      });
    } else if (widget.standalone) {
      Navigator.of(context).pop();
    } else {
      context.read<ShellController>().go(ShellTab.home);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------------
  // Build
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return SSPage(
      header: GlassHeader(
        title: 'Report Incident',
        subtitle: 'Step $_step of 3',
        onBack: _back,
        trailing: StepDots(step: _step, count: 3),
        bottom: ThinProgress(value: _step / 3),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween(begin: const Offset(0.06, 0), end: Offset.zero).animate(anim),
              child: child,
            ),
          ),
          child: switch (_step) {
            1 => _stepType(context),
            2 => _stepDetails(context),
            _ => _stepEvidence(context),
          },
        ),
      ),
    );
  }

  Widget _heading(String title, String subtitle) {
    final c = context.ss;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: c.foreground)),
        const SizedBox(height: 4),
        Text(subtitle, style: TextStyle(fontSize: 13, color: c.mutedForeground)),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _stepType(BuildContext context) {
    final c = context.ss;
    return Column(
      key: const ValueKey('type'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('What happened?', 'Select the type of incident you want to report'),
        if (_attachments.isNotEmpty) ...[
          MessageBanner(
            text: '${_attachments.length} recording${_attachments.length == 1 ? '' : 's'} '
                'attached and ready to send.',
            color: AppColors.success,
            icon: Icons.attach_file_rounded,
          ),
          const SizedBox(height: 12),
        ],
        for (final t in _incidentTypes) ...[
          _SelectableCard(
            selected: _type == t.id,
            onTap: () => setState(() => _type = t.id),
            child: Row(
              children: [
                IconTile(
                  icon: t.icon,
                  color: _type == t.id ? AppColors.primary : t.color,
                  size: 48,
                  radius: 16,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.label,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: c.foreground,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        t.description,
                        style: TextStyle(fontSize: 12, color: c.mutedForeground),
                      ),
                    ],
                  ),
                ),
                _Radio(selected: _type == t.id),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 8),
        GradientButton(
          label: 'Continue',
          onPressed: _type == null ? null : () => _goToStep(2),
        ),
      ],
    );
  }

  Widget _stepDetails(BuildContext context) {
    final c = context.ss;
    return Column(
      key: const ValueKey('details'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Add Details', 'More information helps keep others safe'),
        Text('Location',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.foreground)),
        const SizedBox(height: 8),
        SSCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          child: Row(
            children: [
              const Icon(Icons.place_outlined, size: 18, color: AppColors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _where,
                  maxLength: 200,
                  maxLines: 1,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => setState(() {}),
                  style: TextStyle(fontSize: 14, color: c.foreground),
                  decoration: InputDecoration(
                    hintText: 'Where did this happen?',
                    hintStyle: TextStyle(color: c.mutedForeground),
                    counterText: '',
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
              ),
              if (_where.text.isNotEmpty)
                IconButton(
                  tooltip: 'Clear',
                  icon: Icon(Icons.close_rounded, size: 18, color: c.mutedForeground),
                  onPressed: () => setState(_where.clear),
                )
              else
                IconButton(
                  tooltip: 'Use my current location',
                  icon: const Icon(Icons.my_location_rounded, size: 18, color: AppColors.primary),
                  onPressed: _useCurrentLocation,
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final place in _quickPlaces)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _Chip(
                    icon: Icons.place_outlined,
                    label: place,
                    onTap: () => setState(() => _where.text = place),
                  ),
                ),
            ],
          ),
        ),
        if (_where.text.trim().length >= 3) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: _Chip(
              icon: _searchingPlace ? Icons.hourglass_top_rounded : Icons.search_rounded,
              label: 'Find this place on the map',
              onTap: _searchingPlace ? () {} : _findOnMap,
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text('Map pin',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: c.mutedForeground)),
        const SizedBox(height: 8),
        SSCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              _locating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _location == null ? Icons.location_off_outlined : Icons.place_rounded,
                      size: 18,
                      color: AppColors.primary,
                    ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _locationName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, color: c.foreground),
                    ),
                    if (_location != null)
                      Text(
                        _locationSource == 'gps' ? 'From GPS' : 'Placed on the map',
                        style: TextStyle(fontSize: 11, color: c.mutedForeground),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            _Chip(
              icon: Icons.my_location_rounded,
              label: 'Current location',
              onTap: _useCurrentLocation,
            ),
            _Chip(
              icon: Icons.map_outlined,
              label: "Not here? Pick on map",
              onTap: _pickOnMap,
            ),
          ],
        ),
        const SizedBox(height: 20),
        SSTextField(
          controller: _details,
          label: 'Description',
          hint: 'Describe what happened...',
          maxLines: 5,
        ),
        const SizedBox(height: 20),
        SSCard(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Report Anonymously',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.foreground,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Your identity will be hidden',
                      style: TextStyle(fontSize: 12, color: c.mutedForeground),
                    ),
                  ],
                ),
              ),
              SSToggle(
                value: _anonymous,
                onChanged: (v) => setState(() => _anonymous = v),
              ),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          MessageBanner(text: _error!),
        ],
        const SizedBox(height: 20),
        GradientButton(label: 'Continue', onPressed: () => _goToStep(3)),
      ],
    );
  }

  Widget _stepEvidence(BuildContext context) {
    final c = context.ss;
    int countOf(EvidenceKind k) => _attachments.where((a) => a.kind == k).length;

    return Column(
      key: const ValueKey('evidence'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Upload Evidence', 'Add photos, audio, or videos (optional, up to $_maxFiles)'),
        _EvidenceOption(
          icon: Icons.photo_camera_outlined,
          color: AppColors.primary,
          title: 'Take Photo',
          subtitle: 'Open camera to capture evidence',
          count: countOf(EvidenceKind.photo),
          onTap: _takePhoto,
        ),
        const SizedBox(height: 12),
        _EvidenceOption(
          icon: Icons.mic_none_rounded,
          color: AppColors.warning,
          title: 'Record Audio',
          subtitle: 'Voice recording as evidence',
          count: countOf(EvidenceKind.audio),
          onTap: _recordAudio,
        ),
        const SizedBox(height: 12),
        _EvidenceOption(
          icon: Icons.photo_library_outlined,
          color: AppColors.lavender,
          title: 'Upload from Gallery',
          subtitle: 'Photos and videos',
          count: countOf(EvidenceKind.video) + countOf(EvidenceKind.file),
          onTap: _pickFromGallery,
        ),
        const SizedBox(height: 12),
        _EvidenceOption(
          icon: Icons.content_paste_rounded,
          color: AppColors.primary,
          title: 'Paste from Clipboard',
          subtitle: 'Adds copied text to your description',
          highlighted: true,
          onTap: _pasteText,
        ),
        const SizedBox(height: 20),
        if (_attachments.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.primary.withValues(alpha: 0.2), width: 2),
            ),
            child: Column(
              children: [
                Icon(Icons.attach_file_rounded, size: 20, color: c.mutedForeground),
                const SizedBox(height: 6),
                Text(
                  'No evidence yet. You can still submit without it.',
                  style: TextStyle(fontSize: 11, color: c.mutedForeground),
                ),
              ],
            ),
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  'Attachments (${_attachments.length}/$_maxFiles)',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: c.foreground,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => setState(_attachments.clear),
                child: Text(
                  'Clear all',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.destructive.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ],
          ),
          for (var i = 0; i < _attachments.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _AttachmentTile(
                item: _attachments[i],
                onRemove: () => setState(() => _attachments.removeAt(i)),
              ),
            ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 16),
          MessageBanner(text: _error!),
        ],
        const SizedBox(height: 20),
        GradientButton(
          label: 'Submit Report',
          variant: SSButtonVariant.success,
          loading: _submitting,
          onPressed: _submit,
        ),
        const SizedBox(height: 4),
        if (_attachments.isEmpty)
          TextButton(
            onPressed: _submitting ? null : _submit,
            child: Text(
              'Skip and Submit',
              style: TextStyle(fontSize: 14, color: c.mutedForeground),
            ),
          ),
      ],
    );
  }
}

class _SelectableCard extends StatelessWidget {
  const _SelectableCard({required this.selected, required this.onTap, required this.child});

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: selected ? AppColors.primary.withValues(alpha: 0.08) : c.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: selected ? AppColors.primary : c.border, width: 2),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    );
  }
}

class _Radio extends StatelessWidget {
  const _Radio({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? AppColors.primary : Colors.transparent,
        border: Border.all(color: selected ? AppColors.primary : context.ss.border, width: 2),
      ),
      child: selected
          ? Center(
              child: Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              ),
            )
          : null,
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return ActionChip(
      avatar: Icon(icon, size: 14, color: AppColors.primary),
      label: Text(label, style: TextStyle(fontSize: 11, color: c.mutedForeground)),
      backgroundColor: c.card,
      side: BorderSide(color: c.border),
      shape: const StadiumBorder(),
      onPressed: onTap,
    );
  }
}

class _EvidenceOption extends StatelessWidget {
  const _EvidenceOption({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.count = 0,
    this.highlighted = false,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final int count;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return SSCard(
      onTap: onTap,
      color: highlighted ? AppColors.primary.withValues(alpha: 0.05) : null,
      borderColor: highlighted ? AppColors.primary.withValues(alpha: 0.25) : null,
      child: Row(
        children: [
          IconTile(icon: icon, color: color, size: 44, radius: 16),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.foreground),
                ),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(fontSize: 12, color: c.mutedForeground)),
              ],
            ),
          ),
          if (count > 0)
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Text(
                '$count',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color),
              ),
            ),
        ],
      ),
    );
  }
}

class _AttachmentTile extends StatelessWidget {
  const _AttachmentTile({required this.item, required this.onRemove});

  final EvidenceDraft item;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;

    final (IconData icon, Color color, String kind) = switch (item.kind) {
      EvidenceKind.photo => (Icons.photo_camera_outlined, AppColors.primary, 'Photo'),
      EvidenceKind.audio => (
          Icons.mic_none_rounded,
          AppColors.warning,
          'Voice · ${formatClock(item.duration?.inSeconds ?? 0)}',
        ),
      EvidenceKind.video => (Icons.videocam_outlined, AppColors.violet, 'Video'),
      EvidenceKind.file => (Icons.description_outlined, AppColors.lavender, 'File'),
    };

    final sizeKb = item.bytes.lengthInBytes / 1024;
    final size = sizeKb > 1024
        ? '${(sizeKb / 1024).toStringAsFixed(1)} MB'
        : '${sizeKb.round()} KB';

    return SSCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: item.kind == EvidenceKind.photo
                ? Image.memory(
                    item.bytes,
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => IconTile(icon: icon, color: color, size: 56),
                  )
                : IconTile(icon: icon, color: color, size: 56),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.foreground),
                ),
                const SizedBox(height: 2),
                Text('$kind · $size', style: TextStyle(fontSize: 10, color: c.mutedForeground)),
              ],
            ),
          ),
          GestureDetector(
            onTap: onRemove,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: AppColors.destructive.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close_rounded, size: 14, color: AppColors.destructive),
            ),
          ),
        ],
      ),
    );
  }
}

/// Record a voice note: idle → recording → done (re-record or use).
class _AudioRecordSheet extends StatefulWidget {
  const _AudioRecordSheet();

  @override
  State<_AudioRecordSheet> createState() => _AudioRecordSheetState();
}

enum _RecPhase { idle, recording, done }

class _AudioRecordSheetState extends State<_AudioRecordSheet>
    with SingleTickerProviderStateMixin {
  final _recorder = AudioRecorder();
  _RecPhase _phase = _RecPhase.idle;
  int _seconds = 0;
  Timer? _timer;
  Uint8List? _bytes;
  String? _error;

  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void dispose() {
    _timer?.cancel();
    _wave.dispose();
    if (_phase == _RecPhase.recording) _recorder.stop();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      if (!await _recorder.hasPermission()) {
        setState(() => _error = 'Microphone access denied. Allow it in Settings.');
        return;
      }
      final dir = await getTemporaryDirectory();
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
      _wave.repeat(reverse: true);
      setState(() {
        _phase = _RecPhase.recording;
        _seconds = 0;
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _seconds++);
      });
    } catch (e) {
      setState(() => _error = 'Could not start recording.');
    }
  }

  Future<void> _stop() async {
    _timer?.cancel();
    _wave.stop();
    final path = await _recorder.stop();
    if (path == null) {
      setState(() => _phase = _RecPhase.idle);
      return;
    }
    final bytes = await XFile(path).readAsBytes();
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _phase = _RecPhase.done;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final recording = _phase == _RecPhase.recording;
    final done = _phase == _RecPhase.done;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          switch (_phase) {
            _RecPhase.idle => 'Record Audio',
            _RecPhase.recording => 'Recording…',
            _RecPhase.done => 'Recording ready',
          },
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.foreground),
        ),
        const SizedBox(height: 24),
        Center(
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: recording ? AppColors.primaryGradient : null,
              color: recording
                  ? null
                  : (done
                      ? AppColors.success.withValues(alpha: 0.15)
                      : AppColors.primary.withValues(alpha: 0.12)),
              border: Border.all(
                width: 2,
                color: recording
                    ? AppColors.primary
                    : (done
                        ? AppColors.success.withValues(alpha: 0.4)
                        : AppColors.primary.withValues(alpha: 0.3)),
              ),
            ),
            child: Icon(
              Icons.mic_none_rounded,
              size: 32,
              color: recording ? Colors.white : (done ? AppColors.success : AppColors.primary),
            ),
          ),
        ),
        if (recording) ...[
          const SizedBox(height: 16),
          SizedBox(
            height: 40,
            child: AnimatedBuilder(
              animation: _wave,
              builder: (_, _) => Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < 16; i++)
                    Container(
                      width: 5,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      height: 6 + 28 * ((i * 37 % 11) / 11) * (0.3 + 0.7 * _wave.value),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
        if (recording || done) ...[
          const SizedBox(height: 12),
          Text(
            formatClock(_seconds),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              letterSpacing: 2,
              color: c.foreground,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 16),
          MessageBanner(text: _error!, icon: Icons.mic_off_outlined),
        ],
        const SizedBox(height: 24),
        if (_phase == _RecPhase.idle) ...[
          GradientButton(label: 'Start Recording', onPressed: _start),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel', style: TextStyle(color: c.mutedForeground)),
          ),
        ] else if (recording)
          GradientButton(
            label: 'Stop Recording',
            icon: Icons.stop_rounded,
            variant: SSButtonVariant.danger,
            onPressed: _stop,
          )
        else
          Row(
            children: [
              Expanded(
                child: GradientButton(
                  label: 'Re-record',
                  variant: SSButtonVariant.outline,
                  fontSize: 14,
                  onPressed: () => setState(() {
                    _phase = _RecPhase.idle;
                    _seconds = 0;
                    _bytes = null;
                  }),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GradientButton(
                  label: 'Use Recording',
                  variant: SSButtonVariant.success,
                  fontSize: 14,
                  onPressed: () => Navigator.of(context).pop(
                    EvidenceDraft(
                      bytes: _bytes!,
                      filename: 'voice-note-${DateTime.now().millisecondsSinceEpoch}.m4a',
                      kind: EvidenceKind.audio,
                      duration: Duration(seconds: _seconds),
                    ),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
