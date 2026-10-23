import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'features/recorder/recorder_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const SocialMakerApp());
}

class SocialMakerApp extends StatelessWidget {
  const SocialMakerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SocialMaker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFE2C55),
          brightness: Brightness.dark,
        ),
      ),
      home: const RecorderScreen(),
    );
  }
}
