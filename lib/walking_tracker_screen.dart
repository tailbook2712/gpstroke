import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart'; // 加速度センサー用
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
  bool _isMoving = false;  // 移動中かどうかのフラグ
  bool _isTracking = false;  // 追跡中かどうかのフラグ
  Timer? _timer;

  // 加速度センサーの値を保持
  double _accelerationThreshold = 1.0; // 加速度がこれ以上なら移動中とみなす
  bool _accelerometerMoving = false;   // 加速度センサーの結果
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;

  // しきい値 (距離・速度)
  final double distanceThreshold = 3.0; // 3メートル以上動いたら「移動中」とみなす
  final double speedThreshold = 0.5;    // 速度が0.5 m/s 以上なら移動と判定

  @override
  void initState() {
    super.initState();
    _startAccelerometerTracking(); // 加速度センサーの追跡開始
  }

  // 加速度センサーの追跡を開始
  void _startAccelerometerTracking() {
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

  // 位置情報の許可をリクエストし、位置情報を取得する
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

    _startTracking(); // 許可が確認できたら追跡開始
  }

  // 定期的に位置情報を取得し、移動かどうかを判定
  void _startTracking() {
    setState(() {
      _isTracking = true; // 追跡中フラグを設定
    });

    _timer = Timer.periodic(Duration(seconds: 5), (Timer t) async {
      try {
        Position position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.bestForNavigation, // 高精度なGPSデータ
        );
        _checkIfUserIsMoving(position);
      } catch (e) {
        print(e);
      }
    });
  }

  // 追跡を停止する関数
  void _stopTracking() {
    setState(() {
      _isTracking = false;  // 追跡中フラグを解除
      _isMoving = false;    // 停止中にリセット
    });
    _timer?.cancel();  // タイマーを停止
    _accelerometerSubscription?.cancel(); // 加速度センサーの停止
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

      // 移動履歴の保存
      _positions.add(newPosition);

      // 少なくとも3つのデータがあるとき過去の履歴を基に判定
      if (_positions.length >= 3) {
        double totalDistance = 0;
        for (int i = _positions.length - 3; i < _positions.length - 1; i++) {
          totalDistance += Geolocator.distanceBetween(
            _positions[i].latitude, _positions[i].longitude,
            _positions[i + 1].latitude, _positions[i + 1].longitude,
          );
        }

        // 移動距離と速度、そして加速度センサーの判定を組み合わせる
        if ((totalDistance > distanceThreshold && newPosition.speed > speedThreshold) || _accelerometerMoving) {
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
    _timer?.cancel(); // タイマーが動作中の場合はキャンセル
    _accelerometerSubscription?.cancel(); // 加速度センサーのストリームを停止
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
                      title: Text(
                          "位置 ${index + 1}: ${_positions[index].latitude}, ${_positions[index].longitude}"),
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