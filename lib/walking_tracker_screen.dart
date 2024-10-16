import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;
import 'package:walk_tracker_app/art_display_screen.dart';
import 'package:walk_tracker_app/polyline_history_screen.dart';
import 'dart:async';
import 'package:walk_tracker_app/walking_history_screen.dart';
import 'database_helper.dart';
import 'firestore_service.dart';

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

  final double distanceThreshold = 3.0; // 3メートル以上動いたら「移動中」とみなす
  final double speedThreshold = 0.3; // 速度が0.3 m/s 以上なら移動と判定
  final double noiseThreshold = 2.0; // ノイズとみなす移動距離

  late DatabaseHelper _dbHelper;
  late FirestoreService _firestoreService; // Firestoreサービスのインスタンス
  int _currentGroupId = 0; // グループIDを管理

  @override
  void initState() {
    super.initState();
    _dbHelper = DatabaseHelper(); // データベースヘルパーを初期化
    _firestoreService = FirestoreService(); // Firestoreサービスを初期化
    _checkPermissionAndStartTracking(); // 位置情報の許可をリクエストして追跡を開始
    _initializeBackgroundGeolocation(); // flutter_background_geolocation の初期化
    _restoreDataFromFirestore(); // Firestoreからデータを復元
  }

  // 位置情報の許可をリクエストし、位置情報を取得する
  Future<void> _checkPermissionAndStartTracking() async {
    LocationPermission permission;

    // 位置情報の許可を確認
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      // 許可が拒否されている場合、許可をリクエスト
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        print("位置情報の許可が拒否されました。");
        return;
      }
    }

    // 許可が永久に拒否されている場合
    if (permission == LocationPermission.deniedForever) {
      print("位置情報の許可が永久に拒否されています。設定から変更してください。");
      return;
    }

    // 許可が確認できたら位置情報の追跡を開始
    _startTracking();
  }

  // 位置情報の追跡を開始する関数
  void _startTracking() {
    setState(() {
      _isTracking = true;
    });

    bg.BackgroundGeolocation.start(); // flutter_background_geolocation の追跡を開始
  }

  // 記録開始ボタン押下時の処理
  void _startRecording() async {
    setState(() {
      _isRecording = true;
      _positions.clear(); // 記録を開始する際に座標リストをクリア
    });
    // 新しいグループIDを取得
    _currentGroupId = await _dbHelper.getNewGroupId();
  }

  // 記録停止ボタン押下時の処理
  void _stopRecording() async {
    setState(() {
      _isRecording = false;
    });

    // 位置情報をマップ形式で変換して保存
    List<Map<String, dynamic>> positionData = _positions.map((position) {
      return {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'timestamp': position.timestamp!.toIso8601String(),
      };
    }).toList();

    // ローカルDBに保存
    for (var position in _positions) {
      await _dbHelper.insertPosition(
        _currentGroupId,
        position.latitude,
        position.longitude,
        position.timestamp!.toIso8601String(),
      );
    }

    // Firestoreにもグループとして保存
    await _firestoreService.savePositionGroup(_currentGroupId, positionData);
  }

  // 記録されたグループを削除
  Future<void> _deletePositionGroup(int groupId) async {
    await _dbHelper.deletePositionGroup(groupId);
    await _firestoreService.deletePositionGroup(groupId);
  }

  // flutter_background_geolocationのデータを使ってPositionオブジェクトを作成
  void _initializeBackgroundGeolocation() {
    bg.BackgroundGeolocation.onLocation(
      (bg.Location location) {
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
      },
      (bg.LocationError error) {
        print("[onLocation] ERROR: ${error.code}, ${error.message}");
      }
    );

    bg.BackgroundGeolocation.ready(bg.Config(
      desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
      distanceFilter: 5.0, // 更新間隔
      stopOnTerminate: false, // アプリ終了時も動作を継続
      startOnBoot: true, // 再起動後も位置情報追跡を継続
      enableHeadless: true, // バックグラウンドでの動作
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

      // ノイズとみなす移動距離の場合は無視
      if (_isNoise(distance)) {
        return;
      }

      // 記録中であれば座標を保存
      if (_isRecording) {
        _positions.add(newPosition);
      }

      // 移動中かどうかの判定
      if (newPosition.speed > speedThreshold) {
        setState(() {
          _isMoving = true;
          _currentPosition = newPosition;
        });
      } else {
        setState(() {
          _isMoving = false;
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

  // Firestoreからデータを復元
  Future<void> _restoreDataFromFirestore() async {
    try {
      List<Map<String, dynamic>> allPositions = await _firestoreService.getAllPositions();
      for (var position in allPositions) {
        // ローカルデータベースに保存
        await _dbHelper.insertPosition(
          position['groupId'],
          position['latitude'],
          position['longitude'],
          position['timestamp'],
        );
      }
      print("Firestoreからローカルデータベースにデータを復元しました");
    } catch (e) {
      print("データの復元に失敗しました: $e");
    }
  }

  @override
  void dispose() {
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
                      title: Text(
                          "位置 ${index + 1}: ${_positions[index].latitude}, ${_positions[index].longitude}"),
                    );
                  },
                ),
              ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: _isRecording ? null : _startRecording, // 記録開始
              child: Text('記録開始'),
            ),
            SizedBox(height: 10),
            ElevatedButton(
              onPressed: _isRecording ? _stopRecording : null, // 記録停止
              child: Text('記録停止'),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => WalkingHistoryScreen()
                  ),
                );
              },
              child: Text('記録履歴を見る'),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => PolylineHistoryScreen()
                  ),
                );
              },
              child: Text('軌跡履歴を見る'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => ArtDisplayScreen()
                  ),
                );
              },
              child: Text('アートを生成'),
            ),
          ],
        ),
      ),
    );
  }
}