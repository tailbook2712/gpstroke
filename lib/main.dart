import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:walk_tracker_app/route_service.dart';
import 'package:walk_tracker_app/walking_tracker_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 環境変数を読み込み（ファイルなくても続行）
  try {
    await dotenv.load(fileName: ".env");
    print('✓ .env ファイルを読み込みました');
  } catch (e) {
    print('⚠ .env ファイルが見つかりません（ファイルなしで続行します）');
  }

  // RouteService の初期化
  RouteService.initializeApiKey();

  // Firebase初期化
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
