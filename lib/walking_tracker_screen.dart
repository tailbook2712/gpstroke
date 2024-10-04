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
  Timer? _stopTimer; // 停止検知用タイマー
  bool _isStopping = false; // 停止検知の状態
  final int stopDetectionInterval = 5; // 停止検知の秒数

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
      distanceFilter: 5.0,
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
    _accelerometerSubscription?.cancel();
    _gyroscopeSubscription?.cancel();

    _accelerometerSubscription = accelerometerEvents.listen((AccelerometerEvent event) {
      double acceleration = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      _currentVelocity += acceleration * _deltaTime;
      _accelerometerMoving = acceleration > _accelerationThreshold;

      // 移動から停止への遷移をチェック
      if (!_accelerometerMoving) {
        if (_stopTimer == null || !_stopTimer!.isActive) {
          _startStopDetection(); // 停止検知を開始
        }
      } else {
        _cancelStopDetection(); // 移動が再開した場合は停止検知をキャンセル
      }
    });

    _gyroscopeSubscription = gyroscopeEvents.listen((GyroscopeEvent event) {
      double deltaHeading = event.z; // Z軸の回転が方向の変化
      _currentDirection += deltaHeading * _deltaTime; // 方向を更新
    });
  }

  // 停止検知の開始: 一定時間移動がない場合に停止と判断
  void _startStopDetection() {
    _isStopping = true;
    _stopTimer = Timer(Duration(seconds: stopDetectionInterval), () {
      setState(() {
        _isMoving = false; // 停止中に変更
        _isStopping = false;
      });
      print('停止中');
    });
  }

  // 停止検知のキャンセル: 移動が再開した場合にキャンセル
  void _cancelStopDetection() {
    if (_stopTimer != null && _stopTimer!.isActive) {
      _stopTimer!.cancel();
    }
    _isStopping = false;
  }

  @override
  void dispose() {
    _accelerometerSubscription?.cancel(); // 加速度センサーのストリームを停止
    _gyroscopeSubscription?.cancel(); // ジャイロスコープのストリームを停止
    _stopTimer?.cancel(); // 停止検知のタイマーを停止
    bg.BackgroundGeolocation.stop(); // flutter_background_geolocation の停止
    super.dispose();
  }

  // 室内にいる場合のデッドレコニングを使った移動軌跡の補完
  void _useDeadReckoning() {
    double deltaX = _currentVelocity * cos(_currentDirection) * _deltaTime;
    double deltaY = _currentVelocity * sin(_currentDirection) * _deltaTime;

    _previousX += deltaX;
    _previousY += deltaY;

    print('デッドレコニングによる推定位置 X: $_previousX, Y: $_previousY');
  }

  // Wi-Fi接続状況を確認して室内かどうかを判断
  Future<bool> _isConnectedToWiFi() async {
    var connectivityResult = await Connectivity().checkConnectivity();
    return connectivityResult == ConnectivityResult.wifi;
  }

  // GPSの精度やWi-Fi接続状況を使って室内かどうかを判定する
  Future<void> _checkIndoorStatus(Position newPosition) async {
    bool isWiFiConnected = await _isConnectedToWiFi();
    bool isGPSAccurate = newPosition.accuracy < 30.0;

    if (isWiFiConnected || !isGPSAccurate) {
      _isIndoors = true;
      print('室内にいる可能性があります。');
    } else {
      _isIndoors = false;
      print('室外にいる可能性があります。');
    }
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
      _isTracking = true;
    });

    bg.BackgroundGeolocation.start();
  }

  // 追跡を停止する関数
  void _stopTracking() {
    setState(() {
      _isTracking = false;
      _isMoving = false;
    });

    bg.BackgroundGeolocation.stop();
  }

  // ノイズ除去: 小さすぎる距離移動は無視
  bool _isNoise(double distance) {
    return distance < noiseThreshold;
  }

  // ユーザーが移動中かどうかを判定する
  Future<void> _checkIfUserIsMoving(Position newPosition) async {
    await _checkIndoorStatus(newPosition);

    if (_isIndoors) {
      _useDeadReckoning();
    } else if (_previousPosition != null) {
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

      _positions.add(newPosition);
      if (_positions.length > smoothingWindow) {
        _positions.removeAt(0);
      }

      if (newPosition.speed > speedThreshold && _accelerometerMoving) {
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
              onPressed: _isTracking ? _stopTracking : _checkPermissionAndStartTracking,
              child: Text(_isTracking ? '追跡停止' : '追跡開始'),
            ),
          ],
        ),
      ),
    );
  }
}