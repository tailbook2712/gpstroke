import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'database_helper.dart';
import 'route_generation_screen.dart';

/// ルート提案で保存したルートの一覧
///
/// 選択すると {'routePath': List<LatLng>, 'metadata': Map} を返して閉じる
class SavedRouteListScreen extends StatefulWidget {
  const SavedRouteListScreen({super.key});

  @override
  State<SavedRouteListScreen> createState() => _SavedRouteListScreenState();
}

class _SavedRouteListScreenState extends State<SavedRouteListScreen> {
  final DatabaseHelper _dbHelper = DatabaseHelper();
  List<Map<String, dynamic>>? _routes;

  @override
  void initState() {
    super.initState();
    _loadRoutes();
  }

  Future<void> _loadRoutes() async {
    try {
      final routes = await _dbHelper.getSavedRoutes();
      if (!mounted) return;
      setState(() => _routes = routes);
    } catch (e) {
      if (!mounted) return;
      setState(() => _routes = []);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ルートの読み込みに失敗しました: $e')),
      );
    }
  }

  List<LatLng> _toLatLngs(Map<String, dynamic> route) {
    final points =
        route[DatabaseHelper.columnRoutePoints] as List<Map<String, dynamic>>;
    return points
        .map((p) => LatLng(
              (p['latitude'] as num).toDouble(),
              (p['longitude'] as num).toDouble(),
            ))
        .toList();
  }

  void _selectRoute(Map<String, dynamic> route) {
    Navigator.pop(context, {
      'routePath': _toLatLngs(route),
      'metadata': {
        'distance': route[DatabaseHelper.columnRouteDistance],
        'name': route[DatabaseHelper.columnRouteName],
        'savedRouteId': route[DatabaseHelper.columnRouteId],
      },
    });
  }

  Future<void> _deleteRoute(Map<String, dynamic> route) async {
    final id = route[DatabaseHelper.columnRouteId] as int;
    setState(() => _routes!.remove(route));
    await _dbHelper.deleteSavedRoute(id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('「${route[DatabaseHelper.columnRouteName]}」を削除しました')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('保存したルート')),
      body: _routes == null
          ? const Center(child: CircularProgressIndicator())
          : _routes!.isEmpty
              ? _buildEmptyState()
              : ListView.separated(
                  itemCount: _routes!.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) =>
                      _buildRouteTile(_routes![index]),
                ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.route, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            const Text(
              '保存したルートはまだありません',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '作品の制作画面のルート提案ボタンから\nキャンバスに形を描くとルートを作成・保存できます',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRouteTile(Map<String, dynamic> route) {
    final distanceKm =
        (route[DatabaseHelper.columnRouteDistance] as num).toDouble() / 1000;
    final createdAt =
        DateTime.tryParse(route[DatabaseHelper.columnRouteCreatedAt] as String);

    return Dismissible(
      key: ValueKey(route[DatabaseHelper.columnRouteId]),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) => _deleteRoute(route),
      child: ListTile(
        leading: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: Colors.grey[100],
            borderRadius: BorderRadius.circular(8),
          ),
          child: CustomPaint(
            painter: RoutePreviewPainter(route: _toLatLngs(route)),
          ),
        ),
        title: Text(route[DatabaseHelper.columnRouteName] as String),
        subtitle: Text(
          '${distanceKm.toStringAsFixed(2)} km'
          '${createdAt != null ? '  ・  ${DateFormat('yyyy/MM/dd HH:mm').format(createdAt)}' : ''}',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _selectRoute(route),
      ),
    );
  }
}
