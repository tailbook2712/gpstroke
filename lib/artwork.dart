import 'package:cloud_firestore/cloud_firestore.dart';

import 'trajectory.dart';

/// キャンバスに置いた軌跡 1 本（作品・下書きの `strokes` の要素）
///
/// 軌跡そのもの（座標）は持たず、[trajectoryId] で軌跡を参照する
class Stroke {
  /// 参照している軌跡（Trajectory.id）
  final String trajectoryId;

  /// キャンバス上の位置（論理ピクセル。作品・下書きの canvasWidth / canvasHeight の中での座標）
  final double x;
  final double y;

  final double scale;
  final double rotation;

  /// キャンバスに置いた日時（スライドショーの「配置順」に使う。古いデータには無い）
  final DateTime? placedAt;

  const Stroke({
    required this.trajectoryId,
    required this.x,
    required this.y,
    this.scale = 1.0,
    this.rotation = 0.0,
    this.placedAt,
  });

  Map<String, dynamic> toMap() => {
        'trajectoryId': trajectoryId,
        'x': x,
        'y': y,
        'scale': scale,
        'rotation': rotation,
        'placedAt': placedAt == null ? null : Timestamp.fromDate(placedAt!),
      };

  /// 保存データから作る。読めない場合は null
  static Stroke? fromMap(Map<dynamic, dynamic> map) {
    final trajectoryId = map['trajectoryId'];
    final x = map['x'];
    final y = map['y'];
    if (trajectoryId is! String || trajectoryId.isEmpty) return null;
    if (x is! num || y is! num) return null;
    return Stroke(
      trajectoryId: trajectoryId,
      x: x.toDouble(),
      y: y.toDouble(),
      scale: (map['scale'] as num?)?.toDouble() ?? 1.0,
      rotation: (map['rotation'] as num?)?.toDouble() ?? 0.0,
      placedAt: parseTime(map['placedAt']),
    );
  }

  /// 保存データの `strokes` を読む（読めない要素は飛ばす）
  static List<Stroke> listFrom(Object? strokes) {
    if (strokes is! List) return const [];
    return [
      for (final item in strokes.whereType<Map>())
        if (fromMap(item) case final stroke?) stroke,
    ];
  }
}

/// Timestamp か ISO 8601 の文字列を DateTime にする（読めない場合は null）
DateTime? parseTime(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

/// 完成作品
///
/// Firestore の `users/{userId}/artworks/{id}` に、次の形で保存する
/// （読み書きは ArtworkStore が行う。作品画像は `artwork_images/{id}` に別に置く）。
/// ```
/// name               string
/// createdAt          Timestamp
/// updatedAt          Timestamp
/// canvasWidth        number   保存時のキャンバスの大きさ（strokes の x, y はこの中の座標）
/// canvasHeight       number
/// scaleBarDistance   number?  制作時のスケール（m）。古い作品には無い
/// strokes            [Stroke]  配列の順 = 重なり順（奥から手前）
/// totalDistanceKm    number   一覧表示用（軌跡は書き換えないので、保存時に計算して持つ）
/// totalSteps         number
/// shareId            string?  共有したときの共有 ID
/// schemaVersion      2
/// ```
class Artwork {
  /// この形式であることを表す値（以前の形式の作品には無い）
  static const int schemaVersion = 2;

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final double canvasWidth;
  final double canvasHeight;
  final double? scaleBarDistance;
  final List<Stroke> strokes;
  final double totalDistanceKm;
  final int totalSteps;
  final String? shareId;

  const Artwork({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.canvasWidth,
    required this.canvasHeight,
    this.scaleBarDistance,
    required this.strokes,
    required this.totalDistanceKm,
    required this.totalSteps,
    this.shareId,
  });

  /// 新しい形式の作品ドキュメントか（以前の形式は `trajectories` に座標をコピーで持っていた）
  static bool isCurrentFormat(Map<String, dynamic> data) =>
      data['schemaVersion'] == schemaVersion;

  Artwork copyWith({String? shareId, DateTime? updatedAt}) => Artwork(
        id: id,
        name: name,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        canvasWidth: canvasWidth,
        canvasHeight: canvasHeight,
        scaleBarDistance: scaleBarDistance,
        strokes: strokes,
        totalDistanceKm: totalDistanceKm,
        totalSteps: totalSteps,
        shareId: shareId ?? this.shareId,
      );

  Map<String, dynamic> toFirestore() => {
        'name': name,
        'createdAt': Timestamp.fromDate(createdAt),
        'updatedAt': Timestamp.fromDate(updatedAt),
        'canvasWidth': canvasWidth,
        'canvasHeight': canvasHeight,
        'scaleBarDistance': scaleBarDistance,
        'strokes': strokes.map((s) => s.toMap()).toList(),
        'totalDistanceKm': totalDistanceKm,
        'totalSteps': totalSteps,
        'shareId': shareId,
        'schemaVersion': schemaVersion,
      };

  /// 新しい形式の作品ドキュメントから作る。形式が違う・壊れている場合は FormatException
  factory Artwork.fromFirestore(String id, Map<String, dynamic> data) {
    if (!isCurrentFormat(data)) {
      throw FormatException('以前の形式の作品です: $id');
    }
    final canvasWidth = data['canvasWidth'];
    final canvasHeight = data['canvasHeight'];
    if (canvasWidth is! num || canvasHeight is! num) {
      throw FormatException('作品にキャンバスの大きさがありません: $id');
    }
    final createdAt = parseTime(data['createdAt']) ?? DateTime.now();
    return Artwork(
      id: id,
      name: (data['name'] as String?) ?? '無題の作品',
      createdAt: createdAt,
      updatedAt: parseTime(data['updatedAt']) ?? createdAt,
      canvasWidth: canvasWidth.toDouble(),
      canvasHeight: canvasHeight.toDouble(),
      scaleBarDistance: (data['scaleBarDistance'] as num?)?.toDouble(),
      strokes: Stroke.listFrom(data['strokes']),
      totalDistanceKm: (data['totalDistanceKm'] as num?)?.toDouble() ?? 0.0,
      totalSteps: (data['totalSteps'] as num?)?.toInt() ?? 0,
      shareId: data['shareId'] as String?,
    );
  }

  /// 作品詳細画面・共有データの組み立てで使う、キャンバスの状態
  ///
  /// 以前は作品ごとに端末内へ保存していた JSON（座標のコピーを含む）と同じ形にする。
  /// 各ストロークの座標は [trajectories]（軌跡の ID → 軌跡）から埋める。
  /// 参照している軌跡が見つからないストロークは含めない
  Map<String, dynamic> toCanvasData(Map<String, Trajectory> trajectories) {
    final items = <Map<String, dynamic>>[];
    for (final stroke in strokes) {
      final trajectory = trajectories[stroke.trajectoryId];
      if (trajectory == null) continue;
      items.add({
        'positions': [
          for (final p in trajectory.points)
            {
              'latitude': p.latitude,
              'longitude': p.longitude,
              'timestamp': p.timestamp.toUtc().toIso8601String(),
            },
        ],
        'position': {
          'dx': stroke.x / canvasWidth,
          'dy': stroke.y / canvasHeight,
          'absoluteX': stroke.x,
          'absoluteY': stroke.y,
        },
        'scale': stroke.scale,
        'rotation': stroke.rotation,
        'placedAt': stroke.placedAt?.toUtc().toIso8601String(),
        'details': {
          'groupId': trajectory.id,
          'distance': trajectory.distanceKm,
          'steps': trajectory.steps,
          'date': trajectory.startedAt.toUtc().toIso8601String(),
        },
      });
    }

    return {
      'canvasWidth': canvasWidth,
      'canvasHeight': canvasHeight,
      'trajectories': items,
      'meta': {
        'artworkId': id,
        'artworkName': name,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'scaleBarDistance': scaleBarDistance,
        if (shareId != null) 'shareId': shareId,
        'trajectoryCount': items.length,
        'totalDistance': totalDistanceKm,
        'totalSteps': totalSteps,
      },
    };
  }
}
