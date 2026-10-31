import 'dart:convert';
import 'dart:typed_data';
import 'package:geolocator/geolocator.dart';
import 'tcx_parser.dart';

/// FIT ファイル（Garmin のバイナリ形式）から軌跡情報を抽出するクラス
/// record メッセージの座標・時刻・高度，session メッセージのスポーツ種別と開始時刻，
/// Connect IQ アプリが書き込んだ歩数（developer field）だけを読む
class FitParser {
  static const int _recordMessage = 20;
  static const int _sessionMessage = 18;
  static const int _lapMessage = 19;
  static const int _fieldDescriptionMessage = 206;

  // FIT の時刻は 1989-12-31T00:00:00Z からの秒数
  static const int _fitEpochOffsetSeconds = 631065600;

  static GarminActivityData? parseFitFile(
    Uint8List bytes, {
    required double userHeightCm,
  }) {
    try {
      print('📊 FITパース開始: ${bytes.length} bytes');
      if (bytes.length < 12) return null;

      final data = ByteData.sublistView(bytes);
      final headerSize = bytes[0];
      final dataSize = data.getUint32(4, Endian.little);
      if (String.fromCharCodes(bytes.sublist(8, 12)) != '.FIT') {
        print('⚠️ FITヘッダが不正です');
        return null;
      }

      final end = (headerSize + dataSize).clamp(0, bytes.length);
      final definitions = <int, _FitDefinition>{};
      final developerFields = <int, _DeveloperFieldInfo>{};
      final positions = <Position>[];
      int? lastTimestamp;
      int? sport;
      int? sessionStartTime;
      final steps = _StepAccumulator();
      int offset = headerSize;

      while (offset < end) {
        final recordHeader = bytes[offset++];

        // 圧縮タイムスタンプヘッダ（データメッセージ）
        if (recordHeader & 0x80 != 0) {
          final localType = (recordHeader >> 5) & 0x03;
          final timeOffset = recordHeader & 0x1F;
          final definition = definitions[localType];
          if (definition == null) return null;
          if (lastTimestamp != null) {
            int timestamp = (lastTimestamp & ~0x1F) + timeOffset;
            if (timeOffset < (lastTimestamp & 0x1F)) timestamp += 0x20;
            lastTimestamp = timestamp;
          }
          final message = definition.read(data, offset);
          offset += definition.totalSize;
          if (definition.globalNumber == _recordMessage) {
            _addPosition(positions, message.values, lastTimestamp);
            steps.addRecord(_findSteps(message, developerFields));
          }
          continue;
        }

        final localType = recordHeader & 0x0F;

        // 定義メッセージ
        if (recordHeader & 0x40 != 0) {
          final hasDeveloperData = recordHeader & 0x20 != 0;
          final endian = bytes[offset + 1] == 0 ? Endian.little : Endian.big;
          final globalNumber = data.getUint16(offset + 2, endian);
          final fieldCount = bytes[offset + 4];
          offset += 5;

          final fieldDefs = <_FitField>[];
          for (int i = 0; i < fieldCount; i++) {
            fieldDefs.add(_FitField(bytes[offset], bytes[offset + 1]));
            offset += 3;
          }
          final developerDefs = <_DeveloperField>[];
          if (hasDeveloperData) {
            final developerCount = bytes[offset++];
            for (int i = 0; i < developerCount; i++) {
              developerDefs.add(_DeveloperField(
                  bytes[offset], bytes[offset + 1], bytes[offset + 2]));
              offset += 3;
            }
          }
          definitions[localType] = _FitDefinition(
              globalNumber, endian, fieldDefs, developerDefs);
          continue;
        }

        // 通常のデータメッセージ
        final definition = definitions[localType];
        if (definition == null) return null;
        final message = definition.read(data, offset);
        offset += definition.totalSize;
        final fields = message.values;

        final timestamp = fields[253];
        if (timestamp != null && timestamp != 0xFFFFFFFF) {
          lastTimestamp = timestamp;
        }
        switch (definition.globalNumber) {
          case _recordMessage:
            _addPosition(positions, fields, lastTimestamp);
            steps.addRecord(_findSteps(message, developerFields));
            break;
          case _lapMessage:
            steps.addLap(_findSteps(message, developerFields));
            break;
          case _sessionMessage:
            sport ??= fields[5];
            final startTime = fields[2];
            if (startTime != null && startTime != 0xFFFFFFFF) {
              sessionStartTime ??= startTime;
            }
            steps.addSession(_findSteps(message, developerFields));
            break;
          case _fieldDescriptionMessage:
            final developerIndex = fields[0];
            final fieldNumber = fields[1];
            if (developerIndex != null && fieldNumber != null) {
              developerFields[_developerKey(developerIndex, fieldNumber)] =
                  _DeveloperFieldInfo(
                name: message.strings[3] ?? '',
                baseType: fields[2] ?? 0,
              );
            }
            break;
        }
      }

      print('✅ 総Recordポイント数: ${positions.length}');
      if (positions.isEmpty) {
        print('⚠️ ポイントが見つかりません');
        return null;
      }

      double totalDistance = 0.0;
      for (int i = 1; i < positions.length; i++) {
        totalDistance += Geolocator.distanceBetween(
          positions[i - 1].latitude,
          positions[i - 1].longitude,
          positions[i].latitude,
          positions[i].longitude,
        );
      }

      // 記録された歩数があればそれを使い，なければ TCX と同じく身長から推定
      final recordedSteps = steps.total;
      final isStepsEstimated = recordedSteps == null;
      final totalSteps = recordedSteps ??
          TcxParser.estimateSteps(totalDistance, userHeightCm);

      // TCX の Activity Id と同じく開始時刻を記録日時にする（同じアクティビティの重複防止）
      final recordDate = sessionStartTime != null
          ? _toDateTime(sessionStartTime)
          : positions.first.timestamp;

      print('✅ FITパース完了: ${(totalDistance / 1000).toStringAsFixed(2)}km, '
          '歩数: $totalSteps${isStepsEstimated ? '（推定）' : '（記録値）'}');
      return GarminActivityData(
        activityName: '${_sportName(sport)} Activity',
        positions: positions,
        recordDate: recordDate,
        distance: totalDistance / 1000, // メートルからキロメートルに変換
        steps: totalSteps,
        isStepsEstimated: isStepsEstimated,
      );
    } catch (e, stackTrace) {
      print('❌ FIT パースエラー: $e');
      print('スタックトレース: $stackTrace');
      return null;
    }
  }

  static int _developerKey(int developerIndex, int fieldNumber) =>
      (developerIndex << 8) | fieldNumber;

  /// 名前に「step」「歩数」を含む developer field の値を歩数とみなす
  static int? _findSteps(
    _FitMessage message,
    Map<int, _DeveloperFieldInfo> developerFields,
  ) {
    for (final entry in message.developerRaw.entries) {
      final info = developerFields[entry.key];
      if (info == null) continue;
      final name = info.name.toLowerCase();
      if (!name.contains('step') && !name.contains('歩数')) continue;
      final value = info.decode(entry.value, message.endian);
      if (value != null && value > 0) return value.round();
    }
    return null;
  }

  static DateTime _toDateTime(int fitTimestamp) =>
      DateTime.fromMillisecondsSinceEpoch(
        (fitTimestamp + _fitEpochOffsetSeconds) * 1000,
        isUtc: true,
      );

  static void _addPosition(
    List<Position> positions,
    Map<int, int> fields,
    int? timestamp,
  ) {
    final lat = fields[0];
    final lon = fields[1];
    // sint32 の無効値は 0x7FFFFFFF
    if (lat == null || lon == null || lat == 0x7FFFFFFF || lon == 0x7FFFFFFF) {
      return;
    }
    if (timestamp == null) return;

    // 高度は enhanced_altitude(78) を優先し，scale 5・offset 500
    double altitude = 0.0;
    final enhancedAltitude = fields[78];
    final rawAltitude = fields[2];
    if (enhancedAltitude != null && enhancedAltitude != 0xFFFFFFFF) {
      altitude = enhancedAltitude / 5 - 500;
    } else if (rawAltitude != null && rawAltitude != 0xFFFF) {
      altitude = rawAltitude / 5 - 500;
    }

    const semicircleToDegree = 180 / 2147483648;
    positions.add(
      Position(
        latitude: lat * semicircleToDegree,
        longitude: lon * semicircleToDegree,
        timestamp: _toDateTime(timestamp),
        accuracy: 0.0,
        altitude: altitude,
        heading: 0.0,
        speed: 0.0,
        speedAccuracy: 0.0,
        altitudeAccuracy: 0.0,
        headingAccuracy: 0.0,
      ),
    );
  }

  static String _sportName(int? sport) {
    switch (sport) {
      case 1:
        return 'Running';
      case 2:
        return 'Biking';
      case 11:
        return 'Walking';
      case 17:
        return 'Hiking';
      default:
        return 'Other';
    }
  }
}

/// 歩数の集計（session の値 → lap の合計 → record の最大値（累積値とみなす）の順で優先）
class _StepAccumulator {
  int? _session;
  int? _lapSum;
  int? _recordMax;

  void addSession(int? steps) {
    if (steps != null) _session = (_session ?? 0) + steps;
  }

  void addLap(int? steps) {
    if (steps != null) _lapSum = (_lapSum ?? 0) + steps;
  }

  void addRecord(int? steps) {
    if (steps != null && steps > (_recordMax ?? 0)) _recordMax = steps;
  }

  int? get total => _session ?? _lapSum ?? _recordMax;
}

class _FitField {
  final int number;
  final int size;

  _FitField(this.number, this.size);
}

class _DeveloperField {
  final int number;
  final int size;
  final int developerIndex;

  _DeveloperField(this.number, this.size, this.developerIndex);
}

class _DeveloperFieldInfo {
  final String name;
  final int baseType;

  _DeveloperFieldInfo({required this.name, required this.baseType});

  /// FIT の基本型に従って数値に変換（無効値や未対応の型は null）
  double? decode(Uint8List raw, Endian endian) {
    final data = ByteData.sublistView(raw);
    switch (baseType) {
      case 0x02: // uint8
      case 0x0A: // uint8z
        return raw.isNotEmpty && raw[0] != 0xFF ? raw[0].toDouble() : null;
      case 0x84: // uint16
      case 0x8B: // uint16z
        if (raw.length < 2) return null;
        final value = data.getUint16(0, endian);
        return value == 0xFFFF ? null : value.toDouble();
      case 0x83: // sint16
        if (raw.length < 2) return null;
        final value = data.getInt16(0, endian);
        return value == 0x7FFF ? null : value.toDouble();
      case 0x86: // uint32
      case 0x8C: // uint32z
        if (raw.length < 4) return null;
        final value = data.getUint32(0, endian);
        return value == 0xFFFFFFFF ? null : value.toDouble();
      case 0x85: // sint32
        if (raw.length < 4) return null;
        final value = data.getInt32(0, endian);
        return value == 0x7FFFFFFF ? null : value.toDouble();
      case 0x88: // float32
        if (raw.length < 4) return null;
        final value = data.getFloat32(0, endian);
        return value.isFinite ? value : null;
      case 0x89: // float64
        if (raw.length < 8) return null;
        final value = data.getFloat64(0, endian);
        return value.isFinite ? value : null;
      default:
        return null;
    }
  }
}

class _FitMessage {
  final Endian endian;
  final Map<int, int> values; // 1/2/4 バイトの数値フィールド
  final Map<int, String> strings; // field_description の名前用
  final Map<int, Uint8List> developerRaw; // developer field の生バイト

  _FitMessage(this.endian, this.values, this.strings, this.developerRaw);
}

class _FitDefinition {
  final int globalNumber;
  final Endian endian;
  final List<_FitField> fields;
  final List<_DeveloperField> developerFields;

  _FitDefinition(
      this.globalNumber, this.endian, this.fields, this.developerFields);

  int get totalSize =>
      fields.fold(0, (sum, field) => sum + field.size) +
      developerFields.fold(0, (sum, field) => sum + field.size);

  /// 数値フィールド（座標は符号付き），field_description の名前，developer field を読み取る
  _FitMessage read(ByteData data, int offset) {
    final values = <int, int>{};
    final strings = <int, String>{};
    final developerRaw = <int, Uint8List>{};
    final bytes = data.buffer.asUint8List(data.offsetInBytes);

    for (final field in fields) {
      if (globalNumber == FitParser._fieldDescriptionMessage &&
          field.number == 3) {
        final raw = bytes.sublist(offset, offset + field.size);
        final nullIndex = raw.indexOf(0);
        strings[field.number] = utf8.decode(
          nullIndex >= 0 ? raw.sublist(0, nullIndex) : raw,
          allowMalformed: true,
        );
      } else {
        switch (field.size) {
          case 1:
            values[field.number] = data.getUint8(offset);
            break;
          case 2:
            values[field.number] = data.getUint16(offset, endian);
            break;
          case 4:
            values[field.number] = field.number == 0 || field.number == 1
                ? data.getInt32(offset, endian)
                : data.getUint32(offset, endian);
            break;
        }
      }
      offset += field.size;
    }
    for (final field in developerFields) {
      developerRaw[FitParser._developerKey(
              field.developerIndex, field.number)] =
          bytes.sublist(offset, offset + field.size);
      offset += field.size;
    }
    return _FitMessage(endian, values, strings, developerRaw);
  }
}
