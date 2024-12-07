import 'dart:convert';
import 'dart:io';
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

  final double canvasPadding = 20.0; // キャンバスの余白を定義

  @override
  void initState() {
    super.initState();
    _dbHelper = DatabaseHelper();
    _loadCanvasState();
  }

  Future<void> _loadCanvasState() async {
    try {
      String jsonString = await widget.canvasFile.readAsString();
      Map<String, dynamic> data = jsonDecode(jsonString);

      // 現在のキャンバスのサイズを取得
      double currentCanvasWidth = MediaQuery.of(context).size.width;
      double currentCanvasHeight = MediaQuery.of(context).size.height;

      double savedCanvasWidth = data['canvasWidth']; // 保存時のキャンバス幅
      double savedCanvasHeight = data['canvasHeight']; // 保存時のキャンバス高さ

      // 比率計算
      double widthRatio = currentCanvasWidth / savedCanvasWidth; // 幅の比率
      double heightRatio = currentCanvasHeight / savedCanvasHeight; // 高さの比率

      // デバッグ用
      print('復元時の比率 - widthRatio: $widthRatio, heightRatio: $heightRatio');

      setState(() {
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

          // 相対位置をピクセル単位に変換
          double adjustedDx = item['position']['dx'] * savedCanvasWidth;
          double adjustedDy = item['position']['dy'] * savedCanvasHeight;

          // デバッグ用出力
          print(
              '復元時 - dx: $adjustedDx, dy: $adjustedDy (元の dy: ${item['position']['dy']})'
              'adjustedDx: $adjustedDx, adjustedDy: $adjustedDy');

          // スケールは保存時の値をそのまま使用
          double adjustedScale = item['scale'];

          return TransformablePolyline(
            positions,
            Offset(adjustedDx, adjustedDy),
          )
            ..scale = adjustedScale
            ..rotation = item['rotation'];
        }).toList();
      });
    } catch (e) {
      print("キャンバス状態の読み込みエラー: $e");
    }
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
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      appBar: AppBar(
        title: Text('作品の詳細'),
      ),
      body: Container(
        width: screenWidth,
        height: screenHeight,
        child: Stack(
          children: [
            ..._trajectories.map((item) {
              return Positioned(
                left: item.position.dx.clamp(canvasPadding,
                    screenWidth - canvasPadding - item.scale * 150),
                top: item.position.dy.clamp(canvasPadding,
                    screenHeight - canvasPadding - item.scale * 150),
                child: GestureDetector(
                  onTap: () => _showTrajectoryDetails(item),
                  child: Transform(
                    transform: Matrix4.identity()
                      ..translate(75 * item.scale, 75 * item.scale)
                      ..rotateZ(item.rotation)
                      ..translate(-75 * item.scale, -75 * item.scale)
                      ..scale(item.scale),
                    origin: Offset(75, 75),
                    child: CustomPaint(
                      size: Size(150, 150),
                      painter: PolylinePainter(
                        positions: item.polyline,
                        minLat: item.minLat,
                        maxLat: item.maxLat,
                        minLon: item.minLon,
                        maxLon: item.maxLon,
                      ),
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
