import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class DraftListScreen extends StatelessWidget {
  final Function(Map<String, dynamic>) onDraftSelected;

  DraftListScreen({required this.onDraftSelected});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('途中保存一覧'),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _loadDrafts(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(child: CircularProgressIndicator());
          }

          final drafts = snapshot.data!;
          return ListView.builder(
            itemCount: drafts.length,
            itemBuilder: (context, index) {
              final draft = drafts[index];
              final timestamp = draft['timestamp'] ?? '不明な日時';

              return Dismissible(
                key: ValueKey(draft['filePath']),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: Colors.red,
                  alignment: Alignment.centerRight,
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Icon(Icons.delete, color: Colors.white),
                ),
                onDismissed: (direction) async {
                  await _deleteDraft(draft['filePath']);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('下書きを削除しました')),
                  );
                },
                child: ListTile(
                  title: Text('下書き ${index + 1}'),
                  subtitle: Text(timestamp),
                  onTap: () {
                    onDraftSelected(draft);
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<List<Map<String, dynamic>>> _loadDrafts() async {
    final directory = await getApplicationDocumentsDirectory();
    final draftsDirectory = Directory('${directory.path}/drafts');

    if (!(await draftsDirectory.exists())) {
      return [];
    }

    final draftFiles = draftsDirectory.listSync().whereType<File>();
    return Future.wait(draftFiles.map((file) async {
      try {
        final jsonString = await file.readAsString();
        final data = jsonDecode(jsonString);

        // デフォルト値を設定
        data['filePath'] = file.path;
        data['timestamp'] ??= '不明な日時';
        return data;
      } catch (e) {
        // エラーが発生した場合は無視して次のファイルを処理
        return {'filePath': file.path, 'timestamp': '不明な日時'};
      }
    }));
  }

  Future<void> _deleteDraft(String filePath) async {
    final file = File(filePath);
    if (await file.exists()) {
      await file.delete();
    }
  }
}