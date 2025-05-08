import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'artwork_creation_screen.dart';
import 'database_helper.dart';
import 'utils/utils.dart';
import 'walking_detail_screen.dart';
import 'polyline_painter.dart';

class ArtworkDetailScreen extends StatefulWidget {
  final File canvasFile;

  ArtworkDetailScreen({required this.canvasFile});

  @override
  _ArtworkDetailScreenState createState() => _ArtworkDetailScreenState();
}

class _ArtworkDetailScreenState extends State<ArtworkDetailScreen> with TickerProviderStateMixin {
  List<TransformablePolyline> _trajectories = [];
  late DatabaseHelper _dbHelper;

  String _artworkName = "作品の詳細"; // 初期状態のタイトル
  final double canvasPadding = 20.0; // キャンバスの余白を定義
  bool _isColorful = false; // カラフル表示を切り替えるためのフラグ
  List<Color> _trajectoryColors = []; // 軌跡ごとの色を保持するリスト
  
  // 軌跡のサイズ定義 - ArtworkCreationScreenと同じサイズを使用
  final double trajectorySize = 100.0;
  
  // キャンバスの設定情報
  double? savedCanvasWidth;
  double? savedCanvasHeight;

  // スライドショー機能の状態管理
  bool _isSlideshowPlaying = false;
  int _currentTrajectoryIndex = -1; // -1は非選択状態
  late AnimationController _highlightController;
  late AnimationController _popupController;
  
  // スライドショーの設定
  final Duration _highlightDuration = Duration(milliseconds: 500);
  final Duration _popupDuration = Duration(milliseconds: 500);
  final Duration _transitionDuration = Duration(milliseconds: 500);
  final Duration _detailScreenDuration = Duration(seconds: 5); // 詳細画面の表示時間

  @override
  void initState() {
    super.initState();
    _dbHelper = DatabaseHelper();
    
    // アニメーション用コントローラの初期化
    _highlightController = AnimationController(
      vsync: this,
      duration: _highlightDuration,
    );
    
    _popupController = AnimationController(
      vsync: this,
      duration: _popupDuration,
    );
    
    // ウィジェットが描画された後にキャンバス状態を読み込む
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCanvasState();
    });
  }

  @override
  void dispose() {
    _highlightController.dispose();
    _popupController.dispose();
    super.dispose();
  }

  // キャンバスの状態の復元
  Future<void> _loadCanvasState() async {
    try {
      String jsonString = await widget.canvasFile.readAsString();
      Map<String, dynamic> data = jsonDecode(jsonString);

      // 作品名を取得
      String artworkName = data['meta']['artworkName'] ?? '作品の詳細';

      // 現在のキャンバスのサイズを取得
      final mediaQuery = MediaQuery.of(context);
      double currentCanvasWidth = mediaQuery.size.width;
      double currentCanvasHeight = mediaQuery.size.height - 
          mediaQuery.padding.top - 
          mediaQuery.padding.bottom - 
          AppBar().preferredSize.height;

      savedCanvasWidth = data['canvasWidth'] ?? currentCanvasWidth; // 保存時のキャンバス幅
      savedCanvasHeight = data['canvasHeight'] ?? currentCanvasHeight; // 保存時のキャンバス高さ

      print('保存時のキャンバスサイズ: $savedCanvasWidth x $savedCanvasHeight');
      print('現在のキャンバスサイズ: $currentCanvasWidth x $currentCanvasHeight');

      setState(() {
        _artworkName = artworkName;
        _trajectories = (data['trajectories'] as List<dynamic>).map((item) {
          List<Position> positions = (item['positions'] as List).map((pos) {
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

          // 相対位置を絶対位置に変換
          double relativeX = item['position']['dx'];
          double relativeY = item['position']['dy'];
          
          // 現在のキャンバスサイズに合わせて絶対位置を計算
          double absoluteX = relativeX * currentCanvasWidth;
          double absoluteY = relativeY * currentCanvasHeight;

          print('軌跡の相対位置: ($relativeX, $relativeY)');
          print('軌跡の絶対位置: ($absoluteX, $absoluteY)');
          print('軌跡の回転角度: ${item['rotation']}');
          print('軌跡のスケール: ${item['scale']}');

          return TransformablePolyline(
            positions,
            Offset(absoluteX, absoluteY),
          )
            ..scale = item['scale'] ?? 1.0
            ..rotation = item['rotation'] ?? 0.0;
        }).toList();

        // 初期状態の色リストを生成
        _trajectoryColors = List.generate(
          _trajectories.length,
          (_) => Colors.blue, // デフォルトカラーは青に設定
        );
      });
    } catch (e) {
      print("キャンバス状態の読み込みエラー: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("キャンバス状態の読み込みに失敗しました: $e")),
      );
    }
  }

  // カラフルな色を生成する
  Color _generateRandomColor() {
    Random random = Random();
    return Color.fromARGB(
      255,
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    );
  }

  void _setColorfulMode(bool isColorful) {
    setState(() {
      _isColorful = isColorful;
      _trajectoryColors = isColorful
          ? List.generate(
              _trajectories.length,
              (_) => _generateRandomColor(), // ランダムな色を生成
            )
          : List.generate(
              _trajectories.length,
              (_) => Colors.blue, // 青色に戻す
            );
    });
  }

  Future<void> _showTrajectoryDetails(TransformablePolyline trajectory) async {
    try {
      // 一貫性のある groupId を生成
      String groupId = generateGroupId(trajectory.polyline);

      // デバッグログ
      print("取得する groupId: $groupId");

      // データベースから記録を取得
      Map<String, dynamic>? record =
          await _dbHelper.getWalkingDataByGroupId(groupId);

      if (record != null) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => WalkingDetailScreen(
              groupId: groupId,
              date: record['date'],
              steps: record['steps'],
              distance: (record['distance'] / 1000).toStringAsFixed(2),
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("記録が見つかりません。")),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("エラーが発生しました: $e")),
      );
    }
  }

  // スライドショーの開始
  void _startSlideshow() async {
    if (_trajectories.isEmpty) return;
    
    setState(() {
      _isSlideshowPlaying = true;
      _currentTrajectoryIndex = -1; // リセット
    });
    
    // 最初の軌跡から順番に表示
    _showNextTrajectory();
  }
  
  // スライドショーの停止
  void _stopSlideshow() {
    setState(() {
      _isSlideshowPlaying = false;
      _currentTrajectoryIndex = -1;
      // _currentTrajectoryDetails = null;
    });
    
    // アニメーションをリセット
    _highlightController.reset();
    _popupController.reset();
    
    // 全ての軌跡の色を元に戻す
    setState(() {
      _trajectoryColors = List.generate(
        _trajectories.length,
        (_) => _isColorful 
            ? _generateRandomColor() 
            : Colors.blue,
      );
    });
  }
  
  // 次の軌跡を表示
  void _showNextTrajectory() async {
    if (!_isSlideshowPlaying) return;
    
    // 次のインデックスを計算
    int nextIndex = _currentTrajectoryIndex + 1;
    
    // 全ての軌跡を表示し終えたらスライドショーを停止
    if (nextIndex >= _trajectories.length) {
      _stopSlideshow();
      return;
    }
    
    // 次の軌跡をハイライト
    setState(() {
      _currentTrajectoryIndex = nextIndex;
      
      // 現在の軌跡をハイライト（赤色に変更）
      _trajectoryColors[nextIndex] = Colors.red;
    });
    
    // ハイライトのアニメーション
    _highlightController.reset();
    await _highlightController.forward();
    
    // 軌跡のポップアップアニメーション
    _popupController.reset();
    await _popupController.forward();
    
    // 軌跡の詳細情報を取得
    TransformablePolyline trajectory = _trajectories[nextIndex];
    String groupId = generateGroupId(trajectory.polyline);
    Map<String, dynamic>? record = await _dbHelper.getWalkingDataByGroupId(groupId);
    
    if (record != null) {
      // 詳細画面を表示するためのルート
      final detailRoute = PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => WalkingDetailScreen(
          groupId: groupId,
          date: record['date'],
          steps: record['steps'],
          distance: (record['distance'] / 1000).toStringAsFixed(2),
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: Duration(milliseconds: 500),
      );
      
      // 詳細画面へ遷移
      Navigator.of(context).push(detailRoute);
      
      // 一定時間後に自動で戻る
      await Future.delayed(_detailScreenDuration);
      
      // コンテキストが有効かつ、まだ詳細画面が表示されている場合は戻る
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      
      // ポップアップを元に戻す
      await _popupController.reverse();
      
      // 現在の軌跡の色を元に戻す（または指定の色に）
      setState(() {
        _trajectoryColors[nextIndex] = _isColorful 
            ? _generateRandomColor() 
            : Colors.blue;
      });
      
      // 次の軌跡へ移行するための遅延
      await Future.delayed(_transitionDuration);
      
      // スライドショーがまだ再生中なら次へ進む
      if (_isSlideshowPlaying) {
        _showNextTrajectory();
      }
    } else {
      // 記録が見つからない場合
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("軌跡の記録が見つかりません。")),
      );
      
      // ポップアップを元に戻す
      await _popupController.reverse();
      
      // 現在の軌跡の色を元に戻す
      setState(() {
        _trajectoryColors[nextIndex] = _isColorful 
            ? _generateRandomColor() 
            : Colors.blue;
      });
      
      // 次へ進む
      await Future.delayed(_transitionDuration);
      _showNextTrajectory();
    }
  }
  
  // この関数は不要になったため削除
  // 代わりにWalkingDetailScreenを表示する

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_artworkName),
        actions: [
          // カラフルモード切り替えボタン
          IconButton(
            icon: Icon(
              _isColorful ? Icons.color_lens : Icons.color_lens_outlined,
            ),
            onPressed: () {
              _setColorfulMode(!_isColorful); // カラフルモードを切り替え
            },
          ),
          // スライドショー制御ボタン
          IconButton(
            icon: Icon(
              _isSlideshowPlaying ? Icons.stop : Icons.slideshow,
            ),
            onPressed: () {
              if (_isSlideshowPlaying) {
                _stopSlideshow();
              } else {
                _startSlideshow();
              }
            },
          ),
        ],
      ),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        color: Colors.grey[200], // ArtworkCreationScreenと同じ背景色
        child: Stack(
          children: [
            // 軌跡の表示
            ..._trajectories.asMap().entries.map((entry) {
              int index = entry.key;
              TransformablePolyline item = entry.value;
              
              // 現在表示中の軌跡かどうかの判定
              bool isCurrentlyHighlighted = index == _currentTrajectoryIndex;
              
              // 拡大スケールを計算（ハイライト中ならアニメーション付き）
              double scale = item.scale;
              if (isCurrentlyHighlighted) {
                scale = scale * (1.0 + (_popupController.value * 0.5)); // 最大1.5倍まで拡大
              }
              
              return Positioned(
                left: item.position.dx,
                top: item.position.dy,
                child: GestureDetector(
                  onTap: () => _showTrajectoryDetails(item),
                  child: Container(
                    width: trajectorySize,
                    height: trajectorySize,
                    child: Stack(
                      children: [
                        // 回転と拡大縮小を適用
                        Positioned.fill(
                          child: Transform.rotate(
                            angle: item.rotation,
                            alignment: Alignment.center,
                            child: Transform.scale(
                              scale: scale,
                              alignment: Alignment.center,
                              child: CustomPaint(
                                size: Size(trajectorySize, trajectorySize),
                                painter: PolylinePainter(
                                  positions: item.polyline,
                                  minLat: item.minLat,
                                  maxLat: item.maxLat,
                                  minLon: item.minLon,
                                  maxLon: item.maxLon,
                                  color: _trajectoryColors[index], // 軌跡ごとの色を使用
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
            
            // スライドショー中のインジケーター
            if (_isSlideshowPlaying)
              Positioned(
                bottom: 20,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'スライドショー再生中: ${_currentTrajectoryIndex + 1} / ${_trajectories.length}',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}