import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:walk_tracker_app/canvas_scale_widgets.dart';
import 'package:walk_tracker_app/polyline_painter.dart';
import 'package:walk_tracker_app/utils/canvas_scale.dart';

Position _position(double latitude, double longitude) {
  return Position(
    latitude: latitude,
    longitude: longitude,
    timestamp: DateTime(2026, 11, 1),
    accuracy: 0.0,
    altitude: 0.0,
    heading: 0.0,
    speed: 0.0,
    speedAccuracy: 0.0,
    altitudeAccuracy: 0.0,
    headingAccuracy: 0.0,
  );
}

/// 函館付近から東へ [meters] 進む軌跡（差し渡し ≒ meters）
List<Position> _eastward(double meters) {
  const lat = 41.8418;
  const lon = 140.7669;
  final lonDelta = meters / (111320.0 * math.cos(lat * math.pi / 180.0));
  return [
    _position(lat, lon),
    _position(lat + 0.0001, lon + lonDelta / 2),
    _position(lat, lon + lonDelta),
  ];
}

void main() {
  test('trajectoryExtentMeters は軌跡の差し渡しを返す', () {
    expect(trajectoryExtentMeters(_eastward(1000)), closeTo(1000, 1));
    expect(trajectoryExtentMeters(const []), 0.0);
  });

  group('ScaledTrajectory', () {
    Future<Size> pumpIn(WidgetTester tester, double boxSide) async {
      await tester.pumpWidget(MaterialApp(
        home: Center(
          // 固定サイズの置き場所
          child: SizedBox(
            width: 68,
            height: 65,
            child: ClipRect(
              child: ScaledTrajectory(
                positions: _eastward(1000),
                boxSide: boxSide,
              ),
            ),
          ),
        ),
      ));
      return tester.getSize(find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is PolylinePainter));
    }

    testWidgets('置き場所の大きさに関係なく、指定した枠の大きさで描く', (tester) async {
      // 置き場所より小さい軌跡は、引き伸ばさずそのままの大きさで描く
      expect(await pumpIn(tester, 20), const Size(20, 20));
      // 置き場所より大きい軌跡は、縮めずにはみ出して描く
      expect(await pumpIn(tester, 300), const Size(300, 300));
    });

    testWidgets('同じ縮小率を掛ければ、軌跡どうしの大きさの比が保たれる', (tester) async {
      // 500m スケールのキャンバスで 1km と 2km の軌跡を、同じ縮小率で描く
      const ratio = 60 / 390;
      final small =
          await pumpIn(tester, CanvasScale.boxPixels(1000, 500) * ratio);
      final large =
          await pumpIn(tester, CanvasScale.boxPixels(2000, 500) * ratio);
      expect(large.width / small.width, closeTo(2.0, 1e-6));
    });
  });

  group('CanvasScaleBar', () {
    testWidgets('縮尺を表示し、増減のボタンを持たない', (tester) async {
      var tapped = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CanvasScaleBar(
            distanceMeters: 1000,
            onTap: () => tapped = true,
          ),
        ),
      ));

      expect(find.text('1km'), findsOneWidget);
      expect(find.byIcon(Icons.lock), findsOneWidget);
      expect(find.byIcon(Icons.add), findsNothing);
      expect(find.byIcon(Icons.remove), findsNothing);

      await tester.tap(find.byType(CanvasScaleBar));
      expect(tapped, isTrue);
    });
  });
}
