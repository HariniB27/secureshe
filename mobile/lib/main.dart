import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';

import 'screens/app_shell.dart';
import 'screens/archive_lock_screen.dart';
import 'screens/login_screen.dart';
import 'screens/my_reports_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/personal_info_screen.dart';
import 'screens/privacy_security_screen.dart';
import 'screens/register_screen.dart';
import 'screens/report_screen.dart';
import 'screens/report_status_screen.dart';
import 'screens/sos_confirm_screen.dart';
import 'screens/trip_tracking_screen.dart';
import 'services/api_service.dart';
import 'state/app_prefs.dart';
import 'state/auth_state.dart';
import 'state/contacts_state.dart';
import 'state/shell_controller.dart';
import 'state/trip_state.dart';
import 'theme.dart';
import 'widgets/ss_ui.dart';

/// Lets code outside the widget tree (the API layer) change screens.
final navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = AppPrefs();
  final auth = AuthState();

  // When the server rejects the login token for good (even after a refresh),
  // sign out and go to the login screen, which explains why.
  ApiService.onSessionExpired = () async {
    await auth.expireSession();
    navigatorKey.currentState?.pushNamedAndRemoveUntil('/login', (_) => false);
  };

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: auth),
        ChangeNotifierProvider.value(value: prefs),
        ChangeNotifierProvider(create: (_) => ContactsState()),
        ChangeNotifierProvider(create: (_) => ShellController()),
        ChangeNotifierProvider(create: (_) => TripState(prefs)),
      ],
      child: const SecureSheApp(),
    ),
  );
}

class SecureSheApp extends StatelessWidget {
  const SecureSheApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeMode = context.select<AppPrefs, ThemeMode>((p) => p.themeMode);

    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'SecureShe',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      initialRoute: '/',
      routes: {
        '/': (context) => const SplashScreen(),
        '/login': (context) => const LoginScreen(),
        '/register': (context) => const RegisterScreen(),
        '/home': (context) => const AppShell(),
        '/sos-confirm': (context) => const SosConfirmScreen(),
        '/trip': (context) => const TripTrackingScreen(),
        '/my-reports': (context) => const MyReportsScreen(),
        '/notifications': (context) => const NotificationsScreen(),
        '/personal-info': (context) => const PersonalInfoScreen(),
        '/privacy-security': (context) => const PrivacySecurityScreen(),
        '/archive': (context) => const ArchiveLockScreen(),
        // Older names still used by some buttons.
        '/complaint': (context) => const ReportScreen(standalone: true),
        '/sos': (context) => const SosConfirmScreen(),
      },
      onGenerateRoute: (settings) {
        // /report-status/<id>
        final name = settings.name ?? '';
        if (name.startsWith('/report-status/')) {
          final id = name.substring('/report-status/'.length);
          return MaterialPageRoute(
            settings: settings,
            builder: (_) => ReportStatusScreen(complaintId: id),
          );
        }

        // Old map / circle routes open the matching tab.
        const tabRoutes = {
          '/map': ShellTab.map,
          '/safe-route': ShellTab.map,
          '/trusted-circle': ShellTab.circle,
          '/report': ShellTab.report,
          '/profile': ShellTab.profile,
        };
        final tab = tabRoutes[name];
        if (tab != null) {
          return MaterialPageRoute(
            settings: settings,
            builder: (context) => AppShell(initialTab: tab),
          );
        }
        return null;
      },
    );
  }
}

/// Loads settings, checks for a saved session (and the optional
/// biometric lock), then goes to Home or Login.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String? _lockMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final prefs = context.read<AppPrefs>();
    final auth = context.read<AuthState>();
    final contacts = context.read<ContactsState>();

    await prefs.load();
    final loggedIn = await auth.checkPersistedSession();
    if (!mounted) return;

    if (!loggedIn) {
      Navigator.of(context).pushReplacementNamed('/login');
      return;
    }

    if (prefs.biometricLock && !await _unlock()) return;

    await contacts.loadCached();
    contacts.refresh();

    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed('/home');
  }

  /// Face ID / fingerprint, when turned on in Privacy & Security.
  /// Devices without biometrics (or web) skip straight through.
  Future<bool> _unlock() async {
    final auth = LocalAuthentication();
    try {
      if (!await auth.isDeviceSupported()) return true;
      final ok = await auth.authenticate(localizedReason: 'Unlock SecureShe');
      if (!ok && mounted) {
        setState(() => _lockMessage = 'Locked. Tap to try again.');
      }
      return ok;
    } catch (_) {
      return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SSPage(
      body: Center(
        child: GestureDetector(
          onTap: _lockMessage == null
              ? null
              : () {
                  setState(() => _lockMessage = null);
                  _start();
                },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  gradient: AppColors.primaryGradient,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.35),
                      blurRadius: 40,
                    ),
                  ],
                ),
                child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 34),
              ),
              const SizedBox(height: 20),
              if (_lockMessage != null)
                Text(
                  _lockMessage!,
                  style: TextStyle(color: context.ss.mutedForeground),
                )
              else
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
