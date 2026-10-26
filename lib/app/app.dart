import 'package:flutter/material.dart';

import '../features/home/home_screen.dart';

class OfflineVideoCallApp extends StatelessWidget {
  const OfflineVideoCallApp({super.key});

  static const Color _seedColor = Colors.indigo;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offline Video Call',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: _seedColor),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seedColor,
          brightness: Brightness.dark,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
