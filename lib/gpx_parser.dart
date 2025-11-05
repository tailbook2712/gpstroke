import 'package:xml/xml.dart' as xml;
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

/// GPX ファイルから軌跡情報を抽出するクラス
class GpxParser {
  /// GPX ファイルの内容を解析して軌跡情報を取得
  static Future<GarminActivityData?> parseGpxFile(String gpxContent) async {
    try {
      final document = xml.XmlDocument.parse(gpxContent);
      final root = document.rootElement;

      // メタデータを取得
      final metadata = root.findElements('metadata').isNotEmpty
          ? root.findElements('metadata').first
          : null;

      String? activityName;
      DateTime? recordDate;

      if (metadata != null) {
        activityName =
            metadata.findElements('name').firstOrNull?.innerText.trim();

        final timeStr =
            metadata.findElements('time').firstOrNull?.innerText.trim();
        if (timeStr != null) {
          recordDate = DateTime.tryParse(timeStr);
        }
      }

      // トラックからポイントを取得
      final positions = <Position>[];
      final trk = root.findElements('trk').firstOrNull;

      if (trk != null) {
        for (final trkseg in trk.findElements('trkseg')) {
          for (final trkpt in trkseg.findElements('trkpt')) {
            final lat = double.tryParse(trkpt.getAttribute('lat') ?? '');
            final lon = double.tryParse(trkpt.getAttribute('lon') ?? '');

            if (lat != null && lon != null) {
              String? timeStr;
              double? elevation;

              // 時刻と高度を取得
              timeStr =
                  trkpt.findElements('time').firstOrNull?.innerText.trim();

              final eleStr =
                  trkpt.findElements('ele').firstOrNull?.innerText.trim();
              elevation = double.tryParse(eleStr ?? '');

              final timestamp = timeStr != null
                  ? DateTime.tryParse(timeStr) ?? DateTime.now()
                  : DateTime.now();

              positions.add(
                Position(
                  latitude: lat,
                  longitude: lon,
                  timestamp: timestamp,
                  accuracy: 0.0,
                  altitude: elevation ?? 0.0,
                  heading: 0.0,
                  speed: 0.0,
                  speedAccuracy: 0.0,
                  altitudeAccuracy: 0.0,
                  headingAccuracy: 0.0,
                ),
              );
            }
          }
        }
      }

      if (positions.isEmpty) {
        return null;
      }

      // 距離を計算
      double totalDistance = 0.0;
      for (int i = 1; i < positions.length; i++) {
        totalDistance += Geolocator.distanceBetween(
          positions[i - 1].latitude,
          positions[i - 1].longitude,
          positions[i].latitude,
          positions[i].longitude,
        );
      }

      // 日付がない場合は最初のポイントの時刻を使用
      recordDate ??=
          positions.isNotEmpty ? positions.first.timestamp : DateTime.now();

      return GarminActivityData(
        activityName: activityName ?? 'Garmin Activity',
        positions: positions,
        recordDate: recordDate,
        distance: totalDistance / 1000, // メートルからキロメートルに変換
        steps: positions.length, // ポイント数を歩数として使用
      );
    } catch (e) {
      print('GPX パースエラー: $e');
      return null;
    }
  }
}

/// Garmin アクティビティデータを表すクラス
class GarminActivityData {
  final String activityName;
  final List<Position> positions;
  final DateTime recordDate;
  final double distance; // キロメートル
  final int steps;

  GarminActivityData({
    required this.activityName,
    required this.positions,
    required this.recordDate,
    required this.distance,
    required this.steps,
  });

  /// 日付をフォーマットして取得
  String getFormattedDate() {
    return DateFormat('yyyy-MM-dd HH:mm').format(recordDate);
  }

  /// グループID を生成（タイムスタンプベース）
  String generateGroupId() {
    return 'garmin_${recordDate.millisecondsSinceEpoch}';
  }
}
