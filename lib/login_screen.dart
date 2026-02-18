import 'package:flutter/material.dart';
import 'auth_service.dart';

/// 軌跡アイコンを描画するカスタムペインター
class _TrajectoryIconPainter extends CustomPainter {
  final Color color;
  _TrajectoryIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    // 軌跡を模した曲線パス
    path.moveTo(size.width * 0.15, size.height * 0.85);
    path.cubicTo(
      size.width * 0.1,
      size.height * 0.55,
      size.width * 0.4,
      size.height * 0.65,
      size.width * 0.35,
      size.height * 0.35,
    );
    path.cubicTo(
      size.width * 0.3,
      size.height * 0.15,
      size.width * 0.55,
      size.height * 0.1,
      size.width * 0.5,
      size.height * 0.3,
    );
    path.cubicTo(
      size.width * 0.45,
      size.height * 0.5,
      size.width * 0.7,
      size.height * 0.55,
      size.width * 0.65,
      size.height * 0.25,
    );
    path.cubicTo(
      size.width * 0.6,
      size.height * 0.05,
      size.width * 0.85,
      size.height * 0.15,
      size.width * 0.85,
      size.height * 0.4,
    );
    path.cubicTo(
      size.width * 0.85,
      size.height * 0.6,
      size.width * 0.75,
      size.height * 0.75,
      size.width * 0.9,
      size.height * 0.85,
    );

    canvas.drawPath(path, paint);

    // 始点マーカー
    final startPaint = Paint()
      ..color = color.withOpacity(0.9)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(size.width * 0.15, size.height * 0.85),
      5,
      startPaint,
    );

    // 終点マーカー（現在地風）
    final endPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(size.width * 0.9, size.height * 0.85),
      6,
      endPaint,
    );
    final endRing = Paint()
      ..color = color.withOpacity(0.3)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(size.width * 0.9, size.height * 0.85),
      10,
      endRing,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// ログイン画面（Googleアカウントでサインイン）
class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);

  @override
  _LoginScreenState createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final AuthService _authService = AuthService();
  bool _isLoading = false;

  Future<void> _handleGoogleSignIn() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final user = await _authService.signInWithGoogle();
      if (user == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('サインインがキャンセルされました')),
        );
      }
      // サインイン成功時は authStateChanges により自動的にホーム画面に遷移
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('サインインに失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF2196F3), // Blue
              Color(0xFF1976D2),
              Color(0xFF1565C0),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 軌跡を模したアプリアイコン
                  CustomPaint(
                    size: const Size(120, 120),
                    painter: _TrajectoryIconPainter(color: Colors.white),
                  ),
                  const SizedBox(height: 32),
                  // アプリ名
                  const Text(
                    'GPStroke',
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 2.0,
                    ),
                  ),
                  const SizedBox(height: 60),
                  // Googleサインインボタン
                  _isLoading
                      ? const CircularProgressIndicator(
                          color: Colors.white,
                        )
                      : SizedBox(
                          width: double.infinity,
                          height: 54,
                          child: ElevatedButton(
                            onPressed: _handleGoogleSignIn,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: Colors.black87,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 4,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Image.network(
                                  'https://www.gstatic.com/firebasejs/ui/2.0.0/images/auth/google.svg',
                                  height: 24,
                                  width: 24,
                                  errorBuilder: (context, error, stackTrace) {
                                    return const Icon(
                                      Icons.g_mobiledata,
                                      size: 28,
                                      color: Colors.red,
                                    );
                                  },
                                ),
                                const SizedBox(width: 12),
                                const Text(
                                  'Googleアカウントでログイン',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                  const SizedBox(height: 24),
                  Text(
                    'ログインすると軌跡や作品がアカウントに保存されます',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withOpacity(0.6),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
