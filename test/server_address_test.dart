import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/services/platform_api.dart';

void main() {
  test('a bare IP gets http:// and the demo port', () {
    expect(PlatformApi.normalizeServerAddress('192.168.0.103'), 'http://192.168.0.103:8000');
    expect(PlatformApi.normalizeServerAddress(' 192.168.0.103:9000/ '), 'http://192.168.0.103:9000');
  });

  test('a full URL is kept, and empty means the built-in address', () {
    expect(PlatformApi.normalizeServerAddress('https://api.example.com/'), 'https://api.example.com');
    expect(PlatformApi.normalizeServerAddress(''), PlatformApi.defaultBaseUrl);
  });

  test('switching server applies immediately', () async {
    final saved = await PlatformApi.instance.setServerAddress('10.0.0.5');
    expect(saved, 'http://10.0.0.5:8000');
    expect(PlatformApi.baseUrl, 'http://10.0.0.5:8000');
    await PlatformApi.instance.setServerAddress('');
    expect(PlatformApi.baseUrl, PlatformApi.defaultBaseUrl);
  });
}
