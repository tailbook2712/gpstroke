import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'artwork_detail_screen.dart';

class ArtworkListScreen extends StatelessWidget {
  final List<Map<String, dynamic>> savedArtworks; // 保存されたアートワークのファイルリスト

  ArtworkListScreen({required this.savedArtworks});

  // キャンバスのメタ情報を読み込む
  Future<Map<String, dynamic>> _loadCanvasMeta(File canvasFile) async {
    String jsonString = await canvasFile.readAsString();
    Map<String, dynamic> data = jsonDecode(jsonString);

    // メタデータを正確に取得
    return {
      'trajectoryCount': data['meta']['trajectoryCount'] ?? 0,
      'totalDistance': (data['meta']['totalDistance'] ?? 0.0),
      'totalSteps': data['meta']['totalSteps'] ?? 0,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('ギャラリー'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: GridView.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2, // 2列表示
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            childAspectRatio: 0.7, // カードの高さを調整
          ),
          itemCount: savedArtworks.length,
          itemBuilder: (context, index) {
            return FutureBuilder<Map<String, dynamic>>(
              future: _loadCanvasMeta(savedArtworks[index]['canvasFile']),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return Center(child: CircularProgressIndicator());
                }

                final meta = snapshot.data!;
                final trajectoryCount = meta['trajectoryCount'] ?? 0;
                final totalDistance = (meta['totalDistance'] ?? 0.0) / 1000.0; // km単位に変換
                final totalSteps = meta['totalSteps'] ?? 0;

                return GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ArtworkDetailScreen(
                          canvasFile: savedArtworks[index]['canvasFile'],
                        ),
                      ),
                    );
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // 画像部分
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.file(
                            savedArtworks[index]['imageFile'],
                            fit: BoxFit.contain,
                            width: double.infinity,
                            height: 150, // 高さを固定
                          ),
                        ),
                      ),
                      // テキスト部分: 画像の下に表示
                      Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              '軌跡数: $trajectoryCount',
                              style: TextStyle(fontSize: 12),
                            ),
                            Text(
                              '総距離: ${totalDistance.toStringAsFixed(2)} km',
                              style: TextStyle(fontSize: 12),
                            ),
                            Text(
                              '総歩数: $totalSteps',
                              style: TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}