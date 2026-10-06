import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/camera_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const FindInFrontApp());
}

class FindInFrontApp extends StatelessWidget {
  const FindInFrontApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FindInFront',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const CameraScreen(),
    );
  }
}
