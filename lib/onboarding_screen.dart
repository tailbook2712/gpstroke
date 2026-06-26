import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kOnboardingShownKey = 'onboarding_shown';

Future<bool> hasShownOnboarding() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_kOnboardingShownKey) ?? false;
}

Future<void> markOnboardingShown() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_kOnboardingShownKey, true);
}

class _TrajectoryIconPainter extends CustomPainter {
  final Color color;
  const _TrajectoryIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    path.moveTo(size.width * 0.15, size.height * 0.85);
    path.cubicTo(size.width * 0.1, size.height * 0.55, size.width * 0.4,
        size.height * 0.65, size.width * 0.35, size.height * 0.35);
    path.cubicTo(size.width * 0.3, size.height * 0.15, size.width * 0.55,
        size.height * 0.1, size.width * 0.5, size.height * 0.3);
    path.cubicTo(size.width * 0.45, size.height * 0.5, size.width * 0.7,
        size.height * 0.55, size.width * 0.65, size.height * 0.25);
    path.cubicTo(size.width * 0.6, size.height * 0.05, size.width * 0.85,
        size.height * 0.15, size.width * 0.85, size.height * 0.4);
    path.cubicTo(size.width * 0.85, size.height * 0.6, size.width * 0.75,
        size.height * 0.75, size.width * 0.9, size.height * 0.85);
    canvas.drawPath(path, paint);

    final startPaint = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
        Offset(size.width * 0.15, size.height * 0.85), 5, startPaint);

    final endPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
        Offset(size.width * 0.9, size.height * 0.85), 6, endPaint);
    canvas.drawCircle(
        Offset(size.width * 0.9, size.height * 0.85),
        10,
        Paint()
          ..color = color.withValues(alpha: 0.3)
          ..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SlideData {
  final String title;
  final String description;
  final String? imagePath;
  final bool showSkip;

  const _SlideData({
    required this.title,
    required this.description,
    this.imagePath,
    required this.showSkip,
  });
}

const _slides = [
  _SlideData(
    title: 'ようこそ',
    description: '軌跡を組み合わせて、\n一つの作品を作り上げよう',
    imagePath: null,
    showSkip: false,
  ),
  _SlideData(
    title: '軌跡の記録',
    description: '外に出て、移動の軌跡を\nストロークとして記録しよう',
    imagePath: 'assets/images/onboarding_mock1.png',
    showSkip: true,
  ),
  _SlideData(
    title: '作品の制作',
    description: '複数の軌跡を組み合わせて\n作品を作ろう',
    imagePath: 'assets/images/onboarding_mock2.png',
    showSkip: true,
  ),
  _SlideData(
    title: '作品の閲覧',
    description: '作品を保存して、\nいつでも振り返ろう',
    imagePath: 'assets/images/onboarding_mock3.png',
    showSkip: true,
  ),
];

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onFinished;

  const OnboardingScreen({super.key, required this.onFinished});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _currentPage = 0;

  bool get _isLastPage => _currentPage == _slides.length - 1;

  void _goToNext() {
    if (!_isLastPage) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _finish();
    }
  }

  void _finish() async {
    await markOnboardingShown();
    widget.onFinished();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GPStrokeの使い方'),
        centerTitle: true,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        actions: [
          if (_slides[_currentPage].showSkip)
            TextButton(
              onPressed: _finish,
              child: const Text(
                'スキップ',
                style: TextStyle(color: Colors.grey, fontSize: 15),
              ),
            ),
        ],
      ),
      backgroundColor: Colors.white,
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: _slides.length,
              onPageChanged: (index) {
                setState(() => _currentPage = index);
              },
              itemBuilder: (context, index) {
                return _SlidePage(data: _slides[index]);
              },
            ),
          ),
          _PageIndicator(count: _slides.length, current: _currentPage),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _goToNext,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2196F3),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                child: Text(
                  _isLastPage ? 'はじめる' : '次へ',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class _SlidePage extends StatelessWidget {
  final _SlideData data;

  const _SlidePage({required this.data});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (data.imagePath == null) ...[
            _AppIconWidget(),
          ] else ...[
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Image.asset(
                  data.imagePath!,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ],
          const SizedBox(height: 32),
          Text(
            data.title,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            data.description,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 15,
              color: Colors.black54,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _AppIconWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 140,
      height: 140,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF2196F3),
            Color(0xFF1976D2),
            Color(0xFF1565C0),
          ],
        ),
        borderRadius: BorderRadius.circular(32),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2196F3).withValues(alpha: 0.35),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: const CustomPaint(
        painter: _TrajectoryIconPainter(color: Colors.white),
      ),
    );
  }
}

class _PageIndicator extends StatelessWidget {
  final int count;
  final int current;

  const _PageIndicator({required this.count, required this.current});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (index) {
        final isActive = index == current;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: isActive ? 20 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: isActive
                ? const Color(0xFF2196F3)
                : const Color(0xFFBBDEFB),
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}
