import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart'; // Google Maps用
import 'package:geolocator/geolocator.dart'; // 現在地取得用
import 'database_helper.dart'; // データベースヘルパーのインポート

class WalkingDetailScreen extends StatefulWidget {
  final int groupId;
  
  WalkingDetailScreen({required this.groupId});

  @override
  _WalkingDetailScreenState createState() => _WalkingDetailScreenState();
}

class _WalkingDetailScreenState extends State<WalkingDetailScreen> {
  late DatabaseHelper _dbHelper;
  late GoogleMapController _mapController;
  List<LatLng> _polylinePoints = [];
  LatLng? _initialPosition; // 初期位置をnullで初期化
  Set<Polyline> _polylines = {}; // ポリラインを保存するセット

  @override
  void initState() {
    super.initState();
    _dbHelper = DatabaseHelper();
    _fetchPositions(); // 指定されたグループの位置情報を取得
  }

  // Google Mapが初期化されたときに呼び出されるコールバック
  void _onMapCreated(GoogleMapController controller) {
    _mapController = controller;
  }

  // 指定されたグループIDの位置情報をデータベースから取得し、ポリライン用の座標リストを作成
  Future<void> _fetchPositions() async {
    List<Map<String, dynamic>> positions = await _dbHelper.getPositionsByGroupId(widget.groupId);
    setState(() {
      _polylinePoints = positions.map((position) {
        return LatLng(position['latitude'], position['longitude']);
      }).toList();

      // 最初に記録された位置を初期位置として設定
      if (_polylinePoints.isNotEmpty) {
        _initialPosition = _polylinePoints.first;
      }

      // ポリラインを作成してセットに追加
      _polylines.add(
        Polyline(
          polylineId: PolylineId('walking_route'),
          points: _polylinePoints,
          color: Colors.blue,
          width: 4,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('移動軌跡: グループID ${widget.groupId}'),
      ),
      body: _initialPosition == null
          ? Center(child: CircularProgressIndicator()) // 初期位置が取得できるまでローディング表示
          : GoogleMap(
              initialCameraPosition: CameraPosition(
                target: _initialPosition!, // 記録した最初の座標を初期位置に設定
                zoom: 15.0, // 初期ズームレベル
              ),
              polylines: _polylines, // ポリラインをマップに追加
              onMapCreated: _onMapCreated, // マップ作成時のコールバック
              myLocationEnabled: true, // 現在地表示を有効化
              myLocationButtonEnabled: true, // 現在地ボタンを表示
              zoomGesturesEnabled: true, // 拡大・縮小を有効化
              scrollGesturesEnabled: true, // パン（移動）を有効化
              rotateGesturesEnabled: true, // 回転を有効化
              tiltGesturesEnabled: true, // 傾きジェスチャーを有効化
            ),
    );
  }
}