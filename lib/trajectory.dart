import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

import 'utils/polyline_codec.dart';

/// 座標列の長さ（km）
double trajectoryLengthKm(List<Position> points) {
  var meters = 0.0;
  for (var i = 1; i < points.length; i++) {
    meters += Geolocator.distanceBetween(points[i - 1].latitude,
        points[i - 1].longitude, points[i].latitude, points[i].longitude);
  }
  return meters / 1000.0;
}

/// 軌跡の記録元
enum TrajectorySource {
  /// アプリで記録した
  gps,

  /// Garmin などのファイル（FIT / TCX）から取り込んだ
  garmin,

  /// ヘルスケア（Apple Watch など）から取り込んだ
  healthkit,

  /// 取り込んだが、記録元が分からない（記録元を保存していなかった頃の軌跡）
  imported;

  static TrajectorySource fromName(String? name) =>
      TrajectorySource.values.firstWhere((s) => s.name == name,
          orElse: () => TrajectorySource.imported);
}

/// 歩いた軌跡 1 本
///
/// Firestore の `users/{userId}/trajectories/{id}` に、次の形で保存する
/// （読み書きは TrajectoryStore が行う）。
/// ```
/// source       'gps' | 'garmin' | 'healthkit' | 'imported'
/// startedAt    Timestamp  最初の点の時刻（記録日時）
/// endedAt      Timestamp  最後の点の時刻
/// distanceKm   number
/// steps        number
/// polyline     string     緯度経度（Encoded Polyline、小数 6 桁）
/// timeOffsets  string     各点の時刻（startedAt からのミリ秒を encodeIntDeltas で）
/// createdAt    Timestamp  保存した日時（サーバー時刻）
/// ```
class Trajectory {
  /// 軌跡の ID（以前の groupId をそのまま使う）
  ///
  /// アプリで記録した軌跡は座標のハッシュ（generateGroupId）、
  /// 取り込んだ軌跡は `garmin_<記録日時のミリ秒>`
  final String id;

  final TrajectorySource source;

  /// 各点の位置と時刻
  final List<Position> points;

  /// 距離（km）
  final double distanceKm;

  final int steps;

  Trajectory({
    required this.id,
    required this.source,
    required this.points,
    required this.distanceKm,
    required this.steps,
  }) : assert(points.isNotEmpty);

  /// 緯度経度を保存するときの小数点以下の桁数（6 桁 ≒ 10 cm）
  static const int coordinatePrecision = 6;

  /// 記録日時（最初の点の時刻）
  DateTime get startedAt => points.first.timestamp;

  /// 最後の点の時刻
  DateTime get endedAt => points.last.timestamp;

  /// Firestore に保存する内容（createdAt は保存する側で付ける）
  Map<String, dynamic> toFirestore() {
    final start = startedAt;
    return {
      'source': source.name,
      'startedAt': Timestamp.fromDate(start),
      'endedAt': Timestamp.fromDate(endedAt),
      'distanceKm': distanceKm,
      'steps': steps,
      'polyline': encodePolyline(
        points
            .map((p) => {'latitude': p.latitude, 'longitude': p.longitude})
            .toList(),
        precision: coordinatePrecision,
      ),
      'timeOffsets': encodeIntDeltas(points
          .map((p) => p.timestamp.difference(start).inMilliseconds)
          .toList()),
    };
  }

  /// Firestore のドキュメントから作る。形式が壊れている場合は FormatException
  factory Trajectory.fromFirestore(String id, Map<String, dynamic> data) {
    final polyline = data['polyline'];
    final startedAt = data['startedAt'];
    if (polyline is! String || startedAt is! Timestamp) {
      throw FormatException('軌跡の形式が正しくありません: $id');
    }
    final latLngs =
        decodePolyline(polyline, precision: coordinatePrecision);
    if (latLngs.isEmpty) {
      throw FormatException('軌跡に座標がありません: $id');
    }

    final start = startedAt.toDate().toUtc();
    final timeOffsets = data['timeOffsets'];
    final offsets =
        timeOffsets is String ? decodeIntDeltas(timeOffsets) : const <int>[];
    final hasTimes = offsets.length == latLngs.length;

    return Trajectory(
      id: id,
      source: TrajectorySource.fromName(data['source'] as String?),
      points: [
        for (var i = 0; i < latLngs.length; i++)
          _position(
            latLngs[i]['latitude']!,
            latLngs[i]['longitude']!,
            hasTimes ? start.add(Duration(milliseconds: offsets[i])) : start,
          ),
      ],
      distanceKm: (data['distanceKm'] as num?)?.toDouble() ?? 0.0,
      steps: (data['steps'] as num?)?.toInt() ?? 0,
    );
  }

  /// 以前の形式の軌跡から作る。読めない場合は null
  ///
  /// [row] は Firestore の `walking_data` のドキュメント（`groupId`、
  /// `positions` は Map のリスト）か、端末の SQLite の `walking_data` の行
  /// （`group_id`、`positions` は JSON 文字列）。
  /// 記録元は保存していなかったため、`is_from_garmin` が立っていれば Garmin、
  /// ID が `garmin_` で始まれば取り込み（Garmin かヘルスケアかは分からない）、
  /// それ以外はアプリで記録した軌跡とみなす
  static Trajectory? fromLegacy(Map<String, dynamic> row) {
    final id = (row['groupId'] ?? row['group_id'])?.toString() ?? '';
    Object? positions = row['positions'];
    if (positions is String) {
      try {
        positions = jsonDecode(positions);
      } catch (_) {
        return null;
      }
    }
    if (id.isEmpty || positions is! List || positions.isEmpty) return null;

    // 時刻のない点は、記録日時（date）で補う
    final fallbackTime = _parseTime(row['date']) ?? DateTime.now().toUtc();
    final points = <Position>[];
    for (final point in positions) {
      if (point is! Map) return null;
      final latitude = point['latitude'];
      final longitude = point['longitude'];
      if (latitude is! num || longitude is! num) return null;
      points.add(_position(
        latitude.toDouble(),
        longitude.toDouble(),
        _parseTime(point['timestamp']) ?? fallbackTime,
      ));
    }

    final isFromGarmin =
        row['is_from_garmin'] == true || row['is_from_garmin'] == 1;
    final source = isFromGarmin
        ? TrajectorySource.garmin
        : id.startsWith('garmin_')
            ? TrajectorySource.imported
            : TrajectorySource.gps;

    return Trajectory(
      id: id,
      source: source,
      points: points,
      distanceKm: (row['distance'] as num?)?.toDouble() ?? 0.0,
      steps: (row['steps'] as num?)?.toInt() ?? 0,
    );
  }

  /// 時刻の文字列を UTC の DateTime にする（タイムゾーンのない文字列は端末の時刻とみなす）
  static DateTime? _parseTime(Object? value) {
    if (value is! String) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  static Position _position(
      double latitude, double longitude, DateTime timestamp) {
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
}
