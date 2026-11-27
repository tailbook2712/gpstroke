import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:walk_tracker_app/artwork.dart';
import 'package:walk_tracker_app/artwork_home_view.dart';
import 'package:walk_tracker_app/draft_store.dart';
import 'package:walk_tracker_app/polyline_painter.dart';
import 'package:walk_tracker_app/utils/trajectory_usage.dart';

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

/// 下書きのストロークが参照する軌跡（サムネイル用）
final _draftTrajectory = [
  _position(41.8418, 140.7669),
  _position(41.8428, 140.7689),
  _position(41.8418, 140.7709),
];

/// Firestore に保存される形の下書き（軌跡は ID で参照する）
Map<String, dynamic> _draft({
  required String timestamp,
  double? scaleBarDistance,
  int trajectoryCount = 1,
}) {
  return {
    'draftId': 'draft_$timestamp',
    'updatedAt': Timestamp.fromDate(DateTime.parse(timestamp)),
    'canvasWidth': 390.0,
    'canvasHeight': 640.0,
    if (scaleBarDistance != null) 'scaleBarDistance': scaleBarDistance,
    'strokes': [
      for (var i = 0; i < trajectoryCount; i++)
        Stroke(
          trajectoryId: 'walk-$i',
          x: (0.3 + 0.2 * i) * 390.0,
          y: 0.4 * 640.0,
          scale: 1.5,
          rotation: 0.3,
        ).toMap(),
    ],
  };
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required List<List<Position>> trajectories,
  List<Map<String, dynamic>>? drafts = const [],
  ValueChanged<double>? onCreate,
  ValueChanged<Map<String, dynamic>>? onOpenDraft,
  ValueChanged<Map<String, dynamic>>? onDeleteDraft,
  Size screen = const Size(390, 760),
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ArtworkHomeView(
        trajectories: trajectories,
        // 画面下部の軌跡リスト分を除いたキャンバス
        canvasSize: Size(screen.width, screen.height - 120),
        drafts: drafts,
        onCreate: onCreate ?? (_) {},
        onOpenDraft: onOpenDraft ?? (_) {},
        onDeleteDraft: onDeleteDraft,
        pointsOf: (trajectoryId) =>
            trajectoryId.startsWith('walk-') ? _draftTrajectory : null,
      ),
    ),
  ));
  // 読み込み中の表示はアニメーションが止まらないため、収束は待たない
  await tester.pump();
}

void main() {
  group('ArtworkHomeView 新しく作る', () {
    testWidgets('手持ちの軌跡から推奨スケールを示し、最初から選択している', (tester) async {
      await _pumpHome(tester, trajectories: [
        _eastward(500),
        _eastward(1000),
        _eastward(5000),
      ]);

      // 中央値 1km → 500m を推奨
      expect(find.text('おすすめ'), findsOneWidget);
      expect(find.text('500m で制作を始める'), findsOneWidget);
    });

    testWidgets('選択中のスケールで素材として使える軌跡の本数を示す', (tester) async {
      await _pumpHome(tester, trajectories: [
        _eastward(100),
        _eastward(1000),
        _eastward(1200),
        _eastward(5000),
      ]);

      // 500m（短辺 約2.4km、下限 150m）: 5km は大きすぎ、100m は小さすぎる
      expect(find.text('500m で制作を始める'), findsOneWidget);
      expect(find.text('使える軌跡 2 / 4本'), findsOneWidget);
      expect(find.text('大きすぎ 1本・小さすぎ 1本'), findsOneWidget);

      // 1km（短辺 約4.9km、下限 300m）: 5km も大きすぎる
      await tester.tap(find.byTooltip('スケールを大きくする'));
      await tester.pump();
      expect(find.text('使える軌跡 2 / 4本'), findsOneWidget);
      expect(find.text('大きすぎ 1本・小さすぎ 1本'), findsOneWidget);

      // 2km（短辺 約9.8km、下限 600m）: 5km が収まる
      await tester.tap(find.byTooltip('スケールを大きくする'));
      await tester.pump();
      expect(find.text('使える軌跡 3 / 4本'), findsOneWidget);
      expect(find.text('小さすぎ 1本'), findsOneWidget);
    });

    testWidgets('数値を変えると、カードの軌跡の大きさが変わる', (tester) async {
      await _pumpHome(tester, trajectories: [_eastward(1000)]);

      // カード内の軌跡（下書きがないので、軌跡を描く CustomPaint はこれだけ）
      final trajectory = find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is PolylinePainter);
      final sizeAt500m = tester.getSize(trajectory);

      await tester.tap(find.byTooltip('スケールを大きくする'));
      await tester.pump();
      // 500m → 1km で半分の大きさになる
      expect(tester.getSize(trajectory).width,
          closeTo(sizeAt500m.width / 2, 0.01));

      await tester.tap(find.byTooltip('スケールを小さくする'));
      await tester.pump();
      expect(tester.getSize(trajectory), sizeAt500m);
    });

    testWidgets('選んだスケールで新しいキャンバスを始められる', (tester) async {
      double? created;
      await _pumpHome(
        tester,
        trajectories: [_eastward(1000)],
        onCreate: (scale) => created = scale,
      );

      // 500m → 1km → 2km
      await tester.tap(find.byTooltip('スケールを大きくする'));
      await tester.pump();
      await tester.tap(find.byTooltip('スケールを大きくする'));
      await tester.pump();
      expect(find.text('2km で制作を始める'), findsOneWidget);
      // おすすめの目印は、おすすめのスケールを選んでいるときだけ出す
      expect(find.text('おすすめ'), findsNothing);
      expect(find.textContaining('おすすめは'), findsNothing);

      await tester.tap(find.text('2km で制作を始める'));
      expect(created, 2000);

      // おすすめのスケールに戻すと、目印も戻る
      await tester.tap(find.byTooltip('スケールを小さくする'));
      await tester.pump();
      await tester.tap(find.byTooltip('スケールを小さくする'));
      await tester.pump();
      expect(find.text('500m で制作を始める'), findsOneWidget);
      expect(find.text('おすすめ'), findsOneWidget);
    });

    testWidgets('スライダーでもスケールを変えられる', (tester) async {
      await _pumpHome(tester, trajectories: [_eastward(1000)]);

      // 右端までドラッグすると最大の 10km になり、それ以上は大きくできない
      await tester.drag(find.byType(Slider), const Offset(400, 0));
      await tester.pump();
      expect(find.text('10km で制作を始める'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add))
            .onPressed,
        isNull,
      );
    });

    testWidgets('軌跡がなければ推奨は出さず、既定の 500m を選択している', (tester) async {
      await _pumpHome(tester, trajectories: const []);

      expect(find.text('おすすめ'), findsNothing);
      expect(find.text('500m で制作を始める'), findsOneWidget);
      expect(find.text('軌跡はまだありません'), findsOneWidget);
    });
  });

  group('ArtworkHomeView 下書きから続ける', () {
    testWidgets('下書きを日時・スケール・軌跡の本数つきで並べ、タップで開く', (tester) async {
      Map<String, dynamic>? opened;
      final drafts = [
        _draft(
          timestamp: '2026-11-15T18:30:00.000',
          scaleBarDistance: 1000,
          trajectoryCount: 2,
        ),
        // スケール固定の導入前に保存された下書き（scaleBarDistance なし）
        _draft(timestamp: '2026-10-01T09:05:00.000'),
      ];
      await _pumpHome(
        tester,
        trajectories: const [],
        drafts: drafts,
        onOpenDraft: (draft) => opened = draft,
      );

      expect(find.text('2件'), findsOneWidget);
      expect(find.text('2026/11/15 18:30'), findsOneWidget);
      expect(find.text('スケール 1km・軌跡 2本'), findsOneWidget);
      expect(find.text('スケール 500m・軌跡 1本'), findsOneWidget);

      await tester.tap(find.text('2026/11/15 18:30'));
      expect(opened, same(drafts.first));
    });

    testWidgets('確認のうえで下書きを削除できる', (tester) async {
      Map<String, dynamic>? deleted;
      final draft =
          _draft(timestamp: '2026-11-15T18:30:00.000', scaleBarDistance: 500);
      await _pumpHome(
        tester,
        trajectories: const [],
        drafts: [draft],
        onDeleteDraft: (d) => deleted = d,
      );

      await tester.tap(find.byTooltip('下書きを削除'));
      await tester.pumpAndSettle();
      expect(find.text('下書きを削除しますか？'), findsOneWidget);

      // キャンセルでは削除しない
      await tester.tap(find.text('キャンセル'));
      await tester.pumpAndSettle();
      expect(deleted, isNull);

      await tester.tap(find.byTooltip('下書きを削除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('削除'));
      await tester.pumpAndSettle();
      expect(deleted, same(draft));
    });

    testWidgets('下書きがなければ案内を出す', (tester) async {
      await _pumpHome(tester, trajectories: const [], drafts: const []);
      expect(find.textContaining('まだ下書きはありません'), findsOneWidget);
    });

    testWidgets('読み込み中は進行表示を出す', (tester) async {
      await _pumpHome(tester, trajectories: const [], drafts: null);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('中身が読めなかった下書きがあっても表示できる', (tester) async {
      await _pumpHome(
        tester,
        trajectories: const [],
        drafts: [
          {'filePath': '/drafts/broken.json', 'timestamp': '不明な日時'},
        ],
      );
      expect(tester.takeException(), isNull);
      expect(find.text('日時不明'), findsOneWidget);
    });
  });

  testWidgets('小さい画面でもレイアウトが崩れない', (tester) async {
    await _pumpHome(
      tester,
      trajectories: [_eastward(300), _eastward(20000)],
      drafts: [
        _draft(timestamp: '2026-11-15T18:30:00.000', scaleBarDistance: 10000),
        _draft(timestamp: '2026-11-14T08:00:00.000', scaleBarDistance: 50),
      ],
      screen: const Size(320, 568),
    );
    expect(tester.takeException(), isNull);
  });

  test('TrajectoryUsage は作品・下書きの strokes から使われている軌跡を集める', () {
    const stroke = Stroke(trajectoryId: 'a', x: 0, y: 0);
    final used = TrajectoryUsage.usedTrajectoryIds([
      [stroke, const Stroke(trajectoryId: 'b', x: 1, y: 1)],
      const [],
      [stroke],
    ]);
    expect(used, {'a', 'b'});
  });

  test('DraftStore.newestFirst は新しい順に並べ、日時不明を末尾に置く', () {
    final sorted = DraftStore.newestFirst([
      // 以前の形式（文字列の timestamp）も読める
      {'id': 'old', 'timestamp': '2026-10-01T09:05:00.000'},
      {'id': 'unknown', 'timestamp': '不明な日時'},
      {'id': 'new', 'updatedAt': Timestamp.fromDate(DateTime(2026, 11, 15, 18, 30))},
    ]);
    expect(sorted.map((d) => d['id']), ['new', 'old', 'unknown']);
  });
}
