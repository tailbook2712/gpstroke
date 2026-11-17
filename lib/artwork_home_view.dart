import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

import 'canvas_scale_widgets.dart';
import 'route_generation_screen.dart' show DraftCanvasOverlayPainter;
import 'utils/canvas_scale.dart';

/// 作品制作のホーム（キャンバスに入る前の画面）
///
/// 上段で新しいキャンバスのスケールを選び、下段に途中保存した下書きを並べる。
/// スケールは制作を始めると変更できないため（#132）、数値を変えると、手持ちの軌跡が
/// キャンバス上でどの大きさになるかがカードの図に反映されるようにする。
class ArtworkHomeView extends StatefulWidget {
  /// 手持ちの（まだ作品に使っていない）軌跡
  final List<List<Position>> trajectories;

  /// 制作キャンバスの大きさ（論理ピクセル）
  final Size canvasSize;

  /// 途中保存した下書き（読み込み中は null）
  final List<Map<String, dynamic>>? drafts;

  /// スケールを決めて新しいキャンバスを作るとき
  final ValueChanged<double> onCreate;

  /// 下書きを開くとき
  final ValueChanged<Map<String, dynamic>> onOpenDraft;

  /// 下書きを削除するとき（null の場合は削除ボタンを出さない）
  final ValueChanged<Map<String, dynamic>>? onDeleteDraft;

  const ArtworkHomeView({
    super.key,
    required this.trajectories,
    required this.canvasSize,
    required this.drafts,
    required this.onCreate,
    required this.onOpenDraft,
    this.onDeleteDraft,
  });

  @override
  State<ArtworkHomeView> createState() => _ArtworkHomeViewState();
}

class _ArtworkHomeViewState extends State<ArtworkHomeView> {
  static const double _sidePadding = 16.0;

  List<double> _extents = const [];
  List<Position>? _typicalTrajectory;
  double? _typicalExtent;
  double? _recommended;
  double _selected = CanvasScale.defaultDistance;
  bool _userSelected = false;

  double get _canvasHeight => widget.canvasSize.height > 0
      ? widget.canvasSize.height
      : widget.canvasSize.width;

  double get _canvasShortSide =>
      math.min(widget.canvasSize.width, _canvasHeight);

  @override
  void initState() {
    super.initState();
    _recompute();
  }

  @override
  void didUpdateWidget(ArtworkHomeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.trajectories, widget.trajectories) ||
        oldWidget.canvasSize != widget.canvasSize) {
      _recompute();
    }
  }

  void _recompute() {
    final entries = <MapEntry<double, List<Position>>>[];
    for (final positions in widget.trajectories) {
      final extent = trajectoryExtentMeters(positions);
      if (extent > 0) entries.add(MapEntry(extent, positions));
    }
    entries.sort((a, b) => a.key.compareTo(b.key));

    _extents = entries.map((e) => e.key).toList();
    if (entries.isEmpty) {
      _typicalTrajectory = null;
      _typicalExtent = null;
    } else {
      // 中央値にあたる軌跡を「標準的な軌跡」としてカードの図に使う
      final typical = entries[entries.length ~/ 2];
      _typicalExtent = typical.key;
      _typicalTrajectory = typical.value;
    }

    _recommended = CanvasScale.recommend(_extents, _canvasShortSide);
    if (!_userSelected) {
      _selected = _recommended ?? CanvasScale.defaultDistance;
    }
  }

  void _select(double scale) {
    setState(() {
      _selected = scale;
      _userSelected = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final drafts = widget.drafts;
    return SafeArea(
      top: false,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _buildNewCanvasSection()),
          const SliverToBoxAdapter(child: Divider(height: 1)),
          SliverToBoxAdapter(child: _buildDraftsHeader(drafts)),
          if (drafts == null)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else if (drafts.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                    _sidePadding, 4, _sidePadding, 24),
                child: Text(
                  'まだ下書きはありません。\n'
                  '制作中にメニューから「下書き保存」をすると、ここに並びます。',
                  style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                ),
              ),
            )
          else
            SliverPadding(
              padding:
                  const EdgeInsets.fromLTRB(_sidePadding, 0, _sidePadding, 16),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
                  mainAxisExtent: 232,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildDraftCard(drafts[index]),
                  childCount: drafts.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ─── 新しいキャンバス ─────────────────────────────

  Widget _buildNewCanvasSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(_sidePadding, 16, _sidePadding, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '新しく作る',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 2),
          Text(
            'スケールは制作を始めると変更できません',
            style: TextStyle(fontSize: 12, color: Colors.grey[700]),
          ),
          const SizedBox(height: 10),
          _buildCanvasCard(),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => widget.onCreate(_selected),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: Text(
                '${CanvasScale.format(_selected)} で制作を始める',
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 新しいキャンバスのカード
  ///
  /// スケールの数値を変えると、キャンバスの縮小図に描いた軌跡の大きさが変わる
  Widget _buildCanvasCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildCanvasPreview(),
              const SizedBox(width: 14),
              Expanded(child: _buildScaleSummary()),
            ],
          ),
          const SizedBox(height: 4),
          _buildScaleControl(),
        ],
      ),
    );
  }

  /// キャンバスの縮小図（標準的な軌跡を、選択中のスケールでの実寸比で描く）
  Widget _buildCanvasPreview() {
    const maxFrameWidth = 110.0;
    const maxFrameHeight = 150.0;
    final canvas = widget.canvasSize;
    // k = キャンバスの縮小率
    final k =
        math.min(maxFrameWidth / canvas.width, maxFrameHeight / _canvasHeight);

    Widget? trajectory;
    final positions = _typicalTrajectory;
    if (positions != null && _typicalExtent != null) {
      trajectory = ScaledTrajectory(
        positions: positions,
        boxSide: CanvasScale.boxPixels(_typicalExtent!, _selected) * k,
      );
    }

    return Container(
      width: canvas.width * k,
      height: _canvasHeight * k,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        border: Border.all(color: Colors.grey[400]!),
      ),
      child: ClipRect(
        child: Stack(
          children: [
            if (trajectory != null) Positioned.fill(child: trajectory),
            // 縮小図上のスケールバー
            Positioned(
              left: 5,
              bottom: 4,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: CanvasScale.barPixelLength * k,
                    height: 4,
                    decoration: const BoxDecoration(
                      border: Border(
                        left: BorderSide(color: Colors.black54),
                        right: BorderSide(color: Colors.black54),
                        bottom: BorderSide(color: Colors.black54),
                      ),
                    ),
                  ),
                  Text(
                    CanvasScale.format(_selected),
                    style: const TextStyle(fontSize: 8, color: Colors.black54),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 選択中のスケールの数値と、そのスケールで使える軌跡の本数
  Widget _buildScaleSummary() {
    final metersPerPixel = CanvasScale.metersPerPixel(_selected);
    final total = _extents.length;
    final counts =
        CanvasScale.countByFit(_extents, _selected, _canvasShortSide);
    final usable = counts[TrajectoryFit.usable]!;
    final tooLarge = counts[TrajectoryFit.tooLarge]!;
    final tooSmall = counts[TrajectoryFit.tooSmall]!;
    final hintStyle = TextStyle(fontSize: 11, color: Colors.grey[700]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          CanvasScale.format(_selected),
          style: const TextStyle(
              fontSize: 30, fontWeight: FontWeight.bold, height: 1.1),
        ),
        const SizedBox(height: 2),
        // おすすめのスケールを選んでいるときだけ目印を出す
        // （表示の有無でレイアウトが動かないよう、場所は確保しておく）
        SizedBox(
          height: 22,
          child: _selected == _recommended
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: _buildRecommendedChip(),
                )
              : null,
        ),
        const SizedBox(height: 8),
        Text(
          '全体 約'
          '${CanvasScale.formatApprox(widget.canvasSize.width * metersPerPixel)}'
          ' × 約'
          '${CanvasScale.formatApprox(_canvasHeight * metersPerPixel)}',
          style: hintStyle,
        ),
        const SizedBox(height: 6),
        if (total == 0)
          Text('軌跡はまだありません', style: hintStyle)
        else ...[
          Text(
            '使える軌跡 $usable / $total本',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: _usableColor(usable, total),
            ),
          ),
          if (usable < total)
            Text(
              [
                if (tooLarge > 0) '大きすぎ $tooLarge本',
                if (tooSmall > 0) '小さすぎ $tooSmall本',
              ].join('・'),
              style: hintStyle,
            ),
        ],
      ],
    );
  }

  Color _usableColor(int usable, int total) {
    if (usable == total) return Colors.green[700]!;
    if (usable == 0) return Colors.red[700]!;
    return Colors.orange[800]!;
  }

  /// スケールの数値を変える操作（スライダーと、1段階ずつの − ＋）
  Widget _buildScaleControl() {
    const options = CanvasScale.options;
    final index = options.indexOf(_selected);

    return Row(
      children: [
        IconButton(
          tooltip: 'スケールを小さくする',
          icon: const Icon(Icons.remove),
          onPressed: index > 0 ? () => _select(options[index - 1]) : null,
        ),
        Expanded(
          child: Slider(
            value: index.toDouble(),
            min: 0,
            max: (options.length - 1).toDouble(),
            divisions: options.length - 1,
            activeColor: Colors.blue,
            label: CanvasScale.format(_selected),
            semanticFormatterCallback: (value) =>
                CanvasScale.format(options[value.round()]),
            onChanged: (value) => _select(options[value.round()]),
          ),
        ),
        IconButton(
          tooltip: 'スケールを大きくする',
          icon: const Icon(Icons.add),
          onPressed: index < options.length - 1
              ? () => _select(options[index + 1])
              : null,
        ),
      ],
    );
  }

  /// 推奨スケールの目印
  Widget _buildRecommendedChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.blue,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Text(
        'おすすめ',
        style: TextStyle(
          fontSize: 11,
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  // ─── 下書き ─────────────────────────────

  Widget _buildDraftsHeader(List<Map<String, dynamic>>? drafts) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(_sidePadding, 16, _sidePadding, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          const Text(
            '下書きから続ける',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 8),
          if (drafts != null && drafts.isNotEmpty)
            Text(
              '${drafts.length}件',
              style: TextStyle(fontSize: 13, color: Colors.grey[700]),
            ),
        ],
      ),
    );
  }

  String _formatSavedAt(Map<String, dynamic> draft) {
    final savedAt = DateTime.tryParse('${draft['timestamp']}');
    if (savedAt == null) return '日時不明';
    return DateFormat('yyyy/MM/dd HH:mm').format(savedAt);
  }

  Widget _buildDraftCard(Map<String, dynamic> draft) {
    final trajectories = (draft['trajectories'] as List?)
            ?.whereType<Map>()
            .map((t) => Map<String, dynamic>.from(t))
            .toList() ??
        const <Map<String, dynamic>>[];
    // スケールを持たない古い下書きは、当時の初期値で開かれる
    final scale = (draft['scaleBarDistance'] as num?)?.toDouble() ??
        CanvasScale.defaultDistance;
    final savedAt = _formatSavedAt(draft);

    return Semantics(
      button: true,
      label: '下書き $savedAt',
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: Colors.grey[300]!),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => widget.onOpenDraft(draft),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                      child: Center(
                        child: _buildDraftThumbnail(draft, trajectories),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          savedAt,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          'スケール ${CanvasScale.format(scale)}・'
                          '軌跡 ${trajectories.length}本',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              TextStyle(fontSize: 11, color: Colors.grey[700]),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (widget.onDeleteDraft != null)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Material(
                    color: Colors.white.withValues(alpha: 0.9),
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: IconButton(
                      tooltip: '下書きを削除',
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints.tightFor(width: 32, height: 32),
                      icon: Icon(Icons.delete_outline,
                          size: 18, color: Colors.grey[700]),
                      onPressed: () => _confirmDeleteDraft(draft, savedAt),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 下書きのキャンバスを縮小して描く
  Widget _buildDraftThumbnail(
    Map<String, dynamic> draft,
    List<Map<String, dynamic>> trajectories,
  ) {
    // 保存時のキャンバスの大きさ（なければ現在のキャンバスで代用）
    final savedWidth = (draft['canvasWidth'] as num?)?.toDouble() ?? 0.0;
    final savedHeight = (draft['canvasHeight'] as num?)?.toDouble() ?? 0.0;
    final width = savedWidth > 0 ? savedWidth : widget.canvasSize.width;
    final height = savedHeight > 0 ? savedHeight : _canvasHeight;

    return LayoutBuilder(builder: (context, constraints) {
      final k = math.min(
          constraints.maxWidth / width, constraints.maxHeight / height);
      return Container(
        width: width * k,
        height: height * k,
        decoration: BoxDecoration(
          color: Colors.grey[200],
          border: Border.all(color: Colors.grey[400]!),
        ),
        child: ClipRect(
          child: FittedBox(
            fit: BoxFit.fill,
            child: SizedBox(
              width: width,
              height: height,
              child: CustomPaint(
                painter: DraftCanvasOverlayPainter(
                  trajectories: trajectories,
                  color: Colors.blue,
                  // 縮小後も線が見えるよう、縮小率の分だけ太く描く
                  strokeWidth: 1.6 / k,
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  Future<void> _confirmDeleteDraft(
      Map<String, dynamic> draft, String savedAt) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('下書きを削除しますか？'),
        content: Text('$savedAt の下書きを削除します。この操作は取り消せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.onDeleteDraft?.call(draft);
  }
}
