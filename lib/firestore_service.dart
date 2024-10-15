import 'package:cloud_firestore/cloud_firestore.dart';

class FirestoreService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<void> savePosition(int groupId, double latitude, double longitude, String timestamp) async {
    await _firestore.collection('positions').add({
      'groupId': groupId,
      'latitude': latitude,
      'longitude': longitude,
      'timestamp': timestamp,
    });
  }

  // 他にも必要なメソッドを追加できます（位置情報を取得するなど）
}