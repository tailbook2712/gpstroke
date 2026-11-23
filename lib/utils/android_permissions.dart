import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android の実行時権限を要求する（実装は MainActivity.kt）。
///
/// AndroidManifest.xml に書くだけでは有効にならない権限を、ユーザーに許可を求めて有効にする。
/// iOS では何もせず、すべて許可済みとして返す（iOS の歩数は CMPedometer が
/// 自身で「モーションとフィットネス」の許可を求めるため）。
class AndroidRuntimePermissions {
  static const _channel = MethodChannel('gpstroke/permissions');

  /// 歩数センサーの利用（Android 10 以降で必要）
  static const activityRecognition = 'activityRecognition';

  /// 通知の表示（Android 13 以降で必要）
  static const notification = 'notification';

  /// 権限を要求し、権限名 → 許可されたか を返す
  static Future<Map<String, bool>> request(List<String> permissions) async {
    if (!Platform.isAndroid) {
      return {for (final p in permissions) p: true};
    }
    try {
      final result = await _channel.invokeMapMethod<String, bool>(
        'request',
        {'permissions': permissions},
      );
      return {for (final p in permissions) p: result?[p] ?? false};
    } on PlatformException catch (e) {
      debugPrint('権限リクエストに失敗: $e');
      return {for (final p in permissions) p: false};
    }
  }
}
