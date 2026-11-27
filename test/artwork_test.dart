import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import 'package:walk_tracker_app/artwork.dart';
import 'package:walk_tracker_app/artwork_share_service.dart';
import 'package:walk_tracker_app/artwork_store.dart';
import 'package:walk_tracker_app/legacy_canvas_conversion.dart';
import 'package:walk_tracker_app/trajectory.dart';
import 'package:walk_tracker_app/utils/utils.dart';

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

Trajectory _trajectory(String id, double startLatitude,
    {TrajectorySource source = TrajectorySource.gps}) {
  final start = DateTime.utc(2026, 11, 20, 8, 0);
  return Trajectory(
    id: id,
    source: source,
    points: [
      _position(startLatitude, 140.75, start),
      _position(startLatitude + 0.001, 140.751, start.add(const Duration(seconds: 30))),
      _position(startLatitude + 0.002, 140.749, start.add(const Duration(seconds: 60))),
    ],
    distanceKm: 0.25,
    steps: 320,
  );
}

/// 以前の形式（作品・下書き）にコピーされていた軌跡
List<Map<String, dynamic>> _copiedPositions(Trajectory trajectory) => [
      for (final p in trajectory.points)
        {
          'latitude': p.latitude,
          'longitude': p.longitude,
          'timestamp': p.timestamp.toIso8601String(),
        },
    ];

void main() {
  final walkA = _trajectory('walk-a', 41.78);
  final walkB = _trajectory('walk-b', 41.80);
  final placedAt = DateTime(2026, 11, 21, 10, 0);

  Artwork artwork({String? shareId}) => Artwork(
        id: 'artwork_1795749749920',
        name: '函館の鳥',
        createdAt: DateTime(2026, 11, 26, 15, 0),
        updatedAt: DateTime(2026, 11, 26, 15, 5),
        canvasWidth: 390.0,
        canvasHeight: 707.0,
        scaleBarDistance: 500.0,
        strokes: [
          Stroke(
              trajectoryId: 'walk-a',
              x: 202.3,
              y: 255.6,
              scale: 3.77,
              rotation: 0.0,
              placedAt: placedAt),
          const Stroke(trajectoryId: 'walk-b', x: 177.3, y: 244.6, scale: 3.36, rotation: 1.48),
        ],
        totalDistanceKm: 0.5,
        totalSteps: 640,
        shareId: shareId,
      );

  group('Artwork の保存形式', () {
    test('保存して読み直すと同じ内容になる', () {
      final restored =
          Artwork.fromFirestore('artwork_1795749749920', artwork(shareId: 'abc').toFirestore());

      expect(restored.name, '函館の鳥');
      expect(restored.createdAt, DateTime(2026, 11, 26, 15, 0));
      expect(restored.updatedAt, DateTime(2026, 11, 26, 15, 5));
      expect(restored.canvasWidth, 390.0);
      expect(restored.scaleBarDistance, 500.0);
      expect(restored.totalSteps, 640);
      expect(restored.shareId, 'abc');
      expect(restored.strokes.map((s) => s.trajectoryId), ['walk-a', 'walk-b']);
      expect(restored.strokes.first.placedAt, placedAt);
      expect(restored.strokes.last.placedAt, isNull);
      expect(restored.strokes.last.rotation, 1.48);
    });

    test('座標のコピーや画像は持たない', () {
      final data = artwork().toFirestore();
      expect(data.containsKey('trajectories'), isFalse);
      expect(data.containsKey('imageData'), isFalse);
      expect(data['schemaVersion'], Artwork.schemaVersion);
      expect((data['strokes'] as List).first['placedAt'], Timestamp.fromDate(placedAt));
    });

    test('以前の形式のドキュメントは読まない（変換が必要）', () {
      expect(
        () => Artwork.fromFirestore('old', {'trajectories': [], 'canvasWidth': 390}),
        throwsFormatException,
      );
    });

    test('Stroke.listFrom は読めない要素を飛ばす', () {
      final strokes = Stroke.listFrom([
        {'trajectoryId': 'a', 'x': 1, 'y': 2},
        {'trajectoryId': '', 'x': 1, 'y': 2},
        {'x': 1, 'y': 2},
        'broken',
      ]);
      expect(strokes.single.trajectoryId, 'a');
      expect(strokes.single.x, 1.0);
    });
  });

  group('作品詳細・共有に渡すキャンバスの状態', () {
    test('以前の作品ファイルと同じ形にし、座標は軌跡から埋める', () {
      final data = artwork(shareId: 'abc')
          .toCanvasData({'walk-a': walkA, 'walk-b': walkB});

      expect(data['canvasWidth'], 390.0);
      final items = data['trajectories'] as List;
      expect(items.length, 2);
      final first = items.first as Map;
      expect((first['positions'] as List).length, walkA.points.length);
      expect(first['position']['absoluteX'], 202.3);
      expect(first['position']['dx'], closeTo(202.3 / 390.0, 1e-9));
      expect(first['scale'], 3.77);
      expect(first['details']['groupId'], 'walk-a');
      expect(first['details']['steps'], 320);
      expect(first['details']['date'], walkA.startedAt.toIso8601String());
      expect(DateTime.parse(first['placedAt'] as String).isAtSameMomentAs(placedAt),
          isTrue);
      expect(data['meta']['artworkName'], '函館の鳥');
      expect(data['meta']['shareId'], 'abc');
    });

    test('軌跡が見つからないストロークは含めない', () {
      final data = artwork().toCanvasData({'walk-b': walkB});
      final items = data['trajectories'] as List;
      expect(items.single['details']['groupId'], 'walk-b');
      expect(data['meta']['trajectoryCount'], 1);
    });

    test('共有データを組み立てられる（作品に保存した共有 ID を使う）', () async {
      final data = artwork(shareId: 'saved-share-id')
          .toCanvasData({'walk-a': walkA, 'walk-b': walkB});
      expect(ArtworkShareService.resolveShareId(data, 'uid'), 'saved-share-id');

      final payload = await ArtworkShareService.buildSharePayload(
        data,
        shareId: 'saved-share-id',
        ownerUid: 'uid',
      );
      expect(payload['strokeCount'], 2);
      expect(payload['artworkName'], '函館の鳥');
      expect(payload['totalSteps'], 640);
    });
  });

  group('以前の形式からの変換', () {
    test('保存されている groupId → 座標の照合 → 座標から作る、の順で軌跡を決める', () {
      final resolver = LegacyStrokeResolver([walkA, walkB]);

      // 1. groupId が手持ちにある
      expect(resolver.resolve({'groupId': 'walk-a', 'positions': []}), 'walk-a');
      expect(
          resolver.resolve({
            'details': {'groupId': 'walk-b'},
            'positions': [],
          }),
          'walk-b');

      // 2. groupId がない・手持ちにない ID でも、座標が一致すれば手持ちの軌跡
      expect(resolver.resolve({'positions': _copiedPositions(walkA)}), 'walk-a');
      expect(
          resolver.resolve({
            'details': {'groupId': 'generated-hash'},
            'positions': _copiedPositions(walkB),
          }),
          'walk-b');
      expect(resolver.created, isEmpty);

      // 3. 手持ちにない軌跡は、コピーされている座標から作る
      final unknown = _trajectory('x', 35.0);
      final id = resolver.resolve({
        'positions': _copiedPositions(unknown),
        'details': {'distance': 1.5, 'steps': 2000},
      });
      expect(id, generateGroupId(unknown.points));
      expect(resolver.created.single.id, id);
      expect(resolver.created.single.distanceKm, 1.5);
      expect(resolver.created.single.steps, 2000);

      // 同じ座標をもう一度変換しても、作り直さない
      expect(resolver.resolve({'positions': _copiedPositions(unknown)}), id);
      expect(resolver.created.length, 1);

      // 保存されていた ID はそのまま使う
      final other = _trajectory('y', 36.0);
      expect(
          resolver.resolve({
            'groupId': 'garmin_1795573553021',
            'positions': _copiedPositions(other),
          }),
          'garmin_1795573553021');
      expect(resolver.created.last.source, TrajectorySource.imported);

      // 座標を読めない軌跡は null
      expect(resolver.resolve({'positions': 'broken'}), isNull);
    });

    test('作品: 絶対座標・メタデータ・共有 ID を引き継ぐ', () {
      final converted = convertLegacyArtwork(
        'artwork_1795669132262',
        {
          'canvasWidth': 390.0,
          'canvasHeight': 707.6,
          'imageData': 'base64...',
          'timestamp': '2026-11-20T09:00:00.000',
          'trajectories': [
            {
              'positions': _copiedPositions(walkA),
              'position': {'dx': 0.5, 'dy': 0.4, 'absoluteX': 202.3, 'absoluteY': 255.6},
              'scale': 3.77,
              'rotation': 0,
              'placedAt': '2026-11-20T08:59:00.000',
              'details': {'groupId': 'walk-a'},
            },
            // 絶対座標を持たない古い作品
            {
              'positions': _copiedPositions(walkB),
              'position': {'dx': 0.25, 'dy': 0.5},
            },
          ],
          'meta': {
            'artworkName': ' 函館の鳥 ',
            'createdAt': '2026-11-20T08:59:30.000',
            'totalDistance': 0.5,
            'totalSteps': 640,
            'scaleBarDistance': 500,
            'shareId': 'P5J94wMXekzsN_RjhtSH',
          },
        },
        LegacyStrokeResolver([walkA, walkB]),
      );

      expect(converted.name, '函館の鳥');
      expect(converted.createdAt, DateTime(2026, 11, 20, 8, 59, 30));
      expect(converted.scaleBarDistance, 500.0);
      expect(converted.totalSteps, 640);
      expect(converted.shareId, 'P5J94wMXekzsN_RjhtSH');
      expect(converted.strokes.map((s) => s.trajectoryId), ['walk-a', 'walk-b']);
      expect(converted.strokes.first.x, 202.3);
      expect(converted.strokes.first.rotation, 0.0);
      expect(converted.strokes.first.placedAt, DateTime(2026, 11, 20, 8, 59));
      expect(converted.strokes.last.x, closeTo(0.25 * 390.0, 1e-9));
      expect(converted.strokes.last.y, closeTo(0.5 * 707.6, 1e-9));
    });

    test('作品: 作成日時がなければ作品 ID の時刻を使い、名前がなければ無題にする', () {
      final converted = convertLegacyArtwork(
        'artwork_1795669132262',
        {
          'canvasWidth': 390,
          'canvasHeight': 700,
          'trajectories': [],
        },
        LegacyStrokeResolver(const []),
      );
      expect(converted.createdAt,
          DateTime.fromMillisecondsSinceEpoch(1795669132262));
      expect(converted.name, '無題の作品');
      expect(converted.shareId, isNull);
    });

    test('作品: キャンバスの大きさがなければ FormatException', () {
      expect(
        () => convertLegacyArtwork('a', {'trajectories': []}, LegacyStrokeResolver(const [])),
        throwsFormatException,
      );
    });

    test('下書き: 位置を割合から px にし、保存日時を Timestamp にする（下絵の設定は残す）', () {
      final legacy = {
        'draftId': 'draft_1',
        'canvasWidth': 390.0,
        'canvasHeight': 587.0,
        'scaleBarDistance': 1000.0,
        'timestamp': '2026-11-15T18:30:00.000',
        'hasGuideImage': true,
        'guideImageOpacity': 0.5,
        'trajectories': [
          {
            'positions': _copiedPositions(walkA),
            'position': {'dx': 0.5, 'dy': 0.25},
            'scale': 2.0,
            'rotation': 0.5,
            'groupId': 'walk-a',
          },
        ],
      };
      expect(isLegacyDraft(legacy), isTrue);

      final converted = convertLegacyDraft(legacy, LegacyStrokeResolver([walkA]));
      expect(isLegacyDraft(converted), isFalse);
      expect(converted.containsKey('trajectories'), isFalse);
      expect(converted.containsKey('timestamp'), isFalse);
      expect(converted['updatedAt'],
          Timestamp.fromDate(DateTime(2026, 11, 15, 18, 30)));
      expect(converted['guideImageOpacity'], 0.5);
      expect(converted['draftId'], 'draft_1');

      final stroke = Stroke.listFrom(converted['strokes']).single;
      expect(stroke.trajectoryId, 'walk-a');
      expect(stroke.x, 195.0);
      expect(stroke.y, closeTo(146.75, 1e-9));
      expect(stroke.scale, 2.0);
    });

    test('下書き: 保存日時が分からない場合は updatedAt を入れない', () {
      final converted = convertLegacyDraft({
        'canvasWidth': 390.0,
        'canvasHeight': 587.0,
        'timestamp': '不明な日時',
        'trajectories': [],
      }, LegacyStrokeResolver(const []));
      expect(converted.containsKey('updatedAt'), isFalse);
      expect(converted['strokes'], isEmpty);
    });

    test('下書き: 読めない下書きはそのまま返す', () {
      final broken = {'draftId': 'broken', 'trajectories': []};
      expect(convertLegacyDraft(broken, LegacyStrokeResolver(const [])),
          same(broken));
    });
  });

  test('作品画像は長辺 1600px 以下・Firestore に収まる PNG にする', () {
    final large = img.Image(width: 3000, height: 1500);
    img.fill(large, color: img.ColorRgb8(240, 240, 240));
    img.drawLine(large, x1: 0, y1: 0, x2: 2999, y2: 1499, color: img.ColorRgb8(0, 0, 255), thickness: 8);
    final original = Uint8List.fromList(img.encodePng(large));

    final compressed = ArtworkStore.compressArtworkImage(original);
    expect(compressed.width, 1600);
    expect(compressed.height, 800);
    expect(compressed.bytes.length, lessThanOrEqualTo(ArtworkStore.maxImageBytes));
    expect(img.decodePng(compressed.bytes), isNotNull);
  });
}
