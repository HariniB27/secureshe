import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/safety_map_screen.dart';
import 'screens/login_screen.dart';
import 'screens/placeholder_screen.dart';
import 'screens/register_screen.dart';
import 'state/auth_state.dart';
import 'theme.dart';
import 'screens/home_screen.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
void main() {
  WidgetsFlutterBinding.ensureInitialized();

  MapboxOptions.setAccessToken(
    const String.fromEnvironment('ACCESS_TOKEN'),
  );

  runApp(
    ChangeNotifierProvider(
      create: (_) => AuthState(),
      child: const SecureSheApp(),
    ),
  );
}

class SecureSheApp extends StatelessWidget {
  const SecureSheApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SecureShe',
      debugShowCheckedModeBanner: false,
      theme: appTheme,
      initialRoute: '/',
      routes: {
        '/': (context) => const SplashScreen(),
        '/login': (context) => const LoginScreen(),
        '/register': (context) => const RegisterScreen(),
        '/home': (context) => const HomeScreen(),
        '/complaint': (context) => const PlaceholderScreen(title: 'Complaint'),
        '/archive': (context) => const PlaceholderScreen(title: 'Archive'),
        '/sos': (context) => const PlaceholderScreen(title: 'SOS'),
        '/map': (context) => const SafetyMapScreen(),
      },
    );
  }
}

/// Checks for a persisted session on startup, then routes to '/home' if
/// already logged in, or '/login' otherwise.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkSession());
  }

  Future<void> _checkSession() async {
    final authState = context.read<AuthState>();
    final isLoggedIn = await authState.checkPersistedSession();

    if (!mounted) return;

    Navigator.of(context).pushReplacementNamed(isLoggedIn ? '/home' : '/login');
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
