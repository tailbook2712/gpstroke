import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:walk_tracker_app/auth_service.dart';
import 'package:walk_tracker_app/login_screen.dart';
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
      title: 'GPStroke',
      home: AuthGate(),
    );
  }
}

/// 認証状態に応じてログイン画面またはホーム画面を表示するゲート
class AuthGate extends StatelessWidget {
  final AuthService _authService = AuthService();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: _authService.authStateChanges,
      builder: (context, snapshot) {
        // 接続待ち
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        // ログイン済み → ホーム画面
        if (snapshot.hasData) {
          return WalkingTrackerScreen();
        }

        // 未ログイン → ログイン画面
        return const LoginScreen();
      },
    );
  }
}
