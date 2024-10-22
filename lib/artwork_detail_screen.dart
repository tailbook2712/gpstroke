import 'dart:io';
import 'package:flutter/material.dart';

class ArtworkDetailScreen extends StatelessWidget {
  final File artworkFile;

  ArtworkDetailScreen({required this.artworkFile});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Artwork Detail'),
      ),
      body: Center(
        child: Image.file(
          artworkFile, // タップされたアートワークの画像を表示
          fit: BoxFit.contain, // 画像を画面内に収める
        ),
      ),
    );
  }
}