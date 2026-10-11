import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../models/session.dart';
import '../services/platform_api.dart';
import '../services/upload_queue.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/shell_widgets.dart';
import '../widgets/street_map.dart';
import 'outlet_screen.dart';
import 'register_outlet_screen.dart';

class SalesHomeScreen extends StatefulWidget {
  const SalesHomeScreen({super.key, required this.session});
  final UserSession session;

  @override
  State<SalesHomeScreen> createState() => _SalesHomeScreenState();
}

class _SalesHomeScreenState extends State<SalesHomeScreen> {
  final _mapKey = GlobalKey<StreetMapState>();
  List<Shop> _shops = const [];
  ({Shop shop, double meters})? _detected;
  Shop? _selected;
  bool _loading = true;
  String? _error;

  Shop? get _active => _selected ?? _detected?.shop;
  bool get _atActiveShop => _active != null && _active!.id == _detected?.shop.id;

  double? get _activeMeters =>
      _active == null ? null : distanceMeters(SimulatedGps.lat, SimulatedGps.lng, _active!.lat, _active!.lng);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final shops = (await PlatformApi.instance.outlets()).map(Shop.fromJson).toList();
      if (!mounted) return;
      setState(() {
        _shops = shops;
        _detected = SimulatedGps.detect(shops);
        _selected = shops.where((s) => s.id == _selected?.id).firstOrNull;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  Future<void> _open(Shop shop) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        settings: const RouteSettings(name: OutletScreen.routeName),
        builder: (_) => OutletScreen(shop: shop, atShop: shop.id == _detected?.shop.id),
      ),
    );
    if (mounted) _load(); // visits and recommendations may have changed
  }

  /// A shop that is not in the list yet: register it, then the visit starts from its page.
  Future<void> _registerShop() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RegisterOutletScreen()));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final top = ShelfSightHeader.totalHeight(context);
    final navH = FloatingGlassNav.totalHeight(context);
    final screenH = MediaQuery.sizeOf(context).height;
    return Stack(
      children: [
        Positioned.fill(
          child: StreetMap(
            key: _mapKey,
            shops: _shops,
            detectedShopId: _detected?.shop.id,
            selectedShopId: _selected?.id,
            topInset: top,
            bottomInset: screenH * .42,
            onShopTap: (s) => setState(() => _selected = s),
          ),
        ),
        // OSM attribution, unobtrusive.
        Positioned(
          left: 10,
          top: top + 6,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .6),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text(
                t('© OpenStreetMap contributors · simulated GPS'),
                style: TextStyle(fontSize: AppFontSize.xs, color: AppColors.inkMuted),
              ),
            ),
          ),
        ),
        Positioned(
          right: 12,
          top: top + 6,
          child: Material(
            color: Colors.white,
            elevation: 1,
            shape: const CircleBorder(),
            child: IconButton(
              tooltip: t('Recenter on my location'),
              onPressed: () => _mapKey.currentState?.recenter(MediaQuery.sizeOf(context)),
              icon: const Icon(Icons.my_location_rounded, color: AppColors.navy),
            ),
          ),
        ),
        DraggableScrollableSheet(
          initialChildSize: .40,
          minChildSize: .22,
          maxChildSize: .86,
          snap: true,
          snapSizes: const [.22, .40, .86],
          builder: (context, controller) => DecoratedBox(
            decoration: const BoxDecoration(
              color: AppColors.canvas,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              boxShadow: [BoxShadow(color: Color(0x140B1426), blurRadius: 12, offset: Offset(0, -2))],
            ),
            child: ListView(
              controller: controller,
              padding: EdgeInsets.fromLTRB(16, 10, 16, navH + 12),
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(3)),
                  ),
                ),
                const SizedBox(height: 14),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_error != null)
                  SurfaceCard(
                    color: AppColors.redSoft,
                    borderColor: AppColors.red,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _error!,
                          style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink),
                        ),
                        const SizedBox(height: 10),
                        PrimaryButton(label: t('Try again'), onPressed: _load),
                      ],
                    ),
                  )
                else ...[
                  _ShopStatusCard(shop: _active, meters: _activeMeters, atShop: _atActiveShop),
                  if (_active != null) ...[
                    const SizedBox(height: 12),
                    PrimaryButton(label: t('Open shop'), onPressed: () => _open(_active!)),
                  ],
                  ListenableBuilder(
                    listenable: UploadQueue.instance,
                    builder: (context, _) {
                      final pending = UploadQueue.instance.pendingCount;
                      if (pending == 0) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          '$pending photo${pending == 1 ? '' : 's'} waiting to upload',
                          style: const TextStyle(fontSize: AppFontSize.md, color: AppColors.inkMuted),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          t('Your shops'),
                          style: TextStyle(fontSize: AppFontSize.lg, fontWeight: FontWeight.w600, color: AppColors.ink),
                        ),
                      ),
                      TextButton(
                        key: const Key('register-shop'),
                        onPressed: _registerShop,
                        child: Text(t('New shop')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SurfaceCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (var i = 0; i < _shops.length; i++) ...[
                          if (i > 0) const Divider(indent: 16, endIndent: 16),
                          _ShopRow(
                            shop: _shops[i],
                            detected: _shops[i].id == _detected?.shop.id,
                            selected: _shops[i].id == _active?.id,
                            onTap: () => _open(_shops[i]),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: ShelfSightHeader(
            title: 'Hi, ${widget.session.name.split(' ').first}',
            subtitle: '${widget.session.territory} · ${_shops.length} shop${_shops.length == 1 ? '' : 's'}',
          ),
        ),
      ],
    );
  }
}

class _ShopStatusCard extends StatelessWidget {
  const _ShopStatusCard({required this.shop, required this.meters, required this.atShop});
  final Shop? shop;
  final double? meters;
  final bool atShop;

  @override
  Widget build(BuildContext context) {
    if (shop == null) {
      return Text(
        t('No assigned shop nearby. Move closer or tap a shop on the map.'),
        style: TextStyle(fontSize: AppFontSize.base, color: AppColors.inkMuted),
      );
    }
    final m = meters!.round();
    final distance = m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km away' : '$m m away';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          shop!.name,
          style: const TextStyle(fontSize: AppFontSize.xl, fontWeight: FontWeight.w600, letterSpacing: -.3, color: AppColors.ink),
        ),
        const SizedBox(height: 2),
        Text(shop!.area, style: const TextStyle(color: AppColors.inkMuted, fontSize: AppFontSize.base)),
        const SizedBox(height: 8),
        Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: atShop ? AppColors.emeraldDark : AppColors.amber,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              atShop ? 'Shop detected · GPS ±$m m' : 'Not here · $distance',
              style: const TextStyle(fontSize: AppFontSize.md, color: AppColors.inkMuted),
            ),
          ],
        ),
      ],
    );
  }
}

class _ShopRow extends StatelessWidget {
  const _ShopRow({required this.shop, required this.detected, required this.selected, required this.onTap});
  final Shop shop;
  final bool detected;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = detected
        ? 'Here'
        : shop.visitedToday
        ? 'Done'
        : null;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shop.name,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      fontSize: AppFontSize.lg,
                      color: AppColors.ink,
                    ),
                  ),
                  Text(
                    'Last visit: ${shop.lastVisit}',
                    style: const TextStyle(color: AppColors.inkMuted, fontSize: AppFontSize.md),
                  ),
                ],
              ),
            ),
            if (status != null)
              Text(
                status,
                style: TextStyle(
                  fontSize: AppFontSize.md,
                  fontWeight: FontWeight.w500,
                  color: detected ? AppColors.emeraldDark : AppColors.inkMuted,
                ),
              ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.border),
          ],
        ),
      ),
    );
  }
}
