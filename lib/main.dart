import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:walk_tracker_app/auth_service.dart';
import 'package:walk_tracker_app/login_screen.dart';
import 'package:walk_tracker_app/onboarding_screen.dart';
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

  final showOnboarding = !(await hasShownOnboarding());

  runApp(MyApp(showOnboarding: showOnboarding));
}

class MyApp extends StatelessWidget {
  final bool showOnboarding;

  const MyApp({super.key, required this.showOnboarding});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GPStroke',
      theme: ThemeData(
        appBarTheme: const AppBarTheme(centerTitle: true),
      ),
      home: _RootScreen(showOnboarding: showOnboarding),
    );
  }
}

class _RootScreen extends StatefulWidget {
  final bool showOnboarding;

  const _RootScreen({required this.showOnboarding});

  @override
  State<_RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<_RootScreen> {
  late bool _showOnboarding;

  @override
  void initState() {
    super.initState();
    _showOnboarding = widget.showOnboarding;
  }

  @override
  Widget build(BuildContext context) {
    if (_showOnboarding) {
      return OnboardingScreen(
        onFinished: () {
          setState(() => _showOnboarding = false);
        },
      );
    }
    return AuthGate();
  }
}

/// 認証状態に応じてログイン画面またはホーム画面を表示するゲート
class AuthGate extends StatelessWidget {
  final AuthService _authService = AuthService();

  AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: _authService.authStateChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasData) {
          return const WalkingTrackerScreen();
        }

        return const LoginScreen();
      },
    );
  }
}
