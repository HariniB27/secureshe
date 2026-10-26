import 'package:flutter/material.dart';

class HomeMenuScreen extends StatelessWidget {
  const HomeMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget item(String label, String route) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
          child: SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: () => Navigator.pushNamed(context, route),
              child: Text(label),
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text("SecureShe")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            item("SOS", "/sos"),
            item("Trusted Circle", "/trusted-circle"),
            item("Safety Map", "/map"),
          ],
        ),
      ),
    );
  }
}