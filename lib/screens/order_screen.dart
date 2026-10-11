import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../services/platform_api.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/shell_widgets.dart';

class _Line {
  _Line({
    required this.productId,
    required this.name,
    required this.price,
    required this.quantity,
    this.suggested,
    this.recommendationId,
    this.sources = const [],
    this.reasons = const [],
  });

  /// A line of the platform's suggestion (history, shelf gaps, recommendations).
  factory _Line.suggested(Map<String, dynamic> data) {
    final sources = (data['sources'] as List? ?? const []).cast<Map<String, dynamic>>();
    return _Line(
      productId: data['product_id'] as String,
      name: data['name'] as String,
      price: (data['unit_price'] as num).toDouble(),
      quantity: data['quantity'] as int,
      suggested: data['quantity'] as int,
      recommendationId: sources
          .where((s) => s['source'] == 'recommendation')
          .map((s) => s['recommendation_id'] as String?)
          .firstOrNull,
      sources: sources,
      reasons: (data['reasons'] as List? ?? const []).cast<String>(),
    );
  }

  /// A line of an order that already exists.
  factory _Line.ordered(Map<String, dynamic> data) => _Line(
    productId: data['product_id'] as String,
    name: data['name'] as String,
    price: (data['unit_price'] as num).toDouble(),
    quantity: data['quantity'] as int,
    suggested: data['suggested_quantity'] as int?,
    recommendationId: data['recommendation_id'] as String?,
    reasons: (data['reasons'] as List? ?? const []).cast<String>(),
  );

  final String productId;
  final String name;
  final double price;
  int quantity;
  final int? suggested;
  final String? recommendationId;
  final List<Map<String, dynamic>> sources;
  final List<String> reasons;
}

/// An order for one outlet. Without [order] it starts from the platform's suggestion
/// (usual order sizes, shelf gaps from the latest photos, recommendations) and places a
/// new order; with [order] it edits that order while the server still allows changes.
/// Suggested and final quantities are both stored.
class OrderScreen extends StatefulWidget {
  const OrderScreen({
    super.key,
    required this.outletId,
    required this.outletName,
    this.visitId,
    this.order,
  });
  final String outletId;
  final String outletName;
  final String? visitId;
  final Map<String, dynamic>? order;

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  // One id per screen instance: a double tap or retry cannot create two orders.
  final String _clientOrderId = newClientId();
  List<_Line>? _lines;
  String? _error;
  bool _saving = false;
  final Set<String> _open = {}; // lines showing why they were suggested

  bool get _editing => widget.order != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final order = widget.order;
    if (order != null) {
      _lines = (order['lines'] as List).cast<Map<String, dynamic>>().map(_Line.ordered).toList();
      return;
    }
    try {
      final suggestion = await PlatformApi.instance.suggestedOrder(widget.outletId, visitId: widget.visitId);
      if (!mounted) return;
      setState(() {
        _lines = (suggestion['lines'] as List).cast<Map<String, dynamic>>().map(_Line.suggested).toList();
        _error = null;
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  double get _total => (_lines ?? const []).fold(0, (sum, line) => sum + line.quantity * line.price);

  Future<void> _addProduct() async {
    final messenger = ScaffoldMessenger.of(context);
    List<Map<String, dynamic>> products;
    try {
      products = (await PlatformApi.instance.products(own: true))
          .where((p) => p['trade_price'] != null)
          .toList();
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
      return;
    }
    if (!mounted) return;
    final product = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (context) => _OwnProductPicker(products: products),
    );
    if (product == null || !mounted) return;
    setState(() {
      final existing = _lines!.where((l) => l.productId == product['id']).firstOrNull;
      if (existing != null) {
        existing.quantity++;
      } else {
        _lines!.add(_Line(
          productId: product['id'] as String,
          name: product['name'] as String,
          price: (product['trade_price'] as num).toDouble(),
          quantity: 1,
        ));
      }
    });
  }

  Future<void> _save() async {
    final lines = _lines!.where((l) => l.quantity > 0).toList();
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (_editing) {
        final updated = await PlatformApi.instance.updateOrder(widget.order!['id'] as String, [
          for (final line in lines) {'product_id': line.productId, 'quantity': line.quantity},
        ]);
        messenger.showSnackBar(SnackBar(content: Text(t('Order updated.'))));
        navigator.pop(updated);
      } else {
        await PlatformApi.instance.createOrder(widget.outletId, _clientOrderId, visitId: widget.visitId, [
          for (final line in lines)
            {
              'product_id': line.productId,
              'quantity': line.quantity,
              'suggested_quantity': ?line.suggested,
              'recommendation_id': ?line.recommendationId,
              if (line.sources.isNotEmpty) 'sources': line.sources,
            },
        ]);
        messenger.showSnackBar(SnackBar(content: Text(t('Order placed.'))));
        navigator.pop(true);
      }
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    final nothing = lines == null || lines.every((l) => l.quantity == 0);
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(title: Text(_editing ? 'Edit order' : 'Suggested order')),
      bottomNavigationBar: lines == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: PrimaryButton(
                  label: _saving
                      ? 'Saving…'
                      : nothing
                      ? (_editing ? 'Nothing left: cancel the order instead' : 'Add at least one product')
                      : '${_editing ? 'Save changes' : 'Place order'} · ৳${_total.round()}',
                  onPressed: _saving || nothing ? null : _save,
                ),
              ),
            ),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
          : lines == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(AppSpace.page, 8, AppSpace.page, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 12),
                  child: Text(
                    _editing
                        ? 'Change anything. The original suggestion is kept.'
                        : 'From usual orders and the last shelf photos. Change anything.',
                    style: const TextStyle(fontSize: AppFontSize.md, color: AppColors.inkMuted),
                  ),
                ),
                if (lines.isEmpty)
                  SurfaceCard(child: Text(t('Nothing to suggest yet. Add products below.')))
                else
                  SurfaceCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (final (i, line) in lines.indexed) ...[
                          if (i > 0) const Divider(height: 1, indent: 16),
                          _LineRow(
                            line: line,
                            open: _open.contains(line.productId),
                            onToggle: () => setState(() {
                              if (!_open.remove(line.productId)) _open.add(line.productId);
                            }),
                            onChanged: (quantity) => setState(() => line.quantity = quantity),
                          ),
                        ],
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _saving ? null : _addProduct,
                    icon: const Icon(Icons.add_rounded),
                    label: Text(t('Add product')),
                  ),
                ),
              ],
            ),
    );
  }
}

/// One order line: name, price and quantity; tap it to see why it was suggested.
class _LineRow extends StatelessWidget {
  const _LineRow({required this.line, required this.open, required this.onToggle, required this.onChanged});
  final _Line line;
  final bool open;
  final VoidCallback onToggle;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final changed = line.suggested != null && line.suggested != line.quantity;
    return InkWell(
      onTap: line.reasons.isEmpty ? null : onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(line.name, style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink)),
                      const SizedBox(height: 2),
                      Text(
                        '৳${line.price.toStringAsFixed(2)}'
                        '${changed ? ' · suggested ${line.suggested}' : ''}',
                        style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: t('Decrease'),
                  visualDensity: VisualDensity.compact,
                  onPressed: line.quantity == 0 ? null : () => onChanged(line.quantity - 1),
                  icon: const Icon(Icons.remove_rounded, color: AppColors.inkMuted),
                ),
                SizedBox(
                  width: 36,
                  child: Text(
                    '${line.quantity}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: AppFontSize.lg, color: AppColors.ink),
                  ),
                ),
                IconButton(
                  tooltip: t('Increase'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onChanged(line.quantity + 1),
                  icon: const Icon(Icons.add_rounded, color: AppColors.inkMuted),
                ),
              ],
            ),
            if (open)
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final reason in line.reasons)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          reason,
                          style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted, height: 1.4),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _OwnProductPicker extends StatefulWidget {
  const _OwnProductPicker({required this.products});
  final List<Map<String, dynamic>> products;
  @override
  State<_OwnProductPicker> createState() => _OwnProductPickerState();
}

class _OwnProductPickerState extends State<_OwnProductPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final needle = _query.toLowerCase();
    final matches = widget.products
        .where((p) =>
            needle.isEmpty ||
            (p['name'] as String).toLowerCase().contains(needle) ||
            (p['sku'] as String).toLowerCase().contains(needle))
        .toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  autofocus: true,
                  onChanged: (value) => setState(() => _query = value),
                  decoration: InputDecoration(
                    hintText: t('Search our products'),
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: matches.length,
                  itemBuilder: (context, index) {
                    final p = matches[index];
                    return ListTile(
                      title: Text(p['name'] as String),
                      subtitle: Text('${p['category']} · ৳${(p['trade_price'] as num).toStringAsFixed(2)}'),
                      onTap: () => Navigator.of(context).pop(p),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
