import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';

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

  @override
  void dispose() {
    _descriptionController.dispose();
    _recorder.dispose();
    super.dispose();
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
    });
    _clearEvidence();
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
