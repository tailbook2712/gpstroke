import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:walk_tracker_app/walking_tracker_screen.dart';


Future<void> main() async {
  runApp(MyApp());
  await dotenv.load(fileName: ".env");
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