import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'database_helper.dart';

class WalkingDetailScreen extends StatefulWidget {
  final int groupId;
  final String date;
  final int steps;
  final String distance;

  WalkingDetailScreen({
    required this.groupId,
    required this.date,
    required this.steps,
    required this.distance,
  });

  @override
  _WalkingDetailScreenState createState() => _WalkingDetailScreenState();
}

class _WalkingDetailScreenState extends State<WalkingDetailScreen> {
  late DatabaseHelper _dbHelper;
  late GoogleMapController _mapController;

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

  void _onMapCreated(GoogleMapController controller) {
    _mapController = controller;
  }

  // 指定されたグループ ID に基づいて位置情報と詳細データを取得
  Future<void> _fetchPositionsAndDetails() async {
    try {
      // 位置情報を取得
      List<Map<String, dynamic>> positions =
          await _dbHelper.getPositionsByGroupId(widget.groupId);

      setState(() {
        _polylinePoints = positions.map((position) {
          return LatLng(position['latitude'], position['longitude']);
        }).toList();

        if (_polylinePoints.isNotEmpty) {
          _initialPosition = _polylinePoints.first;
        }

        _polylines.add(
          Polyline(
            polylineId: PolylineId('walking_route_${widget.groupId}'),
            points: _polylinePoints,
            color: Colors.blue,
            width: 4,
          ),
        );
      });

      // 歩行記録が存在するか確認
      Map<String, dynamic>? record =
          await _dbHelper.getRecordByGroupId(widget.groupId);

      if (record != null) {
        setState(() {
          // 日付、歩数、距離を更新（既存のウィジェットを上書き）
          _date = record['date'];
          _steps = record['steps'];
          _distance = (record['distance'] / 1000).toStringAsFixed(2);
        });
      }
    } catch (e) {
      print("データの取得中にエラーが発生しました: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("データの取得中にエラーが発生しました")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.date), // 日付を表示
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '歩数: ${widget.steps} 歩',
                  style: TextStyle(fontSize: 18),
                ),
                SizedBox(height: 8),
                Text(
                  '距離: ${widget.distance} km',
                  style: TextStyle(fontSize: 18),
                ),
              ],
            ),
          ),
          Expanded(
            child: _initialPosition == null
                ? Center(child: CircularProgressIndicator())
                : GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: _initialPosition!,
                      zoom: 15.0,
                    ),
                    polylines: _polylines,
                    onMapCreated: _onMapCreated,
                    myLocationEnabled: true,
                    myLocationButtonEnabled: true,
                    zoomGesturesEnabled: true,
                    scrollGesturesEnabled: true,
                    rotateGesturesEnabled: true,
                    tiltGesturesEnabled: true,
                  ),
          ),
        ],
      ),
    );
  }
}