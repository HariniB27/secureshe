import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../services/safety_api_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  SafetyScore? _safetyScore;
  bool _isLoading = true;
  String? _error;

  // Bengaluru coordinates for the initial safety check.
  static const LatLng _defaultLocation = LatLng( 12.9716,77.5946,);

  @override
  void initState() {
    super.initState();
    _loadSafetyScore();
  }

  Future<void> _loadSafetyScore() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result =
          await SafetyApiService().fetchScore(_defaultLocation);

      if (!mounted) return;

      setState(() {
        _safetyScore = result;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Color _scoreColor(int score) {
    if (score >= 70) {
      return Colors.green;
    }

    if (score >= 40) {
      return Colors.orange;
    }

    return Colors.red;
  }

  IconData _scoreIcon(int score) {
    if (score >= 70) {
      return Icons.shield;
    }

    if (score >= 40) {
      return Icons.warning_amber;
    }

    return Icons.dangerous;
  }

  @override
  Widget build(BuildContext context) {
    final score = _safetyScore;

    return Scaffold(
      appBar: AppBar(
        title: const Text('SecureShe'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: () {
              Navigator.of(context).pushReplacementNamed('/login');
            },
          ),
        ],
      ),

      body: RefreshIndicator(
        onRefresh: _loadSafetyScore,

        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [

            const Text(
              'Welcome to SecureShe 👋',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 8),

            const Text(
              'Stay informed. Stay aware. Stay safe.',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey,
              ),
            ),

            const SizedBox(height: 24),

            // Safety score card.
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(24),

                child: Column(
                  children: [

                    const Text(
                      'CURRENT SAFETY SCORE',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),

                    const SizedBox(height: 20),

                    if (_isLoading)
                      const SizedBox(
                        height: 80,
                        width: 80,
                        child: CircularProgressIndicator(),
                      )

                    else if (_error != null)
                      Column(
                        children: [
                          const Icon(
                            Icons.error_outline,
                            size: 50,
                            color: Colors.red,
                          ),

                          const SizedBox(height: 12),

                          const Text(
                            'Unable to load safety score.',
                            textAlign: TextAlign.center,
                          ),

                          const SizedBox(height: 12),

                          ElevatedButton(
                            onPressed: _loadSafetyScore,
                            child: const Text('Retry'),
                          ),
                        ],
                      )

                    else if (score != null)
                      Column(
                        children: [

                          Icon(
                            _scoreIcon(score.score),
                            size: 60,
                            color: _scoreColor(score.score),
                          ),

                          const SizedBox(height: 10),

                          Text(
                            '${score.score}',
                            style: TextStyle(
                              fontSize: 56,
                              fontWeight: FontWeight.bold,
                              color: _scoreColor(score.score),
                            ),
                          ),

                          Text(
                            'out of 100',
                            style: TextStyle(
                              color: Colors.grey.shade600,
                            ),
                          ),

                          const SizedBox(height: 12),

                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 8,
                            ),

                            decoration: BoxDecoration(
                              color: _scoreColor(score.score)
                                  .withOpacity(0.15),
                              borderRadius:
                                  BorderRadius.circular(20),
                            ),

                            child: Text(
                              score.band.toUpperCase(),
                              style: TextStyle(
                                color: _scoreColor(score.score),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            // Historical risk.
            if (score != null)
              Card(
                child: ListTile(
                  leading: const Icon(
                    Icons.history,
                    size: 32,
                  ),

                  title: const Text(
                    'Historical Crime Risk',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  subtitle: Text(
                    'Risk value: ${score.historicalRisk.toStringAsFixed(3)}',
                  ),
                ),
              ),

            // Live reports.
            if (score != null)
              Card(
                child: ListTile(
                  leading: const Icon(
                    Icons.warning_amber,
                    size: 32,
                  ),

                  title: const Text(
                    'Live Reports',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  subtitle: Text(
                    '${score.liveReportCount} reports near this location',
                  ),
                ),
              ),

            const SizedBox(height: 20),

            // Safety map.
            Card(
              elevation: 3,

              child: InkWell(
                borderRadius: BorderRadius.circular(12),

                onTap: () {
                  Navigator.of(context).pushNamed('/map');
                },

                child: const Padding(
                  padding: EdgeInsets.all(22),

                  child: Row(
                    children: [

                      Icon(
                        Icons.map,
                        size: 45,
                      ),

                      SizedBox(width: 18),

                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,

                          children: [
                            Text(
                              'Safety Map',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),

                            SizedBox(height: 5),

                            Text(
                              'View safety information and crime areas on the map.',
                            ),
                          ],
                        ),
                      ),

                      Icon(Icons.arrow_forward_ios),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Report incident.
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.report,
                  size: 35,
                ),

                title: const Text(
                  'Report an Incident',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),

                subtitle: const Text(
                  'Submit a complaint or safety report.',
                ),

                trailing:
                    const Icon(Icons.arrow_forward_ios),

                onTap: () {
                  Navigator.of(context)
                      .pushNamed('/complaint');
                },
              ),
            ),

            const SizedBox(height: 16),

            // SOS.
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.sos,
                  size: 35,
                ),

                title: const Text(
                  'Emergency SOS',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),

                subtitle: const Text(
                  'Access emergency assistance.',
                ),

                trailing:
                    const Icon(Icons.arrow_forward_ios),

                onTap: () {
                  Navigator.of(context)
                      .pushNamed('/sos');
                },
              ),
            ),

            const SizedBox(height: 30),

            const Center(
              child: Text(
                'SecureShe • Safety Intelligence Platform',
                style: TextStyle(
                  color: Colors.grey,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}