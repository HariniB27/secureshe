import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../services/api_service.dart';
import 'placeholder_screen.dart';

/// Gate in front of the complaint archive: tries biometrics first (when the
/// device supports it), and always offers a password fallback via
/// POST /api/auth/verify-password — since not every device has biometrics
/// enrolled, and this plugin has no web implementation at all.
class ArchiveLockScreen extends StatefulWidget {
  const ArchiveLockScreen({super.key});

  @override
  State<ArchiveLockScreen> createState() => _ArchiveLockScreenState();
}

class _ArchiveLockScreenState extends State<ArchiveLockScreen> {
  final _auth = LocalAuthentication();
  final _passwordController = TextEditingController();

  bool _biometricsChecked = false;
  bool _biometricsAvailable = false;
  bool _isVerifyingPassword = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkBiometrics());
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _checkBiometrics() async {
    bool available = false;
    try {
      available = await _auth.isDeviceSupported() && await _auth.canCheckBiometrics;
    } catch (_) {
      available = false;
    }

    if (!mounted) return;
    setState(() {
      _biometricsAvailable = available;
      _biometricsChecked = true;
    });

    if (available) {
      await _authenticateWithBiometrics();
    }
  }

  Future<void> _authenticateWithBiometrics() async {
    setState(() => _error = null);
    try {
      final didAuthenticate = await _auth.authenticate(
        localizedReason: 'Unlock your complaint archive',
      );
      if (didAuthenticate) _unlock();
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Biometric authentication unavailable — use your password instead.');
    }
  }

  Future<void> _verifyPassword() async {
    if (_passwordController.text.isEmpty) {
      setState(() => _error = 'Enter your password.');
      return;
    }

    setState(() {
      _isVerifyingPassword = true;
      _error = null;
    });

    try {
      final response = await ApiService.verifyPassword(_passwordController.text);
      if (!mounted) return;

      if (response.statusCode == 200) {
        _unlock();
      } else if (response.statusCode == 401) {
        setState(() => _error = 'Incorrect password.');
      } else {
        setState(() => _error = 'Verification failed (${response.statusCode}).');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Cannot reach the server. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _isVerifyingPassword = false);
    }
  }

  void _unlock() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const PlaceholderScreen(title: 'Archive')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Complaint Archive')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.lock_outline, size: 56, color: Color(0xFF1E2761)),
              const SizedBox(height: 16),
              Text(
                'This archive is locked',
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              if (_biometricsAvailable) ...[
                ElevatedButton.icon(
                  onPressed: _authenticateWithBiometrics,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Unlock with Biometrics'),
                ),
                const SizedBox(height: 24),
                const Row(
                  children: [
                    Expanded(child: Divider()),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text('or'),
                    ),
                    Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 24),
              ] else if (_biometricsChecked) ...[
                const Text(
                  'Biometric authentication is not available on this device.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 24),
              ],
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
                onSubmitted: (_) => _verifyPassword(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _isVerifyingPassword ? null : _verifyPassword,
                child: _isVerifyingPassword
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Unlock'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
