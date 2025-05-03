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

class _ArtworkDetailScreenState extends State<ArtworkDetailScreen> {
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

  @override
  void initState() {
    super.initState();
    _dbHelper = DatabaseHelper();
    // ウィジェットが描画された後にキャンバス状態を読み込む
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCanvasState();
    });
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_artworkName),
        actions: [
          IconButton(
            icon: Icon(
              _isColorful ? Icons.color_lens : Icons.color_lens_outlined,
            ),
            onPressed: () {
              _setColorfulMode(!_isColorful); // カラフルモードを切り替え
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
            ..._trajectories.asMap().entries.map((entry) {
              int index = entry.key;
              TransformablePolyline item = entry.value;
              
              return Positioned(
                left: item.position.dx,
                top: item.position.dy,
                child: GestureDetector(
                  onTap: () => _showTrajectoryDetails(item),
                  child: Container(
                    width: trajectorySize,
                    height: trajectorySize,
                    // デバッグ用の境界線（必要に応じてコメント解除）
                    // decoration: BoxDecoration(
                    //   border: Border.all(color: Colors.red, width: 1),
                    // ),
                    child: Stack(
                      children: [
                        // 回転と拡大縮小を個別に適用して、ArtworkCreationScreenと同じ表示になるようにする
                        Positioned.fill(
                          child: Transform.rotate(
                            angle: item.rotation,
                            alignment: Alignment.center,
                            child: Transform.scale(
                              scale: item.scale,
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
          ],
        ),
      ),
    );
  }
}