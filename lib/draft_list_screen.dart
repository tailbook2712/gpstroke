import 'package:flutter/material.dart';

import 'draft_store.dart';
import 'utils/canvas_scale.dart';

class DraftListScreen extends StatelessWidget {
  final Function(Map<String, dynamic>) onDraftSelected;

  DraftListScreen({required this.onDraftSelected});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('下書き一覧'),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: DraftStore.loadAll(),
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
              // 下書きは保存時のスケールで再開されるため、一覧でも分かるようにする
              final scale = (draft['scaleBarDistance'] as num?)?.toDouble();

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
                  await DraftStore.delete(draft['filePath']);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('下書きを削除しました')),
                  );
                },
                child: ListTile(
                  title: Text('下書き ${index + 1}'),
                  subtitle: Text(scale == null
                      ? timestamp
                      : '$timestamp\nスケール ${CanvasScale.format(scale)}'),
                  isThreeLine: scale != null,
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
}
