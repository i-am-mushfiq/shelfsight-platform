import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../models/field_models.dart';
import '../services/platform_api.dart';
import '../theme/app_theme.dart';
import 'app_widgets.dart';

/// Icon for a store type's configured icon key (unknown keys get a generic shop).
IconData storeTypeIcon(String? key) => switch (key) {
  'grocery' => Icons.local_grocery_store_outlined,
  'cosmetics' => Icons.face_retouching_natural_outlined,
  'departmental' => Icons.store_mall_directory_outlined,
  'supershop' => Icons.shopping_cart_outlined,
  'pharmacy' => Icons.local_pharmacy_outlined,
  'wholesale' => Icons.warehouse_outlined,
  'kiosk' => Icons.storefront_outlined,
  _ => Icons.storefront_outlined,
};

/// Grid of store types. [recordedId] marks what the shop is currently recorded as.
class StoreTypeGrid extends StatelessWidget {
  const StoreTypeGrid({
    super.key,
    required this.types,
    required this.selectedId,
    required this.onSelected,
    this.recordedId,
  });

  final List<StoreType> types;
  final String? selectedId;
  final String? recordedId;
  final ValueChanged<StoreType> onSelected;

  @override
  Widget build(BuildContext context) => GridView.count(
    crossAxisCount: 2,
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    mainAxisSpacing: 10,
    crossAxisSpacing: 10,
    childAspectRatio: 1.05,
    children: [
      for (final type in types)
        _StoreTypeTile(
          key: Key('store-type-${type.code}'),
          type: type,
          selected: type.id == selectedId,
          recorded: type.id == recordedId,
          onTap: () => onSelected(type),
        ),
    ],
  );
}

class _StoreTypeTile extends StatelessWidget {
  const _StoreTypeTile({
    super.key,
    required this.type,
    required this.selected,
    required this.recorded,
    required this.onTap,
  });

  final StoreType type;
  final bool selected;
  final bool recorded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? AppColors.mint : Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(color: selected ? AppColors.emeraldDark : AppColors.border, width: selected ? 2 : 1),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(storeTypeIcon(type.icon), color: selected ? AppColors.emeraldDark : AppColors.navy, size: 26),
                const Spacer(),
                if (selected)
                  const Icon(Icons.check_circle_rounded, color: AppColors.emeraldDark, size: 20)
                else if (recorded)
                  Text(
                    t('On record'),
                    style: TextStyle(fontSize: AppFontSize.xs, fontWeight: FontWeight.w600, color: AppColors.inkMuted),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              type.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink, height: 1.2),
            ),
            if (type.nameBn != null)
              Text(
                type.nameBn!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted),
              ),
            const Spacer(),
            if (type.description != null)
              Text(
                type.description!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: AppFontSize.xs, color: AppColors.inkMuted, height: 1.25),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Asks what kind of store this is, before photos are taken. Returns null if dismissed.
Future<StoreType?> pickStoreType(BuildContext context, {required String shopName, String? recordedId}) async {
  final types = (await PlatformApi.instance.storeTypes()).map(StoreType.fromJson).toList();
  if (!context.mounted) return null;
  return showModalBottomSheet<StoreType>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.canvas,
    builder: (context) => _StoreTypeSheet(types: types, shopName: shopName, recordedId: recordedId),
  );
}

class _StoreTypeSheet extends StatefulWidget {
  const _StoreTypeSheet({required this.types, required this.shopName, this.recordedId});
  final List<StoreType> types;
  final String shopName;
  final String? recordedId;

  @override
  State<_StoreTypeSheet> createState() => _StoreTypeSheetState();
}

class _StoreTypeSheetState extends State<_StoreTypeSheet> {
  late StoreType? _selected = widget.types.where((t) => t.id == widget.recordedId).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final recorded = widget.types.where((t) => t.id == widget.recordedId).firstOrNull;
    final changed = recorded != null && _selected != null && _selected!.id != recorded.id;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .88),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(AppSpace.page, 0, AppSpace.page, 16),
          children: [
            Text(t('What kind of store is this?'), style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 2),
            Text(
              '${widget.shopName} · rules, targets and the order follow the store type',
              style: const TextStyle(color: AppColors.inkMuted, fontSize: AppFontSize.md),
            ),
            const SizedBox(height: 14),
            StoreTypeGrid(
              types: widget.types,
              selectedId: _selected?.id,
              recordedId: widget.recordedId,
              onSelected: (type) => setState(() => _selected = type),
            ),
            if (changed) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.amberSoft,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.amber),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.edit_note_rounded, color: AppColors.amberInk),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This shop is recorded as ${recorded.name}. Starting the visit changes it to '
                        '${_selected!.name}.',
                        style: const TextStyle(fontSize: AppFontSize.md, fontWeight: FontWeight.w600, color: AppColors.amberInk),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            PrimaryButton(
              label: _selected == null ? 'Choose a store type' : 'Start visit as ${_selected!.name}',
              onPressed: _selected == null ? null : () => Navigator.of(context).pop(_selected),
            ),
          ],
        ),
      ),
    );
  }
}
