import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'database_helper.dart';
import 'package:intl/intl.dart';
import 'dart:math' as math;

class WalkingDetailScreen extends StatefulWidget {
  final String groupId;
  final String date;
  final int steps;
  final String distance;
  final bool hideBackButton; // 戻るボタンを非表示にするかどうかのフラグ
  final double rotation; // 追加: 軌跡の回転角度

  WalkingDetailScreen({
    required this.groupId,
    required this.date,
    required this.steps,
    required this.distance,
    this.hideBackButton = false,
    this.rotation = 0.0, // デフォルト値は0（回転なし）
  });

  @override
  _WalkingDetailScreenState createState() => _WalkingDetailScreenState();
}

class _WalkingDetailScreenState extends State<WalkingDetailScreen> {
  late DatabaseHelper _dbHelper;
  GoogleMapController? _mapController;

  List<LatLng> _polylinePoints = [];
  LatLng? _initialPosition;
  Set<Polyline> _polylines = {};

  String _date = ''; // ローカル変数で日付を管理
  int _steps = 0; // ローカル変数で歩数を管理
  String _distance = ''; // ローカル変数で距離を管理

  @override
  void initState() {
    super.initState();
    _dbHelper = DatabaseHelper();

    // 初期値を設定
    _date = widget.date;
    _steps = widget.steps;
    _distance = widget.distance;
    
    _fetchPositionsAndDetails();
  }

    // 軌跡の適切なズームレベルを計算
  double _calculateZoomLevel(LatLngBounds bounds, Size mapSize) {
    final double WORLD_WIDTH = 256; // 基本的なスケール定数
    
    // 境界の幅と高さを度単位で計算
    double latDiff = bounds.northeast.latitude - bounds.southwest.latitude;
    double lngDiff = bounds.northeast.longitude - bounds.southwest.longitude;
    
    // 緯度と経度の差がどちらも0の場合（単一地点の場合）、デフォルト値を返す
    if (latDiff < 0.000001 && lngDiff < 0.000001) {
      return 13.0; // デフォルトズームレベルを下げる（より遠くから表示）
    }
    
    // 地図のアスペクト比を考慮
    double mapAspect = mapSize.width / mapSize.height;
    
    // 経度差をアスペクト比で調整
    double adjustedLngDiff = lngDiff * mapAspect;
    
    // ズームレベルの決定要素となる差を選択（大きい方）
    double maxDiff = latDiff > adjustedLngDiff ? latDiff : adjustedLngDiff;
    
    // パディングを考慮（50%のマージン）- より広い範囲を表示
    maxDiff = maxDiff * 1.5;
    
    // ズームレベルの計算（対数関数を使用）
    double zoom = (math.log(360 / maxDiff) / math.ln2) + 1;
    
    // ズームレベルを少し小さくして（より遠くに）調整
    zoom = zoom - 0.5;
    
    // 最大・最小の制限を設ける
    return math.max(12.0, math.min(zoom, 16.0));
  }  // 軌跡の中心点を計算
  LatLng _calculateCenter(List<LatLng> points) {
    if (points.isEmpty) {
      return LatLng(35.0, 135.0); // デフォルト値
    }
    
    double sumLat = 0.0;
    double sumLng = 0.0;
    
    for (LatLng point in points) {
      sumLat += point.latitude;
      sumLng += point.longitude;
    }
    
    return LatLng(sumLat / points.length, sumLng / points.length);
  }
  
  // 軌跡の境界を計算してバウンディングボックスを生成
  LatLngBounds _calculateBounds(List<LatLng> points) {
    if (points.isEmpty) {
      // デフォルト値（小さな範囲）
      return LatLngBounds(
        southwest: LatLng(35.0, 135.0),
        northeast: LatLng(35.01, 135.01),
      );
    }
    
    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;
    
    for (LatLng point in points) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }
    
    // 少し余白を追加する（10%程度）
    double latPadding = (maxLat - minLat) * 0.1;
    double lngPadding = (maxLng - minLng) * 0.1;
    
    return LatLngBounds(
      southwest: LatLng(minLat - latPadding, minLng - lngPadding),
      northeast: LatLng(maxLat + latPadding, maxLng + lngPadding),
    );
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  void _onMapCreated(GoogleMapController controller) {
    _mapController = controller;
    
    if (_polylinePoints.isEmpty) return;
    
    // 地図のサイズを取得（BuildContextから）
    final Size mapSize = MediaQuery.of(context).size;
    
    // 軌跡の中心と境界を計算
    LatLng center = _calculateCenter(_polylinePoints);
    LatLngBounds bounds = _calculateBounds(_polylinePoints);
    
    // 最適なズームレベルを計算
    double zoomLevel = _calculateZoomLevel(bounds, mapSize);
    
    // 角度補正（作品上の軌跡の回転と合わせるために必要な調整）
    double correctedRotation = 0.0;
    if (widget.rotation != 0.0) {
      correctedRotation = (widget.rotation * 180 / 3.14159) % 360;
      // 角度の補正（軌跡と地図の向きを合わせるための調整）
      correctedRotation = -correctedRotation; // 逆向きに回転させる
    }
    
    // 地図を更新（一度の更新で中心、ズーム、回転を設定）
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: center,
          zoom: zoomLevel,
          bearing: correctedRotation,
        ),
      ),
    );
  }

  // 指定されたグループ ID に基づいて位置情報と詳細データを取得
  Future<void> _fetchPositionsAndDetails() async {
    try {
      // データベースから位置情報を取得
      List<Map<String, dynamic>> positions =
          await _dbHelper.getPositionsByGroupId(widget.groupId);

      if (positions.isNotEmpty) {
        setState(() {
          // LatLng に変換
          _polylinePoints = positions.map((position) {
            return LatLng(position['latitude'], position['longitude']);
          }).toList();

          // 初期位置を軌跡の中心に設定
          _initialPosition = _calculateCenter(_polylinePoints);

          // ポリラインを追加
          _polylines.add(
            Polyline(
              polylineId: PolylineId('walking_route_${widget.groupId}'),
              points: _polylinePoints,
              color: Colors.blue,
              width: 4,
            ),
          );

          // 記録日時を設定
          if(positions.isNotEmpty && positions.first.containsKey('timestamp')) {
            _date = positions.first['timestamp'];
          }
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("位置情報が見つかりません")),
        );
      }
    } catch (e) {
      print("データ取得エラー: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("データ取得中にエラーが発生しました")),
      );
    }
  }

  // 日付フォーマットする
  String _formatDate(String date) {
    try {
      final parsedDate = DateTime.parse(date); // 日付文字列をDateTimeに変換
      return DateFormat('yyyy年MM月dd日 hh:mm').format(parsedDate); // フォーマット
    } catch (e) {
      print("日付フォーマットエラー: $e");
      return date; // フォーマットに失敗した場合はそのまま返す
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_formatDate(_date)), // 日付を表示
        automaticallyImplyLeading: !widget.hideBackButton, // hideBackButtonがtrueの場合、戻るボタンを非表示
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 情報ヘッダー部分 - アニメーション効果を追加
          AnimatedContainer(
            duration: Duration(milliseconds: 500),
            curve: Curves.easeInOut,
            padding: const EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 4.0,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.directions_walk, color: Colors.blue),
                    SizedBox(width: 8),
                    Text(
                      '歩数: ${widget.steps} 歩',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
                SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.straighten, color: Colors.green),
                    SizedBox(width: 8),
                    Text(
                      '距離: ${widget.distance} km',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),

              ],
            ),
          ),
          
          // 地図表示部分
          Expanded(
            child: _initialPosition == null
                ? Center(child: CircularProgressIndicator()) // ローディングインジケーター
                : Stack(
                    children: [
                      GoogleMap(
                        initialCameraPosition: CameraPosition(
                          target: _initialPosition!,
                          zoom: 15.0,
                          // 初期の回転角度は設定しない（onMapCreatedで設定）
                        ),
                        polylines: _polylines,
                        onMapCreated: _onMapCreated,
                        myLocationEnabled: true,
                        myLocationButtonEnabled: true,
                        zoomGesturesEnabled: true,
                        scrollGesturesEnabled: true,
                        rotateGesturesEnabled: true,
                        tiltGesturesEnabled: true,
                        mapToolbarEnabled: false, // 地図ツールバーを非表示
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}