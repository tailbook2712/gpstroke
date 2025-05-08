import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'database_helper.dart';
import 'package:intl/intl.dart';

class WalkingDetailScreen extends StatefulWidget {
  final String groupId;
  final String date;
  final int steps;
  final String distance;
  final bool hideBackButton; // 戻るボタンを非表示にするかどうかのフラグを追加

  WalkingDetailScreen({
    required this.groupId,
    required this.date,
    required this.steps,
    required this.distance,
    this.hideBackButton = false, // デフォルトではfalse
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
      // データベースから位置情報を取得
      List<Map<String, dynamic>> positions =
          await _dbHelper.getPositionsByGroupId(widget.groupId);

      if (positions.isNotEmpty) {
        setState(() {
          // LatLng に変換
          _polylinePoints = positions.map((position) {
            return LatLng(position['latitude'], position['longitude']);
          }).toList();

          // 初期位置を設定
          _initialPosition = _polylinePoints.first;

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
          if(positions.isNotEmpty) {
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
                ? Center(child: CircularProgressIndicator()) // ローディングインジケーター
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