import 'package:flutter/material.dart';

import '../models/session.dart';
import '../services/platform_api.dart';
import '../services/upload_queue.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/shell_widgets.dart';
import '../widgets/street_map.dart';
import 'outlet_screen.dart';

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

  double? get _activeMeters => _active == null
      ? null
      : distanceMeters(SimulatedGps.lat, SimulatedGps.lng, _active!.lat, _active!.lng);

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
              color: Colors.white.withValues(alpha: .75),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text(
                '© OpenStreetMap contributors · simulated GPS',
                style: TextStyle(fontSize: 10, color: Color(0xFF475569)),
              ),
            ),
          ),
        ),
        Positioned(
          right: 12,
          top: top + 6,
          child: Material(
            color: Colors.white,
            elevation: 3,
            shape: const CircleBorder(),
            child: IconButton(
              tooltip: 'Recenter on my location',
              onPressed: () =>
                  _mapKey.currentState?.recenter(MediaQuery.sizeOf(context)),
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
              borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
              boxShadow: [
                BoxShadow(
                  color: Color(0x330B1426),
                  blurRadius: 24,
                  offset: Offset(0, -6),
                ),
              ],
            ),
            child: ListView(
              controller: controller,
              padding: EdgeInsets.fromLTRB(16, 10, 16, navH + 12),
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(3),
                    ),
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
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppColors.ink,
                          ),
                        ),
                        const SizedBox(height: 10),
                        PrimaryButton(
                          label: 'Try again',
                          icon: Icons.refresh_rounded,
                          onPressed: _load,
                        ),
                      ],
                    ),
                  )
                else ...[
                  _ShopStatusCard(
                    shop: _active,
                    meters: _activeMeters,
                    atShop: _atActiveShop,
                  ),
                  if (_active != null) ...[
                    const SizedBox(height: 12),
                    PrimaryButton(
                      label: 'Open outlet',
                      icon: Icons.insights_rounded,
                      onPressed: () => _open(_active!),
                    ),
                  ],
                  ListenableBuilder(
                    listenable: UploadQueue.instance,
                    builder: (context, _) {
                      final pending = UploadQueue.instance.pendingCount;
                      if (pending == 0) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: StatusPill(
                          label: '$pending photo${pending == 1 ? '' : 's'} waiting to upload',
                          icon: Icons.cloud_upload_outlined,
                          color: const Color(0xFF92580A),
                          background: AppColors.amberSoft,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    'Assigned shops',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.3,
                      color: AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (final s in _shops)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _ShopRow(
                        shop: s,
                        detected: s.id == _detected?.shop.id,
                        selected: s.id == _active?.id,
                        onTap: () => _open(s),
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
            subtitle: '${widget.session.territory} · ${_shops.length} shops',
          ),
        ),
      ],
    );
  }
}

class _ShopStatusCard extends StatelessWidget {
  const _ShopStatusCard({
    required this.shop,
    required this.meters,
    required this.atShop,
  });
  final Shop? shop;
  final double? meters;
  final bool atShop;

  @override
  Widget build(BuildContext context) {
    if (shop == null) {
      return const SurfaceCard(
        borderColor: AppColors.amber,
        color: AppColors.amberSoft,
        child: Row(
          children: [
            Icon(Icons.location_searching_rounded, color: Color(0xFF92580A)),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'No assigned shop nearby. Move closer or tap a shop on the map.',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF92580A),
                ),
              ),
            ),
          ],
        ),
      );
    }
    final m = meters!.round();
    return SurfaceCard(
      color: atShop ? AppColors.mint : Colors.white,
      borderColor: atShop ? AppColors.emerald : AppColors.border,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: atShop ? AppColors.emerald : AppColors.navy,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.storefront_rounded,
                  color: atShop ? AppColors.navy : Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      shop!.name,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: AppColors.ink,
                      ),
                    ),
                    Text(
                      shop!.area,
                      style: const TextStyle(
                        color: AppColors.inkMuted,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (atShop)
            StatusPill(
              label: 'Shop detected · GPS ±$m m',
              icon: Icons.check_circle_rounded,
              color: AppColors.emeraldDark,
              background: Colors.white,
            )
          else
            StatusPill(
              label: m >= 1000
                  ? 'Not here · ${(m / 1000).toStringAsFixed(1)} km away'
                  : 'Not here · $m m away',
              icon: Icons.near_me_outlined,
              color: const Color(0xFF92580A),
              background: AppColors.amberSoft,
            ),
        ],
      ),
    );
  }
}

class _ShopRow extends StatelessWidget {
  const _ShopRow({
    required this.shop,
    required this.detected,
    required this.selected,
    required this.onTap,
  });
  final Shop shop;
  final bool detected;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      borderColor: selected ? AppColors.emeraldDark : AppColors.border,
      child: Row(
        children: [
          Icon(
            Icons.storefront_rounded,
            color: detected ? AppColors.emeraldDark : AppColors.navy,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  shop.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: AppColors.ink,
                  ),
                ),
                Text(
                  'Last visit: ${shop.lastVisit}',
                  style: const TextStyle(
                    color: AppColors.inkMuted,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          if (detected)
            const StatusPill(label: 'Here', icon: Icons.my_location_rounded)
          else if (shop.visitedToday)
            const StatusPill(label: 'Done', icon: Icons.check_rounded),
        ],
      ),
    );
  }
}
