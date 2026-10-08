import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelfsight/main.dart';
import 'package:shelfsight/services/platform_api.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

const _outlet = {
  'id': 'o1', 'code': 'S-101', 'name': 'Shwapno Banani', 'name_bn': null,
  'address': 'Road 11, Banani', 'lat': 23.79385, 'lng': 90.40672,
  'channel': 'Super Shop', 'channel_code': 'MT-SS', 'territory': 'Banani–Gulshan',
  'class_code': 'B', 'class_label': 'Core', 'last_visit_at': null,
  'open_recommendations': 1, 'data_origin': 'synthetic',
};

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
  if (path == '/v2/outlets') return _json([_outlet]);
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

    await tester.ensureVisible(find.text('Open outlet'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Open outlet'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('SYNTHETIC DEMO DATA'), findsOneWidget);
    expect(find.text('Class B · Core'), findsOneWidget);
    expect(find.textContaining('no shelf audit yet'), findsOneWidget);
    expect(find.text('Start shelf audit'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('Introduce Meril Milk & Kiwi Soap'), 200,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('Confidence 72%'), findsOneWidget);
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
