import 'dart:io';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'tcx_parser.dart';

/// HealthKit から取得したワークアウト（ルート付き）
class SmartwatchWorkout {
  final String uuid;
  final String sourceName; // 記録元アプリ（例: ワークアウト, Garmin Connect）
  final GarminActivityData activity;

  SmartwatchWorkout({
    required this.uuid,
    required this.sourceName,
    required this.activity,
  });
}

/// Apple Watch がヘルスケアに書き込んだワークアウトを取得するサービス（iOS のみ）
/// Garmin はヘルスケアにルートを書き込まないため，ファイルインポートで取り込む
class HealthKitService {
  static const MethodChannel _channel = MethodChannel('gpstroke/healthkit');
  static const String _connectedKey = 'healthkit_connected';
  static const String _promptShownKey = 'healthkit_connect_prompt_shown';

  /// この端末でヘルスケア連携が使えるか
  Future<bool> isAvailable() async {
    if (!Platform.isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on PlatformException catch (e) {
      print('❌ HealthKit 利用可否の確認エラー: $e');
      return false;
    }
  }

  /// 接続済みか
  ///
  /// HealthKit は読み取り許可の状態を返さないため，許可ダイアログの完了を接続とみなす。
  /// ただし，再インストールなどで HealthKit の許可がリセットされ，まだ尋ねていない
  /// 種類がある場合は，未接続に戻す（接続済みのままだと，同期が
  /// 「Authorization not determined」で失敗する）
  Future<bool> isConnected() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_connectedKey) ?? false)) return false;

    try {
      final status = await _channel.invokeMethod<String>('authorizationStatus');
      if (status == 'shouldRequest') {
        print('⚠️ HealthKit の許可がリセットされているため，未接続に戻します');
        await prefs.setBool(_connectedKey, false);
        return false;
      }
    } catch (e) {
      // 判定できないときは，保存済みの状態のまま進める（同期の前にも確認する）
      print('❌ HealthKit の許可状態の確認エラー: $e');
    }
    return true;
  }

  /// 初回遷移時の接続確認ダイアログを表示済みか
  Future<bool> hasShownConnectPrompt() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_promptShownKey) ?? false;
  }

  Future<void> markConnectPromptShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_promptShownKey, true);
  }

  /// ヘルスケアへの読み取り許可をリクエストして接続する
  Future<bool> connect() async {
    final success =
        await _channel.invokeMethod<bool>('requestAuthorization') ?? false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_connectedKey, success);
    return success;
  }

  Future<void> disconnect() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_connectedKey, false);
  }

  /// 直近のルート付きワークアウトを取得（新しい順）
  Future<List<SmartwatchWorkout>> fetchRecentWorkouts({
    int days = 30,
    int limit = 20,
    required double userHeightCm,
  }) async {
    final raw = await _channel.invokeListMethod<Map<dynamic, dynamic>>(
      'fetchRecentWorkouts',
      {'days': days, 'limit': limit},
    );
    if (raw == null) return [];

    print('⌚ HealthKit ワークアウト取得: ${raw.length}件');
    return raw.map((item) => _toWorkout(item, userHeightCm)).toList();
  }

  SmartwatchWorkout _toWorkout(Map<dynamic, dynamic> item, double userHeightCm) {
    final positions = (item['positions'] as List).map((p) {
      final point = p as Map<dynamic, dynamic>;
      return Position(
        latitude: (point['latitude'] as num).toDouble(),
        longitude: (point['longitude'] as num).toDouble(),
        timestamp: DateTime.fromMillisecondsSinceEpoch(
            (point['timestamp'] as num).toInt()),
        accuracy: 0.0,
        altitude: (point['altitude'] as num).toDouble(),
        heading: 0.0,
        speed: 0.0,
        speedAccuracy: 0.0,
        altitudeAccuracy: 0.0,
        headingAccuracy: 0.0,
      );
    }).toList();

    // ワークアウトの総距離がなければ座標列から計算
    double distanceMeters = (item['distanceMeters'] as num?)?.toDouble() ?? 0.0;
    if (distanceMeters <= 0) {
      for (int i = 1; i < positions.length; i++) {
        distanceMeters += Geolocator.distanceBetween(
          positions[i - 1].latitude,
          positions[i - 1].longitude,
          positions[i].latitude,
          positions[i].longitude,
        );
      }
    }

    // 歩数がなければ TCX インポートと同じく身長から推定
    final recordedSteps = (item['steps'] as num?)?.toInt();
    final isStepsEstimated = recordedSteps == null || recordedSteps <= 0;
    final steps = isStepsEstimated
        ? TcxParser.estimateSteps(distanceMeters, userHeightCm)
        : recordedSteps;

    return SmartwatchWorkout(
      uuid: item['uuid'] as String,
      sourceName: item['sourceName'] as String? ?? '',
      activity: GarminActivityData(
        activityName: item['activityName'] as String? ?? 'ワークアウト',
        positions: positions,
        recordDate: DateTime.fromMillisecondsSinceEpoch(
            (item['startDate'] as num).toInt()),
        distance: distanceMeters / 1000,
        steps: steps,
        isStepsEstimated: isStepsEstimated,
      ),
    );
  }
}
