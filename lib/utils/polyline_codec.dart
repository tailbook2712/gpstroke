/// Google Encoded Polyline Algorithm Format のエンコード／デコード
///
/// 共有用データ（Firestore の shared_artworks）に軌跡座標を格納する際、
/// JSON の配列で保存すると 1 点あたり 30 バイト以上必要になるため、
/// 1 点あたり数バイトで済むエンコード形式を採用している。
/// docs/share/index.html の JavaScript 側デコーダと対になっている。
///
/// 仕様: https://developers.google.com/maps/documentation/utilities/polylinealgorithm
library polyline_codec;

/// 緯度経度のリストをエンコードする。
///
/// [points] は `{'latitude': double, 'longitude': double}` を要素とするリスト。
/// [precision] は小数点以下の桁数（デフォルト 5 桁 ≒ 約 1m）。
String encodePolyline(List<Map<String, dynamic>> points, {int precision = 5}) {
  final factor = _pow10(precision);
  final buffer = StringBuffer();
  int prevLat = 0;
  int prevLng = 0;

  for (final point in points) {
    final lat = ((point['latitude'] as num) * factor).round();
    final lng = ((point['longitude'] as num) * factor).round();
    _encodeValue(lat - prevLat, buffer);
    _encodeValue(lng - prevLng, buffer);
    prevLat = lat;
    prevLng = lng;
  }
  return buffer.toString();
}

/// エンコード済み文字列を緯度経度のリストに戻す。
List<Map<String, double>> decodePolyline(String encoded, {int precision = 5}) {
  final factor = _pow10(precision);
  final result = <Map<String, double>>[];
  int index = 0;
  int lat = 0;
  int lng = 0;

  while (index < encoded.length) {
    int shift = 0;
    int value = 0;
    int byte;
    do {
      byte = encoded.codeUnitAt(index++) - 63;
      value |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lat += (value & 1) != 0 ? ~(value >> 1) : (value >> 1);

    shift = 0;
    value = 0;
    do {
      byte = encoded.codeUnitAt(index++) - 63;
      value |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lng += (value & 1) != 0 ? ~(value >> 1) : (value >> 1);

    result.add({'latitude': lat / factor, 'longitude': lng / factor});
  }
  return result;
}

void _encodeValue(int value, StringBuffer buffer) {
  int v = value < 0 ? ~(value << 1) : (value << 1);
  while (v >= 0x20) {
    buffer.writeCharCode((0x20 | (v & 0x1f)) + 63);
    v >>= 5;
  }
  buffer.writeCharCode(v + 63);
}

int _pow10(int exponent) {
  int result = 1;
  for (int i = 0; i < exponent; i++) {
    result *= 10;
  }
  return result;
}
