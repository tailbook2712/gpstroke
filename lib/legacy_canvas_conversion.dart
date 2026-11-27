import 'package:cloud_firestore/cloud_firestore.dart';

import 'artwork.dart';
import 'trajectory.dart';
import 'utils/trajectory_usage.dart';
import 'utils/utils.dart';

/// 以前の形式（作品・下書きが軌跡の座標をコピーで持っていた形）からの変換
///
/// コピーされている軌跡 1 本ごとに、参照する手持ちの軌跡（Trajectory）を次の順で決める。
/// 1. 保存されている groupId（下書きは `groupId`、作品は `details.groupId`）が手持ちにあれば、それ
/// 2. 座標の署名（点の数と、最初・中間・最後の点）が一致する手持ちの軌跡
/// 3. どちらでも見つからなければ、コピーされている座標から軌跡を作る
///    （[created] に入る。保存は呼び出し側で行う）
class LegacyStrokeResolver {
  final Map<String, Trajectory> _byId;
  final Map<String, String> _bySignature;

  /// 3. で新しく作った軌跡（まだ保存していない）
  final List<Trajectory> created = [];

  LegacyStrokeResolver(Iterable<Trajectory> trajectories)
      : _byId = {for (final t in trajectories) t.id: t},
        _bySignature = {
          for (final t in trajectories)
            if (TrajectoryUsage.signatureOfPositions(t.points)
                case final signature?)
              signature: t.id,
        };

  /// 以前の形式の軌跡 1 本が参照する軌跡の ID。座標を読めない場合は null
  String? resolve(Map<dynamic, dynamic> item) {
    final details = item['details'];
    final savedIds = <String>[
      for (final value in [
        item['groupId'],
        if (details is Map) details['groupId'],
      ])
        if (value is String && value.isNotEmpty) value,
    ];
    for (final id in savedIds) {
      if (_byId.containsKey(id)) return id;
    }

    final signature =
        TrajectoryUsage.signatureOfSavedPositions(item['positions']);
    final matched = signature == null ? null : _bySignature[signature];
    if (matched != null) return matched;

    // 手持ちにない軌跡は、コピーされている座標から作る
    final copied = Trajectory.fromLegacy({
      'groupId': savedIds.isNotEmpty ? savedIds.first : '_',
      'positions': item['positions'],
      if (details is Map) ...{
        if (details['distance'] is num) 'distance': details['distance'],
        if (details['steps'] is num) 'steps': details['steps'],
        if (details['date'] is String) 'date': details['date'],
      },
    });
    if (copied == null) return null;
    final trajectory = savedIds.isNotEmpty
        ? copied
        : Trajectory(
            // アプリで記録した軌跡と同じく、座標から ID を作る
            id: generateGroupId(copied.points),
            source: copied.source,
            points: copied.points,
            distanceKm: copied.distanceKm,
            steps: copied.steps,
          );

    _byId[trajectory.id] = trajectory;
    if (signature != null) _bySignature[signature] = trajectory.id;
    created.add(trajectory);
    return trajectory.id;
  }
}

/// 以前の形式の作品（Firestore の作品ドキュメント、または端末内の作品ファイル）を
/// 新しい形式にする。キャンバスの大きさか軌跡の一覧を読めない場合は FormatException
Artwork convertLegacyArtwork(
  String artworkId,
  Map<String, dynamic> data,
  LegacyStrokeResolver resolver,
) {
  final meta = data['meta'] is Map
      ? Map<String, dynamic>.from(data['meta'] as Map)
      : <String, dynamic>{};
  final actualSize = data['actualCanvasSize'];
  final canvasWidth = _toDouble(data['canvasWidth']) ??
      (actualSize is Map ? _toDouble(actualSize['width']) : null);
  final canvasHeight = _toDouble(data['canvasHeight']) ??
      (actualSize is Map ? _toDouble(actualSize['height']) : null);
  if (canvasWidth == null ||
      canvasHeight == null ||
      canvasWidth <= 0 ||
      canvasHeight <= 0) {
    throw FormatException('作品にキャンバスの大きさがありません: $artworkId');
  }
  final items = data['trajectories'];
  if (items is! List) {
    throw FormatException('作品に軌跡の一覧がありません: $artworkId');
  }

  final strokes = <Stroke>[];
  for (final item in items.whereType<Map>()) {
    final trajectoryId = resolver.resolve(item);
    if (trajectoryId == null) continue;
    final position = item['position'] is Map ? item['position'] as Map : const {};
    // 絶対座標を持たない古い作品は、相対座標（0〜1）から求める
    strokes.add(Stroke(
      trajectoryId: trajectoryId,
      x: _toDouble(position['absoluteX']) ??
          (_toDouble(position['dx']) ?? 0.5) * canvasWidth,
      y: _toDouble(position['absoluteY']) ??
          (_toDouble(position['dy']) ?? 0.5) * canvasHeight,
      scale: _toDouble(item['scale']) ?? 1.0,
      rotation: _toDouble(item['rotation']) ?? 0.0,
      placedAt: parseTime(item['placedAt']),
    ));
  }

  final createdAt = parseTime(meta['createdAt']) ??
      parseTime(data['timestamp']) ??
      _timeFromArtworkId(artworkId) ??
      DateTime.now();
  final name = (meta['artworkName'] as String?)?.trim();
  final shareId = meta['shareId'];

  return Artwork(
    id: artworkId,
    name: name == null || name.isEmpty ? '無題の作品' : name,
    createdAt: createdAt,
    updatedAt: createdAt,
    canvasWidth: canvasWidth,
    canvasHeight: canvasHeight,
    scaleBarDistance: _toDouble(meta['scaleBarDistance']),
    strokes: strokes,
    totalDistanceKm: _toDouble(meta['totalDistance']) ?? 0.0,
    totalSteps: _toDouble(meta['totalSteps'])?.round() ?? 0,
    shareId: shareId is String && shareId.isNotEmpty ? shareId : null,
  );
}

/// 以前の形式の下書きか（`strokes` を持たず、軌跡の座標をコピーで持っている）
bool isLegacyDraft(Map<String, dynamic> draft) =>
    draft['strokes'] == null && draft['trajectories'] is List;

/// 以前の形式の下書きを新しい形式にする
///
/// - 軌跡のコピー（`trajectories`）を、軌跡への参照（`strokes`）に置き換える
/// - 位置を割合（0〜1）から、キャンバス上の px にする
/// - 保存日時を文字列の `timestamp` から Timestamp の `updatedAt` にする
/// キャンバスの大きさか軌跡の一覧を読めない場合は、元のまま返す
Map<String, dynamic> convertLegacyDraft(
  Map<String, dynamic> draft,
  LegacyStrokeResolver resolver,
) {
  final canvasWidth = _toDouble(draft['canvasWidth']);
  final canvasHeight = _toDouble(draft['canvasHeight']);
  final items = draft['trajectories'];
  if (canvasWidth == null || canvasHeight == null || items is! List) {
    return draft;
  }

  final strokes = <Stroke>[];
  for (final item in items.whereType<Map>()) {
    final trajectoryId = resolver.resolve(item);
    if (trajectoryId == null) continue;
    final position = item['position'] is Map ? item['position'] as Map : const {};
    strokes.add(Stroke(
      trajectoryId: trajectoryId,
      x: (_toDouble(position['dx']) ?? 0.0) * canvasWidth,
      y: (_toDouble(position['dy']) ?? 0.0) * canvasHeight,
      scale: _toDouble(item['scale']) ?? 1.0,
      rotation: _toDouble(item['rotation']) ?? 0.0,
      placedAt: parseTime(item['placedAt']),
    ));
  }

  final savedAt = parseTime(draft['timestamp']);
  return Map<String, dynamic>.from(draft)
    ..remove('trajectories')
    ..remove('timestamp')
    ..['strokes'] = strokes.map((s) => s.toMap()).toList()
    ..addAll({if (savedAt != null) 'updatedAt': Timestamp.fromDate(savedAt)});
}

double? _toDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

/// `artwork_<ミリ秒>` 形式の作品 ID から作成日時を読む
DateTime? _timeFromArtworkId(String artworkId) {
  final millis = int.tryParse(artworkId.split('_').last);
  return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
}
