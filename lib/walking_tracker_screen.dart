import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:path_provider/path_provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:walk_tracker_app/artwork_list_screen.dart';
import 'package:walk_tracker_app/artwork_creation_screen.dart';
import 'database_helper.dart';
import 'firestore_service.dart';
import 'auth_service.dart';
import 'garmin_import_screen.dart';
import 'route_destination_selection_screen.dart';
import 'package:pedometer/pedometer.dart';

import 'utils/utils.dart';

// 記録モードの定義
enum RecordingMode {
  freeMode, // フリー記録モード（現在の軌跡を自由に記録）
  routeFollowMode, // ルート追従モード（ルート提案のルートをなぞって記録）
}

class WalkingTrackerScreen extends StatefulWidget {
  /// 初期ルートパス（ルート追従モードで開始する場合）
  final List<LatLng>? initialRoutePath;

  /// ルートメタデータ（距離、類似度など）
  final Map<String, dynamic>? initialRouteMetadata;

  const WalkingTrackerScreen({
    Key? key,
    this.initialRoutePath,
    this.initialRouteMetadata,
  }) : super(key: key);

  @override
  _WalkingTrackerScreenState createState() => _WalkingTrackerScreenState();
}

class _WalkingTrackerScreenState extends State<WalkingTrackerScreen> {
  // 記録モード（デフォルト: フリーモード）
  RecordingMode _recordingMode = RecordingMode.freeMode;

  // ルート追従モード用のデータ
  // ignore: unused_field
  List<LatLng>? _suggestedRoutePath; // 提案ルート（Polyline用）
  // ignore: unused_field
  Map<String, dynamic>? _routeMetadata; // ルート情報（距離など）

  // ignore: unused_field
  Position? _currentPosition;
  Position? _previousPosition;
  List<Position> _positions = [];
  // ignore: unused_field
  bool _isMoving = false;
  // ignore: unused_field
  bool _isTracking = false;
  bool _isRecording = false;
  double _totalDistance = 0.0;
  int _stepCount = 0;
  int _initialStepCount = 0; // 記録開始時の初期歩数

  final double distanceThreshold = 3.0;
  final double speedThreshold = 0.3;
  final double noiseThreshold = 2.0;

  late DatabaseHelper _dbHelper;
  List<List<Position>> trajectories = [];
  late FirestoreService _firestoreService;
  final AuthService _authService = AuthService();
  StreamSubscription<Position>? _positionStream;
  StreamSubscription<StepCount>? _stepStream;
  List<Map<String, dynamic>> savedArtworks = []; // スクリーンショットとキャンバス状態のリスト

  GoogleMapController? _mapController;
  Set<Polyline> _polylines = {};

  @override
  void initState() {
    super.initState();
    _dbHelper = DatabaseHelper();
    _firestoreService = FirestoreService();

    // 初期ルートが渡された場合はルート追従モードで開始
    if (widget.initialRoutePath != null &&
        widget.initialRoutePath!.isNotEmpty) {
      _suggestedRoutePath = widget.initialRoutePath;
      _routeMetadata = widget.initialRouteMetadata;
      _recordingMode = RecordingMode.routeFollowMode;
    }

    _initializeScreen(); // 非同期初期化処理をまとめたメソッド
    _loadSavedArtworks();
    _checkPermissionAndStartTracking();
    _initializeBackgroundGeolocation();
    _setInitialCameraPosition();

    // ポリラインを初期化
    _polylines.add(Polyline(
      polylineId: PolylineId("current_route"),
      points: [],
      color: Colors.blue,
      width: 5,
    ));
  }

  // 非同期初期化処理をまとめたメソッド
  Future<void> _initializeScreen() async {
    await _restoreDataFromFirestore(); // FirestoreからローカルDBにデータを復元
    await _loadTrajectories(); // 復元後にローカルDBから軌跡をロード
    await _syncUsedTrajectories(); // 使用済み軌跡情報を同期
    await _restoreArtworksFromFirestore(); // Firestoreからアートワークを復元
  }

  Future<void> _syncUsedTrajectories() async {
    await _dbHelper.syncUsedTrajectoriesFromFirestore();
  }

  // Firestoreから保存されたアートワークを復元
  Future<void> _restoreArtworksFromFirestore() async {
    try {
      final artworks = await _firestoreService.getAllArtworks();
      if (artworks.isEmpty) {
        print('復元可能なアートワークが見つかりませんでした');
        return;
      }

      final directory = await getApplicationDocumentsDirectory();
      final artworksDirectory = Directory('${directory.path}/artworks');
      final canvasDirectory = Directory('${directory.path}/canvas_states');

      if (!(await artworksDirectory.exists())) {
        await artworksDirectory.create(recursive: true);
      }
      if (!(await canvasDirectory.exists())) {
        await canvasDirectory.create(recursive: true);
      }

      int restoredCount = 0;
      for (var artwork in artworks) {
        try {
          final artworkId = artwork['artworkId'] ?? '';
          if (artworkId.isEmpty) {
            print('アートワークIDが見つかりません。スキップします。');
            continue;
          }

          final canvasState = artwork['canvasState'];
          if (canvasState == null) {
            print('キャンバス状態が見つかりません。スキップします: $artworkId');
            continue;
          }

          // 画像データをBase64からデコード
          if (artwork['imageData'] == null) {
            print('画像データが見つかりません。スキップします: $artworkId');
            continue;
          }

          Uint8List imageData = base64Decode(artwork['imageData']);

          // ファイルに保存
          File imgFile = File('${artworksDirectory.path}/$artworkId.png');

          // タイムスタンプの取得（エラーハンドリングを追加）
          String timestamp = '';
          try {
            if (artworkId.contains('_')) {
              timestamp = artworkId.split('_').last;
            } else {
              // タイムスタンプを生成
              timestamp = DateTime.now().millisecondsSinceEpoch.toString();
            }
          } catch (e) {
            // タイムスタンプの取得に失敗した場合は現在時刻を使用
            print('タイムスタンプの取得に失敗しました: $e');
            timestamp = DateTime.now().millisecondsSinceEpoch.toString();
          }

          File canvasFile =
              File('${canvasDirectory.path}/canvas_$timestamp.json');

          // すでに存在する場合はスキップ
          if (await imgFile.exists() && await canvasFile.exists()) {
            print('アートワークはすでに存在します: $artworkId');
            continue;
          }

          // ファイルに書き込み
          await imgFile.writeAsBytes(imageData);
          await canvasFile.writeAsString(jsonEncode(canvasState));

          print('アートワークを復元しました: $artworkId');
          restoredCount++;
        } catch (e) {
          print('アートワークの復元中にエラー: $e');
        }
      }

      print('Firestoreからアートワークを復元しました: $restoredCount件');

      // アートワークのリストを更新
      await _loadSavedArtworks();
    } catch (e) {
      print('Firestoreからのアートワーク復元エラー: $e');
    }
  }

  // 保存された作品をロード
  Future<void> _loadSavedArtworks() async {
    final directory = await getApplicationDocumentsDirectory();
    final artworksDirectory = Directory('${directory.path}/artworks');
    final canvasDirectory = Directory('${directory.path}/canvas_states');

    // 両ディレクトリが存在しない場合は空リストのまま返す
    if (!await artworksDirectory.exists() || !await canvasDirectory.exists()) {
      savedArtworks = [];
      return;
    }

    // スクリーンショットとキャンバス状態を対応付けてロード
    final artworkFiles = artworksDirectory.listSync().whereType<File>();
    final canvasFiles = canvasDirectory.listSync().whereType<File>();

    savedArtworks = artworkFiles
        .map((artworkFile) {
          // 対応するキャンバス状態ファイルを取得
          final timestamp = artworkFile.path.split('_').last.split('.').first;
          final canvasFile = canvasFiles.firstWhere(
            (file) => file.path.contains(timestamp),
            orElse: () => File(''), // 見つからなければ空ファイル（スキップ）
          );

          if (canvasFile.existsSync()) {
            return {
              'imageFile': artworkFile,
              'canvasFile': canvasFile,
            };
          }
          return null; // キャンバスファイルがない場合スキップ
        })
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  // 位置情報の許可を確認してトラッキングを開始
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

  // 位置情報のトラッキングを開始
  void _startTracking() {
    setState(() {
      _isTracking = true;
    });
    bg.BackgroundGeolocation.start();
  }

  // 位置情報の記録を開始
  void _startRecording() async {
    setState(() {
      _isRecording = true;
      _totalDistance = 0.0;
      _stepCount = 0;
      _positions.clear();
    });

    // 歩数のstreamを監視
    _stepStream = Pedometer.stepCountStream.listen((StepCount event) {
      if (_isRecording) {
        setState(() {
          if (_initialStepCount == 0) {
            _initialStepCount = event.steps; // 記録開始時の歩数を保存
          }
          _stepCount = event.steps - _initialStepCount; // 初期歩数を差し引いて0からカウント
        });
      }
    });

    // 位置情報のstreamを監視
    _positionStream =
        Geolocator.getPositionStream().listen((Position position) {
      if (_isRecording) {
        _updateDistance(position);
      }
    });
  }

  // 位置情報の記録を停止
  Future<void> _stopRecording() async {
    setState(() {
      _isRecording = false;
      _initialStepCount = 0;
    });

    _positionStream?.cancel();
    _stepStream?.cancel();

    if (_positions.isEmpty) return;

    final positionData = _positions.map((position) {
      return {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'timestamp': position.timestamp.toIso8601String(),
      };
    }).toList();

    // generateGroupId を使って groupId を生成
    String groupId = generateGroupId(_positions);

    // positions[0]のtimestampをdateとして使用
    final currentDate = _positions[0].timestamp.toIso8601String();

    // 記録モードの情報をメタデータとして保存
    Map<String, dynamic> metadata = {
      'recordingMode': _recordingMode.toString(),
    };

    // ルート追従モードの場合、ルート情報も保存
    if (_recordingMode == RecordingMode.routeFollowMode &&
        _routeMetadata != null) {
      metadata['routeMetadata'] = _routeMetadata;
      metadata['suggestedRouteDistance'] = _routeMetadata?['distance'];
    }

    await _dbHelper.insertWalkingData(
      groupId: groupId,
      date: currentDate,
      steps: _stepCount,
      distance: _totalDistance,
      positions: positionData,
    );

    // Firestore に保存
    await _firestoreService.saveWalkingData(
      groupId: groupId,
      steps: _stepCount,
      distance: _totalDistance,
      positions: positionData,
    );

    print("保存した groupId: $groupId");

    _positions.clear();
  }

  // BackgroundGeolocationの初期化
  void _initializeBackgroundGeolocation() {
    bg.BackgroundGeolocation.onLocation((bg.Location location) {
      _checkIfUserIsMoving(Position(
        latitude: location.coords.latitude,
        longitude: location.coords.longitude,
        timestamp: DateTime.now(),
        accuracy: location.coords.accuracy,
        altitude: location.coords.altitude,
        altitudeAccuracy: location.coords.altitudeAccuracy,
        heading: location.coords.heading,
        speed: location.coords.speed,
        speedAccuracy: location.coords.speedAccuracy,
        headingAccuracy: location.coords.headingAccuracy,
      ));
    }, (bg.LocationError error) {
      print("[onLocation] ERROR: ${error.code}, ${error.message}");
    });

    // BackgroundGeolocationの設定
    bg.BackgroundGeolocation.ready(bg.Config(
      desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
      distanceFilter: 5.0,
      stopOnTerminate: false,
      startOnBoot: true,
      enableHeadless: true,
    )).then((bg.State state) {
      if (!state.enabled) {
        bg.BackgroundGeolocation.start();
      }
    });
  }

  // ユーザーが移動しているかどうかをチェック
  Future<void> _checkIfUserIsMoving(Position newPosition) async {
    if (_previousPosition != null) {
      double distance = Geolocator.distanceBetween(
        _previousPosition!.latitude,
        _previousPosition!.longitude,
        newPosition.latitude,
        newPosition.longitude,
      );

      if (_isNoise(distance)) {
        return;
      }

      // 移動中の場合、速度に応じて記録間隔を変更
      int recordingInterval;
      if (newPosition.speed < 1.5) {
        // ゆっくり歩行
        recordingInterval = 7000;
      } else if (newPosition.speed < 3.5) {
        // 速歩
        recordingInterval = 5000;
      } else if (newPosition.speed < 10.0) {
        // 走る
        recordingInterval = 3000;
      } else {
        // さらに早い場合
        recordingInterval = 2000;
      }

      // 記録中の場合、位置情報を記録
      if (_isRecording) {
        _positions.add(newPosition);

        // ポリラインを更新
        _polylines = {
          Polyline(
            polylineId: PolylineId("current_route"),
            points: _positions
                .map((pos) => LatLng(pos.latitude, pos.longitude))
                .toList(),
            color: Colors.blue,
            width: 5,
          ),
        };
        setState(() {});

        await Future.delayed(Duration(milliseconds: recordingInterval));
      }

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

  bool _isNoise(double distance) {
    return distance < noiseThreshold;
  }

  // 位置情報の距離を更新
  void _updateDistance(Position newPosition) {
    if (_previousPosition != null) {
      final distance = Geolocator.distanceBetween(
        _previousPosition!.latitude,
        _previousPosition!.longitude,
        newPosition.latitude,
        newPosition.longitude,
      );
      // メートル単位からkmに変換
      _totalDistance += distance / 1000.0;
    }

    // ポリラインを更新
    setState(() {
      _positions.add(newPosition);
      _polylines = {
        Polyline(
          polylineId: PolylineId("current_route"),
          points: _positions
              .map((pos) => LatLng(pos.latitude, pos.longitude))
              .toList(),
          color: Colors.blue,
          width: 5,
        ),
      };
    });
    _previousPosition = newPosition;
  }

  // Firestoreからデータを復元
  Future<void> _restoreDataFromFirestore() async {
    try {
      List<Map<String, dynamic>> allWalkingData =
          await _firestoreService.getAllWalkingData();
      for (var data in allWalkingData) {
        // 各フィールドを取得
        String groupId = data['groupId'] ?? 0;
        String date = data['timestamp'] ?? DateTime.now().toIso8601String();
        int steps = data['steps'] ?? 0;
        double distance = data['distance'] ?? 0.0;

        // positionsがリスト型かを確認
        if (data['positions'] is List) {
          List<Map<String, dynamic>> positions =
              List<Map<String, dynamic>>.from(data['positions']);

          // データをローカルデータベースに保存
          await _dbHelper.insertWalkingData(
            groupId: groupId,
            date: date,
            steps: steps,
            distance: distance,
            positions: positions,
          );
        } else {
          print("予期しないpositionsの形式: ${data['positions']}");
        }
      }
      print("Firestoreからローカルデータベースにデータを復元しました");
    } catch (e) {
      print("データの復元に失敗しました: $e");
    }
  }

  // ローカルデータベースから軌跡を読み込む
  Future<void> _loadTrajectories() async {
    try {
      List<Map<String, dynamic>> walkingData =
          await _dbHelper.getAllWalkingData();
      List<List<Position>> loadedTrajectories = [];

      for (var data in walkingData) {
        // positions フィールドを JSON デコード
        List<dynamic> positionsData = jsonDecode(data['positions']);

        // Position オブジェクトに変換
        List<Position> positions = positionsData.map((pos) {
          return Position(
            latitude: pos['latitude'],
            longitude: pos['longitude'],
            timestamp: DateTime.tryParse(pos['timestamp']) ?? DateTime.now(),
            accuracy: 0.0,
            altitude: 0.0,
            altitudeAccuracy: 0.0,
            heading: 0.0,
            headingAccuracy: 0.0,
            speed: 0.0,
            speedAccuracy: 0.0,
          );
        }).toList();

        loadedTrajectories.add(positions);
      }

      setState(() {
        trajectories = loadedTrajectories;
      });
    } catch (e) {
      print("軌跡の読み込みエラー: $e");
    }
  }

  // アートワーク作成画面に遷移
  void _navigateToArtworkCreationScreen() async {
    await _loadTrajectories();
    await _syncUsedTrajectories(); // 使用済み軌跡情報を同期してから作成画面に移動

    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ArtworkCreationScreen(trajectories: trajectories),
      ),
    );

    // 作品が保存された場合、ギャラリーを更新
    if (result != null) {
      await _syncUsedTrajectories(); // 保存後も同期を行う
      await _loadSavedArtworks();
    }
  }

  // アートワークギャラリー画面に遷移
  Future<void> _navigatetoArtworkGalleryScreen() async {
    await _loadSavedArtworks();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ArtworkListScreen(savedArtworks: savedArtworks),
      ),
    );
  }

  // Garmin インポート画面に遷移
  Future<void> _navigateToGarminImportScreen() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GarminImportScreen(),
      ),
    );

    // インポート後、軌跡を再読み込み
    if (result != null) {
      await _loadTrajectories();
    }
  }

  // ルート提案画面に遷移
  Future<void> _navigateToRouteSuggestionScreen() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RouteDestinationSelectionScreen(),
      ),
    );

    // ルート選択画面から戻った場合、トグルをフリーモードにリセット
    setState(() {
      _recordingMode = RecordingMode.freeMode;
    });

    if (result != null && result is Map<String, dynamic>) {
      setState(() {
        _suggestedRoutePath = result['routePath'] as List<LatLng>;
        _routeMetadata = result['metadata'] as Map<String, dynamic>;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'ルートが設定されました: ${(_routeMetadata?['distance'] / 1000).toStringAsFixed(2)}km',
          ),
        ),
      );
    }
  }

  /// Polylineを構築（モードに応じて表示内容を分岐）
  Set<Polyline> _buildPolylines() {
    Set<Polyline> polylines = {};

    // 現在記録中の軌跡（青色）
    polylines.add(
      Polyline(
        polylineId: PolylineId("current_route"),
        points: _positions
            .map((pos) => LatLng(pos.latitude, pos.longitude))
            .toList(),
        color: Colors.blue,
        width: 5,
      ),
    );

    // ルート追従モード時、提案ルートを表示（緑色）
    if (_recordingMode == RecordingMode.routeFollowMode &&
        _suggestedRoutePath != null &&
        _suggestedRoutePath!.isNotEmpty) {
      polylines.add(
        Polyline(
          polylineId: PolylineId("suggested_route"),
          points: _suggestedRoutePath!,
          color: Colors.green,
          width: 4,
          geodesic: true,
        ),
      );
    }

    return polylines;
  }

  @override
  void dispose() {
    bg.BackgroundGeolocation.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('軌跡の記録', style: TextStyle(fontSize: 20)),
            SizedBox(height: 4),
            Text(
              '歩数: $_stepCount 歩  距離: ${(_totalDistance / 1000).toStringAsFixed(2)}km',
              style: TextStyle(fontSize: 14),
            ),
          ],
        ),
        actions: [
          // ユーザーアイコン（ログアウトメニュー）
          PopupMenuButton<String>(
            icon: CircleAvatar(
              radius: 16,
              backgroundImage: _authService.currentUser?.photoURL != null
                  ? NetworkImage(_authService.currentUser!.photoURL!)
                  : null,
              child: _authService.currentUser?.photoURL == null
                  ? Icon(Icons.person, size: 20)
                  : null,
            ),
            onSelected: (value) async {
              if (value == 'logout') {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text('ログアウト'),
                    content: Text('ログアウトしますか？'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text('キャンセル'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: Text('ログアウト'),
                      ),
                    ],
                  ),
                );
                if (confirm == true) {
                  await _authService.signOut();
                }
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _authService.currentUser?.displayName ?? 'ユーザー',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.black),
                    ),
                    Text(
                      _authService.currentUser?.email ?? '',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout, color: Colors.red),
                    SizedBox(width: 8),
                    Text('ログアウト', style: TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: LatLng(35.0, 135.0),
              zoom: 16,
            ),
            onMapCreated: (GoogleMapController controller) {
              _mapController = controller;
              _setInitialCameraPosition();
            },
            polylines: _buildPolylines(),
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
          ),
          // モード選択パネルとボタン（BottomNavigationBar の上）
          Positioned(
            bottom: 60,
            left: 16,
            right: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // トグルボタン（小さく、白背景）
                SegmentedButton<RecordingMode>(
                  segments: <ButtonSegment<RecordingMode>>[
                    ButtonSegment<RecordingMode>(
                      value: RecordingMode.freeMode,
                      label: Text('フリー'),
                      icon: Icon(Icons.location_on),
                    ),
                    ButtonSegment<RecordingMode>(
                      value: RecordingMode.routeFollowMode,
                      label: Text('ルート'),
                      icon: Icon(Icons.route),
                    ),
                  ],
                  selected: <RecordingMode>{_recordingMode},
                  style: SegmentedButton.styleFrom(
                    backgroundColor: Colors.white,
                    selectedBackgroundColor: Colors.blue,
                    selectedForegroundColor: Colors.white,
                  ),
                  onSelectionChanged: (Set<RecordingMode> newSelection) {
                    setState(() {
                      _recordingMode = newSelection.first;
                      // ルート提案モードに切り替えた時、自動的にルート提案画面に移動
                      if (_recordingMode == RecordingMode.routeFollowMode &&
                          (_suggestedRoutePath == null ||
                              _suggestedRoutePath!.isEmpty)) {
                        _navigateToRouteSuggestionScreen();
                      }
                    });
                  },
                ),
                SizedBox(height: 12),
                // アクションボタン
                SizedBox(
                  width: 200,
                  child: ElevatedButton.icon(
                    onPressed: _isRecording
                        ? _stopRecording
                        : (_recordingMode == RecordingMode.routeFollowMode &&
                                (_suggestedRoutePath == null ||
                                    _suggestedRoutePath!.isEmpty))
                            ? _navigateToRouteSuggestionScreen
                            : _startRecording,
                    icon: Icon(
                      _isRecording
                          ? Icons.stop
                          : (_recordingMode == RecordingMode.routeFollowMode &&
                                  (_suggestedRoutePath == null ||
                                      _suggestedRoutePath!.isEmpty))
                              ? Icons.add_location
                              : Icons.play_arrow,
                    ),
                    label: Text(
                      _isRecording
                          ? '記録停止'
                          : (_recordingMode == RecordingMode.routeFollowMode &&
                                  (_suggestedRoutePath == null ||
                                      _suggestedRoutePath!.isEmpty))
                              ? 'ルート提案'
                              : '記録開始',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isRecording
                          ? Colors.red
                          : (_recordingMode == RecordingMode.routeFollowMode &&
                                  (_suggestedRoutePath == null ||
                                      _suggestedRoutePath!.isEmpty))
                              ? Colors.orange
                              : Colors.blue,
                      padding: EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: 0,
        selectedItemColor: Colors.blue,
        unselectedItemColor: Colors.grey,
        items: [
          BottomNavigationBarItem(
            icon: Icon(Icons.location_on),
            label: '軌跡の記録',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.brush),
            label: '作品の制作',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.download),
            label: 'Garmin',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.collections),
            label: 'ギャラリー',
          ),
        ],
        onTap: (index) {
          switch (index) {
            case 0:
              break;
            case 1:
              _navigateToArtworkCreationScreen();
              break;
            case 2:
              _navigateToGarminImportScreen();
              break;
            case 3:
              _navigatetoArtworkGalleryScreen();
              break;
          }
        },
      ),
    );
  }

  Future<void> _setInitialCameraPosition() async {
    try {
      Position position = await Geolocator.getCurrentPosition();
      setState(() {
        _currentPosition = position;
      });

      _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(position.latitude, position.longitude),
            zoom: 16,
          ),
        ),
      );
    } catch (e) {
      print("現在位置を取得できませんでした: $e");
    }
  }
}
