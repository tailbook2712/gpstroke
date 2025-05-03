import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'dart:ui' as ui;
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
      'artworkName': data['meta']['artworkName'] ?? 'No Name',
    };
  }

  // 画像の実際のサイズを取得する
  Future<Size> _getImageSize(File imageFile) async {
    final bytes = await imageFile.readAsBytes();
    final ui.Image image = await decodeImageFromList(bytes);
    final size = Size(image.width.toDouble(), image.height.toDouble());
    image.dispose(); // メモリ解放
    return size;
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
                  child: Card(
                    elevation: 4,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 画像部分 - アスペクト比を維持して表示
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                            child: FutureBuilder<Size>(
                              future: _getImageSize(savedArtworks[index]['imageFile']),
                              builder: (context, imageSnapshot) {
                                // 画像サイズが取得できた場合はそのアスペクト比を使用
                                final aspectRatio = imageSnapshot.hasData
                                    ? imageSnapshot.data!.width / imageSnapshot.data!.height
                                    : 16 / 9; // デフォルトのアスペクト比

                                final containerWidth = (MediaQuery.of(context).size.width - 48) / 2; // 2列表示を考慮
                                final containerHeight = containerWidth / aspectRatio;

                                return Container(
                                  height: containerHeight,
                                  width: containerWidth,
                                  child: Image.file(
                                    savedArtworks[index]['imageFile'],
                                    fit: BoxFit.contain,
                                    width: double.infinity,
                                    height: double.infinity,
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                        // テキスト部分: 画像の下に表示
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                meta['artworkName'],
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              SizedBox(height: 4),
                              Text(
                                '軌跡数: $trajectoryCount',
                                style: TextStyle(fontSize: 12),
                              ),
                              Text(
                                '距離: ${totalDistance.toStringAsFixed(2)} km',
                                style: TextStyle(fontSize: 12),
                              ),
                              Text(
                                '歩数: $totalSteps',
                                style: TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
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