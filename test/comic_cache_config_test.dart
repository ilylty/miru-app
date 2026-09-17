import 'package:flutter_test/flutter_test.dart';
import 'package:miru_app/models/comic_cache_config.dart';
import 'package:miru_app/utils/comic_cache_config_store.dart';

void main() {
  group('ComicCacheConfig 默认值', () {
    test('默认配置满足「缓存后 n 话 + 话间隔 l + 图间隔 m」', () {
      const config = ComicCacheConfig();
      expect(config.enabled, isTrue);
      expect(config.preloadChapterCount, greaterThan(0));
      expect(config.chapterInterval, greaterThan(0));
      expect(config.imageInterval, greaterThan(0));
      expect(config.maxConcurrent, greaterThan(0));
      expect(config.seamlessChapterSwitch, isTrue);
    });

    test('间隔 Duration 与秒数一致', () {
      const config = ComicCacheConfig(chapterInterval: 5, imageInterval: 2);
      expect(config.chapterIntervalDuration, const Duration(seconds: 5));
      expect(config.imageIntervalDuration, const Duration(seconds: 2));
    });
  });

  group('ComicCacheConfig.fromMap 边界裁剪', () {
    test('n / l / m 全部可配置', () {
      final config = ComicCacheConfig.fromMap({
        'enabled': true,
        'preloadChapterCount': 7,
        'chapterInterval': 11,
        'imageInterval': 4,
        'maxConcurrent': 6,
        'maxDiskSizeMB': 512,
        'cacheOnRead': false,
        'seamlessChapterSwitch': false,
      });
      expect(config.preloadChapterCount, 7);
      expect(config.chapterInterval, 11);
      expect(config.imageInterval, 4);
      expect(config.maxConcurrent, 6);
      expect(config.maxDiskSizeMB, 512);
      expect(config.cacheOnRead, isFalse);
      expect(config.seamlessChapterSwitch, isFalse);
    });

    test('超出范围的 n 被裁剪到 [min, max]', () {
      expect(
        ComicCacheConfig.fromMap({'preloadChapterCount': 999})
            .preloadChapterCount,
        ComicCacheConfig.maxPreloadChapterCount,
      );
      expect(
        ComicCacheConfig.fromMap({'preloadChapterCount': -5})
            .preloadChapterCount,
        ComicCacheConfig.minPreloadChapterCount,
      );
    });

    test('负数间隔被裁剪为 0（不会出现负等待）', () {
      final config = ComicCacheConfig.fromMap({
        'chapterInterval': -10,
        'imageInterval': -3,
      });
      expect(config.chapterInterval, 0);
      expect(config.imageInterval, 0);
    });

    test('过大间隔被裁剪到上限', () {
      final config = ComicCacheConfig.fromMap({
        'chapterInterval': 100000,
        'imageInterval': 100000,
      });
      expect(config.chapterInterval, ComicCacheConfig.maxIntervalSeconds);
      expect(config.imageInterval, ComicCacheConfig.maxIntervalSeconds);
    });

    test('并发数不会小于 1（避免调度器死锁）', () {
      expect(ComicCacheConfig.fromMap({'maxConcurrent': 0}).maxConcurrent, 1);
      expect(
        ComicCacheConfig.fromMap({'maxConcurrent': 999}).maxConcurrent,
        ComicCacheConfig.maxConcurrentLimit,
      );
    });

    test('字符串数字也能解析（兼容旧存储/手改配置）', () {
      final config = ComicCacheConfig.fromMap({
        'preloadChapterCount': '3',
        'chapterInterval': '5',
        'imageInterval': '2',
        'enabled': 'true',
        'cacheOnRead': 'false',
      });
      expect(config.preloadChapterCount, 3);
      expect(config.chapterInterval, 5);
      expect(config.imageInterval, 2);
      expect(config.enabled, isTrue);
      expect(config.cacheOnRead, isFalse);
    });

    test('null / 空 map 回退默认值', () {
      expect(ComicCacheConfig.fromMap(null), const ComicCacheConfig());
      expect(
        ComicCacheConfig.fromMap(const {}),
        const ComicCacheConfig(),
      );
    });
  });

  group('ComicCacheConfigStore 序列化', () {
    test('encode → decode 往返一致', () {
      const config = ComicCacheConfig(
        enabled: false,
        preloadChapterCount: 5,
        chapterInterval: 9,
        imageInterval: 3,
        maxConcurrent: 2,
        maxDiskSizeMB: 128,
        cacheOnRead: false,
        seamlessChapterSwitch: false,
      );
      final encoded = ComicCacheConfigStore.encode(config);
      expect(encoded, isA<String>());
      expect(ComicCacheConfigStore.decode(encoded), config);
    });

    test('损坏的 JSON 回退默认值而不是抛异常', () {
      expect(
        ComicCacheConfigStore.decode('{not json'),
        const ComicCacheConfig(),
      );
      expect(ComicCacheConfigStore.decode(''), const ComicCacheConfig());
      expect(ComicCacheConfigStore.decode(null), const ComicCacheConfig());
      expect(ComicCacheConfigStore.decode(42), const ComicCacheConfig());
    });

    test('可以直接解析 Map（Hive 里存成 map 的旧数据）', () {
      final config = ComicCacheConfigStore.decode({
        'preloadChapterCount': 4,
        'chapterInterval': 6,
        'imageInterval': 1,
      });
      expect(config.preloadChapterCount, 4);
      expect(config.chapterInterval, 6);
      expect(config.imageInterval, 1);
    });

    test('存储 key 与 SettingKey 对齐', () {
      expect(ComicCacheConfigStore.storageKey, 'ComicCacheConfig');
    });

    test('★ 保存配置会发出变更通知（设置页改完立即生效）', () async {
      var notified = 0;
      void listener() => notified++;
      ComicCacheConfigStore.revision.addListener(listener);
      addTearDown(() => ComicCacheConfigStore.revision.removeListener(listener));
      ComicCacheConfigStore.notifyChanged();
      ComicCacheConfigStore.notifyChanged();
      expect(notified, 2);
    });
  });

  group('ComicCacheConfig.copyWith', () {
    test('只改一个字段，其它保持', () {
      const base = ComicCacheConfig(preloadChapterCount: 2);
      final next = base.copyWith(preloadChapterCount: 9);
      expect(next.preloadChapterCount, 9);
      expect(next.chapterInterval, base.chapterInterval);
      expect(next.imageInterval, base.imageInterval);
      expect(next.enabled, base.enabled);
    });
  });
}
