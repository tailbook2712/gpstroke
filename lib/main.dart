import 'package:flutter/material.dart';
import 'package:walk_tracker_app/walking_tracker_screen.dart';


void main() {
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