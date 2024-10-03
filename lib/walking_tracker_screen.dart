import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart'; // 加速度センサー用
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg; // flutter_background_geolocation のインポート
import 'package:connectivity_plus/connectivity_plus.dart'; // Wi-Fi接続確認用
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

  // 加速度センサーとジャイロスコープの変数
  double _currentVelocity = 0.0; // 現在の速度
  double _currentDirection = 0.0; // 現在の方向（ラジアン単位）
  double _previousX = 0.0; // 前のX座標
  double _previousY = 0.0; // 前のY座標
  double _deltaTime = 0.1; // 時間間隔
  double _accelerationThreshold = 1.0; // 加速度がこれ以上なら移動中とみなす
  bool _accelerometerMoving = false; // 加速度センサーの結果
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  StreamSubscription<GyroscopeEvent>? _gyroscopeSubscription;

  // しきい値 (距離・速度)
  final double distanceThreshold = 3.0; // 3メートル以上動いたら「移動中」とみなす
  final double speedThreshold = 0.3; // 速度が0.3 m/s 以上なら移動と判定
  final int smoothingWindow = 3; // 平滑化のためのウィンドウサイズ
  final double noiseThreshold = 2.0; // ノイズとみなす移動距離

  bool _isIndoors = false; // 室内判定のフラグ

  @override
  void initState() {
    super.initState();
    _startAccelerometerTracking(); // 加速度センサーの追跡開始
    _initializeBackgroundGeolocation(); // flutter_background_geolocation の初期化
  }

  // flutter_background_geolocationのデータを使ってPositionオブジェクトを作成
  void _initializeBackgroundGeolocation() {
    bg.BackgroundGeolocation.onLocation((bg.Location location) {
      // 位置情報が更新された場合に呼び出される
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
      distanceFilter: 5.0, // 5メートルごとに更新 (より細かい更新)
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
    _gyroscopeSubscription?.cancel();

    // 加速度センサー
    _accelerometerSubscription = accelerometerEvents.listen((AccelerometerEvent event) {
      double acceleration = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      _currentVelocity += acceleration * _deltaTime; // 速度を更新
      _accelerometerMoving = acceleration > _accelerationThreshold; // 一定の加速度以上なら移動中
    });

    // ジャイロスコープ
    _gyroscopeSubscription = gyroscopeEvents.listen((GyroscopeEvent event) {
      double deltaHeading = event.z; // Z軸の回転が方向の変化
      _currentDirection += deltaHeading * _deltaTime; // 方向を更新
    });
  }

  // Wi-Fi接続状況を確認して室内かどうかを判断
  Future<bool> _isConnectedToWiFi() async {
    var connectivityResult = await Connectivity().checkConnectivity();
    return connectivityResult == ConnectivityResult.wifi;
  }

  // GPSの精度やWi-Fi接続状況を使って室内かどうかを判定する
  Future<void> _checkIndoorStatus(Position newPosition) async {
    bool isWiFiConnected = await _isConnectedToWiFi();
    bool isGPSAccurate = newPosition.accuracy < 30.0; // GPS精度が30m以下なら正確

    // Wi-Fiに接続しているか、GPSが不正確であれば室内と判定
    if (isWiFiConnected || !isGPSAccurate) {
      _isIndoors = true;
      print('室内にいる可能性があります。');
    } else {
      _isIndoors = false;
      print('室外にいる可能性があります。');
    }
  }

  // 室内にいる場合のデッドレコニングを使った移動軌跡の補完
  void _useDeadReckoning() {
    // 移動距離を推定
    double deltaX = _currentVelocity * cos(_currentDirection) * _deltaTime;
    double deltaY = _currentVelocity * sin(_currentDirection) * _deltaTime;

    // 座標を更新
    _previousX += deltaX;
    _previousY += deltaY;

    print('デッドレコニングによる推定位置 X: $_previousX, Y: $_previousY');
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
  Future<void> _checkIfUserIsMoving(Position newPosition) async {
    // 室内かどうかの確認
    await _checkIndoorStatus(newPosition);

    if (_isIndoors) {
      // 室内の場合はデッドレコニングで位置を補完
      _useDeadReckoning();
    } else if (_previousPosition != null) {
      // 距離を計算
      double distance = Geolocator.distanceBetween(
        _previousPosition!.latitude,
        _previousPosition!.longitude,
        newPosition.latitude,
        newPosition.longitude,
      );

      // ノイズ（小さな移動）を無視
      if (_isNoise(distance)) {
        print('ノイズとして無視されました');
        return;
      }

      // 平滑化: 過去の位置データと平均して急激な変化を抑える
      _positions.add(newPosition);
      if (_positions.length > smoothingWindow) {
        _positions.removeAt(0); // ウィンドウサイズを超えたら古いデータを削除
      }

      // 移動距離と速度、加速度センサーの判定を両方満たしている場合に移動中と判定
      if (newPosition.speed > speedThreshold && _accelerometerMoving) {
        setState(() {
          _isMoving = true;
          _currentPosition = newPosition; // 位置情報を更新
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

  @override
  void dispose() {
    _accelerometerSubscription?.cancel(); // 加速度センサーのストリームを停止
    _gyroscopeSubscription?.cancel(); // ジャイロスコープのストリームを停止
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