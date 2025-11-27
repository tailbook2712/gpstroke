import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter/material.dart';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// ルート生成とルート類似度計算を担当するサービス
class RouteService {
  // Google Maps Routes API Key (初期化時に読み込み)
  static late final String _apiKey;
  static const String _routesApiUrl =
      'https://routes.googleapis.com/directions/v2:computeRoutes';

  /// API キーの初期化
  static void initializeApiKey() {
    _apiKey = dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '';
    if (_apiKey.isEmpty) {
      print('警告: Google Maps API Key が設定されていません');
    } else {
      print('Google Maps API Key が正常に読み込まれました');
    }
  }

  /// キャンバスに描いた形状をLatLngのリストに変換
  ///
  /// [designShape]: キャンバス上の描画データ (List<List<Offset>>)
  /// [startingPoint]: 出発地
  /// [destination]: 目的地
  ///
  /// Returns: 正規化されたLatLngリスト
  static List<LatLng> convertDesignShapeToLatLngs(
    List<List<Offset>> designShape,
    LatLng startingPoint,
    LatLng destination,
  ) {
    if (designShape.isEmpty) return [];

    // 全てのオフセットを1次元リストに変換
    List<Offset> allPoints = [];
    for (final stroke in designShape) {
      allPoints.addAll(stroke);
    }

    if (allPoints.isEmpty) return [];

    // キャンバス座標の正規化（0.0 ～ 1.0）
    double minX = allPoints.map((p) => p.dx).reduce((a, b) => a < b ? a : b);
    double maxX = allPoints.map((p) => p.dx).reduce((a, b) => a > b ? a : b);
    double minY = allPoints.map((p) => p.dy).reduce((a, b) => a < b ? a : b);
    double maxY = allPoints.map((p) => p.dy).reduce((a, b) => a > b ? a : b);

    double width = (maxX - minX).abs();
    double height = (maxY - minY).abs();

    if (width == 0 || height == 0) return [];

    // 正規化されたポイントを生成
    List<Offset> normalizedPoints = allPoints.map((p) {
      return Offset(
        (p.dx - minX) / width,
        (p.dy - minY) / height,
      );
    }).toList();

    // 正規化されたポイントをLatLngに変換（出発地と目的地を基準）
    List<LatLng> pathPoints = normalizedPoints.map((p) {
      double lat = startingPoint.latitude +
          (destination.latitude - startingPoint.latitude) * p.dy;
      double lng = startingPoint.longitude +
          (destination.longitude - startingPoint.longitude) * p.dx;
      return LatLng(lat, lng);
    }).toList();

    return pathPoints;
  }

  /// 2点間の距離を計算（Haversine公式）
  ///
  /// Returns: メートル単位の距離
  static double calculateDistance(LatLng point1, LatLng point2) {
    const earthRadiusM = 6371000; // 地球の半径（メートル）

    double lat1Rad = _degreesToRadians(point1.latitude);
    double lat2Rad = _degreesToRadians(point2.latitude);
    double deltaLat = _degreesToRadians(point2.latitude - point1.latitude);
    double deltaLng = _degreesToRadians(point2.longitude - point1.longitude);

    double a = sin(deltaLat / 2) * sin(deltaLat / 2) +
        cos(lat1Rad) * cos(lat2Rad) * sin(deltaLng / 2) * sin(deltaLng / 2);
    double c = 2 * asin(sqrt(a));

    return earthRadiusM * c;
  }

  /// ラジアンに変換
  static double _degreesToRadians(double degrees) {
    return degrees * pi / 180.0;
  }

  /// パスの全体距離を計算
  static double calculatePathDistance(List<LatLng> path) {
    if (path.length < 2) return 0.0;

    double totalDistance = 0.0;
    for (int i = 0; i < path.length - 1; i++) {
      totalDistance += calculateDistance(path[i], path[i + 1]);
    }
    return totalDistance;
  }

  /// 2つのパスの類似度を計算（Hausdorff距離ベース）
  /// 0.0 ～ 1.0 で返す（1.0 に近いほど類似）
  ///
  /// [path1]: 設計パス（キャンバスから生成）
  /// [path2]: 候補ルート
  ///
  /// Returns: 類似度（0.0 ～ 1.0）
  static double calculateShapeSimilarity(
      List<LatLng> path1, List<LatLng> path2) {
    if (path1.isEmpty || path2.isEmpty) return 0.0;

    // Hausdorff距離を計算
    double hausdorffDistance = _calculateHausdorffDistance(path1, path2);

    // 正規化（距離が小さいほど類似度が高い）
    // 最大距離を仮定：10km = 10000m
    const maxDistance = 10000.0;
    double similarity = 1.0 - (hausdorffDistance / maxDistance).clamp(0.0, 1.0);

    return similarity;
  }

  /// Hausdorff距離を計算（形状の類似度評価用）
  static double _calculateHausdorffDistance(
    List<LatLng> path1,
    List<LatLng> path2,
  ) {
    double maxMin1 = 0.0;
    for (final p1 in path1) {
      double minDist = double.infinity;
      for (final p2 in path2) {
        minDist = min(minDist, calculateDistance(p1, p2));
      }
      maxMin1 = max(maxMin1, minDist);
    }

    double maxMin2 = 0.0;
    for (final p2 in path2) {
      double minDist = double.infinity;
      for (final p1 in path1) {
        minDist = min(minDist, calculateDistance(p1, p2));
      }
      maxMin2 = max(maxMin2, minDist);
    }

    return max(maxMin1, maxMin2);
  }

  /// Google Maps Routes API でルート候補を取得
  ///
  /// [startingPoint]: 出発地
  /// [destination]: 目的地
  /// [designPath]: 設計パス（形状参考用）
  /// [targetDistance]: 目標距離（メートル）
  ///
  /// Returns: ルートのポイント (List<LatLng>)
  static Future<List<LatLng>> generateRouteCandidates(
    LatLng startingPoint,
    LatLng destination,
    List<LatLng> designPath,
    double targetDistance,
  ) async {
    try {
      // API Key が設定されているか確認
      if (_apiKey.isEmpty || _apiKey == 'YOUR_GOOGLE_MAPS_API_KEY_HERE') {
        print('警告: Google Maps API Key が設定されていません。デモルートを使用します。');
        return _generateDemoRoute(startingPoint, destination, designPath);
      }

      // Google Maps Routes API へリクエスト
      final response = await _fetchRouteFromAPI(
        startingPoint,
        destination,
        designPath,
        targetDistance,
      );

      if (response != null) {
        return response;
      } else {
        // API 呼び出し失敗時はデモルートを返す
        print('Google Maps Routes API 呼び出し失敗。デモルートを使用します。');
        return _generateDemoRoute(startingPoint, destination, designPath);
      }
    } catch (e) {
      print('ルート生成エラー: $e');
      return _generateDemoRoute(startingPoint, destination, designPath);
    }
  }

  /// Google Maps Routes API へリクエストを送信
  static Future<List<LatLng>?> _fetchRouteFromAPI(
    LatLng startingPoint,
    LatLng destination,
    List<LatLng> designPath,
    double targetDistance,
  ) async {
    try {
      // API キーのチェック
      if (_apiKey.isEmpty) {
        print('❌ エラー: Google Maps API Key が空です');
        return null;
      }

      print(
          '🔍 API キー (最初の20文字): ${_apiKey.substring(0, min(20, _apiKey.length))}...');

      final url = Uri.parse('$_routesApiUrl?key=$_apiKey');

      final requestBody = {
        'origin': {
          'location': {
            'latLng': {
              'latitude': startingPoint.latitude,
              'longitude': startingPoint.longitude,
            },
          },
        },
        'destination': {
          'location': {
            'latLng': {
              'latitude': destination.latitude,
              'longitude': destination.longitude,
            },
          },
        },
        'travelMode': 'WALK', // 徒歩を指定
        'computeAlternativeRoutes': false,
        // デザインパスをウェイポイント（経由地）として追加
        // ※ Google Maps Routes API は最大25個のウェイポイントまで対応
        if (designPath.isNotEmpty)
          'intermediates': _selectWaypoints(designPath, maxWaypoints: 25)
              .map((point) => {
                    'location': {
                      'latLng': {
                        'latitude': point.latitude,
                        'longitude': point.longitude,
                      }
                    }
                  })
              .toList(),
      };

      print('📍 リクエスト送信中...');
      print('   出発地: ${startingPoint.latitude}, ${startingPoint.longitude}');
      print('   目的地: ${destination.latitude}, ${destination.longitude}');

      final response = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'X-Goog-Api-Key': _apiKey,
              'X-Goog-FieldMask':
                  'routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline',
            },
            body: jsonEncode(requestBody),
          )
          .timeout(Duration(seconds: 10));

      print('📋 レスポンスステータス: ${response.statusCode}');

      if (response.statusCode == 200) {
        print('✅ Routes API 呼び出し成功');
        final jsonResponse = jsonDecode(response.body);
        return _parsePolylineFromResponse(jsonResponse);
      } else {
        print('❌ API エラー (${response.statusCode})');
        print('レスポンス本文: ${response.body}');
        return null;
      }
    } catch (e) {
      print('❌ API リクエスト失敗: $e');
      return null;
    }
  }

  /// レスポンスからポリラインをパース
  static List<LatLng>? _parsePolylineFromResponse(Map<String, dynamic> json) {
    try {
      final routes = json['routes'] as List?;
      if (routes == null || routes.isEmpty) {
        print('ルート情報が見つかりません');
        return null;
      }

      final firstRoute = routes[0] as Map<String, dynamic>;
      final polyline = firstRoute['polyline'] as Map<String, dynamic>?;

      if (polyline == null || polyline['encodedPolyline'] == null) {
        print('ポリラインが見つかりません');
        return null;
      }

      final encodedPolyline = polyline['encodedPolyline'] as String;
      return _decodePolyline(encodedPolyline);
    } catch (e) {
      print('ポリラインパース失敗: $e');
      return null;
    }
  }

  /// エンコードされたポリラインをデコード
  ///
  /// Google Maps API は「ポリライン アルゴリズム」でエンコードしたデータを返す
  /// https://developers.google.com/maps/documentation/utilities/polylinealgorithm
  static List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> poly = [];
    int index = 0;
    int lat = 0;
    int lng = 0;

    while (index < encoded.length) {
      int result = 0;
      int shift = 0;
      int b;

      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);

      int dlat = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
      lat += dlat;

      result = 0;
      shift = 0;

      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);

      int dlng = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
      lng += dlng;

      poly.add(LatLng(lat / 1e5, lng / 1e5));
    }

    return poly;
  }

  /// デモルート生成（API Key 未設定時）
  static List<LatLng> _generateDemoRoute(
    LatLng startingPoint,
    LatLng destination,
    List<LatLng> designPath,
  ) {
    List<LatLng> route = [startingPoint];

    // 設計パスを参考にウェイポイントを生成
    if (designPath.isNotEmpty) {
      // デザインパスを線形補間で密にサンプリング
      // これにより、描いた形に近いルートが実現される
      List<LatLng> interpolatedPath = _interpolatePathPoints(designPath);

      // 補間後のパスから適切な間隔でウェイポイントを選択
      // 密度: 元のパス上のほぼすべてのポイントを含める
      int step = max(1, interpolatedPath.length ~/ 30); // 最大30ポイント程度

      for (int i = 0; i < interpolatedPath.length; i += step) {
        route.add(interpolatedPath[i]);
      }

      // 最後のポイントを必ず含める
      if (route.last != interpolatedPath.last) {
        route.add(interpolatedPath.last);
      }
    } else {
      // 設計パスがない場合は、単純な直線ルート
      double midLat = (startingPoint.latitude + destination.latitude) / 2;
      double midLng = (startingPoint.longitude + destination.longitude) / 2;
      route.add(LatLng(midLat, midLng));
    }

    route.add(destination);
    return route;
  }

  /// パスポイントを線形補間で密にサンプリング
  static List<LatLng> _interpolatePathPoints(List<LatLng> path) {
    if (path.length < 2) return path;

    List<LatLng> interpolated = [];

    for (int i = 0; i < path.length - 1; i++) {
      interpolated.add(path[i]);

      // 隣接する2点間を補間
      LatLng p1 = path[i];
      LatLng p2 = path[i + 1];

      // 2点間の距離に基づいて補間ポイント数を決定
      double distance = calculateDistance(p1, p2); // メートル単位

      // 距離に応じて補間ポイント数を調整（100m あたり1ポイント）
      int interpolationCount = max(1, (distance / 100).ceil());

      for (int j = 1; j < interpolationCount; j++) {
        double ratio = j / interpolationCount;
        double lat = p1.latitude + (p2.latitude - p1.latitude) * ratio;
        double lng = p1.longitude + (p2.longitude - p1.longitude) * ratio;
        interpolated.add(LatLng(lat, lng));
      }
    }

    // 最後のポイントを追加
    interpolated.add(path.last);

    return interpolated;
  }

  /// ルート候補を評価し、スコアリング
  static Map<String, dynamic> evaluateRoute({
    required List<LatLng> route,
    required List<LatLng> designPath,
    required double targetDistance,
  }) {
    double routeDistance = calculatePathDistance(route);
    double shapeSimilarity = calculateShapeSimilarity(designPath, route);

    // スコア計算：距離適合度 + 形状類似度
    double distanceError = (routeDistance - targetDistance).abs();
    double distanceFitness =
        1.0 - (distanceError / targetDistance).clamp(0.0, 1.0);

    double totalScore = (distanceFitness * 0.5) + (shapeSimilarity * 0.5);

    return {
      'route': route,
      'distance': routeDistance,
      'shapeSimilarity': shapeSimilarity,
      'distanceFitness': distanceFitness,
      'totalScore': totalScore,
    };
  }

  /// デザインパスから最大数のウェイポイントを選択
  /// 形状を保つために、均等に分散したポイントと重要なポイント（曲がり角）を選択
  static List<LatLng> _selectWaypoints(
    List<LatLng> designPath, {
    required int maxWaypoints,
  }) {
    if (designPath.length <= maxWaypoints) {
      return designPath;
    }

    // Step 1: 均等に分散したポイントを選択（基本）
    List<LatLng> evenlySpaced = [];
    for (int i = 0; i < maxWaypoints; i++) {
      int index = (i * designPath.length / maxWaypoints).floor();
      if (index < designPath.length) {
        evenlySpaced.add(designPath[index]);
      }
    }

    // Step 2: 曲率が高い（曲がっている）ポイントを検出
    // これにより、形状の重要な部分が保持される
    List<int> importantIndices = _findCurvaturePoints(designPath, maxPoints: 5);

    // Step 3: 重要なポイントと均等分散ポイントをマージ
    Set<LatLng> selected = {};
    selected.addAll(evenlySpaced);

    for (int idx in importantIndices) {
      if (idx >= 0 && idx < designPath.length) {
        selected.add(designPath[idx]);
      }
    }

    // Step 4: リストに変換して、最初と最後のポイントを保証
    List<LatLng> result = selected.toList();
    result.sort((a, b) {
      // デザインパス上の元の順序を保持
      int idxA = designPath.indexOf(a);
      int idxB = designPath.indexOf(b);
      return idxA.compareTo(idxB);
    });

    // 最初と最後が確実に含まれるようにする
    if (result.isEmpty || result.first != designPath.first) {
      result.insert(0, designPath.first);
    }
    if (result.isEmpty || result.last != designPath.last) {
      result.add(designPath.last);
    }

    // 最大数を超えた場合は、重要でないポイントから削除
    if (result.length > maxWaypoints) {
      result = result.sublist(0, maxWaypoints);
      if (result.last != designPath.last) {
        result[result.length - 1] = designPath.last;
      }
    }

    return result;
  }

  /// 曲率が高いポイント（曲がり角）を検出
  static List<int> _findCurvaturePoints(
    List<LatLng> path, {
    required int maxPoints,
  }) {
    if (path.length < 3) return [];

    List<int> curvatureIndices = [];

    // 各ポイントの曲率を計算
    for (int i = 1; i < path.length - 1; i++) {
      LatLng p0 = path[i - 1];
      LatLng p1 = path[i];
      LatLng p2 = path[i + 1];

      // ベクトルを計算
      double v1Lat = p1.latitude - p0.latitude;
      double v1Lng = p1.longitude - p0.longitude;
      double v2Lat = p2.latitude - p1.latitude;
      double v2Lng = p2.longitude - p1.longitude;

      // 外積（2D）で曲率を推定
      double curvature = (v1Lat * v2Lng - v1Lng * v2Lat).abs();

      // 曲率が高ければインデックスを記録
      if (curvature > 0.00001) {
        curvatureIndices.add(i);
      }
    }

    // 曲率が高いポイントから順にソート
    curvatureIndices.sort((a, b) {
      double curvatureA = _calculatePointCurvature(path, a);
      double curvatureB = _calculatePointCurvature(path, b);
      return curvatureB.compareTo(curvatureA); // 降順
    });

    // 上位 maxPoints 個を取得
    return curvatureIndices.take(maxPoints).toList();
  }

  /// 指定のポイントの曲率を計算
  static double _calculatePointCurvature(List<LatLng> path, int index) {
    if (index <= 0 || index >= path.length - 1) return 0.0;

    LatLng p0 = path[index - 1];
    LatLng p1 = path[index];
    LatLng p2 = path[index + 1];

    double v1Lat = p1.latitude - p0.latitude;
    double v1Lng = p1.longitude - p0.longitude;
    double v2Lat = p2.latitude - p1.latitude;
    double v2Lng = p2.longitude - p1.longitude;

    return (v1Lat * v2Lng - v1Lng * v2Lat).abs();
  }

  // ============================================================
  // Roads API を使用したスナップ処理
  // ============================================================

  /// スケッチのポイントを Roads API でスナップして道路に沿わせる
  ///
  /// [designPath]: スケッチの全ポイント
  /// [startingPoint]: 出発地（スケッチの始点）
  /// [destination]: 到着地（スケッチの終点）
  ///
  /// Returns: 道路にスナップされたポイント
  static Future<List<LatLng>> snapSketchToRoads({
    required List<LatLng> designPath,
    required LatLng startingPoint,
    required LatLng destination,
  }) async {
    try {
      if (designPath.isEmpty) {
        return [startingPoint, destination];
      }

      print('🔄 Roads API でスケッチをスナップ中...');

      // API キーのチェック
      if (_apiKey.isEmpty) {
        print('❌ エラー: Google Maps API Key が空です');
        return designPath;
      }

      // スケッチのすべてのポイントをスナップ
      List<LatLng> snappedPoints = await _snapPointsToRoads(designPath);

      // 始点を出発地に、終点を到着地に強制
      if (snappedPoints.isNotEmpty) {
        snappedPoints[0] = startingPoint;
        if (snappedPoints.length > 1) {
          snappedPoints[snappedPoints.length - 1] = destination;
        }
      }

      print('✅ スナップ完了: ${snappedPoints.length}個のポイント');
      return snappedPoints;
    } catch (e) {
      print('❌ スナップ処理エラー: $e');
      return designPath;
    }
  }

  /// 複数のポイントを Roads API でスナップ
  static Future<List<LatLng>> _snapPointsToRoads(
    List<LatLng> points,
  ) async {
    if (points.isEmpty) return [];

    try {
      // Roads API の URL
      const String roadsApiUrl = 'https://roads.googleapis.com/v1/snapToRoads';

      // ポイントを間引いて100個以内に収める
      List<LatLng> chunkedPoints = _samplePoints(points, 100);

      // API リクエストの構築
      final Uri uri = Uri.parse(roadsApiUrl).replace(
        queryParameters: {
          'path': chunkedPoints
              .map((p) => '${p.latitude},${p.longitude}')
              .join('|'),
          'interpolate': 'true',
          'key': _apiKey,
        },
      );

      print('📍 API リクエスト送信: ${chunkedPoints.length}個のポイント');

      final response = await http.get(uri).timeout(Duration(seconds: 15));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final snappedPoints = _parseSnappedPoints(json, points);
        print('✅ Roads API レスポンス受信: ${snappedPoints.length}個のスナップ済みポイント');
        return snappedPoints;
      } else {
        print('❌ Roads API エラー (${response.statusCode}): ${response.body}');
        return points; // スナップ失敗時は元のポイントを返す
      }
    } catch (e) {
      print('❌ Roads API リクエスト失敗: $e');
      return points;
    }
  }

  /// Roads API のレスポンスをパース
  static List<LatLng> _parseSnappedPoints(
    Map<String, dynamic> json,
    List<LatLng> originalPoints,
  ) {
    try {
      final snappedPoints = json['snappedPoints'] as List?;
      if (snappedPoints == null || snappedPoints.isEmpty) {
        print('⚠️ スナップされたポイントが見つかりません');
        return originalPoints;
      }

      List<LatLng> result = [];
      for (var point in snappedPoints) {
        final location = point['location'] as Map<String, dynamic>?;
        if (location != null) {
          double lat = (location['latitude'] as num).toDouble();
          double lng = (location['longitude'] as num).toDouble();
          result.add(LatLng(lat, lng));
        }
      }

      if (result.isEmpty) {
        return originalPoints;
      }

      return result;
    } catch (e) {
      print('❌ レスポンスパースエラー: $e');
      return originalPoints;
    }
  }

  /// ポイントリストを指定された最大数に間引く
  static List<LatLng> _samplePoints(List<LatLng> points, int maxCount) {
    if (points.length <= maxCount) return points;

    List<LatLng> sampled = [];
    // 始点は必ず含める
    sampled.add(points.first);

    // 中間ポイントを均等に間引く
    // (points.length - 1) / (maxCount - 1) の間隔で取得
    double step = (points.length - 1) / (maxCount - 1);
    for (int i = 1; i < maxCount - 1; i++) {
      int index = (i * step).round();
      if (index > 0 && index < points.length - 1) {
        sampled.add(points[index]);
      }
    }

    // 終点は必ず含める
    sampled.add(points.last);

    return sampled;
  }
}
