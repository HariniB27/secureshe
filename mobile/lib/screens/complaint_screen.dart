import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';
import 'location_picker_screen.dart';

enum _EvidenceKind { photo, audio }

class ComplaintScreen extends StatefulWidget {
  const ComplaintScreen({super.key});

  @override
  State<ComplaintScreen> createState() => _ComplaintScreenState();
}

class _ComplaintScreenState extends State<ComplaintScreen> {
  final _descriptionController = TextEditingController();
  final _recorder = AudioRecorder();

  Uint8List? _evidenceBytes;
  String? _evidenceFilename;
  _EvidenceKind? _evidenceKind;

  bool _isRecording = false;
  bool _isSubmitting = false;
  String? _error;
  Map<String, dynamic>? _result;

  LatLng? _location;
  String? _locationSource; // 'gps' or 'manual'
  bool _isLoadingLocation = false;
  String? _locationNotice;

  @override
  void initState() {
    super.initState();
    _fetchCurrentLocation();
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _recorder.dispose();
    super.dispose();
  }

  /// Gets the device's current position as the default location. Any
  /// failure (permission denied, location services off, etc.) is handled
  /// gracefully — it never blocks submission, it just leaves [_location]
  /// unset so the user can fall back to placing a pin manually.
  Future<void> _fetchCurrentLocation() async {
    setState(() {
      _isLoadingLocation = true;
      _locationNotice = null;
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() => _locationNotice = 'Location services are off — add a location manually.');
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        setState(() => _locationNotice = 'Location permission denied — add a location manually.');
        return;
      }

      final position = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      setState(() {
        _location = LatLng(position.latitude, position.longitude);
        _locationSource = 'gps';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _locationNotice = 'Could not get your location — add a location manually.');
    } finally {
      if (mounted) setState(() => _isLoadingLocation = false);
    }
  }

  Future<void> _pickLocationManually() async {
    final picked = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(initialCenter: _location),
      ),
    );

    if (picked == null || !mounted) return;
    setState(() {
      _location = picked;
      _locationSource = 'manual';
      _locationNotice = null;
    });
  }

  void _clearEvidence() {
    setState(() {
      _evidenceBytes = null;
      _evidenceFilename = null;
      _evidenceKind = null;
    });
  }

  Future<void> _takePhoto() async {
    setState(() => _error = null);
    try {
      final photo = await ImagePicker().pickImage(source: ImageSource.camera);
      if (photo == null) return; // user cancelled

      final bytes = await photo.readAsBytes();
      if (!mounted) return;
      setState(() {
        _evidenceBytes = bytes;
        _evidenceFilename = photo.name;
        _evidenceKind = _EvidenceKind.photo;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not access the camera: $e');
    }
  }

  Future<void> _toggleRecording() async {
    setState(() => _error = null);

    if (_isRecording) {
      final path = await _recorder.stop();
      setState(() => _isRecording = false);

      if (path == null) return;
      try {
        final bytes = await XFile(path).readAsBytes();
        if (!mounted) return;
        setState(() {
          _evidenceBytes = bytes;
          _evidenceFilename = 'evidence_audio.m4a';
          _evidenceKind = _EvidenceKind.audio;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() => _error = 'Could not read the recorded audio: $e');
      }
      return;
    }

    try {
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        setState(() => _error = 'Microphone permission is required to record audio.');
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final path =
          '${tempDir.path}/complaint_audio_${DateTime.now().millisecondsSinceEpoch}.m4a';

      await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
      if (!mounted) return;
      setState(() => _isRecording = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not start recording: $e');
    }
  }

  Future<void> _submit() async {
    if (_descriptionController.text.trim().isEmpty) {
      setState(() => _error = 'Please describe what happened.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      final response = await ApiService.submitComplaint(
        description: _descriptionController.text.trim(),
        evidenceBytes: _evidenceBytes,
        evidenceFilename: _evidenceFilename,
        lat: _location?.latitude,
        lng: _location?.longitude,
        locationSource: _locationSource,
      );

      if (!mounted) return;

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 201) {
        setState(() => _result = data);
      } else {
        setState(() => _error = data['error'] as String? ?? 'Submission failed');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Cannot reach the server. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _startNewComplaint() {
    setState(() {
      _result = null;
      _error = null;
      _descriptionController.clear();
      _location = null;
      _locationSource = null;
      _locationNotice = null;
    });
    _clearEvidence();
    _fetchCurrentLocation();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Submit a Complaint')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: _result != null ? _buildResult(context, _result!) : _buildForm(context),
        ),
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _descriptionController,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'Description',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isSubmitting ? null : _takePhoto,
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text('Take Photo'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isSubmitting ? null : _toggleRecording,
                icon: Icon(_isRecording ? Icons.stop_circle_outlined : Icons.mic_none),
                label: Text(_isRecording ? 'Stop Recording' : 'Record Audio'),
              ),
            ),
          ],
        ),
        if (_evidenceBytes != null) ...[
          const SizedBox(height: 16),
          _buildEvidencePreview(),
        ],
        const SizedBox(height: 16),
        _buildLocationSection(),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!, style: const TextStyle(color: Colors.red)),
        ],
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: _isSubmitting ? null : _submit,
          child: _isSubmitting
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Submit Complaint'),
        ),
      ],
    );
  }

  Widget _buildEvidencePreview() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFCADCFC).withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          if (_evidenceKind == _EvidenceKind.photo)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(_evidenceBytes!, width: 48, height: 48, fit: BoxFit.cover),
            )
          else
            const Icon(Icons.audiotrack, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _evidenceKind == _EvidenceKind.photo ? 'Photo attached' : 'Audio recording attached',
            ),
          ),
          IconButton(
            onPressed: _isSubmitting ? null : _clearEvidence,
            icon: const Icon(Icons.close),
            tooltip: 'Remove evidence',
          ),
        ],
      ),
    );
  }

  Widget _buildLocationSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_isLoadingLocation)
          const Row(
            children: [
              SizedBox(
                height: 16,
                width: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 8),
              Text('Getting your location...'),
            ],
          )
        else if (_location != null)
          Row(
            children: [
              const Icon(Icons.location_on, size: 18, color: Color(0xFF1E2761)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _locationSource == 'gps'
                      ? 'Using your current location'
                      : 'Manual location set',
                ),
              ),
            ],
          )
        else if (_locationNotice != null)
          Row(
            children: [
              const Icon(Icons.location_off_outlined, size: 18, color: Colors.black54),
              const SizedBox(width: 6),
              Expanded(
                child: Text(_locationNotice!, style: const TextStyle(color: Colors.black54)),
              ),
            ],
          ),
        TextButton(
          onPressed: _isSubmitting ? null : _pickLocationManually,
          child: Text(
            _location == null
                ? 'Add Location'
                : "This isn't where it happened — set location manually",
          ),
        ),
      ],
    );
  }

  Widget _buildResult(BuildContext context, Map<String, dynamic> result) {
    final etherscanUrl = result['etherscan_url'] as String?;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.check_circle, color: Colors.green, size: 56),
        const SizedBox(height: 16),
        Text(
          'Complaint submitted',
          style: Theme.of(context).textTheme.headlineMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        _buildResultRow('Complaint ID', result['complaint_id'] as String? ?? '—'),
        _buildResultRow('Evidence Hash', result['evidence_hash'] as String? ?? '—'),
        if (result['latitude'] != null && result['longitude'] != null)
          _buildResultRow(
            'Location (${result['location_source'] ?? 'unknown'})',
            '${result['latitude']}, ${result['longitude']}',
          ),
        if (etherscanUrl != null) ...[
          const SizedBox(height: 16),
          InkWell(
            onTap: () => launchUrl(Uri.parse(etherscanUrl), mode: LaunchMode.externalApplication),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.link, color: Color(0xFF1E2761)),
                const SizedBox(width: 6),
                Text(
                  'View on Etherscan',
                  style: TextStyle(
                    color: const Color(0xFF1E2761),
                    decoration: TextDecoration.underline,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          const SizedBox(height: 8),
          const Text(
            'Blockchain logging did not complete for this complaint — the description and '
            'evidence are still saved.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black54),
          ),
        ],
        const SizedBox(height: 32),
        OutlinedButton(
          onPressed: _startNewComplaint,
          child: const Text('Submit another complaint'),
        ),
      ],
    );
  }

  Widget _buildResultRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.black54, fontSize: 12)),
          SelectableText(value, style: const TextStyle(fontFamily: 'monospace')),
        ],
      ),
    );
  }
}
