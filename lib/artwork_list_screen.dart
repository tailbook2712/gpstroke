import 'dart:io';
import 'package:flutter/material.dart';

import 'artwork_detail_screen.dart';

class ArtworkListScreen extends StatelessWidget {
  final List<File> savedArtworks; // 保存されたアートワークのファイルリスト

  ArtworkListScreen({required this.savedArtworks});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Saved Artworks'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: GridView.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2, // 1行に2つ表示
            crossAxisSpacing: 16, // アイテムの間の横スペース
            mainAxisSpacing: 16, // アイテムの間の縦スペース
            childAspectRatio: 1, // 正方形に近い形に設定
          ),
          itemCount: savedArtworks.length, // 保存されたアートワークの数
          itemBuilder: (context, index) {
            return GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ArtworkDetailScreen(
                      artworkFile: savedArtworks[index],
                    ),
                  ),
                );
              },
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.grey[300], // 背景色
                  borderRadius: BorderRadius.circular(16), // 角を丸くする
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.file(
                    savedArtworks[index], // 保存された画像ファイルを表示
                    fit: BoxFit.cover, // 画像をコンテナに収める
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}