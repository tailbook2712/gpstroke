import 'package:flutter/material.dart';
import 'art_generator.dart';
import 'database_helper.dart';

class ArtDisplayScreen extends StatefulWidget {
  @override
  _ArtDisplayScreenState createState() => _ArtDisplayScreenState();
}

class _ArtDisplayScreenState extends State<ArtDisplayScreen> {
  late Future<Map<String, dynamic>> _artData;
  bool _showTrajectoryHighlight = false; // 軌跡をハイライト表示するフラグ

  @override
  void initState() {
    super.initState();
    _artData = ArtGenerator(DatabaseHelper()).generateArtWithMotif();
  }

  // タップ時に軌跡をハイライトする状態を切り替える
  void _onTap() {
    setState(() {
      _showTrajectoryHighlight = !_showTrajectoryHighlight;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Generated Art'),
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _artData,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            if (snapshot.hasData) {
              return GestureDetector(
                onTap: _onTap, // タップ時に軌跡のハイライトを切り替え
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Motif: ${snapshot.data!['motifName']}',
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 30),
                      CustomPaint(
                        size: Size(300, 300), 
                        painter: _CombinedPainter(
                          snapshot.data!['motifPainter'],
                          snapshot.data!['trajectoryPainter'],
                          highlightTrajectory: _showTrajectoryHighlight, // 軌跡をハイライト表示
                        ),
                      ),
                    ],
                  ),
                ),
              );
            } else {
              return Center(child: Text('Failed to generate art.'));
            }
          } else {
            return Center(child: CircularProgressIndicator());
          }
        },
      ),
    );
  }
}

class _CombinedPainter extends CustomPainter {
  final CustomPainter motifPainter;
  final CustomPainter trajectoryPainter;
  final bool highlightTrajectory;

  _CombinedPainter(this.motifPainter, this.trajectoryPainter, {required this.highlightTrajectory});

  @override
  void paint(Canvas canvas, Size size) {
    // まずモチーフを描画
    motifPainter.paint(canvas, size);

    // 軌跡を描画。ハイライトする場合、異なる色で描画
    if (highlightTrajectory) {
      trajectoryPainter.paint(canvas, size);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}