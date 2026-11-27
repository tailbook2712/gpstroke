import 'dart:io';
import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'artwork.dart';
import 'artwork_detail_screen.dart';
import 'artwork_store.dart';

class ArtworkListScreen extends StatefulWidget {
  ArtworkListScreen();

  @override
  _ArtworkListScreenState createState() => _ArtworkListScreenState();
}

class _ArtworkListScreenState extends State<ArtworkListScreen> {
  /// 作品（新しい順。読み込み中は null）
  List<Artwork>? artworks;

  /// 作品画像（作品 ID → 端末内のファイル）。スクロールのたびに読み直さないよう覚えておく
  final Map<String, Future<File?>> _images = {};

  @override
  void initState() {
    super.initState();
    _loadArtworks();
  }

  // 作品を読み込む（起動時にサーバーから読み込んだ一覧を使う）
  Future<void> _loadArtworks() async {
    List<Artwork> loaded;
    try {
      loaded = await ArtworkStore.loadAll();
    } catch (e) {
      print('❌ 作品の読み込みエラー: $e');
      loaded = [];
    }
    if (!mounted) return;
    setState(() {
      artworks = loaded;
    });
  }

  // 作品画像（端末内になければ Firestore から取得する）
  Future<File?> _imageOf(Artwork artwork) =>
      _images[artwork.id] ??= ArtworkStore.loadImage(artwork.id);

  // 画像の実際のサイズを取得する
  Future<Size> _getImageSize(File imageFile) async {
    final bytes = await imageFile.readAsBytes();
    final ui.Image image = await decodeImageFromList(bytes);
    final size = Size(image.width.toDouble(), image.height.toDouble());
    image.dispose(); // メモリ解放
    return size;
  }

  // 削除してよいかを確認してから、作品を削除する
  Future<void> _confirmDeleteArtwork(Artwork artwork) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text("作品の削除"),
          content: Text("この作品を削除してもよろしいですか？"),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text("キャンセル"),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text("削除"),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    await _deleteArtwork(artwork);
  }

  // 作品を削除する
  // （作品画像と、共有していれば共有データも消える。作品に使っていた軌跡は軌跡リストに戻る）
  Future<void> _deleteArtwork(Artwork artwork) async {
    try {
      await ArtworkStore.delete(artwork);

      if (!mounted) return;
      setState(() {
        artworks?.removeWhere((a) => a.id == artwork.id);
        _images.remove(artwork.id);
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('作品を削除しました')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('削除に失敗しました: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final artworks = this.artworks;
    return Scaffold(
      appBar: AppBar(
        title: Text('ギャラリー'),
      ),
      body: artworks == null
          ? Center(child: CircularProgressIndicator())
          : artworks.isEmpty
              ? Center(child: Text('作品がありません．軌跡から作品を作成してください．'))
              : Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: GridView.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2, // 2列表示
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 16,
                      childAspectRatio: 0.7, // カードの高さを調整
                    ),
                    itemCount: artworks.length,
                    itemBuilder: (context, index) {
                      final artwork = artworks[index];

                      // 長押しで削除（確認ダイアログを挟む）
                      return GestureDetector(
                        onLongPress: () => _confirmDeleteArtwork(artwork),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) =>
                                  ArtworkDetailScreen(artwork: artwork),
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
                                  borderRadius: BorderRadius.vertical(
                                      top: Radius.circular(12)),
                                  child: _buildImage(artwork),
                                ),
                              ),
                              // テキスト部分: 画像の下に表示
                              Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      artwork.name,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    SizedBox(height: 4),
                                    Text(
                                      '軌跡数: ${artwork.strokes.length}',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                    Text(
                                      '距離: ${artwork.totalDistanceKm.toStringAsFixed(2)} km',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                    Text(
                                      '歩数: ${artwork.totalSteps}',
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
                  ),
                ),
    );
  }

  // 作品画像（取得中・取得できない場合は代わりの表示）
  Widget _buildImage(Artwork artwork) {
    return FutureBuilder<File?>(
      future: _imageOf(artwork),
      builder: (context, fileSnapshot) {
        if (fileSnapshot.connectionState != ConnectionState.done) {
          return Center(child: CircularProgressIndicator());
        }
        final imageFile = fileSnapshot.data;
        if (imageFile == null) {
          return Container(
            color: Colors.grey[200],
            child: Center(
              child: Icon(Icons.image_not_supported_outlined,
                  color: Colors.grey[500]),
            ),
          );
        }
        return FutureBuilder<Size>(
          future: _getImageSize(imageFile),
          builder: (context, imageSnapshot) {
            // 画像サイズが取得できた場合はそのアスペクト比を使用
            final aspectRatio = imageSnapshot.hasData
                ? imageSnapshot.data!.width / imageSnapshot.data!.height
                : 16 / 9; // デフォルトのアスペクト比

            final containerWidth =
                (MediaQuery.of(context).size.width - 48) / 2; // 2列表示を考慮
            final containerHeight = containerWidth / aspectRatio;

            return Container(
              height: containerHeight,
              width: containerWidth,
              child: Image.file(
                imageFile,
                fit: BoxFit.contain,
                width: double.infinity,
                height: double.infinity,
              ),
            );
          },
        );
      },
    );
  }
}
