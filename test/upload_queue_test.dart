import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelfsight/services/platform_api.dart';
import 'package:shelfsight/services/upload_queue.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  late Directory temp;
  late File photo;
  final queue = UploadQueue.instance;

  /// Signs the shared API client in against [uploads], which answers capture uploads.
  Future<void> signIn(Future<http.Response> Function(http.BaseRequest request) uploads) async {
    PlatformApi.instance.httpClient = MockClient.streaming((request, body) async {
      await body.drain<void>();
      final response = request.url.path == '/v2/auth/login'
          ? _json({
              'access_token': 't',
              'user': {'id': 'u', 'employee_id': 'SO-1', 'name': 'A', 'role': 'sales_officer'},
            })
          : await uploads(request);
      return http.StreamedResponse(Stream.value(response.bodyBytes), response.statusCode, headers: response.headers);
    });
    await PlatformApi.instance.login('SO-1', 'x');
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('shelfsight-queue');
    photo = File('${temp.path}/shot.jpg')..writeAsBytesSync(List.filled(64, 7));
    queue.resetForTest(Directory('${temp.path}/queue')..createSync());
  });

  tearDown(() async {
    queue.resetForTest(temp);
    PlatformApi.instance.signOut();
    await temp.delete(recursive: true);
  });

  test('photo stays queued while offline and uploads once the connection returns', () async {
    var online = false;
    final seenIds = <String>[];
    await signIn((request) async {
      if (!online) throw const SocketException('no route to host');
      final fields = (request as http.MultipartRequest).fields;
      seenIds.add(fields['client_capture_id']!);
      expect(fields['category_id'], 'cat-1');
      return _json({'id': 'cap-1', 'duplicate_of': null, 'quality': {'warnings': ['Image may be blurry.']}}, 201);
    });

    final item = await queue.enqueue(visitId: 'v1', sourcePath: photo.path, area: 'Soap', categoryId: 'cat-1');
    await queue.drain();
    expect(item.state, UploadState.queued);
    expect(item.attempts, greaterThanOrEqualTo(1));
    expect(queue.pendingCount, 1);
    expect(File(item.filePath).existsSync(), isTrue, reason: 'the photo is copied into app storage');

    // The queue survives an app restart: a fresh load reads it back from disk.
    queue.resetForTest(Directory('${temp.path}/queue'));
    await queue.load();
    expect(queue.forVisit('v1').single.clientCaptureId, item.clientCaptureId);

    online = true;
    await queue.drain();
    final restored = queue.forVisit('v1').single;
    expect(restored.state, UploadState.uploaded);
    expect(restored.captureId, 'cap-1');
    expect(restored.qualityWarnings, ['Image may be blurry.']);
    expect(seenIds.toSet(), {item.clientCaptureId}, reason: 'retries reuse the same id so the server can deduplicate');

    await queue.clearVisit('v1');
    expect(queue.items, isEmpty);
    expect(File(restored.filePath).existsSync(), isFalse);
  });

  test('a photo the server refuses is marked rejected and not retried', () async {
    var calls = 0;
    await signIn((request) async {
      calls++;
      return _json({'detail': 'Unable to decode image'}, 422);
    });
    final item = await queue.enqueue(visitId: 'v2', sourcePath: photo.path);
    await queue.drain();
    await queue.drain();
    expect(item.state, UploadState.rejected);
    expect(item.error, 'Unable to decode image');
    expect(calls, 1);
  });
}
