import 'package:flutter_test/flutter_test.dart';
import 'package:walk_tracker_app/artwork_share_service.dart';
import 'package:walk_tracker_app/utils/polyline_codec.dart';

Map<String, dynamic> _trajectory({
  required List<List<double>> latLngs,
  required String firstTimestamp,
  double? absoluteX,
  double? absoluteY,
  double? dx,
  double? dy,
  double scale = 1.0,
  double rotation = 0.0,
  Map<String, dynamic>? details,
}) {
  return {
    'positions': latLngs
        .asMap()
        .entries
        .map((e) => {
              'latitude': e.value[0],
              'longitude': e.value[1],
              'timestamp': e.key == 0 ? firstTimestamp : '',
            })
        .toList(),
    'position': {
      if (absoluteX != null) 'absoluteX': absoluteX,
      if (absoluteY != null) 'absoluteY': absoluteY,
      if (dx != null) 'dx': dx,
      if (dy != null) 'dy': dy,
    },
    'scale': scale,
    'rotation': rotation,
    if (details != null) 'details': details,
  };
}

void main() {
  group('ArtworkShareService.buildSharePayload', () {
    test('作品ファイルから記録順に並んだ共有データを生成する', () async {
      final data = {
        'canvasWidth': 390.0,
        'canvasHeight': 700.0,
        'trajectories': [
          // 新しい方（後にソートされるべき）
          _trajectory(
            latLngs: [
              [35.0, 135.0],
              [35.001, 135.001],
            ],
            firstTimestamp: '2026-09-02T08:00:00.000Z',
            absoluteX: 100.0,
            absoluteY: 200.0,
            scale: 1.5,
            rotation: 0.3,
            details: {
              'groupId': 'g-new',
              'date': '2026-09-02T08:00:00.000Z',
              'steps': 1200,
              'distance': 0.9,
            },
          ),
          // 古い方（先頭に来るべき）
          _trajectory(
            latLngs: [
              [36.0, 136.0],
              [36.002, 136.002],
            ],
            firstTimestamp: '2026-09-01T07:30:00.000Z',
            absoluteX: 250.0,
            absoluteY: 400.0,
            details: {
              'groupId': 'g-old',
              'date': '2026-09-01T07:30:00.000Z',
              'steps': 800,
              'distance': 0.6,
            },
          ),
        ],
        'meta': {
          'artworkName': ' 朝の散歩 ',
          'artworkId': 'art-1',
          'createdAt': '2026-09-03T00:00:00.000Z',
        },
      };

      final payload = await ArtworkShareService.buildSharePayload(
        data,
        shareId: 'share123',
        ownerUid: 'uid-1',
      );

      expect(payload['version'], ArtworkShareService.payloadVersion);
      expect(payload['shareId'], 'share123');
      expect(payload['ownerUid'], 'uid-1');
      expect(payload['artworkId'], 'art-1');
      expect(payload['artworkName'], '朝の散歩');
      expect(payload['createdAt'], '2026-09-03T00:00:00.000Z');
      expect(payload['canvasWidth'], 390.0);
      expect(payload['canvasHeight'], 700.0);
      expect(payload['strokeCount'], 2);
      expect(payload['totalSteps'], 2000);
      expect(payload['totalDistance'], closeTo(1.5, 1e-9));

      final strokes = payload['strokes'] as List<Map<String, dynamic>>;
      expect(strokes.map((s) => s['groupId']), ['g-old', 'g-new']);

      final newer = strokes[1];
      expect(newer['x'], 100.0);
      expect(newer['y'], 200.0);
      expect(newer['scale'], 1.5);
      expect(newer['rotation'], 0.3);
      expect(newer['steps'], 1200);
      expect(newer['distance'], 0.9);
      expect(newer['date'], '2026-09-02T08:00:00.000Z');
      expect(newer['pointCount'], 2);

      final decoded = decodePolyline(newer['polyline'] as String);
      expect(decoded[0]['latitude'], closeTo(35.0, 1e-9));
      expect(decoded[1]['longitude'], closeTo(135.001, 1e-9));
    });

    test('旧形式（相対座標）の位置はキャンバスサイズから絶対座標に変換する', () async {
      final data = {
        'canvasWidth': 400.0,
        'canvasHeight': 800.0,
        'trajectories': [
          _trajectory(
            latLngs: [
              [35.0, 135.0],
              [35.001, 135.001],
            ],
            firstTimestamp: '2026-09-01T07:30:00.000Z',
            dx: 0.25,
            dy: 0.5,
            details: {'groupId': 'g', 'date': '', 'steps': 10, 'distance': 0.1},
          ),
        ],
        'meta': {'artworkName': 'x'},
      };

      final payload = await ArtworkShareService.buildSharePayload(
        data,
        shareId: 's',
        ownerUid: 'u',
      );
      final stroke = (payload['strokes'] as List).first as Map<String, dynamic>;
      expect(stroke['x'], 100.0);
      expect(stroke['y'], 400.0);
    });

    test('詳細情報が欠けている場合は detailsLookup で補完する', () async {
      final data = {
        'canvasWidth': 400.0,
        'canvasHeight': 800.0,
        'trajectories': [
          _trajectory(
            latLngs: [
              [35.0, 135.0],
              [35.001, 135.001],
            ],
            firstTimestamp: '',
            absoluteX: 10.0,
            absoluteY: 20.0,
            // details なし（古い作品ファイル）
          ),
        ],
        'meta': {'artworkName': ''},
      };

      final lookedUp = <String>[];
      final payload = await ArtworkShareService.buildSharePayload(
        data,
        shareId: 's',
        ownerUid: 'u',
        detailsLookup: (groupId) async {
          lookedUp.add(groupId);
          return {
            'date': '2026-08-31T12:00:00.000Z',
            'steps': 345,
            'distance': 0.25,
          };
        },
      );

      expect(lookedUp.length, 1);
      expect(lookedUp.single, isNotEmpty); // 座標から生成された groupId
      expect(payload['artworkName'], '無題の作品');
      final stroke = (payload['strokes'] as List).first as Map<String, dynamic>;
      expect(stroke['date'], '2026-08-31T12:00:00.000Z');
      expect(stroke['steps'], 345);
      expect(stroke['distance'], 0.25);
    });

    test('ストロークが無い作品は例外になる', () {
      expect(
        () => ArtworkShareService.buildSharePayload(
          {'canvasWidth': 1.0, 'canvasHeight': 1.0, 'trajectories': []},
          shareId: 's',
          ownerUid: 'u',
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('共有 ID', () {
    test('deriveShareId は同じユーザー・作品なら常に同じ URL 安全な 20 文字を返す', () {
      final a = ArtworkShareService.deriveShareId(
          ownerUid: 'uid-1', artworkKey: 'art-1');
      final b = ArtworkShareService.deriveShareId(
          ownerUid: 'uid-1', artworkKey: 'art-1');
      expect(a, b);
      expect(a, matches(RegExp(r'^[A-Za-z0-9_-]{20}$')));
    });

    test('deriveShareId はユーザーまたは作品が違えば別の ID になる', () {
      final base = ArtworkShareService.deriveShareId(
          ownerUid: 'uid-1', artworkKey: 'art-1');
      expect(
          ArtworkShareService.deriveShareId(
              ownerUid: 'uid-2', artworkKey: 'art-1'),
          isNot(base));
      expect(
          ArtworkShareService.deriveShareId(
              ownerUid: 'uid-1', artworkKey: 'art-2'),
          isNot(base));
    });

    test('resolveShareId は保存済み shareId → 作品 ID 導出 → ランダムの順で決める', () {
      expect(
        ArtworkShareService.resolveShareId(
            {'meta': {'artworkId': 'art-1', 'shareId': 'keep-this'}}, 'uid-1'),
        'keep-this',
      );
      expect(
        ArtworkShareService.resolveShareId({'meta': {'artworkId': 'art-1'}}, 'uid-1'),
        ArtworkShareService.deriveShareId(ownerUid: 'uid-1', artworkKey: 'art-1'),
      );
      final random1 = ArtworkShareService.resolveShareId({'meta': {}}, 'uid-1');
      final random2 = ArtworkShareService.resolveShareId({'meta': {}}, 'uid-1');
      expect(random1, matches(RegExp(r'^[A-Za-z0-9]{20}$')));
      expect(random1, isNot(random2));
    });
  });

  test('generateShareId は英数字 20 文字を返す', () {
    final id = ArtworkShareService.generateShareId();
    expect(id, matches(RegExp(r'^[A-Za-z0-9]{20}$')));
    expect(ArtworkShareService.buildShareUrl(id),
        'https://tailbook2712.github.io/gpstroke/share/?id=$id');
  });
}
