import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelfsight/main.dart';
import 'package:shelfsight/screens/visit_report_screen.dart';
import 'package:shelfsight/services/platform_api.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

const _outlet = {
  'id': 'o1', 'code': 'S-101', 'name': 'Shwapno Banani', 'name_bn': null,
  'address': 'Road 11, Banani', 'lat': 23.79385, 'lng': 90.40672,
  'channel': 'Super Shop', 'channel_code': 'MT-SS', 'channel_id': 'st-ss', 'channel_icon': 'supershop',
  'territory': 'Banani–Gulshan', 'class_code': 'B', 'class_label': 'Core', 'last_visit_at': null,
  'open_recommendations': 1, 'is_verified': true, 'data_origin': 'synthetic',
};

Map<String, dynamic> _storeType(String id, String code, String name, String icon) => {
  'id': id, 'code': code, 'name': name, 'name_bn': 'বাংলা', 'icon': icon,
  'description': 'Synthetic description for $name', 'is_store_type': true,
};

final _storeTypes = [
  _storeType('st-groc', 'GT-GROC', 'Grocery (Mudi)', 'grocery'),
  _storeType('st-cos', 'GT-COS', 'Cosmetics & Toiletries', 'cosmetics'),
  _storeType('st-dept', 'GT-DEPT', 'Departmental Store', 'departmental'),
  _storeType('st-ss', 'MT-SS', 'Super Shop', 'supershop'),
  _storeType('st-ph', 'PH', 'Pharmacy', 'pharmacy'),
  _storeType('st-ws', 'WS', 'Wholesale (Paikari)', 'wholesale'),
];

Map<String, dynamic> visitReport({String orderStatus = 'confirmed'}) => {
  'data_origin': 'synthetic',
  'visit': {
    'id': 'v1', 'status': 'submitted', 'started_at': '2026-10-10T08:30:00+00:00',
    'officer': {'id': 'u1', 'name': 'Rahim Ahmed', 'employee_id': 'SO-1001'},
  },
  'outlet': {'id': 'o1', 'code': 'S-101', 'name': 'Shwapno Banani', 'is_verified': true,
             'class': {'code': 'B', 'label': 'Core'}},
  'store_type': {'id': 'st-cos', 'code': 'GT-COS', 'name': 'Cosmetics & Toiletries', 'icon': 'cosmetics'},
  'previous_store_type': {'id': 'st-groc', 'code': 'GT-GROC', 'name': 'Grocery (Mudi)', 'icon': 'grocery'},
  'photos': {'total': 2, 'analysed': 2, 'models': [{'provider': 'claude-shelf', 'version': 'claude-opus-5-5/medium'}]},
  'shelf': {
    'basis': 'all', 'share_of_shelf': 0.1429, 'range': [0.1429, 0.2857], 'total_facings': 7, 'own_facings': 1,
    'competitor_facings': 5, 'unknown_facings': 1, 'verified_ratio': 0.0,
    'by_manufacturer': [
      {'id': 'm2', 'name': 'Unilever Bangladesh', 'is_own': false, 'facings': 5, 'share': 0.7143},
      {'id': 'm1', 'name': 'Square Toiletries', 'is_own': true, 'facings': 1, 'share': 0.1429},
    ],
    'by_brand': [],
    'by_product': [
      {'id': 'p1', 'sku': 'SQ-MER-SOAP-100', 'name': 'Meril Milk & Rose Soap 100g', 'is_own': true, 'facings': 1},
      {'id': 'p2', 'sku': 'UNI-LUX-100', 'name': 'Lux Soft Touch Soap 100g', 'is_own': false, 'facings': 3},
    ],
    'by_category': [
      {'id': 'c1', 'name': 'Bar Soap', 'own': 1, 'competitor': 3, 'unknown': 0, 'total': 4, 'own_share': 0.25},
    ],
  },
  'availability': [
    {'product_id': 'p3', 'status': 'missing', 'facings': 0, 'min_facings': 2, 'priority': 2, 'unidentified_nearby': 0,
     'product': {'id': 'p3', 'sku': 'SQ-MER-SHMP-180', 'name': 'Meril Herbal Shampoo 180ml'}},
    {'product_id': 'p1', 'status': 'low', 'facings': 1, 'min_facings': 2, 'priority': 1, 'unidentified_nearby': 1,
     'product': {'id': 'p1', 'sku': 'SQ-MER-SOAP-100', 'name': 'Meril Milk & Rose Soap 100g'}},
  ],
  'placement': {'score': null, 'results': []},
  'recommendations': [],
  'order': {
    'id': 'ord1', 'source': 'auto', 'status': orderStatus, 'value': 748.0, 'editable': orderStatus != 'cancelled',
    'meta': orderStatus == 'cancelled' ? {'cancel_reason': 'Owner will order next week'} : {},
    'lines': [
      {'product_id': 'p3', 'name': 'Meril Herbal Shampoo 180ml', 'quantity': 4, 'unit_price': 167.2,
       'suggested_quantity': 4, 'reasons': ['Missing on shelf: 0 of 2 facings, restock 4']},
    ],
  },
  'warnings': [],
  'summary_text': 'ShelfSight visit report — Shwapno Banani (S-101)',
};

/// Requests the fake platform received, newest last.
final recorded = <http.Request>[];

const _intelligence = {
  'data_origin': 'synthetic',
  'classification': {
    'code': 'B', 'label': 'Core', 'source': 'rule', 'confidence': 1.0,
    'evidence': {'reasons': ['Sales percentile 0.5 >= 0.45']},
  },
  'scores': [
    {'dimension': 'assortment', 'value': 80.0, 'unit': 'pct', 'inputs': {}},
    {'dimension': 'share_of_shelf', 'value': null, 'unit': 'pct', 'inputs': {'reason': 'no shelf audit yet'}},
  ],
  'recommendations': [
    {
      'id': 'r1', 'type': 'add_sku', 'status': 'open', 'priority': 1, 'confidence': 0.72,
      'action': 'Introduce Meril Milk & Kiwi Soap 150g (SQ-MER-SOAP-150).',
      'reason': 'Outlet has 0 units, but 89% of 27 comparable outlets bought it.',
      'evidence': {'peer_penetration': 0.89, 'peer_buyers': 24, 'peer_group': {'basis': 'same channel and outlet class', 'size': 27}},
      'expected_impact': {'monthly_value_bdt': 971.0},
      'source': 'portfolio.peer_benchmark', 'generator_version': 'recommendations-1.0',
    },
  ],
  'portfolio': {
    'current_mix': {'brand': [{'key': 'b1', 'label': 'Meril', 'value_share': 0.6}]},
    'target_mix': {'brand': [{'key': 'b1', 'target_share': 0.34}]},
    'peer_benchmark': {'brand': [{'key': 'b1', 'value_share': 0.4}]},
    'totals': {'monthly_value': 6131.0, 'distinct_skus': 8},
    'window': {'days': 90},
  },
  'shelf': null,
  'competition': {'presence': [], 'price_positioning': []},
};

const _overview = {
  'data_origin': 'synthetic',
  'groups': [
    {
      'id': 't1', 'label': 'Banani–Gulshan', 'outlets': 34, 'monthly_value_bdt': 250000.0,
      'visited_30d': 5, 'own_facings': 20.0, 'total_facings': 50.0, 'open_recommendations': 40,
      'opportunity_bdt_per_month': 30000.0, 'share_of_shelf': 0.4, 'coverage_30d': 0.147,
    },
  ],
};

const _competition = {
  'data_origin': 'synthetic', 'outlets_audited': 5, 'outlets_in_scope': 34,
  'groups': [
    {
      'id': 'c1', 'label': 'Super Shop', 'total_facings': 50.0,
      'manufacturers': [
        {'id': 'm1', 'name': 'Square Toiletries', 'is_own': true, 'facings': 20.0},
        {'id': 'm2', 'name': 'Unilever Bangladesh', 'is_own': false, 'facings': 25.0},
      ],
    },
  ],
};

/// Fake platform: the app's real API client runs against these canned responses.
MockClient fakePlatform() => MockClient((request) async {
  recorded.add(request);
  final path = request.url.path;
  if (path == '/v2/auth/login') {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (body['password'] != 'shelf123') {
      return _json({'detail': 'Employee ID or password is incorrect'}, 401);
    }
    final id = body['employee_id'] as String;
    return _json({
      'access_token': 'test-token',
      'user': {
        'id': 'u1', 'employee_id': id, 'name': id.startsWith('TO') ? 'Nusrat Jahan' : 'Rahim Ahmed',
        'role': id.startsWith('TO') ? 'supervisor' : 'sales_officer',
        'territory': 'Banani–Gulshan', 'data_origin': 'synthetic',
      },
    });
  }
  if (request.headers['Authorization'] != 'Bearer test-token') return _json({'detail': 'Missing bearer token'}, 401);
  if (path == '/v2/outlets' && request.method == 'POST') {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final type = _storeTypes.firstWhere((t) => t['id'] == body['store_type_id']);
    return _json({
      ..._outlet, 'id': 'o-new', 'code': 'F-1A2B3C4D5E', 'name': body['name'], 'channel': type['name'],
      'channel_code': type['code'], 'channel_id': type['id'], 'is_verified': false, 'possible_duplicates': [],
      'replayed': false,
    }, 201);
  }
  if (path == '/v2/outlets') return _json([_outlet]);
  if (path == '/v2/catalog/store-types') return _json(_storeTypes);
  if (path == '/v2/visits' && request.method == 'POST') {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final type = _storeTypes.firstWhere((t) => t['id'] == body['store_type_id']);
    return _json({'id': 'v1', 'status': 'open', 'outlet_id': body['outlet_id'], 'store_type': type}, 201);
  }
  if (path == '/v2/visits/v1/report') {
    final cancelled = recorded.any((r) => r.url.path == '/v2/orders/ord1/cancel');
    return _json(visitReport(orderStatus: cancelled ? 'cancelled' : 'confirmed'));
  }
  if (path == '/v2/orders/ord1/cancel') return _json(visitReport(orderStatus: 'cancelled')['order'] as Object);
  if (path.endsWith('/intelligence:refresh')) return _json(_intelligence);
  if (path == '/v2/analytics/overview') return _json(_overview);
  if (path == '/v2/analytics/competition') return _json(_competition);
  if (path == '/v2/visits') return _json([]);
  return _json({'detail': 'Not found'}, 404);
});

Future<void> signIn(WidgetTester tester, String id) async {
  PlatformApi.instance.httpClient = fakePlatform();
  await tester.pumpWidget(const ShelfSightApp());
  await tester.pump(const Duration(milliseconds: 2300));
  await tester.pump(const Duration(milliseconds: 600));
  await tester.enterText(find.byType(EditableText).at(0), id);
  await tester.enterText(find.byType(EditableText).at(1), 'shelf123');
  await tester.tap(find.text('Sign in').last);
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pump(const Duration(milliseconds: 600));
  expect(find.text('Find your current shop'), findsOneWidget);
  await tester.tap(find.text('Not now'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  fieldFlowTests();

  testWidgets('splash opens login and shows the server rejection', (tester) async {
    PlatformApi.instance.httpClient = fakePlatform();
    await tester.pumpWidget(const ShelfSightApp());
    expect(find.text('Retail visibility, measured'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2300));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Welcome back'), findsOneWidget);

    await tester.enterText(find.byType(EditableText).at(0), 'SO-1042');
    await tester.enterText(find.byType(EditableText).at(1), 'wrong');
    await tester.tap(find.text('Sign in').last);
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Employee ID or password is incorrect'), findsOneWidget);
  });

  testWidgets('sales officer sees outlets from the API and opens outlet intelligence', (tester) async {
    await signIn(tester, 'SO-1001');
    expect(find.text('Visits'), findsOneWidget);
    expect(find.text('Learn'), findsOneWidget);
    expect(find.text('Exceptions'), findsNothing);
    expect(find.textContaining('simulated GPS'), findsOneWidget);
    expect(find.textContaining('Shop detected · GPS'), findsOneWidget);
    expect(find.text('Shwapno Banani'), findsWidgets);

    await tester.ensureVisible(find.text('Open shop'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Open shop'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    // The summary: class, no audit yet, and that the numbers are demo data.
    expect(find.textContaining('Class B · Core'), findsOneWidget);
    expect(find.textContaining('No shelf audit yet'), findsOneWidget);
    expect(find.textContaining('Demo data'), findsOneWidget);
    expect(find.text('Start visit'), findsOneWidget);
    // A recommendation is one row; its detail opens in a sheet.
    await tester.scrollUntilVisible(find.textContaining('Introduce Meril Milk & Kiwi Soap'), 200,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.textContaining('Introduce Meril Milk & Kiwi Soap'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('We are fairly sure about this'), findsOneWidget);
    expect(find.text("I'll do it"), findsOneWidget);
  });

  testWidgets('supervisor dashboard is built from analytics, not constants', (tester) async {
    await signIn(tester, 'TO-2001');
    expect(find.text('Exceptions'), findsWidgets);
    expect(find.text('Team'), findsOneWidget);
    expect(find.text('40%'), findsWidgets); // 20 own of 50 facings
    expect(find.text('5 of 34 outlets audited · 50 facings counted'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Unilever Bangladesh'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Unilever Bangladesh'), findsOneWidget);
  });
}


/// A tall screen so the store-type grid and report fit (the test font is wider than real fonts).
void usePhoneScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void fieldFlowTests() {
  testWidgets('a shelf audit starts by choosing one of the store types', (tester) async {
    usePhoneScreen(tester);
    recorded.clear();
    await signIn(tester, 'SO-1001');
    await tester.ensureVisible(find.text('Open shop'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Open shop'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Super Shop'), findsOneWidget);

    await tester.tap(find.text('Start visit'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('What kind of store is this?'), findsOneWidget);
    for (final type in _storeTypes) {
      expect(find.byKey(Key('store-type-${type['code']}')), findsOneWidget);
    }
    // Pre-selected: what the shop is recorded as.
    await tester.ensureVisible(find.text('Start visit as Super Shop'));
    expect(find.text('Start visit as Super Shop'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('store-type-GT-COS')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('store-type-GT-COS')));
    await tester.pump();
    expect(find.textContaining('recorded as Super Shop'), findsOneWidget);
    await tester.ensureVisible(find.text('Start visit as Cosmetics & Toiletries'));
    await tester.pump();
    await tester.tap(find.text('Start visit as Cosmetics & Toiletries'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    final start = recorded.lastWhere((r) => r.url.path == '/v2/visits' && r.method == 'POST');
    expect((jsonDecode(start.body) as Map)['store_type_id'], 'st-cos');
    expect(find.text('Shelf photos'), findsOneWidget);
    expect(find.text('Shwapno Banani · Cosmetics & Toiletries'), findsOneWidget);
    expect(find.textContaining('Rack: All products'), findsOneWidget);
    expect(find.byKey(const Key('live-scan')), findsOneWidget);
    expect(find.byKey(const Key('photo-sphere')), findsOneWidget);
  });

  testWidgets('the visit report shows the shelf, missing products and the automatic order', (tester) async {
    usePhoneScreen(tester);
    recorded.clear();
    PlatformApi.instance.httpClient = fakePlatform();
    await PlatformApi.instance.login('SO-1001', 'shelf123');
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(MaterialApp(home: VisitReportScreen(visitId: 'v1', report: visitReport())));
    await tester.pump();
    // The result first, in plain words.
    expect(find.text('of this shelf is Square'), findsOneWidget);
    expect(find.textContaining('Demo data'), findsOneWidget);
    expect(find.text('Shop type changed to Cosmetics & Toiletries'), findsOneWidget);
    expect(find.text('14%'), findsOneWidget);
    expect(find.text('Unilever Bangladesh'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Missing'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Few left'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Order placed'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Made from this visit'), findsOneWidget);
    // The report lists product and quantity; the reasons are shown when editing the order.
    expect(find.textContaining('Missing on shelf: 0 of 2 facings'), findsNothing);

    await tester.tap(find.byTooltip('Share'));
    await tester.pump();
    expect(copied, startsWith('ShelfSight visit report'));

    await tester.ensureVisible(find.text('Cancel order'));
    await tester.pump();
    await tester.tap(find.text('Cancel order'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Owner will order next week');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Cancel order'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final cancel = recorded.lastWhere((r) => r.url.path == '/v2/orders/ord1/cancel');
    expect((jsonDecode(cancel.body) as Map)['reason'], 'Owner will order next week');
    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.text('Cancelled: Owner will order next week'), findsOneWidget);
  });

  testWidgets('an officer registers a shop that is not on the list', (tester) async {
    usePhoneScreen(tester);
    recorded.clear();
    await signIn(tester, 'SO-1001');
    await tester.ensureVisible(find.byKey(const Key('register-shop')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('register-shop')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Register a new shop'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('register-name')), 'Notun Pharmacy');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('store-type-PH')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('store-type-PH')));
    await tester.pump();
    await tester.tap(find.text('Register shop'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    final body = jsonDecode(recorded.lastWhere((r) => r.url.path == '/v2/outlets' && r.method == 'POST').body) as Map;
    expect(body['name'], 'Notun Pharmacy');
    expect(body['store_type_id'], 'st-ph');
    expect(body['lat'], isNotNull);
    expect(find.text('Pharmacy'), findsOneWidget);
    expect(find.textContaining('New shop, awaiting verification'), findsOneWidget);
  });
}
