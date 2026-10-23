import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'features/recorder/recorder_screen.dart';
import 'brand.dart';

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
        scaffoldBackgroundColor: Brand.night,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Brand.pink,
          brightness: Brightness.dark,
        ),
      ),
      home: const RecorderScreen(),
    );
  }
}
