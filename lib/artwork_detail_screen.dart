import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'artwork_creation_screen.dart';
import 'database_helper.dart';
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

  @override
  void initState() {
    super.initState();
    _dbHelper = DatabaseHelper();
    _loadCanvasState();
  }

  Future<void> _loadCanvasState() async {
    try {
      String jsonString = await widget.canvasFile.readAsString();
      List<dynamic> data = jsonDecode(jsonString);

      setState(() {
        _trajectories = data.map((item) {
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

          return TransformablePolyline(
            positions,
            Offset(item['position']['dx'], item['position']['dy']),
          )
            ..scale = item['scale']
            ..rotation = item['rotation'];
        }).toList();
      });
    } catch (e) {
      print("キャンバス状態の読み込みエラー: $e");
    }
  }

  Future<void> _showTrajectoryDetails(TransformablePolyline trajectory) async {
    try {
      // groupIdの取得: positionsからユニークなハッシュを生成
      int groupId = trajectory.polyline.hashCode;

      // データベースから記録を取得
      Map<String, dynamic>? record = await _dbHelper.getRecordByGroupId(groupId);

      if (record != null) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => WalkingDetailScreen(
              groupId: groupId,
              date: record['date'],
              steps: record['steps'],
              distance: record['distance'].toStringAsFixed(2),
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
        title: Text('Artwork Detail'),
      ),
      body: Stack(
        children: [
          Stack(
            children: _trajectories.map((item) {
              return Positioned(
                left: item.position.dx,
                top: item.position.dy,
                child: GestureDetector(
                  onTap: () => _showTrajectoryDetails(item),
                  child: Transform(
                    transform: Matrix4.identity()
                      ..translate(item.position.dx, item.position.dy)
                      ..scale(item.scale)
                      ..rotateZ(item.rotation),
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
          ),
        ],
      ),
    );
  }
}