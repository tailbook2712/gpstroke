import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 途中保存した作品（下書き）の読み込みと削除
///
/// 下書きはアプリのドキュメント領域の `drafts/` に JSON ファイルとして保存されている。
class DraftStore {
  DraftStore._();

  /// 保存されている下書きをすべて読み込む
  ///
  /// 各要素には、ファイルの場所を表す `filePath` を付け加える。
  static Future<List<Map<String, dynamic>>> loadAll() async {
    final directory = await getApplicationDocumentsDirectory();
    final draftsDirectory = Directory('${directory.path}/drafts');

    if (!(await draftsDirectory.exists())) {
      return [];
    }

    final draftFiles = draftsDirectory.listSync().whereType<File>();
    return Future.wait(draftFiles.map((file) async {
      try {
        final jsonString = await file.readAsString();
        final data = Map<String, dynamic>.from(jsonDecode(jsonString) as Map);

        // デフォルト値を設定
        data['filePath'] = file.path;
        data['timestamp'] ??= '不明な日時';
        return data;
      } catch (e) {
        // 読めないファイルも一覧には出し、削除できるようにする
        return <String, dynamic>{
          'filePath': file.path,
          'timestamp': '不明な日時',
        };
      }
    }));
  }

  /// 下書きを新しい順に並べ替える（日時が分からないものは末尾）
  static List<Map<String, dynamic>> newestFirst(
      Iterable<Map<String, dynamic>> drafts) {
    DateTime? savedAt(Map<String, dynamic> draft) =>
        DateTime.tryParse('${draft['timestamp']}');

    return drafts.toList()
      ..sort((a, b) {
        final timeA = savedAt(a);
        final timeB = savedAt(b);
        if (timeA == null && timeB == null) return 0;
        if (timeA == null) return 1;
        if (timeB == null) return -1;
        return timeB.compareTo(timeA);
      });
  }

  /// 下書きを削除する
  static Future<void> delete(String filePath) async {
    final file = File(filePath);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
