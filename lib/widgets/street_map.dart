import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../models/session.dart';
import '../theme/app_theme.dart';

/// Offline OpenStreetMap-style street map (painted) for the Banani area demo.
/// Swap [StreetMap] for flutter_map + OSM tiles in production; marker widgets
/// and [MapProjection] stay the same.
abstract final class MapProjection {
  static const width = 1100.0;
  static const height = 1000.0;
  static const _lat0 = 23.7860, _lat1 = 23.7990;
  static const _lng0 = 90.3990, _lng1 = 90.4130;

  static Offset project(double lat, double lng) => Offset(
    (lng - _lng0) / (_lng1 - _lng0) * width,
    (1 - (lat - _lat0) / (_lat1 - _lat0)) * height,
  );
}

class StreetMap extends StatefulWidget {
  const StreetMap({
    super.key,
    required this.shops,
    required this.detectedShopId,
    required this.onShopTap,
    this.selectedShopId,
    this.topInset = 0,
    this.bottomInset = 0,
  });

  final List<Shop> shops;
  final String? detectedShopId;
  final String? selectedShopId;
  final ValueChanged<Shop> onShopTap;

  /// Space covered by glass chrome; the map centers in the remaining area.
  final double topInset;
  final double bottomInset;

  @override
  State<StreetMap> createState() => StreetMapState();
}

class StreetMapState extends State<StreetMap>
    with SingleTickerProviderStateMixin {
  final _controller = TransformationController();
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();
  bool _centered = false;

  @override
  void dispose() {
    _controller.dispose();
    _pulse.dispose();
    super.dispose();
  }

  void recenter(Size viewport) {
    final user = MapProjection.project(SimulatedGps.lat, SimulatedGps.lng);
    const scale = 1.15;
    final cx = viewport.width / 2;
    final cy =
        widget.topInset +
        (viewport.height - widget.topInset - widget.bottomInset) / 2;
    _controller.value = Matrix4.identity()
      ..translateByDouble(cx - user.dx * scale, cy - user.dy * scale, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (!_centered) {
          _centered = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) recenter(size);
          });
        }
        final user = MapProjection.project(SimulatedGps.lat, SimulatedGps.lng);
        return Semantics(
          label: t('Street map showing your location and assigned shops'),
          child: InteractiveViewer(
            transformationController: _controller,
            constrained: false,
            minScale: .6,
            maxScale: 2.2,
            boundaryMargin: const EdgeInsets.all(400),
            child: SizedBox(
              width: MapProjection.width,
              height: MapProjection.height,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Positioned.fill(
                    child: CustomPaint(painter: _StreetPainter()),
                  ),
                  for (final shop in widget.shops)
                    if (shop.id != widget.detectedShopId)
                      _pin(shop, detected: false),
                  for (final shop in widget.shops)
                    if (shop.id == widget.detectedShopId)
                      _pin(shop, detected: true),
                  Positioned(
                    left: user.dx - 40,
                    top: user.dy - 40,
                    child: _PulsingDot(animation: _pulse),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _pin(Shop shop, {required bool detected}) {
    final p = MapProjection.project(shop.lat, shop.lng);
    final selected = widget.selectedShopId == shop.id;
    final s = detected ? 38.0 : 28.0;
    final tip = s * math.sqrt2 / 2;
    final box = s * math.sqrt2 + 8;
    return Positioned(
      left: p.dx - box / 2,
      top: p.dy - tip - box / 2,
      width: box,
      height: box,
      child: Semantics(
        button: true,
        label: detected
            ? '${shop.name}, detected shop'
            : '${shop.name}, assigned shop',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onShopTap(shop),
          child: Center(
            child: Transform.rotate(
              angle: -math.pi / 4,
              child: Container(
                width: s,
                height: s,
                decoration: BoxDecoration(
                  color: detected ? AppColors.emerald : AppColors.navy,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(s / 2),
                    topRight: Radius.circular(s / 2),
                    bottomRight: Radius.circular(s / 2),
                  ),
                  border: Border.all(
                    color: selected ? AppColors.emeraldDark : Colors.white,
                    width: detected || selected ? 3 : 2,
                  ),
                  boxShadow: const [
                    BoxShadow(color: Color(0x550B1426), blurRadius: 8),
                  ],
                ),
                child: Transform.rotate(
                  angle: math.pi / 4,
                  child: Icon(
                    Icons.storefront_rounded,
                    size: detected ? 21 : 15,
                    color: detected ? AppColors.navy : Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PulsingDot extends StatelessWidget {
  const _PulsingDot({required this.animation});
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 80,
      height: 80,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) {
          final t = animation.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 22 + 52 * t,
                height: 22 + 52 * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.emerald.withValues(alpha: .38 * (1 - t)),
                ),
              ),
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.emerald,
                  border: Border.all(color: Colors.white, width: 3.5),
                  boxShadow: const [
                    BoxShadow(color: Color(0x660B1426), blurRadius: 6),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StreetPainter extends CustomPainter {
  const _StreetPainter();

  static const _land = Color(0xFFF2EFE9);
  static const _block = Color(0xFFE6E1D8);
  static const _building = Color(0xFFD9D3C7);
  static const _park = Color(0xFFCDEBB0);
  static const _water = Color(0xFFAAD3DF);
  static const _casing = Color(0xFFC9C4BA);
  static const _minor = Colors.white;
  static const _major = Color(0xFFFCE9A6);
  static const _majorCasing = Color(0xFFE0B64C);

  // Road polylines in map pixels. Deterministic "Banani-like" grid.
  static const _verticalMinor = [
    90.0,
    230.0,
    380.0,
    520.0,
    660.0,
    810.0,
    960.0,
  ];
  static const _horizontalMinor = [
    80.0,
    210.0,
    340.0,
    470.0,
    610.0,
    750.0,
    880.0,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _land);

    // Lake (Banani/Gulshan lake edge) on the right.
    final lake = Path()
      ..moveTo(size.width, 120)
      ..cubicTo(1010, 150, 990, 260, 1030, 340)
      ..cubicTo(1060, 400, 1040, 470, size.width, 500)
      ..lineTo(size.width, 120)
      ..close();
    canvas.drawPath(lake, Paint()..color = _water);

    // City blocks with building footprints.
    final rng = math.Random(11);
    final xs = [0.0, ..._verticalMinor, size.width];
    final ys = [0.0, ..._horizontalMinor, size.height];
    for (var i = 0; i < xs.length - 1; i++) {
      for (var j = 0; j < ys.length - 1; j++) {
        final r = Rect.fromLTRB(
          xs[i] + 8,
          ys[j] + 8,
          xs[i + 1] - 8,
          ys[j + 1] - 8,
        );
        if (r.width < 20 || r.height < 20) continue;
        final isPark = (i == 3 && j == 3) || (i == 1 && j == 5);
        canvas.drawRRect(
          RRect.fromRectAndRadius(r, const Radius.circular(4)),
          Paint()..color = isPark ? _park : _block,
        );
        if (isPark) continue;
        for (var k = 0; k < 7; k++) {
          final bw = 22 + rng.nextDouble() * 34;
          final bh = 18 + rng.nextDouble() * 30;
          final bx =
              r.left + 6 + rng.nextDouble() * math.max(1, r.width - bw - 12);
          final by =
              r.top + 6 + rng.nextDouble() * math.max(1, r.height - bh - 12);
          canvas.drawRect(
            Rect.fromLTWH(bx, by, bw, bh),
            Paint()..color = _building,
          );
        }
      }
    }

    // Minor roads: casing then fill.
    void roads(Paint paint, double w) {
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..strokeCap = StrokeCap.round;
      for (final x in _verticalMinor) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      }
      for (final y in _horizontalMinor) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      }
    }

    roads(Paint()..color = _casing, 14);
    roads(Paint()..color = _minor, 11);

    // Major roads (Kemal Ataturk Ave diagonal-ish + Road 27 horizontal).
    final major = Path()
      ..moveTo(0, 560)
      ..cubicTo(260, 520, 520, 600, 760, 470)
      ..cubicTo(900, 395, 1010, 420, size.width, 410);
    canvas.drawPath(
      major,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 24
        ..strokeCap = StrokeCap.round
        ..color = _majorCasing,
    );
    canvas.drawPath(
      major,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 19
        ..strokeCap = StrokeCap.round
        ..color = _major,
    );
    final major2 = Path()
      ..moveTo(520, 0)
      ..cubicTo(500, 250, 560, 420, 520, size.height);
    canvas.drawPath(
      major2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 22
        ..color = _majorCasing,
    );
    canvas.drawPath(
      major2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 17
        ..color = _major,
    );

    // Labels.
    _label(canvas, 'Kemal Ataturk Avenue', const Offset(130, 520), -.06);
    _label(canvas, 'Road 11', const Offset(560, 322), 0);
    _label(canvas, 'Road 27', const Offset(110, 735), 0);
    _label(canvas, 'Banani', const Offset(250, 400), 0, big: true);
    _label(
      canvas,
      'Gulshan Lake',
      const Offset(940, 300),
      -math.pi / 2.4,
      color: const Color(0xFF4A89A0),
    );
    _label(
      canvas,
      'Banani Park',
      const Offset(535, 500),
      0,
      color: const Color(0xFF5C8A3A),
    );
  }

  void _label(
    Canvas canvas,
    String text,
    Offset at,
    double angle, {
    bool big = false,
    Color color = const Color(0xFF6B6558),
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: big ? AppFontSize.xl : AppFontSize.sm,
          fontWeight: big ? FontWeight.w600 : FontWeight.w500,
          color: color,
          letterSpacing: big ? 1.2 : .2,
          shadows: const [
            Shadow(color: Colors.white, blurRadius: 3),
            Shadow(color: Colors.white, blurRadius: 3),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(angle);
    tp.paint(canvas, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
