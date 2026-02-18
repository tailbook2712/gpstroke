import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// 認証サービス（Google Sign-In + Firebase Auth）
class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    clientId: Platform.isIOS
        ? '36151156004-tfmj1eecuptta3v0g2e3dln6jh6b4ima.apps.googleusercontent.com'
        : null,
  );
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// 現在ログイン中のユーザー
  User? get currentUser => _auth.currentUser;

  /// ユーザーIDを取得（未ログイン時はnull）
  String? get userId => _auth.currentUser?.uid;

  /// ログイン状態の変化を監視するストリーム
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// Googleアカウントでサインイン
  Future<User?> signInWithGoogle() async {
    try {
      // Googleサインインフローを開始
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      if (googleUser == null) {
        // ユーザーがサインインをキャンセルした場合
        print('⚠ Googleサインインがキャンセルされました');
        return null;
      }

      // Google認証情報を取得
      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      // Firebase用の認証情報を作成
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      // Firebaseでサインイン
      final UserCredential userCredential = await _auth.signInWithCredential(
        credential,
      );
      final User? user = userCredential.user;

      if (user != null) {
        // Firestoreにユーザー情報を保存・更新
        await _saveUserToFirestore(user);
        print('✅ Googleサインイン成功: ${user.displayName} (${user.uid})');
      }

      return user;
    } catch (e) {
      print('❌ Googleサインインエラー: $e');
      return null;
    }
  }

  /// サインアウト
  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
      await _auth.signOut();
      print('✅ サインアウトしました');
    } catch (e) {
      print('❌ サインアウトエラー: $e');
    }
  }

  /// Firestoreにユーザー情報を保存
  Future<void> _saveUserToFirestore(User user) async {
    try {
      await _db.collection('users').doc(user.uid).set({
        'uid': user.uid,
        'displayName': user.displayName,
        'email': user.email,
        'photoURL': user.photoURL,
        'lastLoginAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      print('✅ ユーザー情報をFirestoreに保存しました');
    } catch (e) {
      print('❌ ユーザー情報の保存エラー: $e');
    }
  }
}
