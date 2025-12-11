import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:convert';
import 'dart:typed_data';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // 位置情報と歩行データをFirestoreに保存するメソッド（共通）
  Future<void> saveWalkingData({
    required String groupId,
    required List<Map<String, dynamic>> positions,
    required int steps,
    required double distance,
  }) async {
    try {
      // positions[0]のtimestampをdateとして使用
      String date = positions.isNotEmpty
          ? positions[0]['timestamp'] as String
          : DateTime.now().toIso8601String();

      // Firestoreにデータを保存（walking_data コレクション）
      await _db.collection('walking_data').doc(groupId).set({
        'groupId': groupId,
        'positions': positions,
        'date': date,
        'steps': steps,
        'distance': distance,
        'saved_at': FieldValue.serverTimestamp(),
      });
      print("✅ 軌跡をFirestoreに保存しました: GroupID $groupId");
    } catch (e) {
      print("❌ Firestoreへの保存エラー: $e");
    }
  }

  // GroupIDごとの歩行データと位置情報を取得するメソッド
  Future<Map<String, dynamic>?> getWalkingDataByGroupId(String groupId) async {
    try {
      // groupIdに対応するドキュメントからデータを取得
      QuerySnapshot querySnapshot = await _db
          .collection('walking_data')
          .where('groupId', isEqualTo: groupId)
          .get();

      if (querySnapshot.docs.isNotEmpty) {
        return querySnapshot.docs.first.data() as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      print("Firestoreからのデータ取得エラー: $e");
      return null;
    }
  }

  // Firestoreからすべての歩行データを取得するメソッド
  Future<List<Map<String, dynamic>>> getAllWalkingData() async {
    try {
      QuerySnapshot snapshot = await _db.collection('walking_data').get();
      return snapshot.docs.map((doc) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        data['groupId'] = doc.id; // ドキュメント ID を groupId として追加
        return data;
      }).toList();
    } catch (e) {
      print("Firestoreからのデータ取得エラー: $e");
      return [];
    }
  }

  // 特定のGroupIDの歩行データをFirestoreから削除するメソッド
  Future<void> deleteWalkingDataByGroupId(String groupId) async {
    try {
      QuerySnapshot querySnapshot = await _db
          .collection('walking_data')
          .where('groupId', isEqualTo: groupId.toString())
          .get();

      for (var doc in querySnapshot.docs) {
        await _db.collection('walking_data').doc(doc.id).delete();
      }

      print("FirestoreからGroupID $groupId の歩行データを削除しました");
    } catch (e) {
      print("Firestoreから削除エラー: $e");
    }
  }

  // 作品データをFirestoreに保存するメソッド
  Future<void> saveArtwork({
    required String artworkId,
    required Map<String, dynamic> canvasState,
    required Uint8List imageData,
  }) async {
    try {
      // Base64にエンコードして保存
      String base64Image = base64Encode(imageData);

      // マップにデータを展開して直接保存する方法
      final Map<String, dynamic> saveData = {
        'artworkId': artworkId,
        'imageData': base64Image,
        'timestamp': DateTime.now().toIso8601String(),
        // マップの各キーを展開して保存
        'canvasWidth': canvasState['canvasWidth'],
        'canvasHeight': canvasState['canvasHeight'],
        'trajectories': canvasState['trajectories'],
        'meta': canvasState['meta'],
      };

      print('Firestoreに保存するデータのキー: ${saveData.keys.toList()}');

      // Firestoreに作品データを保存
      await _db.collection('artworks').doc(artworkId).set(saveData);
      print("作品データをFirestoreに保存しました: ArtworkID $artworkId");
    } catch (e) {
      print("作品のFirestoreへの保存エラー: $e");
    }
  }

  // Firestoreからすべての作品データを取得するメソッド
  Future<List<Map<String, dynamic>>> getAllArtworks() async {
    try {
      QuerySnapshot snapshot = await _db.collection('artworks').get();
      List<Map<String, dynamic>> result = [];

      for (var doc in snapshot.docs) {
        try {
          Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
          print('Firestoreから取得したデータのキー (${doc.id}): ${data.keys.toList()}');

          // キャンバス状態を再構築
          Map<String, dynamic> canvasState = {
            'canvasWidth': data['canvasWidth'],
            'canvasHeight': data['canvasHeight'],
            'trajectories': data['trajectories'],
            'meta': data['meta'],
          };

          // アートワークデータの構造を整形
          Map<String, dynamic> artworkData = {
            'artworkId': data['artworkId'] ?? doc.id,
            'canvasState': canvasState,
            'imageData': data['imageData'],
            'timestamp': data['timestamp'] ?? DateTime.now().toIso8601String(),
          };

          // 必須フィールドの存在確認
          if (data.containsKey('imageData') &&
              data.containsKey('canvasWidth') &&
              data.containsKey('canvasHeight') &&
              data.containsKey('trajectories') &&
              data.containsKey('meta')) {
            result.add(artworkData);
            print('有効なアートワークデータ: ${doc.id}');
          } else {
            print("無効なアートワークデータ: 必須フィールドが不足しています。ドキュメントID: ${doc.id}");
            print("存在するフィールド: ${data.keys.toList()}");
          }
        } catch (e) {
          print("アートワークデータの処理中にエラー: ${doc.id}, $e");
        }
      }

      print("取得したアートワーク数: ${result.length}件");
      return result;
    } catch (e) {
      print("Firestoreからの作品データ取得エラー: $e");
      return [];
    }
  }

  // 特定の作品をFirestoreから削除するメソッド
  Future<void> deleteArtworkById(String artworkId) async {
    try {
      await _db.collection('artworks').doc(artworkId).delete();
      print("FirestoreからArtworkID $artworkId の作品を削除しました");
    } catch (e) {
      print("Firestoreからの作品削除エラー: $e");
    }
  }

  // *** 使用済み軌跡情報の同期機能 ***

  // 使用済み軌跡インデックスをFirestoreに保存
  Future<void> saveUsedTrajectories(List<int> indices) async {
    try {
      // 既存のデータを取得
      DocumentSnapshot doc =
          await _db.collection('app_data').doc('used_trajectories').get();

      // データをマージ
      if (doc.exists) {
        List<dynamic> existingIndices =
            (doc.data() as Map<String, dynamic>)['indices'] ?? [];
        Set<int> uniqueIndices = {...existingIndices.cast<int>(), ...indices};

        await _db.collection('app_data').doc('used_trajectories').update({
          'indices': uniqueIndices.toList(),
          'updated_at': DateTime.now().toIso8601String(),
        });
      } else {
        // 最初の保存
        await _db.collection('app_data').doc('used_trajectories').set({
          'indices': indices,
          'updated_at': DateTime.now().toIso8601String(),
        });
      }
      print("使用済み軌跡情報をFirestoreに保存しました: ${indices.length}件");
    } catch (e) {
      print("使用済み軌跡の保存エラー: $e");
    }
  }

  // Firestoreから使用済み軌跡インデックスを取得
  Future<List<int>> getUsedTrajectories() async {
    try {
      DocumentSnapshot doc =
          await _db.collection('app_data').doc('used_trajectories').get();

      if (doc.exists) {
        List<dynamic> indices =
            (doc.data() as Map<String, dynamic>)['indices'] ?? [];
        print("Firestoreから使用済み軌跡情報を取得: ${indices.length}件");
        return indices.cast<int>();
      }
      return [];
    } catch (e) {
      print("使用済み軌跡の取得エラー: $e");
      return [];
    }
  }

  /// 使用済みGarmin軌跡をFirestoreに保存（永続化）
  Future<void> markGarminActivityAsUsedInFirestore(String groupId) async {
    try {
      await _db.collection('app_data').doc('used_garmin_activities').update({
        'groupIds': FieldValue.arrayUnion([groupId]),
        'updatedAt': FieldValue.serverTimestamp(),
      }).catchError((e) {
        // ドキュメントが存在しない場合はsetで作成
        if (e.code == 'not-found') {
          return _db.collection('app_data').doc('used_garmin_activities').set({
            'groupIds': [groupId],
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
        throw e;
      });
      print("Garmin軌跡の使用済み情報をFirestoreに保存: $groupId");
    } catch (e) {
      print("Firestore保存エラー: $e");
    }
  }

  /// Firestoreから使用済みGarmin軌跡のリストを取得
  Future<List<String>> getUsedGarminActivitiesFromFirestore() async {
    try {
      DocumentSnapshot doc =
          await _db.collection('app_data').doc('used_garmin_activities').get();

      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>;
        List<dynamic> groupIds = data['groupIds'] ?? [];
        print("Firestoreから使用済みGarmin軌跡を取得: ${groupIds.length}件");
        return groupIds.cast<String>();
      }
      return [];
    } catch (e) {
      print("Firestore取得エラー: $e");
      return [];
    }
  }

  /// 軌跡を使用済みとしてマーク
  Future<void> markTrajectoryAsUsedInFirestore(String groupId) async {
    try {
      await _db.collection('used_trajectories').doc(groupId).set({
        'groupId': groupId,
        'marked_at': FieldValue.serverTimestamp(),
      });
      print("✅ 軌跡を使用済みとしてマーク: $groupId");
    } catch (e) {
      print("❌ 使用済み軌跡の保存エラー: $e");
    }
  }

  /// Firestoreから使用済み軌跡をすべて取得
  Future<List<Map<String, dynamic>>> getUsedTrajectoriesFromFirestore() async {
    try {
      QuerySnapshot snapshot = await _db.collection('used_trajectories').get();
      final result = snapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        return {
          'groupId': data['groupId'] as String,
        };
      }).toList();

      print("📌 使用済み軌跡取得: ${result.length}件");
      return result;
    } catch (e) {
      print("❌ 使用済み軌跡取得エラー: $e");
      return [];
    }
  }
}
