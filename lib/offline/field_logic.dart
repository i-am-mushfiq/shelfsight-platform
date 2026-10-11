import 'dart:math' as math;

/// The server's field logic, ported so the app can run a visit without a server: shelf rows
/// and bands, share of shelf, must-stock availability, placement rules, the suggested and
/// automatic order, scores, shelf-based recommendations, the pre-call brief and the visit
/// report. Each function names the Python it mirrors (retail_platform/...) and keeps its
/// rules and output shape, so screens cannot tell which side computed a result.
///
/// Records are the JSON maps the server sends (and tools/export_offline_demo.py exports).
typedef Json = Map<String, dynamic>;

double round4(num v) => (v * 10000).round() / 10000;
double round2(num v) => (v * 100).round() / 100;
String pct(num? v) => v == null ? '—' : '${(v * 100).round()}%';

/// A detected facing after human review (domain/records.py Facing).
class Facing {
  const Facing({
    required this.id,
    required this.captureId,
    required this.label,
    required this.productId,
    required this.manufacturerId,
    required this.confidence,
    required this.verified,
    required this.yCenter,
    this.shelfRow,
    this.shelfRowsTotal,
    this.categoryId,
  });

  final String id, captureId, label;
  final String? productId, manufacturerId, categoryId;
  final double confidence, yCenter;
  final bool verified;
  final int? shelfRow, shelfRowsTotal;
}

// --- domain/shelf.py ---------------------------------------------------------------------------

/// Facings clustered into shelf rows by vertical centre: a new row starts where consecutive
/// centres are further apart than half the median facing height. 1-based rows from the top.
(List<int>, int) assignShelfRows(List<double> yCenters, List<double> heights, {double gapRatio = .5}) {
  if (yCenters.isEmpty) return (<int>[], 0);
  final order = List<int>.generate(yCenters.length, (i) => i)..sort((a, b) => yCenters[a].compareTo(yCenters[b]));
  final sortedHeights = [...heights]..sort();
  final median = sortedHeights.isEmpty ? .1 : sortedHeights[sortedHeights.length ~/ 2];
  final threshold = math.max(.02, gapRatio * median);
  final rowsSorted = [1];
  for (var i = 1; i < order.length; i++) {
    rowsSorted.add(rowsSorted.last + (yCenters[order[i]] - yCenters[order[i - 1]] > threshold ? 1 : 0));
  }
  final rows = List<int>.filled(yCenters.length, 0);
  for (var p = 0; p < order.length; p++) {
    rows[order[p]] = rowsSorted[p];
  }
  return (rows, rowsSorted.last);
}

String? bandFor(int? row, int? total) {
  if (row == null || total == null || total == 0) return null;
  if (total == 1) return 'eye';
  final relative = (row - .5) / total;
  if (relative < .25) return 'top';
  if (relative < .6) return 'eye';
  if (relative < .8) return 'middle';
  return 'bottom';
}

class ShelfSummary {
  ShelfSummary({
    required this.basis,
    required this.totalFacings,
    required this.ownFacings,
    required this.competitorFacings,
    required this.unknownFacings,
    required this.facingsByManufacturer,
    required this.facingsByProduct,
    required this.distinctSkus,
    required this.distinctOwnSkus,
    required this.verifiedRatio,
  });

  final String basis;
  final int totalFacings, ownFacings, competitorFacings, unknownFacings, distinctSkus, distinctOwnSkus;
  final Map<String, int> facingsByManufacturer, facingsByProduct;
  final double verifiedRatio;

  double? get shareOfShelf => totalFacings == 0 ? null : round4(ownFacings / totalFacings);
  List<double>? get range => totalFacings == 0
      ? null
      : [round4(ownFacings / totalFacings), round4((ownFacings + unknownFacings) / totalFacings)];
  double? get shareOfAssortment => distinctSkus == 0 ? null : round4(distinctOwnSkus / distinctSkus);

  Json toJson() => {
    'basis': basis,
    'total_facings': totalFacings,
    'own_facings': ownFacings,
    'competitor_facings': competitorFacings,
    'unknown_facings': unknownFacings,
    'share_of_shelf': shareOfShelf,
    'share_of_shelf_range': range,
    'facings_by_manufacturer': facingsByManufacturer,
    'facings_by_product': facingsByProduct,
    'distinct_skus': distinctSkus,
    'distinct_own_skus': distinctOwnSkus,
    'share_of_assortment': shareOfAssortment,
    'verified_ratio': verifiedRatio,
  };
}

Map<String, int> _count(Iterable<String> keys) {
  final out = <String, int>{};
  for (final k in keys) {
    out[k] = (out[k] ?? 0) + 1;
  }
  return out;
}

ShelfSummary summarize(List<Facing> facings, Set<String> ownManufacturers, [String basis = 'all']) {
  final live = facings.where((f) => f.label != 'rejected').toList();
  final considered = basis == 'verified' ? live.where((f) => f.verified).toList() : live;
  final own = considered.where((f) => f.label == 'own').length;
  final competitor = considered.where((f) => f.label == 'competitor').length;
  final skus = {for (final f in considered) if (f.productId != null) f.productId!};
  final ownSkus = {
    for (final f in considered)
      if (f.productId != null && ownManufacturers.contains(f.manufacturerId)) f.productId!,
  };
  return ShelfSummary(
    basis: basis,
    totalFacings: considered.length,
    ownFacings: own,
    competitorFacings: competitor,
    unknownFacings: considered.length - own - competitor,
    facingsByManufacturer: _count(considered.map((f) => f.manufacturerId).whereType<String>()),
    facingsByProduct: _count(considered.map((f) => f.productId).whereType<String>()),
    distinctSkus: skus.length,
    distinctOwnSkus: ownSkus.length,
    verifiedRatio: round4(live.where((f) => f.verified).length / math.max(1, live.length)),
  );
}

// --- services/ordering.py shelf_stock + domain/availability.py ---------------------------------

class ShelfStock {
  ShelfStock(this.visitId, this.coveredCategories, this.facingsByProduct, this.unidentifiedByCategory, this.verifiedRatio);
  final String visitId;
  final Set<String> coveredCategories;
  final Map<String, int> facingsByProduct, unidentifiedByCategory;
  final double verifiedRatio;
}

/// What one visit's analysed photos show about stock. A photo only proves a product absent
/// when products on it were identified at SKU level. [captures] are the analysed, non-duplicate ones.
ShelfStock? shelfStock(
  String visitId,
  List<Json> captures,
  List<Facing> facings,
  Map<String, List<String>> descendants,
) {
  if (captures.isEmpty) return null;
  Set<String> scopeOf(String category) => {...?descendants[category], category};
  final live = facings.where((f) => f.label != 'rejected').toList();
  final identifiedPhotos = {for (final f in live) if (f.productId != null) f.captureId};
  final covered = <String>{};
  for (final c in captures) {
    final category = c['category_id'] as String?;
    if (category != null && identifiedPhotos.contains(c['id'])) covered.addAll(scopeOf(category));
  }
  for (final f in live) {
    if (f.productId != null && f.categoryId != null) covered.add(f.categoryId!);
  }
  final unidentified = <String, int>{};
  for (final f in live) {
    if (f.productId != null || f.label == 'competitor') continue;
    final scope = f.categoryId != null ? scopeOf(f.categoryId!) : covered;
    for (final category in scope) {
      unidentified[category] = (unidentified[category] ?? 0) + 1;
    }
  }
  return ShelfStock(
    visitId,
    covered,
    _count(live.map((f) => f.productId).whereType<String>()),
    unidentified,
    live.isEmpty ? 0 : round4(live.where((f) => f.verified).length / live.length),
  );
}

/// The core (must-stock) items for a shop: by channel and class, the most important per product.
List<Json> applicableCore(List<Json> core, String channelId, String? classId) {
  final chosen = <String, Json>{};
  for (final item in core) {
    if (item['channel_id'] != null && item['channel_id'] != channelId) continue;
    if (item['outlet_class_id'] != null && item['outlet_class_id'] != classId) continue;
    final current = chosen[item['product_id']];
    if (current == null || (item['priority'] as int) < (current['priority'] as int)) {
      chosen[item['product_id'] as String] = item;
    }
  }
  return chosen.values.toList();
}

List<Json> coreAvailability(List<Json> core, Map<String, Json> products, ShelfStock? shelf) {
  final result = <Json>[];
  for (final item in core) {
    final product = products[item['product_id']];
    if (product == null || product['is_active'] != true) continue;
    final min = item['min_facings'] as int, priority = item['priority'] as int;
    if (shelf == null || !shelf.coveredCategories.contains(product['category_id'])) {
      result.add({'product_id': product['id'], 'status': 'not_checked', 'facings': 0, 'min_facings': min,
          'priority': priority, 'unidentified_nearby': 0});
      continue;
    }
    final seen = shelf.facingsByProduct[product['id']] ?? 0;
    result.add({
      'product_id': product['id'],
      'status': seen >= min ? 'on_shelf' : (seen > 0 ? 'low' : 'missing'),
      'facings': seen,
      'min_facings': min,
      'priority': priority,
      'unidentified_nearby': shelf.unidentifiedByCategory[product['category_id']] ?? 0,
    });
  }
  const rank = {'missing': 0, 'low': 1, 'on_shelf': 2, 'not_checked': 3};
  result.sort((a, b) {
    final s = rank[a['status']]!.compareTo(rank[b['status']]!);
    if (s != 0) return s;
    final p = (a['priority'] as int).compareTo(b['priority'] as int);
    if (p != 0) return p;
    return (products[a['product_id']]!['name'] as String).compareTo(products[b['product_id']]!['name'] as String);
  });
  return result;
}

// --- domain/placement.py ---------------------------------------------------------------------

bool _inCategory(String? category, String? ruleCategory, Map<String, List<String>> descendants) {
  if (ruleCategory == null) return true;
  if (category == null) return false;
  return category == ruleCategory || (descendants[ruleCategory] ?? const []).contains(category);
}

bool _ruleApplies(Json rule, String channelPath, Set<String?> captureCategories, Map<String, List<String>> descendants) {
  final path = rule['channel_path'] as String?;
  if (path != null && path.isNotEmpty && !channelPath.startsWith(path)) return false;
  final ruleCategory = rule['category_id'] as String?;
  if (ruleCategory == null) return true;
  for (final category in captureCategories) {
    if (_inCategory(category, ruleCategory, descendants) ||
        (category != null && (descendants[category] ?? const []).contains(ruleCategory))) {
      return true;
    }
  }
  return false;
}

List<Json> evaluatePlacement(
  List<Json> rules,
  List<Facing> facings,
  String channelPath,
  Map<String, String> brandOfProduct,
  Set<String> ownManufacturers,
  Map<String, List<String>> descendants,
) {
  final live = facings.where((f) => f.label != 'rejected').toList();
  final categories = {for (final f in live) f.categoryId};
  final results = <Json>[];
  for (final rule in rules) {
    if (!_ruleApplies(rule, channelPath, categories, descendants)) continue;
    final scope = live.where((f) => _inCategory(f.categoryId, rule['category_id'] as String?, descendants)).toList();
    final band = rule['preferred_band'] as String, minFacings = rule['min_facings'] as int;
    final minShare = (rule['min_share_of_shelf'] as num?)?.toDouble();
    final expected = {'preferred_band': band, 'min_facings': minFacings, 'min_share_of_shelf': minShare};
    Json result(String status, Json observed, List<String> ids) => {
      'rule_id': rule['id'], 'status': status, 'description': rule['description'], 'priority': rule['priority'],
      'observed': observed, 'expected': expected, 'detection_ids': ids,
    };
    if (scope.isEmpty) {
      results.add(result('not_evaluable', {
        'reason': 'no facing was identified in this rule\'s category '
            '(needs SKU-level recognition or a more specific shelf selection)',
      }, const []));
      continue;
    }
    List<Facing> matches;
    if (rule['product_id'] != null || rule['brand_id'] != null) {
      final identified = scope.where((f) => f.productId != null).toList();
      if (identified.isEmpty) {
        results.add(result('not_evaluable', {'reason': 'detections are not identified at SKU/brand level'}, const []));
        continue;
      }
      matches = rule['product_id'] != null
          ? identified.where((f) => f.productId == rule['product_id']).toList()
          : identified.where((f) => brandOfProduct[f.productId] == rule['brand_id']).toList();
    } else if (rule['manufacturer_id'] != null) {
      matches = scope.where((f) => f.manufacturerId == rule['manufacturer_id']).toList();
    } else {
      matches = scope.where((f) => f.label == 'own' || ownManufacturers.contains(f.manufacturerId)).toList();
    }
    final bands = {for (final f in matches) bandFor(f.shelfRow, f.shelfRowsTotal)};
    final inBand = matches.where((f) => band == 'any' || bandFor(f.shelfRow, f.shelfRowsTotal) == band).toList();
    final share = matches.length / scope.length;
    final failures = <String>[];
    if (matches.length < minFacings) failures.add('${matches.length} facings, expected at least $minFacings');
    final seenBands = (bands.map((b) => b ?? 'unknown').toList()..sort());
    if (band != 'any' && matches.isNotEmpty && inBand.isEmpty) {
      failures.add('not at $band level (seen at: ${seenBands.join(', ')})');
    }
    if (minShare != null && share < minShare) {
      failures.add('share of shelf ${pct(share)}, expected at least ${pct(minShare)}');
    }
    results.add(result(failures.isEmpty ? 'compliant' : 'non_compliant', {
      'facings': matches.length,
      'facings_in_preferred_band': inBand.length,
      'bands_seen': seenBands,
      'share_of_shelf': round4(share),
      'scope_facings': scope.length,
      'unknown_facings_in_scope': scope.where((f) => f.label == 'unknown').length,
      'failures': failures,
    }, [for (final f in matches) f.id]));
  }
  return results;
}

double? complianceScore(List<Json> results) {
  final evaluable = results.where((r) => r['status'] != 'not_evaluable').toList();
  if (evaluable.isEmpty) return null;
  double weight(Json r) => const {1: 3.0, 2: 2.0, 3: 1.0}[r['priority']] ?? 1.0;
  final total = evaluable.fold<double>(0, (s, r) => s + weight(r));
  final passed = evaluable.where((r) => r['status'] == 'compliant').fold<double>(0, (s, r) => s + weight(r));
  return (1000 * passed / total).round() / 10;
}

// --- domain/orders.py ------------------------------------------------------------------------

/// Facings the shop should show (core minimums and product placement rules), and units per facing.
(int, Map<String, int>) shelfPolicy(List<Json> core, List<Json> rules, String channelPath, int unitsPerFacing) {
  final targets = {for (final c in core) c['product_id'] as String: c['min_facings'] as int};
  for (final rule in rules) {
    final productId = rule['product_id'] as String?;
    final path = rule['channel_path'] as String?;
    if (productId != null && (path == null || path.isEmpty || channelPath.startsWith(path))) {
      targets[productId] = math.max(targets[productId] ?? 0, rule['min_facings'] as int);
    }
  }
  return (unitsPerFacing, targets);
}

/// The suggested order: usual order sizes, shelf gaps on photographed shelves, recommendations.
/// [history] is the shop's {order_days, window_days, units, value} over the last 90 days.
List<Json> suggestOrder({
  required Json history,
  required Map<String, Json> products,
  required List<Json> recommendations,
  required Set<String> promoted,
  ShelfStock? shelf,
  int unitsPerFacing = 3,
  Map<String, int> targetFacings = const {},
  Set<String> statuses = const {'open', 'accepted', 'modified'},
}) {
  final units = (history['units'] as Map? ?? const {}).cast<String, num>();
  final value = (history['value'] as Map? ?? const {}).cast<String, num>();
  final orderDays = history['order_days'] as int? ?? 0;
  final suggestion = <String, Json>{};

  Json lineFor(Json product) => suggestion.putIfAbsent(product['id'] as String, () {
    final u = units[product['id']];
    final historical = u != null && u > 0 ? value[product['id']]! / u : null;
    final price = (product['trade_price'] as num?) ?? historical ?? (product['mrp'] as num?) ?? 0;
    return {'product_id': product['id'], 'sku': product['sku'], 'name': product['name'], 'quantity': 0,
        'unit_price': round2(price), 'sources': <Json>[]};
  });

  final replenishment = <String, Json>{};
  if (orderDays > 0) {
    units.forEach((productId, total) {
      final product = products[productId];
      if (product == null || product['is_active'] != true) return;
      final perOrder = (total / orderDays).ceil();
      replenishment[productId] = {
        'source': 'replenishment', 'quantity': perOrder,
        'evidence': {'units_in_window': total, 'order_days': orderDays, 'window_days': history['window_days'] ?? 90},
      };
    });
  }

  final needs = <String, Json>{};
  if (shelf != null) {
    final candidates = {...targetFacings.keys, ...replenishment.keys, ...shelf.facingsByProduct.keys}.toList()..sort();
    for (final productId in candidates) {
      final product = products[productId];
      if (product == null || product['is_own'] != true || product['is_active'] != true) continue;
      if (!shelf.coveredCategories.contains(product['category_id'])) continue;
      final target = targetFacings[productId] ?? (replenishment.containsKey(productId) ? 1 : 0);
      final seen = shelf.facingsByProduct[productId] ?? 0;
      if (target == 0 || seen >= target) continue;
      final gap = target - seen;
      final unidentified = shelf.unidentifiedByCategory[product['category_id']] ?? 0;
      needs[productId] = {
        'source': 'shelf', 'status': seen == 0 ? 'missing' : 'low', 'quantity': gap * unitsPerFacing,
        'uncertain': unidentified >= gap,
        'evidence': {'facings_seen': seen, 'target_facings': target, 'units_per_facing': unitsPerFacing,
            'unidentified_facings_nearby': unidentified, 'visit_id': shelf.visitId, 'verified_ratio': shelf.verifiedRatio},
      };
    }
  }
  for (final productId in ({...replenishment.keys, ...needs.keys}.toList()..sort())) {
    final line = lineFor(products[productId]!);
    for (final source in [replenishment[productId], needs[productId]]) {
      if (source == null) continue;
      line['quantity'] = math.max(line['quantity'] as int, source['quantity'] as int);
      (line['sources'] as List).add(source);
    }
  }
  for (final rec in recommendations) {
    final productId = rec['product_id'] as String?, quantity = rec['suggested_quantity'] as int?;
    if (!statuses.contains(rec['status']) || productId == null || quantity == null || quantity == 0) continue;
    if (rec['type'] != 'add_sku' && rec['type'] != 'increase_volume') continue;
    final product = products[productId];
    if (product == null || product['is_active'] != true) continue;
    final line = lineFor(product);
    line['quantity'] = rec['type'] == 'increase_volume'
        ? (line['quantity'] as int) + quantity
        : math.max(line['quantity'] as int, quantity);
    (line['sources'] as List).add({'source': 'recommendation', 'recommendation_id': rec['id'], 'type': rec['type'],
        'quantity': quantity, 'status': rec['status']});
  }
  for (final line in suggestion.values) {
    final multiple = products[line['product_id']]!['order_multiple'] as int? ?? 1;
    final quantity = line['quantity'] as int;
    if (multiple > 1 && quantity % multiple != 0) {
      line['quantity'] = (quantity / multiple).ceil() * multiple;
      (line['sources'] as List).add({'source': 'pack_multiple', 'multiple': multiple});
    }
    if (promoted.contains(line['product_id'])) {
      (line['sources'] as List).add({'source': 'promotion', 'note': 'active promotion applies'});
    }
  }
  final lines = suggestion.values.where((l) => (l['quantity'] as int) > 0).toList()
    ..sort((a, b) => ((b['quantity'] as int) * (b['unit_price'] as num))
        .compareTo((a['quantity'] as int) * (a['unit_price'] as num)));
  return lines;
}

String explainSource(Json source) {
  final evidence = (source['evidence'] as Map?) ?? const {};
  switch (source['source']) {
    case 'replenishment':
      return 'Usual order: ${source['quantity']} (from ${evidence['units_in_window']} units '
          'over ${evidence['order_days']} orders)';
    case 'shelf':
      final state = source['status'] == 'missing' ? 'Missing on shelf' : 'Low on shelf';
      var text = '$state: ${evidence['facings_seen']} of ${evidence['target_facings']} facings, '
          'restock ${source['quantity']}';
      if (source['uncertain'] == true) text += ' (some facings could not be identified; check before sending)';
      return text;
    case 'recommendation':
      final action = source['type'] == 'add_sku' ? 'New product for this outlet' : 'Grow volume';
      return '$action: ${source['quantity']} (${source['status'] ?? 'open'} recommendation)';
    case 'pack_multiple':
      return 'Rounded up to packs of ${source['multiple']}';
    case 'promotion':
      return 'Active promotion applies';
  }
  return '${source['source']}';
}

// --- domain/competitor.py, scoring.py, recommendations.py --------------------------------------

List<Json> presenceByManufacturer(ShelfSummary summary, Map<String, Json> products, Map<String, Json> manufacturers) {
  final facings = <String, int>{}, skus = <String, Set<String>>{}, categories = <String, Set<String>>{};
  final accounted = <String, int>{};
  summary.facingsByProduct.forEach((productId, count) {
    final product = products[productId];
    if (product == null) return;
    final m = product['manufacturer_id'] as String;
    accounted[m] = (accounted[m] ?? 0) + count;
    facings[m] = (facings[m] ?? 0) + count;
    skus.putIfAbsent(m, () => {}).add(productId);
    categories.putIfAbsent(m, () => {}).add(product['category_id'] as String);
  });
  summary.facingsByManufacturer.forEach((m, count) {
    final remaining = count - (accounted[m] ?? 0);
    if (remaining > 0) facings[m] = (facings[m] ?? 0) + remaining;
  });
  final totalFacings = facings.values.fold<int>(0, (a, b) => a + b);
  final totalSkus = skus.values.fold<int>(0, (a, b) => a + b.length);
  final result = [
    for (final m in {...facings.keys, ...skus.keys})
      {
        'manufacturer_id': m,
        'name': manufacturers[m]?['name'] ?? m,
        'is_own': manufacturers[m]?['is_own'] ?? false,
        'facings': facings[m] ?? 0,
        'share_of_shelf': totalFacings == 0 ? null : round4((facings[m] ?? 0) / totalFacings),
        'skus': skus[m]?.length ?? 0,
        'share_of_assortment': totalSkus == 0 ? null : round4((skus[m]?.length ?? 0) / totalSkus),
        'categories': (categories[m]?.toList() ?? <String>[])..sort(),
      },
  ]..sort((a, b) => (b['facings'] as int).compareTo(a['facings'] as int));
  return result;
}

double? ownShareTarget(List<Json> rules, String channelPath) {
  double? best;
  for (final r in rules) {
    final share = (r['min_share_of_shelf'] as num?)?.toDouble();
    final path = r['channel_path'] as String?;
    if (share == null || r['product_id'] != null || r['brand_id'] != null) continue;
    if (path != null && path.isNotEmpty && !channelPath.startsWith(path)) continue;
    best = best == null ? share : math.max(best, share);
  }
  return best;
}

/// The shelf-based scores; the order-based ones (assortment, opportunity) come from the
/// shop's intelligence as computed from its order history.
List<Json> shelfScores(ShelfSummary? summary, List<Json> core, double? target, double? compliance, int evaluatedRules) {
  Json score(String dimension, double? value, String unit, Json inputs) =>
      {'dimension': dimension, 'value': value, 'unit': unit, 'inputs': inputs};
  final availability = summary == null
      ? score('availability', null, 'pct', {'reason': 'no shelf audit yet'})
      : summary.facingsByProduct.isEmpty
      ? score('availability', null, 'pct', {'reason': 'latest audit has no SKU-level identification', 'basis': summary.basis})
      : core.isEmpty
      ? score('availability', null, 'pct', {'reason': 'no core assortment configured'})
      : () {
          final seen = core.where((c) => (summary.facingsByProduct[c['product_id']] ?? 0) > 0).length;
          return score('availability', (1000 * seen / core.length).round() / 10, 'pct',
              {'core_items': core.length, 'seen_on_shelf': seen, 'basis': summary.basis});
        }();
  Json share;
  if (summary == null || summary.shareOfShelf == null) {
    share = score('share_of_shelf', null, 'pct', {'reason': 'no shelf audit yet'});
  } else {
    final inputs = {'own_facings': summary.ownFacings, 'total_facings': summary.totalFacings,
        'unknown_facings': summary.unknownFacings, 'range': summary.range, 'basis': summary.basis, 'target': target};
    share = target != null && target > 0
        ? score('share_of_shelf', (10 * math.min(100.0, 100 * summary.shareOfShelf! / target)).round() / 10,
            'pct_of_target', inputs)
        : score('share_of_shelf', (1000 * summary.shareOfShelf!).round() / 10, 'pct', inputs);
  }
  final placement = compliance == null
      ? score('placement', null, 'pct', {'reason': 'no evaluable placement rules', 'rules': evaluatedRules})
      : score('placement', compliance, 'pct', {'rules': evaluatedRules});
  final pressure = summary == null || summary.totalFacings == 0
      ? score('competitor_pressure', null, 'pct', {'reason': 'no shelf audit yet'})
      : score('competitor_pressure', (1000 * summary.competitorFacings / summary.totalFacings).round() / 10, 'pct', {
          'competitor_facings': summary.competitorFacings, 'total_facings': summary.totalFacings, 'basis': summary.basis,
        });
  return [availability, share, placement, pressure];
}

/// Recommendation drafts from the shelf (placement rules not met, own share below target).
List<Json> shelfDrafts(String outletId, String visitId, List<Json> placement, ShelfSummary? summary,
    List<Json> presence, double? target, List<String> modelVersions) {
  final drafts = <Json>[];
  for (final result in placement) {
    if (result['status'] != 'non_compliant') continue;
    final observed = result['observed'] as Json, expected = result['expected'] as Json;
    final failures = (observed['failures'] as List).join('; ');
    final unknown = observed['unknown_facings_in_scope'] as int? ?? 0;
    final scope = math.max(1, observed['scope_facings'] as int? ?? 1);
    final short = (observed['facings'] as int? ?? 0) < (expected['min_facings'] as int? ?? 0);
    drafts.add({
      'type': short ? 'increase_facings' : 'fix_placement',
      'action': '${result['description']}: $failures.',
      'reason': 'Channel placement rule not met — $failures.',
      'evidence': {'rule_id': result['rule_id'], 'observed': observed, 'expected': expected,
          'detection_ids': (result['detection_ids'] as List).take(50).toList(), 'visit_id': visitId,
          'model_versions': modelVersions},
      'confidence': (1000 * .85 * (1 - unknown / scope)).round() / 1000,
      'priority': result['priority'], 'source': 'placement.rules',
      'dedupe_key': '$outletId:placement:${result['rule_id']}',
      'product_id': null, 'suggested_quantity': null, 'expected_impact': {'basis': 'compliance'},
    });
  }
  if (summary != null && summary.totalFacings > 0 && target != null) {
    final own = summary.shareOfShelf ?? 0;
    final upper = summary.range?[1] ?? own;
    if (upper < target) {
      Json? leader;
      for (final p in presence) {
        if (p['is_own'] != true && (p['facings'] as int) > 0) {
          leader = p;
          break;
        }
      }
      final leaderText = leader != null && leader['share_of_shelf'] != null
          ? '; largest competitor ${leader['name']} holds ${pct(leader['share_of_shelf'] as num)}'
          : '';
      drafts.add({
        'type': 'competitor_response',
        'action': 'Negotiate more shelf space: own share ${pct(own)} vs target ${pct(target)}$leaderText.',
        'reason': 'Own share of shelf is ${pct(own)} (up to ${pct(upper)} if every unidentified facing were own), '
            'below the ${pct(target)} target.',
        'evidence': {'share_of_shelf': own, 'range': summary.range, 'own_facings': summary.ownFacings,
            'total_facings': summary.totalFacings, 'unknown_facings': summary.unknownFacings, 'basis': summary.basis,
            'competitors': [
              for (final p in presence.where((p) => p['is_own'] != true).take(5))
                {'name': p['name'], 'facings': p['facings'], 'share': p['share_of_shelf']},
            ],
            'visit_id': visitId},
        'confidence': (1000 * (.9 * summary.verifiedRatio + .4 * (1 - summary.verifiedRatio))).round() / 1000,
        'priority': 2, 'source': 'competitor.share_of_shelf',
        'dedupe_key': '$outletId:competitor_response:share_of_shelf',
        'product_id': null, 'suggested_quantity': null,
        'expected_impact': {'share_gap': round4(target - own)},
      });
    }
  }
  return drafts;
}

// --- domain/call_prep.py ---------------------------------------------------------------------

Json buildBrief({
  required Json outlet,
  required Json? classification,
  required List<Json> lastOrders,
  required List<Json> recommendations,
  required List<Json> promotions,
  required List<Json> competitorNotes,
}) {
  final points = <Json>[];
  final recs = [...recommendations]..sort((a, b) {
    final p = (a['priority'] as int).compareTo(b['priority'] as int);
    return p != 0 ? p : (b['confidence'] as num).compareTo(a['confidence'] as num);
  });
  for (final rec in recs.take(3)) {
    points.add({'kind': 'opportunity', 'text': '${rec['action']} ${rec['reason']}',
        'citation': {'recommendation_id': rec['id'], 'source': rec['source']}});
  }
  for (final promo in promotions.take(2)) {
    final names = ((promo['products'] as List?) ?? const []).take(3).join(', ');
    points.add({'kind': 'promotion',
        'text': 'Active offer: ${promo['name']} — ${promo['mechanic']}${names.isEmpty ? '' : ' ($names)'}',
        'citation': {'promotion_id': promo['id'], 'ends_on': promo['ends_on']}});
  }
  for (final note in competitorNotes.take(1)) {
    points.add({'kind': 'competitor', 'text': note['text'], 'citation': {'observation_id': note['id'], 'source': note['source']}});
  }
  if (lastOrders.isNotEmpty) {
    final last = lastOrders.first;
    points.add({'kind': 'relationship',
        'text': 'Last order ${last['order_date']}: ${last['lines']} lines, BDT ${money(last['value'] as num)}.',
        'citation': {'order_id': last['id']}});
  }
  final label = classification?['label'] ?? 'unclassified';
  return {
    'outlet': outlet,
    'headline': '${outlet['name']} · ${outlet['channel']} · $label',
    'last_orders': lastOrders,
    'talking_points': points.take(6).toList(),
    'generator_version': 'call-prep-1.0',
  };
}

/// "12,345" — whole taka with thousands separators, as Python's f"{v:,.0f}".
String money(num value) {
  final digits = value.round().abs().toString();
  final out = StringBuffer(value.round() < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

// --- services/reports.py summary_text ----------------------------------------------------------

String reportSummaryText(Json report) {
  final outlet = report['outlet'] as Json, shelf = report['shelf'] as Json, visit = report['visit'] as Json;
  final lines = ['ShelfSight visit report — ${outlet['name']} (${outlet['code']})'];
  if (report['data_origin'] == 'synthetic') lines.add('SYNTHETIC DEMO DATA — not real sales or market figures');
  var store = (report['store_type'] as Map?)?['name'] as String? ?? 'unknown store type';
  final previous = report['previous_store_type'] as Map?;
  if (previous != null) store += ' (changed from ${previous['name']})';
  final klass = outlet['class'] as Map?;
  lines.add('Store type: $store${klass != null ? ' · Class ${klass['code']} ${klass['label']}' : ''}');
  final officer = (visit['officer'] as Map?)?['name'] ?? 'unknown officer';
  final started = (visit['started_at'] as String);
  final photos = report['photos'] as Json;
  lines.add('Visit: ${started.substring(0, math.min(16, started.length)).replaceFirst('T', ' ')} UTC by $officer · '
      '${photos['analysed']} of ${photos['total']} photos analysed');
  if ((shelf['total_facings'] as int? ?? 0) > 0) {
    final range = shelf['range'] as List?;
    final rangeText = range != null && range[0] != range[1] ? ', could be ${pct(range[0] as num)}–${pct(range[1] as num)}' : '';
    lines.add('Own share of shelf: ${pct(shelf['share_of_shelf'] as num?)} of ${shelf['total_facings']} facings '
        '(${shelf['basis']} basis, ${pct(shelf['verified_ratio'] as num?)} human-verified$rangeText)');
    final competitors = (shelf['by_manufacturer'] as List).cast<Json>().where((m) => m['is_own'] != true).take(4);
    if (competitors.isNotEmpty) {
      lines.add('Competitors: ${competitors.map((m) => '${m['name']} ${pct(m['share'] as num?)}').join(', ')}');
    }
  } else {
    lines.add('No product facings were detected.');
  }
  for (final (status, label) in [('missing', 'Missing on shelf'), ('low', 'Low on shelf')]) {
    final names = [
      for (final a in (report['availability'] as List).cast<Json>())
        if (a['status'] == status) (a['product'] as Map)['name'],
    ];
    if (names.isNotEmpty) lines.add('$label: ${names.join('; ')}');
  }
  final results = ((report['placement'] as Json)['results'] as List).cast<Json>();
  final evaluable = results.where((r) => r['status'] != 'not_evaluable').toList();
  if (evaluable.isNotEmpty) {
    lines.add('Placement: ${evaluable.where((r) => r['status'] == 'compliant').length} of ${evaluable.length} rules met');
  }
  final order = report['order'] as Json?;
  if (order != null) {
    lines.add('Order (${order['source']}, ${order['status']}): ${(order['lines'] as List).length} lines · '
        'BDT ${money(order['value'] as num)}');
    for (final line in (order['lines'] as List).cast<Json>()) {
      final reasons = line['reasons'] as List;
      lines.add('  • ${line['name']} × ${line['quantity']}${reasons.isNotEmpty ? ' — ${reasons.first}' : ''}');
    }
  } else {
    lines.add('Order: none placed in this visit');
  }
  for (final rec in (report['recommendations'] as List).cast<Json>().take(5)) {
    lines.add('Action: ${rec['action']}');
  }
  return lines.join('\n');
}

/// Metres between two points (security.distance_m, haversine).
double distanceM(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1);
  final a = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * r * math.asin(math.sqrt(a));
}
