import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:walk_tracker_app/walking_tracker_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Walking Tracker',
      home: WalkingTrackerScreen(),
    );
  }
}