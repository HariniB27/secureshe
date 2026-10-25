import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile/main.dart';
import 'package:mobile/state/app_prefs.dart';
import 'package:mobile/state/auth_state.dart';
import 'package:mobile/state/contacts_state.dart';
import 'package:mobile/state/shell_controller.dart';
import 'package:mobile/state/trip_state.dart';

void main() {
  testWidgets('App launches to the splash screen', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = AppPrefs();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AuthState()),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider(create: (_) => ContactsState()),
          ChangeNotifierProvider(create: (_) => ShellController()),
          ChangeNotifierProvider(create: (_) => TripState(prefs)),
        ],
        child: const SecureSheApp(),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
