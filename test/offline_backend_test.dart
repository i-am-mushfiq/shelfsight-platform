import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/offline/offline_backend.dart';
import 'package:shelfsight/services/platform_api.dart';

typedef Json = Map<String, dynamic>;

/// The app with no server: every call answered by [OfflineBackend] from the bundled demo
/// snapshot. Where the snapshot holds the demo server's own answer (shops, intelligence,
/// briefs, suggested orders, dashboards), the phone must give the same one. Recognition is
/// replaced by a fixed answer here (the models need the device); test/on_device_test.dart
/// covers the recogniser.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = PlatformApi.instance;
  final snapshot = jsonDecode(File('assets/demo/snapshot.json').readAsStringSync()) as Json;
  final products = (snapshot['products'] as Json).cast<String, Json>();
  late Directory dir;
  late OfflineBackend backend;
  var recognised = 0;

  // A shop with a must-stock product the shelf can be checked for.
  final officer = (snapshot['users'] as Json)['SO-1001'] as Json;
  final shops = (officer['outlet_ids'] as List).cast<String>();
  final core = (snapshot['core'] as List).cast<Json>();
  final shopId = shops.firstWhere((id) => core.any((c) => c['channel_id'] == (snapshot['outlets'] as Json)[id]['channel_id']));
  final shop = (snapshot['outlets'] as Json)[shopId] as Json;
  final mustStock = products[core.firstWhere((c) => c['channel_id'] == shop['channel_id'])['product_id']]!;
  final competitor = products.values.firstWhere((p) => p['is_own'] != true && p['category_id'] == mustStock['category_id'],
      orElse: () => products.values.firstWhere((p) => p['is_own'] != true));
  final ownFood = products.values.firstWhere((p) => (p['sku'] as String).startsWith('SFBL-'));

  Future<Json> recognize(Uint8List bytes, {bool screenPhoto = false, int? maxPacks, Set<String>? allowedSkus}) async {
    recognised++;
    Json look(String? sku, double x, double y, double confidence) => {
      'product_id': sku, 'confidence': confidence, 'method': 'visual',
      'box': {'x': x, 'y': y, 'width': .12, 'height': .3}, 'evidence': {'similarity': .8},
    };
    return {
      'detections': [
        look(mustStock['sku'] as String, .05, .1, .91),
        look(ownFood['sku'] as String, .2, .1, .7),
        look(competitor['sku'] as String, .05, .55, .88),
        look(competitor['sku'] as String, .2, .55, .86),
        look(null, .35, .55, .6),
      ],
    };
  }

  OfflineBackend make() => OfflineBackend(
    snapshot: () async => snapshot,
    recognize: recognize,
    storage: () async => dir,
    inspect: (bytes) async => {'width': 1600, 'height': 1200, 'blur_score': 120.0, 'brightness': 120.0,
        'acceptable': true, 'warnings': <String>[]},
    compose: (frames) async => Panorama(Uint8List.fromList([137, 80, 78, 71]), 'image/png',
        [for (var i = 0; i < frames.length; i++) (i / frames.length, 1 / frames.length)], 1600 * frames.length, 1200),
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('shelfsight-offline-');
    backend = make();
    api.httpClient = backend;
    PlatformApi.baseUrl = PlatformApi.offlineBaseUrl;
  });

  tearDown(() async {
    await backend.idle();
    api.signOut();
    await dir.delete(recursive: true);
  });

  Future<String> photo(String name, [int seed = 1]) async {
    final file = File('${dir.path}/$name.jpg');
    await file.writeAsBytes(List<int>.generate(2048, (i) => (i * seed) % 251));
    return file.path;
  }

  test('signs in with the demo accounts and lists the officer\'s shops as the server did', () async {
    await expectLater(api.login('SO-1001', 'wrong'), throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)));
    final user = await api.login('so-1001', 'shelf123');
    expect(user.name, officer['user']['name']);
    final outlets = await api.outlets();
    expect(outlets.map((o) => o['id']).toSet(), shops.toSet());
    for (final o in outlets) {
      expectSame(o, (snapshot['outlets'] as Json)[o['id']]['summary'], 'outlet ${o['name']}');
    }
  });

  test('shop intelligence, pre-call brief and suggested order are the server\'s', () async {
    await api.login('SO-1001', 'shelf123');
    for (final id in shops.take(12)) {
      final record = (snapshot['outlets'] as Json)[id] as Json;
      final intel = await api.refreshIntelligence(id);
      expectSame(intel['recommendations'], record['intelligence']['recommendations'], 'recommendations $id',
          ignore: {'dedupe_key', 'product_id', 'updated_at', 'visit_id', 'as_of'});
      expectSame(intel['scores'], record['intelligence']['scores'], 'scores $id');
      expectSame(intel['portfolio'], record['intelligence']['portfolio'], 'portfolio $id');
      expectSame(await api.callBrief(id), record['call_brief'], 'brief $id');
      expectSame(await api.suggestedOrder(id), record['suggested_order'], 'suggested order $id');
    }
  });

  test('supervisor dashboards are the server\'s before any visit', () async {
    final entry = (snapshot['users'] as Json)['TO-2001'] as Json;
    await api.login('TO-2001', 'shelf123');
    for (final group in ['territory', 'outlet', 'officer', 'channel']) {
      expectSame(await api.overview(groupBy: group), entry['analytics']['overview:$group'], 'overview by $group');
    }
    expectSame(await api.competition(), entry['analytics']['competition:channel'], 'competition');
  });

  test('a whole visit runs on the phone: photos, sphere, review, report, automatic order', () async {
    final user = await api.login('SO-1001', 'shelf123');
    final recognisedBefore = recognised;
    final storeTypes = await api.storeTypes();
    final otherType = storeTypes.firstWhere((s) => s['id'] != shop['channel_id']);
    // Starting the visit as another store type changes the shop's type.
    var visit = await api.startVisit(clientVisitId: 'visit-0001', outletId: shopId, storeTypeId: otherType['id'] as String);
    expect(visit['store_type']['id'], otherType['id']);
    expect(visit['previous_store_type']['id'], shop['channel_id']);
    expect((await api.outlet(shopId))['channel_id'], otherType['id']);
    // Same client id: the same visit.
    expect((await api.startVisit(clientVisitId: 'visit-0001', outletId: shopId))['id'], visit['id']);
    // Back to the shop's own type, so its must-stock list applies.
    visit = await api.startVisit(clientVisitId: 'visit-0002', outletId: shopId, storeTypeId: shop['channel_id'] as String);
    final visitId = visit['id'] as String;

    final path = await photo('shelf');
    final first = await api.uploadCapture(
      visitId: visitId, filePath: path, clientCaptureId: 'capture-0001', categoryId: mustStock['category_id'] as String);
    expect(first['status'], 'uploaded');
    final again = await api.uploadCapture(visitId: visitId, filePath: path, clientCaptureId: 'capture-0002');
    expect(again['status'], 'duplicate');
    expect(again['duplicate_of'], first['id']);
    final sphere = await api.uploadSphere(
      visitId: visitId, framePaths: [await photo('f1', 3), await photo('f2', 5)], yaws: [90, 10],
      clientCaptureId: 'sphere-0001');
    expect(sphere['kind'], 'sphere');
    expect(sphere['sphere']['frames'], 2);
    await backend.idle();
    // The photo once (not its duplicate), and each sphere frame on its own.
    expect(recognised - recognisedBefore, 3);

    final capture = await api.capture(first['id'] as String);
    expect(capture['status'], 'analysed');
    final detections = (capture['detections'] as List).cast<Json>();
    expect(detections, hasLength(5));
    expect(detections.map((d) => d['shelf_row']).toSet(), {1, 2});
    expect(detections.first['final']['label'], 'own');
    expect(detections.first['final']['product_id'], mustStock['id']);
    expect(detections[2]['final']['label'], 'competitor');
    expect(detections[4]['final']['product_id'], isNull);
    expect(detections.where((d) => d['needs_review'] == true), hasLength(2)); // below 0.75
    expect(capture['inference']['model']['provider'], 'on-device');
    expect(await api.imageBytes('/v2/captures/${first['id']}/image'), hasLength(2048));

    final panorama = await api.capture(sphere['id'] as String);
    expect(panorama['status'], 'analysed');
    final boxes = (panorama['detections'] as List).cast<Json>().map((d) => d['box'] as Json).toList();
    expect(boxes, hasLength(10));
    // The frame turned to 10° comes first; its boxes are in the left half.
    expect(boxes.take(5).every((b) => (b['x'] as num) < .5), isTrue);
    expect(boxes.skip(5).every((b) => (b['x'] as num) >= .5), isTrue);

    // Review: reject one box, name the unknown one, confirm the rest of the photo.
    await api.reviewDetection(detections[1]['id'] as String, 'reject');
    final corrected = await api.reviewDetection(detections[4]['id'] as String, 'correct', productId: mustStock['id'] as String);
    expect(corrected['verification'], 'corrected');
    expect(corrected['final']['label'], 'own');
    for (final d in [detections[0], detections[2], detections[3]]) {
      expect((await api.reviewDetection(d['id'] as String, 'confirm'))['verification'], 'confirmed');
    }

    final result = await api.submitVisit(visitId);
    final report = result['report'] as Json;
    expect(result['visit']['status'], 'submitted');
    expect(report['photos']['total'], 3);
    expect(report['photos']['duplicates'], 1);
    expect(report['photos']['analysed'], 2);
    final shelf = report['shelf'] as Json;
    // First photo: 4 boxes left after the rejection; the sphere: 10.
    expect(shelf['all']['total_facings'], 14);
    expect((shelf['by_manufacturer'] as List), isNotEmpty);
    expect((shelf['by_product'] as List).first['is_own'], isTrue);
    final available = (report['availability'] as List).cast<Json>().firstWhere((a) => a['product_id'] == mustStock['id']);
    expect(available['status'], isNot('not_checked'));
    expect(available['facings'], greaterThan(0));
    expect(report['summary_text'], contains('Own share of shelf'));
    expect(report['visit']['officer']['name'], user.name);
    // The shelf feeds the shop's intelligence.
    expect(result['intelligence']['latest_visit']['id'], visitId);
    expect(result['intelligence']['shelf']['all']['total_facings'], 14);

    final order = result['order'] as Json?;
    expect(order, isNotNull, reason: 'usual order sizes and shelf gaps make an automatic order');
    if (order != null) {
      expect((order['lines'] as List).cast<Json>().any((l) => (l['reasons'] as List).isNotEmpty), isTrue);
      expect(order['source'], 'auto');
      expect(order['status'], 'confirmed');
      final lines = (order['lines'] as List).cast<Json>();
      final changed = await api.updateOrder(order['id'] as String, [
        for (final l in lines) {'product_id': l['product_id'], 'quantity': (l['quantity'] as int) + 1},
      ]);
      expect(changed['meta']['edited'], isTrue);
      expect((changed['lines'] as List).first['suggested_quantity'], lines.first['suggested_quantity']);
      final cancelled = await api.cancelOrder(order['id'] as String, 'Shop closed');
      expect(cancelled['status'], 'cancelled');
    }
    // Submitting again changes nothing; the report can be fetched later.
    await api.submitVisit(visitId);
    final later = await api.visitReport(visitId);
    expect(later['shelf']['all'], shelf['all']);
    await expectLater(
      api.uploadCapture(visitId: visitId, filePath: await photo('late', 7), clientCaptureId: 'capture-0009'),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 409)),
    );

    final visits = await api.visits();
    final listed = visits.firstWhere((v) => v['id'] == visitId);
    expect(listed['photos'], 3);
    expect(listed['share_of_shelf']['all']['facings'], 14);
    expect((await api.visit(visitId))['captures'], hasLength(3));

    // Kept on the phone: a restart finds the visit.
    final restarted = make();
    api.httpClient = restarted;
    expect((await api.visits()).map((v) => v['id']), contains(visitId));

    // The supervisor's dashboard now counts the audit.
    await api.login('TO-2001', 'shelf123');
    final groups = ((await api.overview(groupBy: 'outlet'))['groups'] as List).cast<Json>();
    final row = groups.firstWhere((g) => g['id'] == shopId);
    expect(row['audited'], 1);
    expect(row['visited_30d'], 1);
    final competition = await api.competition();
    expect(competition['outlets_audited'], 1);
  });

  test('a manual order, recommendation decisions and the brief follow each other', () async {
    await api.login('SO-1001', 'shelf123');
    final intel = await api.refreshIntelligence(shopId);
    final recs = (intel['recommendations'] as List).cast<Json>();
    expect(recs, isNotEmpty);
    final rec = recs.first;
    await api.recommendationFeedback(rec['id'] as String, 'accepted');
    final again = await api.refreshIntelligence(shopId);
    final kept = (again['recommendations'] as List).cast<Json>().where((r) => r['id'] == rec['id']).single;
    expect(kept['status'], 'accepted');
    expect((again['recommendations'] as List).where((r) => r['dedupe_key'] == rec['dedupe_key']), hasLength(1));
    final summary = await api.outlet(shopId);
    expect(summary['open_recommendations'], recs.length - 1);

    final priced = products.values.firstWhere((p) => p['is_own'] == true && p['trade_price'] != null);
    final created = await api.createOrder(shopId, 'order-0001', [
      {'product_id': priced['id'], 'quantity': 6},
    ]);
    expect(created['status'], 'confirmed');
    final order = await api.order(created['id'] as String);
    expect(order['value'], closeTo((priced['trade_price'] as num) * 6, .01));
    expect(order['editable'], isTrue);
    expect((await api.createOrder(shopId, 'order-0001', [{'product_id': priced['id'], 'quantity': 6}]))['replayed'], isTrue);
    final brief = await api.callBrief(shopId);
    expect((brief['last_orders'] as List).first['id'], created['id']);
    await expectLater(
      api.createOrder(shopId, 'order-0002', [{'product_id': competitor['id'], 'quantity': 1}]),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 422)),
    );
  });

  test('a shop registered on the phone works like any other', () async {
    await api.login('SO-1001', 'shelf123');
    final storeType = (await api.storeTypes()).first;
    final shopRecord = await api.registerOutlet(
      clientOutletId: 'new-shop-0001', name: 'Notun Store', storeTypeId: storeType['id'] as String,
      lat: (shop['lat'] as num).toDouble(), lng: (shop['lng'] as num).toDouble());
    expect(shopRecord['is_verified'], isFalse);
    expect(shopRecord['code'], 'F-NEW-SHOP-0');
    expect((shopRecord['possible_duplicates'] as List).first['id'], shopId);
    final id = shopRecord['id'] as String;
    expect((await api.outlets()).map((o) => o['id']), contains(id));
    final intel = await api.refreshIntelligence(id);
    expect(intel['outlet']['name'], 'Notun Store');
    expect((intel['recommendations'] as List).every((r) => (r['dedupe_key'] as String).startsWith(id)), isTrue);
    expect((await api.callBrief(id))['headline'], startsWith('Notun Store'));
    final visit = await api.startVisit(clientVisitId: 'visit-new-0001', outletId: id);
    expect(visit['store_type']['id'], storeType['id']);
    // Another officer does not see it.
    await api.login('SO-1042', 'shelf123');
    expect((await api.outlets()).map((o) => o['id']), isNot(contains(id)));
  });

  testWidgets('real photos: quality check and a sphere panorama made on the phone', (tester) async {
    await tester.runAsync(() async {
      // The phone's own image checks and side-by-side panorama; only recognition is fixed.
      backend = OfflineBackend(snapshot: () async => snapshot, recognize: recognize, storage: () async => dir);
      api.httpClient = backend;
      await api.login('SO-1001', 'shelf123');
      final visit = await api.startVisit(clientVisitId: 'visit-real-0001', outletId: shopId);
      final upload = await api.uploadCapture(
        visitId: visit['id'] as String, filePath: 'test/fixtures/screen_shelf.jpg', clientCaptureId: 'capture-real-01');
      // As the server measures it on this photo: 1600 x 1145, sharp (708), brightness 79.
      expect(upload['width'], 1600);
      expect(upload['height'], 1145);
      expect(upload['quality']['brightness'], closeTo(79.04, .5));
      expect(upload['quality']['blur_score'], greaterThan(400));
      expect(upload['quality_acceptable'], isTrue);
      final sphere = await api.uploadSphere(
        visitId: visit['id'] as String,
        framePaths: ['test/fixtures/screen_shelf.jpg', 'test/fixtures/screen_shelf.jpg', 'test/fixtures/screen_shelf.jpg'],
        yaws: [0, 45, 90], clientCaptureId: 'sphere-real-01');
      // Three landscape frames at 800 px wide, side by side.
      expect(sphere['width'], 2400);
      expect(sphere['height'], 573);
      expect(sphere['sphere']['horizontal_degrees'], 150);
      final png = await api.imageBytes('/v2/captures/${sphere['id']}/image');
      final decoded = (await (await ui.instantiateImageCodec(png)).getNextFrame()).image;
      expect([decoded.width, decoded.height], [2400, 573]);
      await backend.idle();
      expect((await api.capture(sphere['id'] as String))['status'], 'analysed');
    });
  });
}

/// Same JSON, numbers equal to 1e-6 (the server rounds in Python, the phone in Dart).
void expectSame(Object? actual, Object? expected, String where, {Set<String> ignore = const {}}) {
  final problems = <String>[];
  void walk(Object? a, Object? e, String path) {
    if (problems.length > 10) return;
    if (a is num && e is num) {
      if ((a - e).abs() > 1e-6 * (1 + e.abs())) problems.add('$path: $a != $e');
    } else if (a is Map && e is Map) {
      for (final key in {...a.keys, ...e.keys}) {
        if (ignore.contains(key) || key == 'data_origin' && a[key] != null) continue;
        if (!a.containsKey(key) || !e.containsKey(key)) {
          problems.add('$path.$key: ${a.containsKey(key) ? 'only on the phone' : 'missing on the phone'}');
          continue;
        }
        walk(a[key], e[key], '$path.$key');
      }
    } else if (a is List && e is List) {
      if (a.length != e.length) {
        problems.add('$path: ${a.length} items != ${e.length}');
        return;
      }
      for (var i = 0; i < a.length; i++) {
        walk(a[i], e[i], '$path[$i]');
      }
    } else if (a != e) {
      problems.add('$path: $a != $e');
    }
  }

  walk(actual, expected, where);
  expect(problems, isEmpty, reason: where);
}
