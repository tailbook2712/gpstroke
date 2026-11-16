import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'utils/canvas_scale.dart';

/// 軌跡の差し渡し（縦横の長い方、メートル）
double trajectoryExtentMeters(List<Position> positions) {
  if (positions.isEmpty) return 0.0;
  double minLat = positions.first.latitude, maxLat = minLat;
  double minLon = positions.first.longitude, maxLon = minLon;
  for (final p in positions) {
    minLat = math.min(minLat, p.latitude);
    maxLat = math.max(maxLat, p.latitude);
    minLon = math.min(minLon, p.longitude);
    maxLon = math.max(maxLon, p.longitude);
  }
  return CanvasScale.extentMeters(
    minLat: minLat,
    maxLat: maxLat,
    minLon: minLon,
    maxLon: maxLon,
  );
}

/// 変更できないスケールバー
///
/// スケールは制作開始時に決まり、制作中は変わらない。
/// 現在の縮尺が分かるよう表示だけを残し、鍵アイコンで固定を示す。
class CanvasScaleBar extends StatelessWidget {
  final double distanceMeters;

  /// タップ時の処理（固定の理由を説明するダイアログなど）
  final VoidCallback? onTap;

  const CanvasScaleBar({
    super.key,
    required this.distanceMeters,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const barColor = Colors.black54;
    return Semantics(
      label: 'キャンバスのスケール ${CanvasScale.format(distanceMeters)}（制作中は変更できません）',
      button: onTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // スケールバーグラフィック（U字型）
                  Container(
                    width: CanvasScale.barPixelLength,
                    height: 8,
                    decoration: const BoxDecoration(
                      border: Border(
                        left: BorderSide(width: 1.5, color: barColor),
                        right: BorderSide(width: 1.5, color: barColor),
                        bottom: BorderSide(width: 1.5, color: barColor),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.lock, size: 14, color: Colors.black45),
                ],
              ),
              const SizedBox(height: 2),
              SizedBox(
                width: CanvasScale.barPixelLength,
                child: Center(
                  child: Text(
                    CanvasScale.format(distanceMeters),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: barColor,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
