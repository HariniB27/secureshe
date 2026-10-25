import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/location_service.dart';
import '../services/routing_service.dart';
import '../services/safety_api_service.dart';
import '../state/app_prefs.dart';
import '../state/contacts_state.dart';
import '../state/shell_controller.dart';
import '../state/trip_state.dart';
import '../theme.dart';
import '../widgets/ss_components.dart';
import '../widgets/ss_ui.dart';

/// Home: SOS hold button, safety score where you are, quick actions
/// (safe trip, call your first trusted contact, audio and video capture)
/// and the latest reports near you.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _NearbyItem {
  _NearbyItem({
    required this.kind,
    required this.title,
    required this.time,
    required this.metres,
    this.icon,
  });

  final AlertKind kind;
  final String title;
  final DateTime? time;
  final double metres;
  final IconData? icon;
}

class _HomeScreenState extends State<HomeScreen> {
  final _api = SafetyApiService();
  final _routing = RoutingService();
  final _distance = const Distance();
  final _recorder = AudioRecorder();

  LatLng? _here;
  String _placeName = 'Finding your location…';
  SafetyScore? _score;
  bool _loadingScore = true;
  List<_NearbyItem> _nearby = [];
  bool _loadingNearby = true;
  Timer? _refreshTimer;

  // Audio capture
  bool _recordingAudio = false;
  int _audioSeconds = 0;
  Timer? _audioTimer;
  EvidenceDraft? _audioClip;

  // Video capture (uses the phone's camera app)
  EvidenceDraft? _videoClip;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(const Duration(minutes: 1), (_) => _loadNearby());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _audioTimer?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final problem = await LocationService.ensurePermission();
    if (problem != null) {
      if (!mounted) return;
      setState(() {
        _placeName = problem;
        _loadingScore = false;
        _loadingNearby = false;
      });
      return;
    }

    final fix = await LocationService.quickFix();
    if (!mounted) return;

    if (fix == null) {
      setState(() {
        _placeName = 'Location unavailable';
        _loadingScore = false;
        _loadingNearby = false;
      });
      return;
    }

    _here = LatLng(fix.latitude, fix.longitude);
    await Future.wait([_loadScore(), _loadPlaceName(), _loadNearby()]);
  }

  Future<void> _loadScore() async {
    final here = _here;
    if (here == null) return;
    try {
      final score = await _api.fetchScore(here);
      if (mounted) setState(() => _score = score);
    } catch (_) {
      // Leave the ring empty; the card still shows the location.
    } finally {
      if (mounted) setState(() => _loadingScore = false);
    }
  }

  Future<void> _loadPlaceName() async {
    final here = _here;
    if (here == null) return;
    final name = await _routing.placeName(here);
    if (mounted) setState(() => _placeName = name ?? 'Your current location');
  }

  Future<void> _loadNearby() async {
    final here = _here;
    if (here == null) return;

    try {
      final results = await Future.wait([
        _api.fetchLiveReports(hours: 24 * 7),
        _api.fetchFlags(hours: 24 * 7),
      ]);
      final reports = (results[0] as LiveReportsPage).reports;
      final flags = results[1] as List<CommunityFlag>;

      final items = <_NearbyItem>[
        for (final r in reports)
          _NearbyItem(
            kind: AlertKind.danger,
            title: 'Incident reported',
            time: r.reportedAt,
            metres: _distance.distance(here, r.point),
          ),
        for (final f in flags)
          if (!f.isSafe)
            _NearbyItem(
              kind: f.kind == 'dark-street' ? AlertKind.warning : AlertKind.danger,
              title: f.label,
              time: f.reportedAt,
              metres: _distance.distance(here, f.point),
              icon: switch (f.kind) {
                'dark-street' => Icons.nightlight_round,
                'suspicious' => Icons.visibility_outlined,
                _ => null,
              },
            ),
      ]..removeWhere((i) => i.metres > 3000);

      items.sort((a, b) {
        final ta = a.time ?? DateTime(2000);
        final tb = b.time ?? DateTime(2000);
        return tb.compareTo(ta);
      });

      if (mounted) setState(() => _nearby = items.take(3).toList());
    } catch (_) {
      // Keep the previous list.
    } finally {
      if (mounted) setState(() => _loadingNearby = false);
    }
  }

  Future<void> _refresh() async {
    setState(() => _loadingScore = true);
    await _load();
  }

  // ------------------------------------------------------------------
  // Quick actions
  // ------------------------------------------------------------------

  Future<void> _callFirstContact(TrustedContact? contact) async {
    if (contact == null) {
      context.read<ShellController>().go(ShellTab.circle);
      return;
    }
    final uri = Uri(scheme: 'tel', path: contact.phone);
    if (!await launchUrl(uri) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start a call to ${contact.name}.')),
      );
    }
  }

  Future<void> _toggleAudio() async {
    if (_recordingAudio) {
      final path = await _recorder.stop();
      _audioTimer?.cancel();
      setState(() => _recordingAudio = false);
      if (path == null) return;

      try {
        final bytes = await XFile(path).readAsBytes();
        if (!mounted) return;
        setState(() {
          _audioClip = EvidenceDraft(
            bytes: bytes,
            filename: 'secureshe-audio-${DateTime.now().millisecondsSinceEpoch}.m4a',
            kind: EvidenceKind.audio,
            duration: Duration(seconds: _audioSeconds),
          );
        });
      } catch (e) {
        _snack('Could not save the recording.');
      }
      return;
    }

    try {
      if (!await _recorder.hasPermission()) {
        _snack('Microphone access denied.');
        return;
      }
      final dir = await getTemporaryDirectory();
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: '${dir.path}/home_audio_${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
      setState(() {
        _recordingAudio = true;
        _audioSeconds = 0;
        _audioClip = null;
      });
      _audioTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _audioSeconds++);
      });
    } catch (e) {
      _snack('Could not start recording.');
    }
  }

  Future<void> _recordVideo() async {
    try {
      final video = await ImagePicker().pickVideo(
        source: ImageSource.camera,
        maxDuration: const Duration(minutes: 5),
      );
      if (video == null) return;
      final Uint8List bytes = await video.readAsBytes();
      if (!mounted) return;
      setState(() {
        _videoClip = EvidenceDraft(
          bytes: bytes,
          filename: video.name,
          kind: EvidenceKind.video,
        );
      });
    } catch (_) {
      _snack('Camera access denied.');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _openTripSheet() {
    showSSSheet<void>(
      context,
      builder: (_) => _TripSheet(near: _here),
    );
  }

  // ------------------------------------------------------------------
  // Build
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final unread = context.select<AppPrefs, int>((p) => p.unreadCount);
    final contacts = context.watch<ContactsState>().contacts;
    final trip = context.watch<TripState>();
    final firstContact = contacts.isEmpty ? null : contacts.first;

    return SSPage(
      header: GlassHeader(
        title: 'SecureShe',
        titleSize: 20,
        subtitle: 'Stay safe · Stay aware',
        leading: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.bolt_rounded, size: 18, color: Colors.white),
        ),
        trailing: SSIconButton(
          icon: Icons.notifications_none_rounded,
          size: 44,
          badge: unread > 0,
          tooltip: 'Notifications',
          onTap: () => Navigator.of(context).pushNamed('/notifications'),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
          children: [
            if (trip.active) ...[
              _ActiveTripBanner(trip: trip),
              const SizedBox(height: 20),
            ],

            // SOS
            Center(
              child: SOSHoldButton(
                onTriggered: () => Navigator.of(context).pushNamed('/sos-confirm'),
              ),
            ),
            const SizedBox(height: 20),
            Center(
              child: SizedBox(
                width: 220,
                child: Text(
                  'Press and hold for 3 seconds to alert emergency contacts',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: c.mutedForeground),
                ),
              ),
            ),
            const SizedBox(height: 32),

            SafetyScoreCard(
              score: _score?.score,
              location: _placeName,
              reportsNearby: _score?.liveReportCount,
              loading: _loadingScore,
              onTap: () => context.read<ShellController>().go(ShellTab.map),
            ),
            const SizedBox(height: 24),

            // Quick actions
            const SectionLabel('Quick Actions', padding: EdgeInsets.fromLTRB(2, 0, 2, 8)),
            Row(
              children: [
                Expanded(
                  child: _QuickAction(
                    gradient: AppColors.primaryGradient,
                    icon: Icons.navigation_rounded,
                    iconColor: Colors.white,
                    iconBackground: Colors.white.withValues(alpha: 0.2),
                    title: 'Start Safe Trip',
                    titleColor: Colors.white,
                    onTap: _openTripSheet,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _QuickAction(
                    leading: firstContact == null
                        ? null
                        : InitialsAvatar(
                            initials: firstContact.initials,
                            color: AppColors.success,
                            size: 40,
                            solid: false,
                            online: true,
                          ),
                    icon: Icons.person_add_alt_1_rounded,
                    iconColor: AppColors.success,
                    title: firstContact?.name ?? 'Add a contact',
                    subtitle: firstContact == null ? 'Trusted circle' : 'Call now',
                    subtitleColor: AppColors.success,
                    subtitleIcon: firstContact == null ? null : Icons.phone_rounded,
                    onTap: () => _callFirstContact(firstContact),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _QuickAction(
                    icon: _recordingAudio ? Icons.stop_rounded : Icons.mic_none_rounded,
                    iconColor: _recordingAudio ? Colors.white : AppColors.destructive,
                    iconBackground: _recordingAudio
                        ? AppColors.destructive
                        : AppColors.destructive.withValues(alpha: 0.12),
                    highlight: _recordingAudio ? AppColors.destructive : null,
                    title: _recordingAudio ? 'Recording…' : 'Audio',
                    subtitle: _recordingAudio ? formatClock(_audioSeconds) : 'Live capture',
                    subtitleColor: _recordingAudio ? AppColors.destructive : null,
                    subtitleIcon: _recordingAudio ? Icons.schedule_rounded : null,
                    onTap: _toggleAudio,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _QuickAction(
                    icon: Icons.videocam_outlined,
                    iconColor: AppColors.violet,
                    iconBackground: AppColors.violet.withValues(alpha: 0.12),
                    title: 'Video',
                    subtitle: 'Live capture',
                    onTap: _recordVideo,
                  ),
                ),
              ],
            ),

            if (_audioClip != null && !_recordingAudio) ...[
              const SizedBox(height: 16),
              _SavedClipBanner(
                color: AppColors.destructive,
                icon: Icons.mic_none_rounded,
                title: 'Audio saved',
                subtitle: '${formatClock(_audioClip!.duration?.inSeconds ?? 0)} · '
                    'Attach it to a report as evidence',
                onUse: () {
                  context.read<ShellController>().reportWith(_audioClip!);
                  setState(() => _audioClip = null);
                },
                onDiscard: () => setState(() => _audioClip = null),
              ),
            ],
            if (_videoClip != null) ...[
              const SizedBox(height: 16),
              _SavedClipBanner(
                color: AppColors.violet,
                icon: Icons.videocam_outlined,
                title: 'Video saved',
                subtitle: 'Attach it to a report as evidence',
                onUse: () {
                  context.read<ShellController>().reportWith(_videoClip!);
                  setState(() => _videoClip = null);
                },
                onDiscard: () => setState(() => _videoClip = null),
              ),
            ],

            const SizedBox(height: 24),

            // Nearby alerts
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Nearby Alerts',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: c.foreground,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => context.read<ShellController>().go(ShellTab.map),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('View All', style: TextStyle(fontSize: 13)),
                      Icon(Icons.chevron_right_rounded, size: 18),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (_loadingNearby)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (_nearby.isEmpty)
              const AlertCard(
                kind: AlertKind.safe,
                title: 'No recent alerts near you',
                description: 'Nothing reported within 3 km in the last week',
                time: 'Updated just now',
              )
            else
              for (final item in _nearby)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: AlertCard(
                    kind: item.kind,
                    title: item.title,
                    icon: item.icon,
                    time: timeAgo(item.time),
                    distance: formatDistance(item.metres),
                    onTap: () => context.read<ShellController>().go(ShellTab.map),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.title,
    required this.onTap,
    this.iconColor,
    this.iconBackground,
    this.gradient,
    this.titleColor,
    this.subtitle,
    this.subtitleColor,
    this.subtitleIcon,
    this.highlight,
    this.leading,
  });

  final IconData icon;
  final Color? iconColor;
  final Color? iconBackground;
  final Gradient? gradient;
  final String title;
  final Color? titleColor;
  final String? subtitle;
  final Color? subtitleColor;
  final IconData? subtitleIcon;
  final Color? highlight;
  final Widget? leading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;

    return Container(
      decoration: BoxDecoration(
        gradient: gradient,
        color: gradient == null
            ? (highlight?.withValues(alpha: 0.12) ?? c.card)
            : null,
        borderRadius: BorderRadius.circular(16),
        border: gradient == null
            ? Border.all(color: highlight?.withValues(alpha: 0.45) ?? c.border)
            : null,
        boxShadow: gradient == null
            ? null
            : [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.35),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
            child: Column(
              children: [
                leading ??
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: iconBackground ?? c.muted,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(icon, size: 20, color: iconColor),
                    ),
                const SizedBox(height: 8),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: titleColor ?? c.foreground,
                  ),
                ),
                if (subtitle != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (subtitleIcon != null) ...[
                        Icon(subtitleIcon, size: 10, color: subtitleColor),
                        const SizedBox(width: 2),
                      ],
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: subtitleColor ?? c.mutedForeground,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SavedClipBanner extends StatelessWidget {
  const _SavedClipBanner({
    required this.color,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onUse,
    required this.onDiscard,
  });

  final Color color;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onUse;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: c.foreground,
                  ),
                ),
                Text(subtitle, style: TextStyle(fontSize: 10, color: c.mutedForeground)),
              ],
            ),
          ),
          SSIconButton(
            icon: Icons.flag_outlined,
            size: 32,
            iconColor: Colors.white,
            background: color,
            borderColor: color,
            tooltip: 'Report with this',
            onTap: onUse,
          ),
          const SizedBox(width: 8),
          SSIconButton(
            icon: Icons.close_rounded,
            size: 32,
            iconColor: c.mutedForeground,
            tooltip: 'Discard',
            onTap: onDiscard,
          ),
        ],
      ),
    );
  }
}

class _ActiveTripBanner extends StatelessWidget {
  const _ActiveTripBanner({required this.trip});

  final TripState trip;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return SSCard(
      borderColor: AppColors.success.withValues(alpha: 0.3),
      color: AppColors.success.withValues(alpha: 0.08),
      onTap: () => Navigator.of(context).pushNamed('/trip'),
      child: Row(
        children: [
          const IconTile(icon: Icons.navigation_rounded, color: AppColors.success),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Safe trip to ${trip.destinationName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: c.foreground,
                  ),
                ),
                Text(
                  '${formatDistance(trip.remainingMetres)} left · '
                  'ETA ${formatDuration(trip.eta)}',
                  style: TextStyle(fontSize: 11, color: c.mutedForeground),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.success),
        ],
      ),
    );
  }
}

/// "Start Safe Trip" sheet: pick a destination, then the Map tab plans
/// and scores the routes.
class _TripSheet extends StatefulWidget {
  const _TripSheet({required this.near});

  final LatLng? near;

  @override
  State<_TripSheet> createState() => _TripSheetState();
}

class _TripSheetState extends State<_TripSheet> {
  final _to = TextEditingController();
  final _routing = RoutingService();
  Timer? _debounce;
  List<PlaceResult> _results = [];
  PlaceResult? _chosen;
  bool _searching = false;

  static const _suggestions = ['Bus Stand', 'Railway Station', 'Hospital', 'Police Station'];

  @override
  void dispose() {
    _debounce?.cancel();
    _to.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _chosen = null;
    _debounce?.cancel();
    if (text.trim().length < 3) {
      setState(() => _results = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 700), () => _search(text));
  }

  Future<void> _search(String text) async {
    setState(() => _searching = true);
    try {
      final results = await _routing.searchPlaces(text.trim(), near: widget.near);
      if (mounted && _to.text.trim() == text.trim()) {
        setState(() => _results = results.take(5).toList());
      }
    } catch (_) {
      // Keep typing; the Map tab can search again.
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _go() {
    final query = _to.text.trim();
    if (_chosen == null && query.isEmpty) return;
    Navigator.of(context).pop();
    context.read<ShellController>().planTrip(place: _chosen, query: query);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final ready = _chosen != null || _to.text.trim().isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetTitle(
          title: 'Start Safe Trip',
          subtitle: 'Enter your route to check safety zones',
        ),
        SSCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: AppColors.success,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                widget.near == null ? 'Your location (finding…)' : 'My Location',
                style: TextStyle(fontSize: 14, color: c.foreground),
              ),
              const Spacer(),
              const Icon(Icons.my_location_rounded, size: 16, color: AppColors.primary),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 22, top: 4, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < 3; i++)
                Container(
                  width: 2,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 3),
                  color: c.border,
                ),
            ],
          ),
        ),
        SSTextField(
          controller: _to,
          hint: 'Where are you going?',
          icon: Icons.place_rounded,
          iconColor: AppColors.primary,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: (_) => _go(),
          trailing: _searching
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
        ),
        if (_results.isNotEmpty) ...[
          const SizedBox(height: 8),
          SSCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final place in _results)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.place_outlined, color: AppColors.primary),
                    title: Text(place.name, style: TextStyle(color: c.foreground)),
                    subtitle: Text(
                      place.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.mutedForeground, fontSize: 11),
                    ),
                    trailing: place.distanceKm == null
                        ? null
                        : Text(
                            formatDistance(place.distanceKm! * 1000),
                            style: TextStyle(fontSize: 11, color: c.mutedForeground),
                          ),
                    onTap: () => setState(() {
                      _chosen = place;
                      _to.text = place.name;
                      _results = [];
                    }),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        SizedBox(
          height: 32,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final s in _suggestions)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    label: Text(s, style: TextStyle(fontSize: 11, color: c.mutedForeground)),
                    backgroundColor: c.card,
                    side: BorderSide(color: c.border),
                    shape: const StadiumBorder(),
                    onPressed: () {
                      _to.text = s;
                      _onChanged(s);
                      _search(s);
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        GradientButton(
          label: 'Check Safe Route',
          icon: Icons.navigation_rounded,
          onPressed: ready ? _go : null,
        ),
      ],
    );
  }
}
