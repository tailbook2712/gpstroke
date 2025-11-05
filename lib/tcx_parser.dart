import 'package:xml/xml.dart' as xml;
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

/// TCX ファイルから軌跡情報を抽出するクラス
class TcxParser {
  /// ヘルパー: localNameで要素を検索
  static xml.XmlElement? _findElementByLocalName(
    xml.XmlElement parent,
    String localName,
  ) {
    for (final child in parent.children) {
      if (child is xml.XmlElement && child.name.local == localName) {
        return child;
      }
    }
    return null;
  }

  /// ヘルパー: localNameで複数の要素を検索
  static List<xml.XmlElement> _findElementsByLocalName(
    xml.XmlElement parent,
    String localName,
  ) {
    final result = <xml.XmlElement>[];
    for (final child in parent.children) {
      if (child is xml.XmlElement && child.name.local == localName) {
        result.add(child);
      }
    }
    return result;
  }

  /// TCX ファイルの内容を解析して軌跡情報を取得
  static Future<GarminActivityData?> parseTcxFile(
    String tcxContent, {
    required double userHeightCm,
  }) async {
    try {
      print('📊 TCXパース開始');
      print('入力サイズ: ${tcxContent.length} bytes');

      final document = xml.XmlDocument.parse(tcxContent);
      final root = document.rootElement;
      print('ルート要素: ${root.name}');

      // Activities要素を取得（名前空間対応）
      // 最初に子要素を確認
      print('ルート直下の要素:');
      for (final child in root.children) {
        if (child is xml.XmlElement) {
          print(
              '  - localName: ${child.name.local}, qualified: ${child.name.qualified}');
        }
      }

      // Activities要素を取得（名前空間なしで検索）
      xml.XmlElement? activitiesElement =
          _findElementByLocalName(root, 'Activities');

      if (activitiesElement == null) {
        print('⚠️ Activities要素が見つかりません');
        return null;
      }
      print('✅ Activities要素を取得しました');

      xml.XmlElement? activity =
          _findElementByLocalName(activitiesElement, 'Activity');

      if (activity == null) {
        print('⚠️ Activity要素が見つかりません');
        return null;
      }
      print('✅ Activity要素を取得しました');

      // アクティビティ開始時刻と名前を取得
      final id = activity.findElements('Id').firstOrNull?.innerText.trim();
      DateTime? recordDate;
      if (id != null) {
        recordDate = DateTime.tryParse(id);
      }

      String activityName = activity.getAttribute('Sport') ?? 'Activity';
      activityName = '$activityName Activity';

      // すべてのLapから軌跡ポイントと距離を集める
      final positions = <Position>[];
      double totalDistance = 0.0; // メートル単位

      final laps = _findElementsByLocalName(activity, 'Lap');
      print('📍 Lap数: ${laps.length}');

      int lapIndex = 0;
      for (final lap in laps) {
        lapIndex++;
        // Lapの距離を加算
        final distanceElement = _findElementByLocalName(lap, 'DistanceMeters');
        if (distanceElement != null) {
          final lapDistance =
              double.tryParse(distanceElement.innerText.trim()) ?? 0.0;
          totalDistance += lapDistance;
          print('  Lap$lapIndex: ${lapDistance.toStringAsFixed(2)}m');
        }

        // Trackポイントを取得
        final track = _findElementByLocalName(lap, 'Track');
        if (track != null) {
          final trackpoints = _findElementsByLocalName(track, 'Trackpoint');
          print('    Trackpoint数: ${trackpoints.length}');

          // 最初のTrackpointの構造を確認（デバッグ用）
          if (trackpoints.isNotEmpty && lapIndex == 1) {
            print('    🔍 最初のTrackpoint内の要素:');
            final firstTrackpoint = trackpoints.first;
            for (final child in firstTrackpoint.children) {
              if (child is xml.XmlElement) {
                final text = child.innerText.trim();
                final preview = text.length > 30 ? text.substring(0, 30) : text;
                print('       - ${child.name.local}: $preview');

                // Position要素の内部構造を詳しく確認
                if (child.name.local == 'Position') {
                  print('         Position内の要素:');
                  for (final posChild in child.children) {
                    if (posChild is xml.XmlElement) {
                      print(
                          '           - ${posChild.name.local}: ${posChild.innerText.trim()}');
                    }
                  }
                }
              }
            }
          }

          for (final trackpoint in trackpoints) {
            // Position タグ内を検索
            final positionElement =
                _findElementByLocalName(trackpoint, 'Position');

            double? latDouble;
            double? lonDouble;

            if (positionElement != null) {
              // Position タグ内から座標を取得
              final latElement =
                  _findElementByLocalName(positionElement, 'LatitudeDegrees');
              final lonElement =
                  _findElementByLocalName(positionElement, 'LongitudeDegrees');

              if (latElement != null && lonElement != null) {
                latDouble = double.tryParse(latElement.innerText.trim());
                lonDouble = double.tryParse(lonElement.innerText.trim());
              }
            } else {
              // Position タグがない場合は Trackpoint 直下を検索
              final latElement =
                  _findElementByLocalName(trackpoint, 'LatitudeDegrees');
              final lonElement =
                  _findElementByLocalName(trackpoint, 'LongitudeDegrees');

              if (latElement != null && lonElement != null) {
                latDouble = double.tryParse(latElement.innerText.trim());
                lonDouble = double.tryParse(lonElement.innerText.trim());
              }
            }

            if (latDouble != null && lonDouble != null) {
              // 時刻を取得
              final timeElement = _findElementByLocalName(trackpoint, 'Time');
              final timeStr = timeElement?.innerText.trim();
              final timestamp = timeStr != null
                  ? DateTime.tryParse(timeStr) ?? DateTime.now()
                  : DateTime.now();

              // 高度を取得
              final altitudeElement =
                  _findElementByLocalName(trackpoint, 'AltitudeMeters');
              final altitude = altitudeElement != null
                  ? double.tryParse(altitudeElement.innerText.trim()) ?? 0.0
                  : 0.0;

              positions.add(
                Position(
                  latitude: latDouble,
                  longitude: lonDouble,
                  timestamp: timestamp,
                  accuracy: 0.0,
                  altitude: altitude,
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

      print('✅ 総Trackpoint数: ${positions.length}');
      print('✅ 総移動距離: ${totalDistance.toStringAsFixed(2)}m');

      if (positions.isEmpty) {
        print('⚠️ ポイントが見つかりません');
        return null;
      }

      // 日付がない場合は最初のポイントの時刻を使用
      recordDate ??=
          positions.isNotEmpty ? positions.first.timestamp : DateTime.now();

      // 歩数を計算
      final steps = _calculateSteps(totalDistance, userHeightCm);
      print('📊 計算結果:');
      print('  距離: ${(totalDistance / 1000).toStringAsFixed(2)}km');
      print('  身長: ${userHeightCm.toStringAsFixed(1)}cm');
      print('  歩数: $steps');

      final result = GarminActivityData(
        activityName: activityName,
        positions: positions,
        recordDate: recordDate,
        distance: totalDistance / 1000, // メートルからキロメートルに変換
        steps: steps,
      );

      print('✅ TCXパース完了');
      return result;
    } catch (e, stackTrace) {
      print('❌ TCX パースエラー: $e');
      print('スタックトレース: $stackTrace');
      return null;
    }
  }

  /// ストライド長を身長から計算（Grubbs公式）
  /// stride_length = 0.413 × height(m)
  static double _calculateStrideLength(double heightCm) {
    return 0.413 * (heightCm / 100);
  }

  /// 歩数を計算
  /// steps = distance(m) / stride_length(m)
  static int _calculateSteps(double distanceMeters, double userHeightCm) {
    final strideLength = _calculateStrideLength(userHeightCm);
    if (strideLength <= 0) {
      print('警告: ストライド長が不正です');
      return 0;
    }
    final steps = (distanceMeters / strideLength).toInt();
    return steps;
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
