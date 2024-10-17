import 'dart:math';
import 'package:flutter/material.dart';
import 'database_helper.dart';

class ArtGenerator {
  final DatabaseHelper _dbHelper;
  final Random _random = Random();

  ArtGenerator(this._dbHelper);

  // モチーフ名と描画データを返す
  Future<Map<String, dynamic>> generateArtWithMotif() async {
    // 保存された移動軌跡データを取得
    List<List<Offset>> trajectories = await _getTrajectories();

    // ランダムにモチーフを選択し、その名前を保存
    Map<String, dynamic> motifData = _generateRandomMotif();
    List<Offset> motif = motifData['motif'];
    String motifName = motifData['motifName'];

    // 移動軌跡とモチーフを組み合わせた描画データを作成
    List<Offset> combinedPoints = _combineTrajectoriesWithMotif(trajectories, motif);

    // CustomPainterとモチーフ名を返す
    return {
      'motifPainter': _MotifPainter(motif), // モチーフ描画
      'trajectoryPainter': _TrajectoryPainter(trajectories), // 軌跡を描画
      'motifName': motifName,
    };
  }

  // 移動軌跡データを取得
  Future<List<List<Offset>>> _getTrajectories() async {
    List<List<Offset>> allTrajectories = [];
    List<int> groupIds = await _dbHelper.getAllGroupIds();

    for (var groupId in groupIds) {
      var positions = await _dbHelper.getPositionsAsPositionsByGroupId(groupId);
      List<Offset> trajectory = positions.map((pos) => Offset(pos.latitude, pos.longitude)).toList();
      allTrajectories.add(trajectory);
    }
    return allTrajectories;
  }

  // モチーフをランダムに生成
  Map<String, dynamic> _generateRandomMotif() {
    int choice = _random.nextInt(10); // 0から9までランダムに選択
    switch (choice) {
      case 0:
        return {'motif': _generateCircleMotif(), 'motifName': 'Circle'};
      case 1:
        return {'motif': _generateAnimalMotif(), 'motifName': 'Animal'};
      case 2:
        return {'motif': _generatePlantMotif(), 'motifName': 'Plant'};
      case 3:
        return {'motif': _generateStarMotif(), 'motifName': 'Star'};
      case 4:
        return {'motif': _generateSpiralMotif(), 'motifName': 'Spiral'};
      case 5:
        return {'motif': _generateWaveMotif(), 'motifName': 'Wave'};
      case 6:
        return {'motif': _generateHeartMotif(), 'motifName': 'Heart'};
      case 7:
        return {'motif': _generateTreeMotif(), 'motifName': 'Tree'};
      case 8:
        return {'motif': _generateButterflyMotif(), 'motifName': 'Butterfly'};
      case 9:
        return {'motif': _generateDiamondMotif(), 'motifName': 'Diamond'};
      default:
        return {'motif': _generateCircleMotif(), 'motifName': 'Circle'};
    }
  }

  // モチーフと移動軌跡を組み合わせて描画データを生成
  List<Offset> _combineTrajectoriesWithMotif(List<List<Offset>> trajectories, List<Offset> motif) {
    List<Offset> combined = [];

    // 軌跡とモチーフを交互に合成
    for (int i = 0; i < trajectories.length; i++) {
      List<Offset> trajectory = trajectories[i];
      for (int j = 0; j < trajectory.length; j++) {
        // 軌跡をスケーリングしてモチーフに合成
        Offset combinedPoint = Offset(
          trajectory[j].dx * (motif[j % motif.length].dx / 100),
          trajectory[j].dy * (motif[j % motif.length].dy / 100),
        );
        combined.add(combinedPoint);
      }
    }

    return combined;
  }

  // 円形モチーフ
  List<Offset> _generateCircleMotif() {
    double radius = 100;
    List<Offset> circle = [];
    for (int i = 0; i < 360; i += 10) {
      double radians = i * pi / 180;
      circle.add(Offset(radius * cos(radians), radius * sin(radians)));
    }
    return circle;
  }

  // 動物モチーフ（仮の形として、三角形）
  List<Offset> _generateAnimalMotif() {
    return [
      Offset(0, 0),
      Offset(100, 150),
      Offset(200, 0),
      Offset(0, 0),
    ];
  }

  // 植物モチーフ（葉っぱのような形）
  List<Offset> _generatePlantMotif() {
    return [
      Offset(0, 0),
      Offset(50, 100),
      Offset(100, 150),
      Offset(150, 100),
      Offset(200, 0),
    ];
  }

  // 星形モチーフ
  List<Offset> _generateStarMotif() {
    return [
      Offset(0, 50),
      Offset(14, 14),
      Offset(50, 0),
      Offset(14, -14),
      Offset(0, -50),
      Offset(-14, -14),
      Offset(-50, 0),
      Offset(-14, 14),
      Offset(0, 50),
    ];
  }

  // 渦巻きモチーフ
  List<Offset> _generateSpiralMotif() {
    List<Offset> spiral = [];
    double radius = 5.0;
    for (double theta = 0.0; theta < 6 * pi; theta += 0.1) {
      double x = radius * cos(theta);
      double y = radius * sin(theta);
      spiral.add(Offset(x, y));
      radius += 0.5;
    }
    return spiral;
  }

  // 波モチーフ
  List<Offset> _generateWaveMotif() {
    List<Offset> wave = [];
    for (double x = -100; x < 100; x += 5) {
      double y = 30 * sin(x / 10);
      wave.add(Offset(x, y));
    }
    return wave;
  }

  // ハートモチーフ
  List<Offset> _generateHeartMotif() {
    List<Offset> heart = [];
    for (double t = -pi; t < pi; t += 0.1) {
      double x = 16.0 * pow(sin(t), 3);
      double y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t);
      heart.add(Offset(x * 10, y * 10));
    }
    return heart;
  }

  // 木モチーフ
  List<Offset> _generateTreeMotif() {
    return [
      Offset(0, 0),
      Offset(0, -100),
      Offset(-50, -150),
      Offset(50, -150),
      Offset(0, -100),
      Offset(-30, -200),
      Offset(30, -200),
    ];
  }

  // 蝶モチーフ
  List<Offset> _generateButterflyMotif() {
    return [
      Offset(0, 0),
      Offset(100, 50),
      Offset(150, 100),
      Offset(100, 150),
      Offset(0, 200),
      Offset(-100, 150),
      Offset(-150, 100),
      Offset(-100, 50),
      Offset(0, 0),
    ];
  }

  // ダイヤモチーフ
  List<Offset> _generateDiamondMotif() {
    return [
      Offset(0, 50),
      Offset(50, 0),
      Offset(0, -50),
      Offset(-50, 0),
      Offset(0, 50),
    ];
  }
}

// モチーフの描画用クラス
class _MotifPainter extends CustomPainter {
  final List<Offset> motifPoints;

  _MotifPainter(this.motifPoints);

  @override
  void paint(Canvas canvas, Size size) {
    var paint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    for (int i = 0; i < motifPoints.length - 1; i++) {
      canvas.drawLine(motifPoints[i], motifPoints[i + 1], paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// 軌跡の描画用クラス
class _TrajectoryPainter extends CustomPainter {
  final List<List<Offset>> trajectoryPoints;

  _TrajectoryPainter(this.trajectoryPoints);

  @override
  void paint(Canvas canvas, Size size) {
    var paint = Paint()
      ..color = Colors.red
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    for (var trajectory in trajectoryPoints) {
      for (int i = 0; i < trajectory.length - 1; i++) {
        canvas.drawLine(trajectory[i], trajectory[i + 1], paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}