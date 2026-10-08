import 'package:flutter/material.dart';

import '../models/session.dart';
import '../services/platform_api.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/shell_widgets.dart';

class _Line {
  _Line(this.data) : quantity = data['quantity'] as int;
  final Map<String, dynamic> data;
  int quantity;

  int get suggested => data['quantity'] as int;
  double get price => (data['unit_price'] as num).toDouble();
  List<Map<String, dynamic>> get sources => (data['sources'] as List).cast<Map<String, dynamic>>();
  String? get recommendationId => sources
      .where((s) => s['source'] == 'recommendation')
      .map((s) => s['recommendation_id'] as String?)
      .firstOrNull;
}

/// Suggested order: replenishment from history plus accepted/open recommendations.
/// The officer edits quantities; suggestion and final quantity are both stored.
class OrderScreen extends StatefulWidget {
  const OrderScreen({super.key, required this.shop});
  final Shop shop;

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  // One id per screen instance: a double tap or retry cannot create two orders.
  final String _clientOrderId = newClientId();
  List<_Line>? _lines;
  String? _error;
  bool _placing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final suggestion = await PlatformApi.instance.suggestedOrder(widget.shop.id);
      if (!mounted) return;
      setState(() {
        _lines = (suggestion['lines'] as List).cast<Map<String, dynamic>>().map(_Line.new).toList();
        _error = null;
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  double get _total =>
      (_lines ?? const []).fold(0, (sum, line) => sum + line.quantity * line.price);

  Future<void> _place() async {
    final lines = _lines!.where((l) => l.quantity > 0).toList();
    setState(() => _placing = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await PlatformApi.instance.createOrder(widget.shop.id, _clientOrderId, [
        for (final line in lines)
          {
            'product_id': line.data['product_id'],
            'quantity': line.quantity,
            'suggested_quantity': line.suggested,
            'recommendation_id': ?line.recommendationId,
          },
      ]);
      messenger.showSnackBar(const SnackBar(content: Text('Order placed.')));
      navigator.pop();
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
      if (mounted) setState(() => _placing = false);
    }
  }

  String _sourceText(Map<String, dynamic> source) => switch (source['source']) {
    'replenishment' =>
      'Usual order: ${source['quantity']} (from ${(source['evidence'] as Map)['units_in_window']} units over ${(source['evidence'] as Map)['order_days']} orders)',
    'recommendation' => 'Recommendation: +${source['quantity']}',
    'promotion' => 'Active promotion applies',
    _ => '${source['source']}',
  };

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(title: Text('Order · ${widget.shop.name}')),
      bottomNavigationBar: lines == null || lines.isEmpty
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border(top: BorderSide(color: AppColors.border)),
                ),
                child: PrimaryButton(
                  label: _placing ? 'Placing…' : 'Place order · ৳${_total.round()}',
                  icon: Icons.check_rounded,
                  onPressed: _placing || lines.every((l) => l.quantity == 0) ? null : _place,
                ),
              ),
            ),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
          : lines == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Suggested quantities. Change anything: the final order is yours.',
                  style: TextStyle(color: AppColors.inkMuted),
                ),
                const SizedBox(height: 12),
                if (lines.isEmpty)
                  const SurfaceCard(child: Text('No order history or recommendations to suggest from.')),
                for (final line in lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: SurfaceCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      line.data['name'] as String,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.ink,
                                      ),
                                    ),
                                    Text(
                                      '৳${line.price.toStringAsFixed(2)} each',
                                      style: const TextStyle(fontSize: 12.5, color: AppColors.inkMuted),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: 'Decrease',
                                onPressed: line.quantity == 0
                                    ? null
                                    : () => setState(() => line.quantity--),
                                icon: const Icon(Icons.remove_circle_outline_rounded),
                              ),
                              SizedBox(
                                width: 34,
                                child: Text(
                                  '${line.quantity}',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Increase',
                                onPressed: () => setState(() => line.quantity++),
                                icon: const Icon(Icons.add_circle_outline_rounded),
                              ),
                            ],
                          ),
                          for (final source in line.sources)
                            Text(
                              '• ${_sourceText(source)}',
                              style: const TextStyle(fontSize: 12.5, color: AppColors.inkMuted),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
