import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/platform_api.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import 'visit_report_screen.dart';

/// Shown right after a visit is finished: each shelf photo with what the model found drawn
/// over it (green = Square, red = anything else), then on to the visit result.
class ShelfResultScreen extends StatefulWidget {
  const ShelfResultScreen({super.key, required this.visitId, required this.captureIds, required this.report});
  final String visitId;
  final List<String> captureIds;
  final Map<String, dynamic> report;

  @override
  State<ShelfResultScreen> createState() => _ShelfResultScreenState();
}

class _ShelfResultScreenState extends State<ShelfResultScreen> {
  static const _own = Color(0xFF22C55E);
  static const _other = Color(0xFFEF4444);

  final _api = PlatformApi.instance;
  final _pages = PageController();
  final Map<String, Map<String, dynamic>> _captures = {};
  final Map<String, Uint8List> _images = {};
  Map<String, String> _names = const {};
  int _page = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final products = await _api.products();
      _names = {for (final p in products) p['id'] as String: p['name'] as String};
      for (final id in widget.captureIds) {
        _captures[id] = await _api.capture(id);
        _images[id] = await _api.imageBytes('/v2/captures/$id/image');
        if (mounted) setState(() {});
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  void _showResult() => Navigator.of(context).pushReplacement(
    MaterialPageRoute(
      builder: (_) => VisitReportScreen(visitId: widget.visitId, report: widget.report, closeToOutlet: true),
    ),
  );

  List<Map<String, dynamic>> _detections(String id) => [
    for (final d in ((_captures[id]?['detections'] as List?) ?? const []).cast<Map<String, dynamic>>())
      if (d['verification'] != 'rejected') d,
  ];

  bool _isOwn(Map<String, dynamic> d) => (d['final'] as Map)['label'] == 'own';

  @override
  Widget build(BuildContext context) {
    final ids = widget.captureIds;
    final current = ids.isEmpty ? null : ids[_page];
    final detections = current == null ? const <Map<String, dynamic>>[] : _detections(current);
    final own = detections.where(_isOwn).length;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _showResult();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF111111),
        appBar: AppBar(
          backgroundColor: const Color(0xFF111111),
          foregroundColor: Colors.white,
          automaticallyImplyLeading: false,
          title: Text(ids.length > 1 ? 'Shelf photo ${_page + 1} of ${ids.length}' : t('Shelf photo')),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.page, 8, AppSpace.page, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (current != null && _captures[current] != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _Count(color: _own, text: '$own Square'),
                        const SizedBox(width: 16),
                        _Count(color: _other, text: '${detections.length - own} other'),
                      ],
                    ),
                  ),
                PrimaryButton(label: t('See visit result'), icon: Icons.arrow_forward_rounded, onPressed: _showResult),
              ],
            ),
          ),
        ),
        body: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
                      const SizedBox(height: 12),
                      PrimaryButton(label: t('Try again'), onPressed: _load),
                    ],
                  ),
                ),
              )
            : ids.isEmpty
            ? Center(
                child: Text(t('No photo could be read.'), style: const TextStyle(color: Colors.white70)),
              )
            : PageView.builder(
                controller: _pages,
                itemCount: ids.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) => _photo(ids[i]),
              ),
      ),
    );
  }

  Widget _photo(String id) {
    final capture = _captures[id];
    final image = _images[id];
    if (capture == null || image == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final width = (capture['width'] as num?)?.toDouble() ?? 3;
    final height = (capture['height'] as num?)?.toDouble() ?? 4;
    return InteractiveViewer(
      maxScale: 5,
      child: Center(
        child: AspectRatio(
          aspectRatio: width / height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(image, fit: BoxFit.fill, gaplessPlayback: true),
              CustomPaint(painter: _Boxes(_detections(id), _isOwn, _names)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.color, required this.text});
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(border: Border.all(color: color, width: 3)),
      ),
      const SizedBox(width: 6),
      Text(
        text,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      ),
    ],
  );
}

class _Boxes extends CustomPainter {
  _Boxes(this.detections, this.isOwn, this.names);
  final List<Map<String, dynamic>> detections;
  final bool Function(Map<String, dynamic>) isOwn;
  final Map<String, String> names;

  @override
  void paint(Canvas canvas, Size size) {
    for (final d in detections) {
      final b = d['box'] as Map;
      final rect = Rect.fromLTWH(
        (b['x'] as num) * size.width,
        (b['y'] as num) * size.height,
        (b['width'] as num) * size.width,
        (b['height'] as num) * size.height,
      );
      final own = isOwn(d);
      final color = own ? _ShelfResultScreenState._own : _ShelfResultScreenState._other;
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = color,
      );
      // Square packs get their product name, so the officer can see what was recognised.
      final productId = (d['final'] as Map)['product_id'] as String?;
      final name = own ? names[productId] : null;
      if (name == null || rect.width < 36) continue;
      final text = TextPainter(
        text: TextSpan(
          text: name,
          style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: rect.width);
      final label = Rect.fromLTWH(rect.left, rect.top, text.width + 6, text.height + 2);
      canvas.drawRect(label, Paint()..color = color);
      text.paint(canvas, Offset(rect.left + 3, rect.top + 1));
    }
  }

  @override
  bool shouldRepaint(covariant _Boxes old) => old.detections != detections;
}
