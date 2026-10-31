import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'fit_parser.dart';
import 'tcx_parser.dart';

/// アクティビティファイル（.tcx / .fit / それらを含む .zip）を読み込むクラス
/// Garmin Connect の「オリジナルをエクスポート」は .fit を含む .zip になる
class ActivityFileLoader {
  static const supportedExtensions = ['.tcx', '.fit', '.zip'];

  static bool isSupported(String fileName) =>
      supportedExtensions.contains(p.extension(fileName).toLowerCase());

  /// ファイルを読み込み，含まれるアクティビティを返す（解析できなければ空）
  static Future<List<GarminActivityData>> load(
    String path, {
    required double userHeightCm,
  }) async {
    final bytes = await File(path).readAsBytes();
    return _parse(p.basename(path), bytes, userHeightCm);
  }

  static Future<List<GarminActivityData>> _parse(
    String fileName,
    Uint8List bytes,
    double userHeightCm,
  ) async {
    switch (p.extension(fileName).toLowerCase()) {
      case '.tcx':
        final activity = await TcxParser.parseTcxFile(
          utf8.decode(bytes, allowMalformed: true),
          userHeightCm: userHeightCm,
        );
        return [if (activity != null) activity];
      case '.fit':
        final activity =
            FitParser.parseFitFile(bytes, userHeightCm: userHeightCm);
        return [if (activity != null) activity];
      case '.zip':
        final archive = ZipDecoder().decodeBytes(bytes);
        final activities = <GarminActivityData>[];
        for (final entry in archive.files) {
          if (!entry.isFile || p.extension(entry.name).toLowerCase() == '.zip') {
            continue;
          }
          if (!isSupported(entry.name)) continue;
          activities.addAll(
            await _parse(entry.name, entry.content, userHeightCm),
          );
        }
        return activities;
      default:
        return [];
    }
  }
}
