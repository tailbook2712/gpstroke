import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:walk_tracker_app/utils/trajectory_filter.dart';

final _t0 = DateTime(2026, 11, 22, 10);

/// 緯度方向に [meters] 進んだ点（1e-5 度 ≒ 1.11m）
Position _fix(double meters, int sec,
    {double speed = -1, double accuracy = 5}) {
  return Position(
    latitude: 35.0 + meters / 111195.0,
    longitude: 135.0,
    timestamp: _t0.add(Duration(seconds: sec)),
    accuracy: accuracy,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: speed,
    speedAccuracy: 0,
  );
}

void main() {
  test('徒歩の速度ならすべて記録され、距離が累積される', () {
    final f = TrajectoryPointFilter();
    final out = [
      for (var i = 0; i < 5; i++) ...f.add(_fix(i * 10.0, i * 7, speed: 1.4)),
    ];
    expect(out.length, 5);
    expect(out.first.startsNewSegment, isTrue);
    expect(out.skip(1).every((p) => !p.startsNewSegment), isTrue);
    final total = out.fold<double>(0, (s, p) => s + p.distanceMeters);
    expect(total, closeTo(40, 0.5));
  });

  test('精度の悪い測位は捨てる', () {
    final f = TrajectoryPointFilter();
    expect(f.add(_fix(0, 0, accuracy: 120)), isEmpty);
    expect(f.add(_fix(0, 1, accuracy: 5)).length, 1);
  });

  test('ドップラー速度が上限を超えた点は記録しない', () {
    final f = TrajectoryPointFilter();
    expect(f.add(_fix(0, 0, speed: 1.4)).length, 1);
    expect(f.add(_fix(100, 5, speed: 15)), isEmpty); // 54 km/h
    expect(f.isSuspendedForSpeed, isTrue);
  });

  test('ドップラー速度が無い場合は距離÷時間で判定する', () {
    final f = TrajectoryPointFilter();
    expect(f.add(_fix(0, 0)).length, 1);
    // 10 秒で 200m = 72 km/h
    expect(f.add(_fix(200, 10)), isEmpty);
    expect(f.isSuspendedForSpeed, isTrue);
  });

  test('車移動の後は一定時間低速が続くまで保留し、再開時は区間を分ける', () {
    final f = TrajectoryPointFilter();
    f.add(_fix(0, 0, speed: 1.4));
    f.add(_fix(10, 7, speed: 1.4));
    // 車で 3km 移動
    for (var i = 1; i <= 10; i++) {
      expect(f.add(_fix(10 + i * 300.0, 7 + i * 20, speed: 15)), isEmpty);
    }
    // 渋滞で一時的に低速 → まだ保留
    expect(f.add(_fix(3020, 230, speed: 2)), isEmpty);
    // 再び高速 → 保留分は破棄
    expect(f.add(_fix(3400, 250, speed: 15)), isEmpty);
    // 降車して歩く
    expect(f.add(_fix(3410, 260, speed: 1.4)), isEmpty);
    expect(f.add(_fix(3420, 290, speed: 1.4)), isEmpty);
    final resumed = f.add(_fix(3430, 320, speed: 1.4));
    expect(f.isSuspendedForSpeed, isFalse);
    expect(resumed.length, 3);
    expect(resumed.first.startsNewSegment, isTrue);
    expect(resumed.first.position.timestamp, _t0.add(const Duration(seconds: 260)));
    expect(resumed[1].startsNewSegment, isFalse);
    expect(resumed[1].distanceMeters, closeTo(10, 0.5));
  });

  test('単発の速度スパイク後、近くで再開した場合は同じ区間として繋ぐ', () {
    final f = TrajectoryPointFilter();
    f.add(_fix(0, 0, speed: 1.4));
    expect(f.add(_fix(10, 7, speed: 12)), isEmpty); // 誤測位
    f.add(_fix(20, 14, speed: 1.4));
    final resumed = f.add(_fix(30, 75, speed: 1.4));
    expect(resumed.length, 2);
    expect(resumed.every((p) => !p.startsNewSegment), isTrue);
  });

  test('ノイズ程度の移動は捨てる', () {
    final f = TrajectoryPointFilter();
    f.add(_fix(0, 0, speed: 0.5));
    expect(f.add(_fix(1, 5, speed: 0.5)), isEmpty);
  });
}
