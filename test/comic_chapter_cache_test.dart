import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:miru_app/controllers/watch/comic_controller.dart';
import 'package:miru_app/data/services/comic_chapter_cache.dart';
import 'package:miru_app/models/index.dart';
import 'package:miru_app/views/pages/watch/reader/comic/comic_strip_view.dart';

import 'comic_strip_seamless_test.dart'
    show FakeChapterWatcher, buildController, settle;

/// ★ 章节元数据缓存：让「再次进入漫画」直接用本地缓存，不等网络。
///
/// 图片字节缓存（ComicImageCache）只解决「图不用重下」，
/// 但解决不了「该画哪些 URL」——后者原本每次进入都要跑一遍扩展
/// （QuickJS 求值 + 网络请求 + HTML 解析），
/// 这才是「每次进入都要等很久」的真正原因。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => Get.testMode = true);
  tearDown(() => Get.reset());

  /// 用可注入的 store 构造控制器（不依赖 Hive）。
  ComicController controllerWith(
    MemoryComicChapterStore store, {
    FakeChapterWatcher? watcher,
    ComicCacheConfig? config,
    int playIndex = 0,
  }) {
    return buildController(
      watcher: watcher,
      playIndex: playIndex,
      config: config,
      chapterStore: store,
    );
  }

  const noCacheConfig = ComicCacheConfig(
    enabled: false,
    preloadChapterCount: 2,
    chapterInterval: 0,
    imageInterval: 0,
    cacheOnRead: false,
    seamlessChapterSwitch: true,
  );

  group('★ ComicChapterCacheEntry 序列化', () {
    test('往返后内容一致', () {
      final entry = ComicChapterCacheEntry(
        chapterUrl: 'https://site/viewer?ep=3',
        urls: const ['https://img/a.jpg', 'https://img/b.jpg'],
        headers: const {'Referer': 'https://site/', 'Cookie': 'a=1'},
        title: 'Chapter 4',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      final restored = ComicChapterCacheEntry.decode(entry.encode())!;
      expect(restored.chapterUrl, entry.chapterUrl);
      expect(restored.urls, entry.urls);
      expect(restored.headers, entry.headers);
      expect(restored.title, entry.title);
      expect(restored.updatedAt, entry.updatedAt);
    });

    test('损坏 / 空数据当作未命中，不抛异常', () {
      expect(ComicChapterCacheEntry.decode(null), isNull);
      expect(ComicChapterCacheEntry.decode(''), isNull);
      expect(ComicChapterCacheEntry.decode('{not json'), isNull);
      expect(ComicChapterCacheEntry.decode('{"urls":[]}'), isNull);
      expect(ComicChapterCacheEntry.decode('{"urls":"nope"}'), isNull);
      // urls 里混入非字符串 / 空串：过滤掉后仍可用。
      final entry = ComicChapterCacheEntry.decode(
        '{"urls":["a.jpg",null,"","b.jpg"]}',
      );
      expect(entry!.urls, ['a.jpg', 'b.jpg']);
    });

    test('缓存键：同一话稳定，不同话 / 不同漫画不冲突', () {
      const url = 'https://site/detail';
      expect(comicChapterCacheKey(url, 1), comicChapterCacheKey(url, 1));
      expect(
        comicChapterCacheKey(url, 1),
        isNot(comicChapterCacheKey(url, 2)),
      );
      expect(
        comicChapterCacheKey(url, 1),
        isNot(comicChapterCacheKey('https://other/detail', 1)),
      );
    });
  });

  group('★ MemoryComicChapterStore', () {
    test('写入后可读回', () async {
      final store = MemoryComicChapterStore();
      await store.write(
        'https://site/d',
        0,
        ComicChapterCacheEntry(
          chapterUrl: 'https://site/ep0',
          urls: const ['u1'],
          updatedAt: DateTime.now(),
        ),
      );
      expect(
        store.read('https://site/d', 0, chapterUrl: 'https://site/ep0')!.urls,
        ['u1'],
      );
    });

    test('播放列表 URL 变了 → 缓存视为失效（避免用过期 URL 列表）', () async {
      final store = MemoryComicChapterStore();
      await store.write(
        'https://site/d',
        0,
        ComicChapterCacheEntry(
          chapterUrl: 'https://site/old',
          urls: const ['u1'],
          updatedAt: DateTime.now(),
        ),
      );
      expect(
        store.read('https://site/d', 0, chapterUrl: 'https://site/new'),
        isNull,
      );
    });
  });

  group('★★ 首次进入：装载后写入元数据缓存', () {
    testWidgets('装载一话后，该话的 URL 列表被持久化', (tester) async {
      final store = MemoryComicChapterStore();
      final watcher = FakeChapterWatcher();
      final c = controllerWith(store, watcher: watcher, config: noCacheConfig);
      addTearDown(c.onClose);

      await c.ensureInitialized();
      await c.ensureStripWindow(0);

      // 第 0 话已经装载 → 应已写入缓存。
      final entry = store.read(
        c.detailUrl,
        0,
        chapterUrl: c.playList[0].url,
      );
      expect(entry, isNotNull, reason: '装载成功的章节必须写入元数据缓存');
      expect(entry!.urls, isNotEmpty);
      expect(entry.urls, c.strip.chapterAt(0)!.urls);
    });
  });

  group('★★★ 再次进入：直接用本地缓存，零网络', () {
    testWidgets('缓存命中时不再请求扩展（这是「进入要等很久」的修复）',
        (tester) async {
      // 第一次进入：正常装载，写入缓存。
      final store = MemoryComicChapterStore();
      final firstWatcher = FakeChapterWatcher();
      final first = controllerWith(
        store,
        watcher: firstWatcher,
        config: noCacheConfig,
      );
      addTearDown(first.onClose);
      await first.ensureInitialized();
      await first.ensureStripWindow(0);
      final firstCalls = firstWatcher.calls.length;
      expect(firstCalls, greaterThan(0), reason: '首次进入需要回源');

      // 第二次进入：全新的控制器（模拟重新打开阅读器），
      // 扩展调用会抛错 —— 只要走了缓存就不该被调用。
      final secondWatcher = FakeChapterWatcher();
      final second = controllerWith(
        store,
        watcher: secondWatcher,
        config: noCacheConfig,
      );
      addTearDown(second.onClose);
      await second.ensureInitialized();

      // ★ 首屏内容应该**立刻**就绪，且没有发生任何扩展请求。
      expect(
        second.strip.chapterAt(0),
        isNotNull,
        reason: '★ 缓存命中后，首屏内容应同步就绪，不需要等待网络',
      );
      expect(
        second.strip.chapterAt(0)!.urls,
        first.strip.chapterAt(0)!.urls,
        reason: '缓存恢复的 URL 列表应与首次一致',
      );
      expect(
        secondWatcher.calls,
        isEmpty,
        reason: '★ 缓存命中时不应请求扩展 —— 这是「秒开」的关键',
      );
    });

    testWidgets('★ 缓存命中是同步的：await 初始化之前内容就已就绪',
        (tester) async {
      final store = MemoryComicChapterStore();
      await store.write(
        'https://example.com/detail',
        0,
        ComicChapterCacheEntry(
          chapterUrl: 'https://example.com/viewer?ep=0',
          urls: const ['https://img.test/c0/i0.jpg'],
          updatedAt: DateTime.now(),
        ),
      );
      // 让扩展永远挂起（用 gate 而不是超长 delay：后者会留下
      // fake-async 定时器，让测试以「A Timer is still pending」失败）。
      final watcher = FakeChapterWatcher()..gate = Completer<void>();
      final c = controllerWith(store, watcher: watcher, config: noCacheConfig);
      addTearDown(c.onClose);

      // 注意：这里**不 await** ensureInitialized()，
      // 只让 _bootstrap 跑到同步铺首屏那一步。
      final initFuture = c.ensureInitialized();
      // 用 pump 排空微任务队列（_initSetting 里有 await）。
      // 不能用 Future.delayed：testWidgets 跑在 fake-async 里，
      // 它创建的 Timer 永远等不到。
      await tester.pump();

      expect(
        c.strip.chapterAt(0),
        isNotNull,
        reason: '★ 首屏必须靠缓存铺出来，绝不能等扩展返回',
      );
      expect(
        c.strip.chapterAt(0)!.urls,
        ['https://img.test/c0/i0.jpg'],
        reason: '内容应来自缓存',
      );
      // ★ 关键：**缓存里有的那一话（第 0 话）永远不该被请求**。
      //   （后台会为缓存里没有的相邻话补请求，那是正常的。）
      expect(
        watcher.calls.where((url) => url.contains('ep=0')),
        isEmpty,
        reason: '★ 缓存命中的话不应回源 —— 首屏零网络',
      );

      // 收尾：放行挂起的扩展调用，避免留下未完成的 future。
      watcher.gate!.complete();
      c.cacheService.dispose();
      unawaited_(initFuture);
    });

    testWidgets('缓存的 headers 会被保留（带 Cookie 的图站才能取到图）',
        (tester) async {
      final store = MemoryComicChapterStore();
      await store.write(
        'https://example.com/detail',
        0,
        ComicChapterCacheEntry(
          chapterUrl: 'https://example.com/viewer?ep=0',
          urls: const ['https://img.test/c0/i0.jpg'],
          headers: const {'Referer': 'https://example.com/'},
          updatedAt: DateTime.now(),
        ),
      );
      final c = controllerWith(
        store,
        watcher: FakeChapterWatcher(),
        config: noCacheConfig,
      );
      addTearDown(c.onClose);
      await c.ensureInitialized();
      await settle(tester);

      expect(c.strip.chapterAt(0)!.headers?['Referer'],
          'https://example.com/');
    });
  });

  group('★ 后台回源校正', () {
    testWidgets('缓存内容过期（张数变化）时会被后台校正替换', (tester) async {
      final store = MemoryComicChapterStore();
      // 缓存里只有 1 张图，但扩展实际返回 4 张。
      // updatedAt 设为 2 小时前 → 已过新鲜期，会被后台校正。
      await store.write(
        'https://example.com/detail',
        0,
        ComicChapterCacheEntry(
          chapterUrl: 'https://example.com/viewer?ep=0',
          urls: const ['https://img.test/stale.jpg'],
          updatedAt: DateTime.now().subtract(const Duration(hours: 2)),
        ),
      );
      final watcher = FakeChapterWatcher();
      final c = controllerWith(store, watcher: watcher, config: noCacheConfig);
      addTearDown(c.onClose);
      await c.ensureInitialized();

      // 先确认用的是缓存（1 张）。
      expect(c.strip.chapterAt(0)!.urls.length, 1);

      // 等后台回源完成。
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 5));
        if (c.strip.chapterAt(0)!.urls.length > 1) {
          break;
        }
      }

      expect(
        c.strip.chapterAt(0)!.urls.length,
        4,
        reason: '★ 后台回源应把过期的缓存内容校正过来',
      );
      expect(watcher.calls, isNotEmpty, reason: '回源需要请求扩展');
      // 校正后的内容也应写回缓存。
      final entry = store.read(
        c.detailUrl,
        0,
        chapterUrl: c.playList[0].url,
      );
      expect(entry!.urls.length, 4);
    });

    testWidgets('★ 缓存新鲜（30 分钟内）时完全不回源 —— 真正的零网络',
        (tester) async {
      final store = MemoryComicChapterStore();
      final firstWatcher = FakeChapterWatcher();
      final first = controllerWith(
        store,
        watcher: firstWatcher,
        config: noCacheConfig,
      );
      addTearDown(first.onClose);

      // 第一次进入，写入缓存（updatedAt = now → 新鲜）。
      await first.ensureInitialized();
      await first.ensureStripWindow(0);
      expect(firstWatcher.calls, isNotEmpty);

      // 第二次进入（全新的控制器）。
      final watcher2 = FakeChapterWatcher();
      final c2 = controllerWith(
        store,
        watcher: watcher2,
        config: noCacheConfig,
      );
      addTearDown(c2.onClose);
      await c2.ensureInitialized();
      final revisionAfterHydrate = c2.stripRevision.value;

      // 把窗口内需要的话都预置成新鲜缓存，排除「补缺章节」的干扰。
      for (var chapter = 0; chapter < 6; chapter++) {
        if (!store.entries.containsKey(
          comicChapterCacheKey(c2.detailUrl, chapter),
        )) {
          await store.write(
            c2.detailUrl,
            chapter,
            ComicChapterCacheEntry(
              chapterUrl: c2.playList[chapter].url,
              urls: List.generate(
                4,
                (i) => 'https://img.test/c$chapter/i$i.jpg',
              ),
              updatedAt: DateTime.now(),
            ),
          );
        }
      }
      await c2.ensureStripWindow(0);
      watcher2.calls.clear();

      // 让后台任务有机会跑完。
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 5));
      }

      expect(
        watcher2.calls,
        isEmpty,
        reason: '★ 缓存新鲜时不应有任何回源请求',
      );
      expect(
        c2.stripRevision.value,
        revisionAfterHydrate,
        reason: '★ 内容一致时不应重建列表',
      );
    });

    testWidgets('★ 缓存过期（超过 30 分钟）时后台静默校正', (tester) async {
      final store = MemoryComicChapterStore();
      // 预置一份**过期**且内容已变（1 张 → 实际 4 张）的缓存。
      await store.write(
        'https://example.com/detail',
        0,
        ComicChapterCacheEntry(
          chapterUrl: 'https://example.com/viewer?ep=0',
          urls: const ['https://img.test/stale.jpg'],
          updatedAt: DateTime.now().subtract(const Duration(hours: 2)),
        ),
      );
      final watcher = FakeChapterWatcher();
      final c = controllerWith(store, watcher: watcher, config: noCacheConfig);
      addTearDown(c.onClose);
      await c.ensureInitialized();

      // 首屏立刻用缓存（不阻塞）。
      expect(c.strip.chapterAt(0)!.urls.length, 1);

      // 后台把它校正过来。
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 5));
        if (c.strip.chapterAt(0)!.urls.length > 1) {
          break;
        }
      }
      expect(c.strip.chapterAt(0)!.urls.length, 4,
          reason: '★ 过期缓存应被后台校正');
      expect(
        watcher.calls.where((url) => url.contains('ep=0')),
        isNotEmpty,
        reason: '过期缓存需要回源',
      );
    });
  });

  group('★ 缓存优先对窗口滑动同样生效', () {
    testWidgets('回拉 / 下滑命中缓存时，loadStripChapter 不再请求扩展',
        (tester) async {
      final store = MemoryComicChapterStore();
      // 预置第 0、1 话的缓存。
      for (var chapter = 0; chapter < 2; chapter++) {
        await store.write(
          'https://example.com/detail',
          chapter,
          ComicChapterCacheEntry(
            chapterUrl: 'https://example.com/viewer?ep=$chapter',
            urls: List.generate(
              4,
              (i) => 'https://img.test/c$chapter/i$i.jpg',
            ),
            updatedAt: DateTime.now(),
          ),
        );
      }
      final watcher = FakeChapterWatcher();
      final c = controllerWith(
        store,
        watcher: watcher,
        config: noCacheConfig,
        playIndex: 1,
      );
      addTearDown(c.onClose);
      await c.ensureInitialized();
      await settle(tester);

      expect(c.strip.hasChapter(0), isTrue);
      expect(c.strip.hasChapter(1), isTrue);

      // 显式再要求装载这两话：应全部走缓存。
      watcher.calls.clear();
      await c.loadStripChapter(0);
      await c.loadStripChapter(1);
      expect(
        watcher.calls,
        isEmpty,
        reason: '★ 缓存命中的章节不应再请求扩展',
      );
    });
  });

  group('★ 渲染路径：缓存恢复的内容能直接上屏', () {
    testWidgets('仅靠缓存（无任何网络）也能渲染出连续流', (tester) async {
      final store = MemoryComicChapterStore();
      for (var chapter = 0; chapter < 3; chapter++) {
        await store.write(
          'https://example.com/detail',
          chapter,
          ComicChapterCacheEntry(
            chapterUrl: 'https://example.com/viewer?ep=$chapter',
            urls: List.generate(
              4,
              (i) => 'https://img.test/c$chapter/i$i.jpg',
            ),
            updatedAt: DateTime.now(),
          ),
        );
      }
      // 扩展永远挂起：渲染完全依赖缓存。
      final watcher = FakeChapterWatcher()..gate = Completer<void>();
      final c = controllerWith(store, watcher: watcher, config: noCacheConfig);
      addTearDown(() {
        watcher.gate?.complete();
        c.onClose();
      });
      await c.ensureInitialized();

      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ComicStripView(
              controller: c,
              itemBuilder: (context, item, index) => SizedBox(
                height: 200,
                child: ColoredBox(
                  key: ValueKey('${item.chapterIndex}-${item.imageIndex}'),
                  color: Colors.primaries[
                      item.chapterIndex % Colors.primaries.length],
                ),
              ),
            ),
          ),
        ),
      );
      await settle(tester);

      expect(tester.takeException(), isNull);
      // 缓存的第 0 话应已经在列表里（完全无网络）。
      expect(find.byKey(const ValueKey('0-0')), findsOneWidget);
      // 第 1 话也已缓存 → 也在窗口内（窗口含当前话 ± span）。
      expect(c.strip.hasChapter(1), isTrue);
      expect(
        watcher.calls.where((url) => url.contains('ep=0')),
        isEmpty,
        reason: '★ 缓存命中的话不应回源',
      );
    });
  });
}

/// 显式忽略一个 future（避免 lint 报未使用）。
void unawaited_(Future<void> future) {
  future.then<void>((_) {}, onError: (_, __) {});
}
