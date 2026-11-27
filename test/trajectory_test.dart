import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:walk_tracker_app/trajectory.dart';
import 'package:walk_tracker_app/utils/trajectory_usage.dart';

Position _position(double latitude, double longitude, DateTime timestamp) {
  return Position(
    latitude: latitude,
    longitude: longitude,
    timestamp: timestamp,
    accuracy: 0.0,
    altitude: 0.0,
    altitudeAccuracy: 0.0,
    heading: 0.0,
    headingAccuracy: 0.0,
    speed: 0.0,
    speedAccuracy: 0.0,
  );
}

void main() {
  final start = DateTime.utc(2026, 11, 20, 22, 30, 5, 123);
  final points = [
    _position(35.6812345678, 139.7671234567, start),
    _position(35.6813, 139.7672, start.add(const Duration(seconds: 5))),
    _position(35.68141, 139.76735,
        start.add(const Duration(seconds: 10, milliseconds: 456))),
  ];

  group('Trajectory の保存形式', () {
    test('保存して読み直すと、座標（小数 6 桁）と各点の時刻（ミリ秒）が戻る', () {
      final trajectory = Trajectory(
        id: 'abc',
        source: TrajectorySource.healthkit,
        points: points,
        distanceKm: 1.25,
        steps: 1600,
      );

      final restored =
          Trajectory.fromFirestore('abc', trajectory.toFirestore());

      expect(restored.id, 'abc');
      expect(restored.source, TrajectorySource.healthkit);
      expect(restored.distanceKm, 1.25);
      expect(restored.steps, 1600);
      expect(restored.points.length, points.length);
      for (var i = 0; i < points.length; i++) {
        expect(restored.points[i].latitude,
            closeTo(points[i].latitude, 0.5e-6));
        expect(restored.points[i].longitude,
            closeTo(points[i].longitude, 0.5e-6));
        expect(restored.points[i].timestamp, points[i].timestamp);
      }
      expect(restored.startedAt.isUtc, isTrue);
      expect(restored.endedAt, points.last.timestamp);
    });

    test('記録日時・最後の点の時刻は Timestamp で保存する', () {
      final data = Trajectory(
        id: 'abc',
        source: TrajectorySource.gps,
        points: points,
        distanceKm: 1.0,
        steps: 0,
      ).toFirestore();

      expect(data['source'], 'gps');
      expect(data['startedAt'], Timestamp.fromDate(start));
      expect(data['endedAt'], Timestamp.fromDate(points.last.timestamp));
    });

    test('形式が壊れたドキュメントは FormatException', () {
      expect(() => Trajectory.fromFirestore('x', {'polyline': ''}),
          throwsFormatException);
    });
  });

  group('以前の形式からの変換', () {
    final legacyPositions = [
      {
        'latitude': 35.6812345678,
        'longitude': 139.7671234567,
        'timestamp': '2026-11-20T22:30:05.123Z',
      },
      {
        'latitude': 35.6813,
        'longitude': 139.7672,
        'timestamp': '2026-11-20T22:30:10.123Z',
      },
    ];

    test('Firestore の walking_data（アプリで記録）', () {
      final trajectory = Trajectory.fromLegacy({
        'groupId': 'a1b2c3',
        'positions': legacyPositions,
        'date': '2026-11-20T22:30:05.123Z',
        'steps': 120,
        'distance': 0.35,
      })!;

      expect(trajectory.id, 'a1b2c3');
      expect(trajectory.source, TrajectorySource.gps);
      expect(trajectory.startedAt, start);
      expect(trajectory.steps, 120);
      expect(trajectory.distanceKm, 0.35);
    });

    test('端末の SQLite の行（Garmin の印あり）', () {
      final trajectory = Trajectory.fromLegacy({
        'group_id': 'garmin_1763677805123',
        'positions': jsonEncode(legacyPositions),
        'date': '2026-11-21 07:30',
        'steps': 0,
        'distance': 2,
        'is_from_garmin': 1,
      })!;

      expect(trajectory.source, TrajectorySource.garmin);
      expect(trajectory.distanceKm, 2.0);
    });

    test('ID が garmin_ で始まる取り込みは、記録元が分からないものとして扱う', () {
      final trajectory = Trajectory.fromLegacy({
        'group_id': 'garmin_1763677805123',
        'positions': jsonEncode(legacyPositions),
        'is_from_garmin': 0,
      })!;

      expect(trajectory.source, TrajectorySource.imported);
    });

    test('タイムゾーンのない時刻は、端末の時刻として読む', () {
      final trajectory = Trajectory.fromLegacy({
        'groupId': 'hk',
        'positions': [
          {'latitude': 35.0, 'longitude': 139.0, 'timestamp': '2026-11-21T07:30:00.000'},
          {'latitude': 35.1, 'longitude': 139.1, 'timestamp': '2026-11-21T07:31:00.000'},
        ],
      })!;

      expect(trajectory.startedAt,
          DateTime(2026, 11, 21, 7, 30).toUtc());
    });

    test('時刻のない点は、記録日時で補う', () {
      final trajectory = Trajectory.fromLegacy({
        'groupId': 'no-time',
        'positions': [
          {'latitude': 35.0, 'longitude': 139.0},
          {'latitude': 35.1, 'longitude': 139.1},
        ],
        'date': '2026-11-20T22:30:05.123Z',
      })!;

      expect(trajectory.startedAt, start);
    });

    test('読めない行は null', () {
      expect(Trajectory.fromLegacy({'groupId': 'x', 'positions': []}), isNull);
      expect(Trajectory.fromLegacy({'groupId': 'x', 'positions': 'not json'}),
          isNull);
      expect(
          Trajectory.fromLegacy({
            'positions': legacyPositions,
          }),
          isNull);
      expect(
          Trajectory.fromLegacy({
            'groupId': 'x',
            'positions': [
              {'latitude': 'a', 'longitude': 139.0},
            ],
          }),
          isNull);
    });
  });

  test('保存し直した軌跡と、下書きにコピーされている座標の署名が一致する', () {
    final trajectory = Trajectory(
      id: 'abc',
      source: TrajectorySource.gps,
      points: points,
      distanceKm: 1.0,
      steps: 0,
    );
    final restored = Trajectory.fromFirestore('abc', trajectory.toFirestore());

    // 下書き・作品には、保存し直す前の座標がそのままコピーされている
    final copied = points
        .map((p) => {'latitude': p.latitude, 'longitude': p.longitude})
        .toList();

    expect(TrajectoryUsage.signatureOfPositions(restored.points),
        TrajectoryUsage.signatureOfSavedPositions(copied));
  });
}
