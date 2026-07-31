import 'package:expert_chat/domain/tools/search_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HttpSearchProvider URL policy', () {
    test('rejects local and ambiguous numeric hosts', () {
      const unsafeUrls = [
        'file:///etc/passwd',
        'ftp://example.com/file',
        'http://localhost/admin',
        'http://service.local/admin',
        'http://service.internal/admin',
        'http://example.com./',
        'http://127.0.0.1/',
        'http://127.1/',
        'http://2130706433/',
        'http://0x7f000001/',
        'http://0177.0.0.1/',
        'http://[::1]/',
        'http://[fc00::1]/',
        'http://[fe80::1]/',
        'http://[::ffff:127.0.0.1]/',
      ];

      for (final url in unsafeUrls) {
        expect(HttpSearchProvider.isSafeHttpUrl(url), isFalse, reason: url);
      }
    });

    test('rejects well-known non-web service ports', () {
      const unsafePortUrls = [
        'http://8.8.8.8:22/',
        'https://example.com:21/',
        'http://example.com:23/',
        'https://example.com:25/',
        'http://example.com:53/',
        'http://8.8.8.8:3306/',
        'http://8.8.8.8:6379/',
        'https://example.com:3389/',
      ];

      for (final url in unsafePortUrls) {
        expect(HttpSearchProvider.isSafeHttpUrl(url), isFalse, reason: url);
      }
    });

    test('accepts web and dev ports (conservative blacklist)', () {
      const safePortUrls = [
        'http://8.8.8.8:8080/',
        'https://example.com:8443/',
        'http://example.com:3000/',
        'https://example.com:8000/',
        'http://8.8.8.8/',
        'https://example.com:80/',
      ];

      for (final url in safePortUrls) {
        expect(HttpSearchProvider.isSafeHttpUrl(url), isTrue, reason: url);
      }
    });

    test('accepts canonical public hosts and addresses', () {
      const safeUrls = [
        'https://example.com/article',
        'http://8.8.8.8/',
        'https://[2001:4860:4860::8888]/',
      ];

      for (final url in safeUrls) {
        expect(HttpSearchProvider.isSafeHttpUrl(url), isTrue, reason: url);
      }
    });
  });

  group('HttpSearchProvider DNS policy', () {
    test('accepts a hostname only when every answer is public', () async {
      final resolvedHosts = <String>[];
      final provider = HttpSearchProvider(
        backend: SearchBackend.duckduckgo,
        apiKey: '',
        hostResolver: (host) async {
          resolvedHosts.add(host);
          return ['93.184.216.34', '2001:4860:4860::8888'];
        },
      );

      expect(
        await provider.isSafeFetchUrl('https://example.com/article'),
        isTrue,
      );
      expect(resolvedHosts, ['example.com']);
    });

    test(
      'rejects private, loopback, link-local, and multicast answers',
      () async {
        const unsafeAddresses = [
          '127.0.0.1',
          '10.0.0.1',
          '172.16.0.1',
          '192.168.0.1',
          '169.254.169.254',
          '224.0.0.1',
          '::1',
          'fc00::1',
          'fe80::1',
          'ff02::1',
          '::ffff:127.0.0.1',
        ];

        for (final address in unsafeAddresses) {
          final provider = HttpSearchProvider(
            backend: SearchBackend.duckduckgo,
            apiKey: '',
            hostResolver: (_) async => [address],
          );
          expect(
            await provider.isSafeFetchUrl('https://search-result.example/page'),
            isFalse,
            reason: address,
          );
        }
      },
    );

    test('rejects a mixed public and private DNS response', () async {
      final provider = HttpSearchProvider(
        backend: SearchBackend.duckduckgo,
        apiKey: '',
        hostResolver: (_) async => ['93.184.216.34', '192.168.1.10'],
      );

      expect(
        await provider.isSafeFetchUrl('https://search-result.example/page'),
        isFalse,
      );
    });

    test('rejects empty or malformed DNS responses', () async {
      final emptyProvider = HttpSearchProvider(
        backend: SearchBackend.duckduckgo,
        apiKey: '',
        hostResolver: (_) async => const [],
      );
      final malformedProvider = HttpSearchProvider(
        backend: SearchBackend.duckduckgo,
        apiKey: '',
        hostResolver: (_) async => ['not-an-address'],
      );

      expect(
        await emptyProvider.isSafeFetchUrl('https://example.com'),
        isFalse,
      );
      expect(
        await malformedProvider.isSafeFetchUrl('https://example.com'),
        isFalse,
      );
    });

    test('does not resolve a rejected URL', () async {
      var resolverCalled = false;
      final provider = HttpSearchProvider(
        backend: SearchBackend.duckduckgo,
        apiKey: '',
        hostResolver: (_) async {
          resolverCalled = true;
          return ['93.184.216.34'];
        },
      );

      expect(await provider.isSafeFetchUrl('http://127.1/admin'), isFalse);
      expect(resolverCalled, isFalse);
    });
  });
}
