import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;
import 'dart:async';
import 'package:walk_tracker_app/walking_history_screen.dart';
import 'database_helper.dart'; // データベースヘルパーのインポート

class WalkingTrackerScreen extends StatefulWidget {
  @override
  _WalkingTrackerScreenState createState() => _WalkingTrackerScreenState();
}

class _WalkingTrackerScreenState extends State<WalkingTrackerScreen> {
  Position? _currentPosition;
  Position? _previousPosition;
  List<Position> _positions = [];
  bool _isMoving = false; // 移動中かどうかのフラグ
  bool _isTracking = false; // 追跡中かどうかのフラグ
  bool _isRecording = false; // 記録中かどうかのフラグ
  Timer? _stopTimer; // 停止検知用タイマー
  final int stopDetectionInterval = 5; // 停止検知の秒数

  final double distanceThreshold = 3.0; // 3メートル以上動いたら「移動中」とみなす
  final double speedThreshold = 0.3; // 速度が0.3 m/s 以上なら移動と判定
  final int smoothingWindow = 3; // 平滑化のためのウィンドウサイズ
  final double noiseThreshold = 2.0; // ノイズとみなす移動距離

  late DatabaseHelper _dbHelper;
  int _currentGroupId = 0; // グループIDを管理

  @override
  void initState() {
    super.initState();
    _dbHelper = DatabaseHelper(); // データベースヘルパーを初期化
    _initializeBackgroundGeolocation(); // flutter_background_geolocation の初期化
  }

  // 記録開始ボタン押下時の処理
  void _startRecording() async {
    setState(() {
      _isRecording = true;
      _positions.clear(); // 記録を開始する際に座標リストをクリア
    });
    // 新しいグループIDを取得
    _currentGroupId = await _dbHelper.getNewGroupId();
    print('記録を開始しました');
  }

  // 記録停止ボタン押下時の処理
  void _stopRecording() async {
    setState(() {
      _isRecording = false;
    });
    
    // 記録された位置情報を保存
    for (var position in _positions) {
      await _dbHelper.insertPosition(
        _currentGroupId,
        position.latitude,
        position.longitude,
        position.timestamp!.toIso8601String(),
      );
    }
    print('記録を停止しました');
  }

  // flutter_background_geolocationのデータを使ってPositionオブジェクトを作成
  void _initializeBackgroundGeolocation() {
    bg.BackgroundGeolocation.onLocation((bg.Location location) {
      _checkIfUserIsMoving(Position(
        latitude: location.coords.latitude,
        longitude: location.coords.longitude,
        timestamp: DateTime.now(),
        accuracy: location.coords.accuracy,
        altitude: location.coords.altitude,
        altitudeAccuracy: location.coords.altitudeAccuracy ?? 0.0,
        heading: location.coords.heading,
        speed: location.coords.speed,
        speedAccuracy: location.coords.speedAccuracy ?? 0.0,
        headingAccuracy: location.coords.headingAccuracy ?? 0.0,
      ));
    });

    bg.BackgroundGeolocation.ready(bg.Config(
      desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
      distanceFilter: 5.0, // 5メートルごとに更新
      stopOnTerminate: false,
      startOnBoot: true,
    )).then((bg.State state) {
      if (!state.enabled) {
        bg.BackgroundGeolocation.start();
      }
    });
  }

  // GPSでのみユーザーが移動中かどうかを判定
  Future<void> _checkIfUserIsMoving(Position newPosition) async {
    if (_previousPosition != null) {
      double distance = Geolocator.distanceBetween(
        _previousPosition!.latitude,
        _previousPosition!.longitude,
        newPosition.latitude,
        newPosition.longitude,
      );

      if (_isNoise(distance)) {
        print('ノイズとして無視されました');
        return;
      }

      // 記録中であれば座標を保存
      if (_isRecording) {
        _positions.add(newPosition);
        print('座標が記録されました: ${newPosition.latitude}, ${newPosition.longitude}');
      }

      if (newPosition.speed > speedThreshold) {
        setState(() {
          _isMoving = true;
          _currentPosition = newPosition;
          print('移動中: 距離 = $distance, 速度 = ${newPosition.speed}');
        });
      } else {
        setState(() {
          _isMoving = false;
          print('停止中');
        });
      }
    } else {
      _currentPosition = newPosition;
    }

    _previousPosition = newPosition;
  }

  // ノイズ除去: 小さすぎる距離移動は無視
  bool _isNoise(double distance) {
    return distance < noiseThreshold;
  }

  @override
  void dispose() {
    _stopTimer?.cancel(); // 停止検知のタイマーを停止
    bg.BackgroundGeolocation.stop(); // flutter_background_geolocation の停止
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('歩行軌跡記録アプリ'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (_isTracking)
              Text(
                _isMoving ? '移動中' : '停止中',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
            SizedBox(height: 20),
            if (_currentPosition != null)
              Text(
                "現在位置: ${_currentPosition!.latitude}, ${_currentPosition!.longitude}",
              ),
            SizedBox(height: 20),
            if (_isMoving && _positions.isNotEmpty)
              Expanded(
                child: ListView.builder(
                  itemCount: _positions.length,
                  itemBuilder: (context, index) {
                    return ListTile(
                      title: Text("位置 ${index + 1}: ${_positions[index].latitude}, ${_positions[index].longitude}"),
                    );
                  },
                ),
              ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: _isRecording ? null : _startRecording, // 記録中は無効
              child: Text('記録開始'),
            ),
            SizedBox(height: 10),
            ElevatedButton(
              onPressed: _isRecording ? _stopRecording : null, // 記録停止時は無効
              child: Text('記録停止'),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => WalkingHistoryScreen()),
                );
              },
              child: Text('記録履歴を見る'),
            ),
          ],
        ),
      ),
    );
  }
}