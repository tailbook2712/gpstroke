import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:geolocator/geolocator.dart';

String generateGroupId(List<Position> positions) {
  // Position オブジェクトを JSON 形式に変換
  String jsonString = jsonEncode(positions.map((pos) {
    return {'latitude': pos.latitude, 'longitude': pos.longitude};
  }).toList());

  // SHA-256 ハッシュを生成
  return sha256.convert(utf8.encode(jsonString)).toString();
}