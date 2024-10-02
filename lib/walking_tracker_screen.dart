import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart'; // 加速度センサー用
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg; // flutter_background_geolocation のインポート
import 'dart:async';
import 'dart:math';

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
  Timer? _timer;

  // 加速度センサーの値を保持
  double _accelerationThreshold = 0.5; // より敏感に移動を検出
  bool _accelerometerMoving = false; // 加速度センサーの結果
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;

  // しきい値 (距離・速度)
  final double distanceThreshold = 2.0; // より敏感に移動を検出
  final double speedThreshold = 0.5; // 速度が0.5 m/s 以上なら移動と判定
  final int smoothingWindow = 3; // 平滑化のためのウィンドウサイズ
  final double noiseThreshold = 1.0; // より敏感にノイズを無視

  @override
  void initState() {
    super.initState();
    _startAccelerometerTracking(); // 加速度センサーの追跡開始
    _initializeBackgroundGeolocation(); // flutter_background_geolocation の初期化
  }

  // flutter_background_geolocationのデータを使ってPositionオブジェクトを作成
  void _initializeBackgroundGeolocation() {
    bg.BackgroundGeolocation.onLocation((bg.Location location) {
      // 必要なパラメータをすべて指定してPositionオブジェクトを作成
      _checkIfUserIsMoving(Position(
        latitude: location.coords.latitude,
        longitude: location.coords.longitude,
        timestamp: DateTime.now(), // タイムスタンプを追加
        accuracy: location.coords.accuracy,
        altitude: location.coords.altitude,
        altitudeAccuracy: location.coords.altitudeAccuracy ?? 0.0, // nullの場合のデフォルト値を設定
        heading: location.coords.heading,
        speed: location.coords.speed,
        speedAccuracy: location.coords.speedAccuracy ?? 0.0, // nullの場合のデフォルト値を設定
        headingAccuracy: location.coords.headingAccuracy ?? 0.0, // nullの場合のデフォルト値を設定
      ));
    });

    bg.BackgroundGeolocation.ready(bg.Config(
      desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
      distanceFilter: 10.0, // 10mごとに更新
      stopOnTerminate: false,
      startOnBoot: true,
    )).then((bg.State state) {
      if (!state.enabled) {
        bg.BackgroundGeolocation.start();
      }
    });
  }

  // 加速度センサーの追跡を開始
  void _startAccelerometerTracking() {
    // すでに購読があればキャンセルしてリッスンし直す
    _accelerometerSubscription?.cancel();

    _accelerometerSubscription = accelerometerEvents.listen((AccelerometerEvent event) {
      // 加速度の大きさを計算
      double acceleration = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);

      // 一定の加速度以上なら移動中とみなす
      if (acceleration > _accelerationThreshold) {
        _accelerometerMoving = true;
      } else {
        _accelerometerMoving = false;
      }
    });
  }

  // 位置情報の許可をリクエストし、バックグラウンドで位置情報を追跡
  Future<void> _checkPermissionAndStartTracking() async {
    LocationPermission permission;

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        print("位置情報の許可が拒否されました。");
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      print("位置情報の許可が永久に拒否されています。設定から変更してください。");
      return;
    }

    _startTracking();
  }

  // 定期的に位置情報を取得し、バックグラウンドで追跡
  void _startTracking() {
    setState(() {
      _isTracking = true; // 追跡中フラグを設定
    });

    bg.BackgroundGeolocation.start(); // flutter_background_geolocation の追跡を開始
  }

  // 追跡を停止する関数
  void _stopTracking() {
    setState(() {
      _isTracking = false; // 追跡中フラグを解除
      _isMoving = false; // 停止中にリセット
    });

    bg.BackgroundGeolocation.stop(); // flutter_background_geolocation の追跡を停止
  }

  // ノイズ除去: 小さすぎる距離移動は無視
  bool _isNoise(double distance) {
    return distance < noiseThreshold;
  }

  // ユーザーが移動中かどうかを判定する
  void _checkIfUserIsMoving(Position newPosition) {
    if (_previousPosition != null) {
      // 距離を計算
      double distance = Geolocator.distanceBetween(
        _previousPosition!.latitude,
        _previousPosition!.longitude,
        newPosition.latitude,
        newPosition.longitude,
      );

      // ノイズ（小さな移動）を無視
      if (_isNoise(distance)) {
        return; // ノイズとして無視
      }

      // 平滑化: 過去の位置データと平均して急激な変化を抑える
      _positions.add(newPosition);
      if (_positions.length > smoothingWindow) {
        _positions.removeAt(0); // ウィンドウサイズを超えたら古いデータを削除
      }

      // 平均位置を計算
      double avgLatitude = _positions.map((pos) => pos.latitude).reduce((a, b) => a + b) / _positions.length;
      double avgLongitude = _positions.map((pos) => pos.longitude).reduce((a, b) => a + b) / _positions.length;

      // 平均位置から移動距離を再計算
      double smoothedDistance = Geolocator.distanceBetween(
        avgLatitude, avgLongitude,
        newPosition.latitude, newPosition.longitude,
      );

      // 移動履歴の保存
      if (_positions.length >= smoothingWindow) {
        // 移動距離と速度、加速度センサーの判定を組み合わせる
        if ((smoothedDistance > distanceThreshold && newPosition.speed > speedThreshold) || _accelerometerMoving) {
          setState(() {
            _isMoving = true;
          });
        } else {
          setState(() {
            _isMoving = false;
          });
        }
      }
    }

    _previousPosition = newPosition;
  }

  @override
  void dispose() {
    _accelerometerSubscription?.cancel(); // 加速度センサーのストリームを停止
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
            // 追跡が開始されたら移動中/停止中を表示
            if (_isTracking)
              Text(
                _isMoving ? '移動中' : '停止中',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
            SizedBox(height: 20),
            // 位置情報の表示
            if (_currentPosition != null)
              Text(
                "現在位置: ${_currentPosition!.latitude}, ${_currentPosition!.longitude}",
              ),
            SizedBox(height: 20),
            // 移動中のとき、記録した座標を表示
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
            // 追跡の開始・停止ボタン
            ElevatedButton(
              onPressed: _isTracking ? _stopTracking : _checkPermissionAndStartTracking,
              child: Text(_isTracking ? '追跡停止' : '追跡開始'),
            ),
          ],
        ),
      ),
    );
  }
}