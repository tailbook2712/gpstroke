import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:walk_tracker_app/canvas_scale_widgets.dart';

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
