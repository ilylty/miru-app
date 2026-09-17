import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:miru_app/controllers/watch/comic_controller.dart';
import 'package:miru_app/data/services/comic_cache_service.dart';
import 'package:miru_app/data/services/extension_service.dart';
import 'package:miru_app/models/index.dart';
import 'package:miru_app/utils/comic_cache_config_store.dart';
import 'package:miru_app/views/pages/watch/reader/comic/comic_strip_view.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// 测试辅助：临时覆盖 ComicCacheConfigStore.load() 的返回值。
class ComicCacheConfigStoreForTest {
  ComicCacheConfigStoreForTest(this.config) {
    _previous = ComicCacheConfigStore.loaderOverride;
    ComicCacheConfigStore.loaderOverride = () => config;
  }

  final ComicCacheConfig config;
  ComicCacheConfig Function()? _previous;

  void restore() {
    ComicCacheConfigStore.loaderOverride = _previous;
  }
}
/// 每个章节的图片数量（固定，方便断言）。
const int imagesPerChapter = 4;

/// 单张图片的渲染高度（像素）。固定高度让滚动距离可精确预测。
const double itemHeight = 200;

/// 章节总数。
const int chapterCount = 6;

/// 一个最小的扩展运行时替身。
///
/// 继承真实的 [ExtensionService]（构造器只做字段赋值，不启动 QuickJS），
/// 只覆盖 `watch`，因此可以在无网络、无 JS 运行时的环境下驱动控制器。
class FakeExtensionService extends ExtensionService {
  FakeExtensionService(this.handler) {
    // 直接给基类的 late 字段赋值，而不是重写它。
    extension = Extension(
      package: 'test.comic',
      author: 'test',
      version: '1.0.0',
      lang: 'zh',
      license: 'MIT',
      type: ExtensionType.manga,
      webSite: 'https://example.com',
      name: 'Test Comic',
    );
  }

  final Future<Object?> Function(String url) handler;

  final List<String> calls = [];

  @override
  Future<Object?> watch(String url) {
    calls.add(url);
    return handler(url);
  }
}

/// 记录每次章节请求，并可控地返回内容 / 抛错 / 延迟。
class FakeChapterWatcher {
  FakeChapterWatcher({this.failChapters = const {}});

  final Set<int> failChapters;
  final List<String> calls = [];
  Duration delay = Duration.zero;

  Future<ExtensionMangaWatch?> call(String url) async {
    calls.add(url);
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    final index = int.parse(Uri.parse(url).queryParameters['ep']!);    if (failChapters.contains(index)) {
      throw Exception('boom chapter $index');
    }
    return ExtensionMangaWatch(
      urls: List.generate(
        imagesPerChapter,
        (i) => 'https://img.test/c$index/i$i.jpg',
      ),
    );
  }
}

List<ExtensionEpisode> buildPlayList() => List.generate(
      chapterCount,
      (i) => ExtensionEpisode(
        name: 'Chapter ${i + 1}',
        url: 'https://example.com/viewer?ep=$i',
      ),
    );

/// 构造一个可注入替身的 ComicController（不触碰 Hive/Isar/网络）。
ComicController buildController({
  int playIndex = 0,
  ComicCacheConfig? config,
  FakeChapterWatcher? watcher,
  ComicCacheService? cacheService,
}) {
  final effectiveConfig = config ??
      const ComicCacheConfig(
        enabled: false, // 测试里不真的下载图片
        preloadChapterCount: 2,
        chapterInterval: 0,
        imageInterval: 0,
        cacheOnRead: false,
        seamlessChapterSwitch: true,
      );
  final effectiveWatcher = watcher ?? FakeChapterWatcher();
  return ComicController(
    title: 'Test Comic',
    playList: buildPlayList(),
    detailUrl: 'https://example.com/detail',
    playIndex: playIndex,
    episodeGroupId: 0,
    runtime: FakeExtensionService(effectiveWatcher.call),
    cover: null,
    anilistID: '',
    config: effectiveConfig,
    cacheService: cacheService,
    initialReadMode: MangaReadMode.webTonn,
  );
}

/// 把控制器接入 widget 树。
Future<void> pumpStrip(
  WidgetTester tester,
  ComicController controller, {
  Size size = const Size(400, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ComicStripView(
          controller: controller,
          itemBuilder: (context, item, index) => SizedBox(
            height: itemHeight,
            child: ColoredBox(
              key: ValueKey('${item.chapterIndex}-${item.imageIndex}'),
              color: Colors.primaries[item.chapterIndex % Colors.primaries.length],
              child: Center(
                child: Text(
                  'c${item.chapterIndex}i${item.imageIndex}',
                  textDirection: TextDirection.ltr,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await settle(tester);
}


/// 有界 settle：连续 pump 直到没有新帧或达到上限。
///
/// 不使用 `pumpAndSettle`，因为列表里的 loading 指示器是无限动画，
/// `pumpAndSettle` 会一直等到超时（表现为测试挂死）。
Future<void> settle(WidgetTester tester, {int maxFrames = 30}) async {
  for (var i = 0; i < maxFrames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (!tester.binding.hasScheduledFrame) {
      return;
    }
  }
}

/// 让连续流装载到以 [chapter] 为中心，并等待初始化完成。
///
/// 注意：`testWidgets` 运行在 fake-async 时区里，`Future.delayed`
/// 只有配合 `tester.pump()` 才会推进，所以这里只做纯 await。
Future<void> loadWindow(ComicController c, int chapter) async {
  await c.ensureInitialized();
  await c.ensureStripWindow(chapter);
}

void main() {
  setUp(() {
    Get.testMode = true;
  });

  tearDown(() {
    Get.reset();
  });

  group('★ 条漫连续流：翻到下一话无感切换', () {
    testWidgets('相邻章节被拼进同一条列表（可连续滚动，无页面跳转）',
        (tester) async {
      final watcher = FakeChapterWatcher();
      final c = buildController(watcher: watcher);
      addTearDown(() { c.onClose(); });
      await loadWindow(c, 0);
      await pumpStrip(tester, c);

      // 窗口应包含当前话与后续章节，且是同一条列表。
      final items = c.strip.items;
      expect(items.length, greaterThan(imagesPerChapter),
          reason: '窗口内应包含不止一话的内容');
      expect(items.map((e) => e.chapterIndex).toSet().length,
          greaterThanOrEqualTo(2),
          reason: '当前话与下一话应同时存在于连续列表中');

      // 列表里能同时找到第 0 话和第 1 话的图片 → 说明确实是连续流。
      expect(find.byKey(const ValueKey('0-0')), findsOneWidget);
      await tester.drag(find.byType(ScrollablePositionedList), const Offset(0, -itemHeight * 4));
      await settle(tester);
      expect(find.byKey(const ValueKey('1-0')), findsOneWidget,
          reason: '继续下滑应自然进入下一话，不需要任何页面跳转');
    });

    testWidgets('滚动跨话时：当前话更新但内容不重载（无感的核心）', (tester) async {
      final watcher = FakeChapterWatcher();
      final c = buildController(watcher: watcher);
      addTearDown(() { c.onClose(); });
      await loadWindow(c, 0);
      await pumpStrip(tester, c);

      final callsBefore = watcher.calls.length;
      final revisionBefore = c.stripRevision.value;
      final itemsBefore = c.strip.items;

      // 模拟滚动到下一话的第一张图。
      final nextChapterItem = itemsBefore.firstWhere(
        (e) => e.chapterIndex == 1 && e.imageIndex == 0,
      );
      c.onTopItemChanged(nextChapterItem);
      await settle(tester);

      expect(c.index.value, 1, reason: '当前话应该跟随滚动更新');
      expect(c.currentPage.value, 0);
      expect(c.stripRevision.value, revisionBefore,
          reason: '★ 章节集合没变 → 不重建列表 → 滚动位置/已解码图片全部保留');
      expect(watcher.calls.length, callsBefore,
          reason: '★ 跨话不应触发任何新的章节请求（内容早就在列表里了）');
    });

    testWidgets('★ 回拉到上一话同样无感', (tester) async {
      final watcher = FakeChapterWatcher();
      final c = buildController(watcher: watcher, playIndex: 3);
      addTearDown(() { c.onClose(); });
      await loadWindow(c, 3);
      await pumpStrip(tester, c);

      final callsBefore = watcher.calls.length;
      final revisionBefore = c.stripRevision.value;

      // 回拉到上一话（第 2 话）的最后一张图。
      final prevItem = c.strip.items.firstWhere(
        (e) => e.chapterIndex == 2 && e.imageIndex == imagesPerChapter - 1,
      );
      c.onTopItemChanged(prevItem);
      await settle(tester);

      expect(c.index.value, 2);
      expect(c.currentPage.value, imagesPerChapter - 1);
      expect(c.stripRevision.value, revisionBefore,
          reason: '回拉同样不应重建列表');
      expect(watcher.calls.length, callsBefore,
          reason: '回拉不应触发新的章节请求');
    });

    testWidgets('从第 1 话滑到第 0 话，再滑回第 1 话：全程零重建', (tester) async {
      final watcher = FakeChapterWatcher();
      final c = buildController(watcher: watcher, playIndex: 2);
      addTearDown(() { c.onClose(); });
      await loadWindow(c, 2);
      await pumpStrip(tester, c);

      final callsBefore = watcher.calls.length;
      final revisionBefore = c.stripRevision.value;

      // 向上滑到第 1 话。
      c.onTopItemChanged(
        c.strip.items.firstWhere((e) => e.chapterIndex == 1),
      );
      await settle(tester);
      expect(c.index.value, 1);

      // 再滑回第 2 话。
      c.onTopItemChanged(
        c.strip.items.firstWhere(
          (e) => e.chapterIndex == 2 && e.imageIndex == 0,
        ),
      );
      await settle(tester);
      expect(c.index.value, 2);

      expect(c.stripRevision.value, revisionBefore,
          reason: '来回跨话都不应该重建列表');
      expect(watcher.calls.length, callsBefore,
          reason: '来回跨话都不应该重新请求章节');
    });
  });

  group('★ 窗口滑动时的像素级锚点补偿', () {
    testWidgets('窗口向前补话后，用户看到的内容位置保持不变', (tester) async {
      // 只装载第 2 话，让窗口从第 2 话开始。
      final watcher = FakeChapterWatcher();
      final c = buildController(watcher: watcher, playIndex: 3);
      addTearDown(() { c.onClose(); });
      await c.ensureInitialized();
      await c.ensureStripWindow(3);
      await pumpStrip(tester, c);

      // 向下滚一点，让视口顶部落在第 2 话中间某张图上。
      await tester.drag(
        find.byType(ScrollablePositionedList),
        const Offset(0, -itemHeight * 1.5),
      );
      await settle(tester);

      final anchorBefore = c.itemPositionsListener.itemPositions.value;
      expect(anchorBefore, isNotEmpty);
      final topBefore = anchorBefore.reduce(
        (a, b) => a.itemLeadingEdge < b.itemLeadingEdge ? a : b,
      );
      final itemBefore = c.strip.items[topBefore.index];
      final offsetBefore =
          c.itemScrollController.isAttached ? topBefore.itemLeadingEdge : 0.0;

      // 现在把前面的章节补进窗口（会让所有下标整体后移）。
      await c.loadStripChapter(1);
      await c.loadStripChapter(0);
      c.stripRevision.value++;
      await settle(tester);

      // 同一个内容条目仍然应该位于视口顶部附近。
      final positionsAfter = c.itemPositionsListener.itemPositions.value;
      final topAfter = positionsAfter.reduce(
        (a, b) => a.itemLeadingEdge < b.itemLeadingEdge ? a : b,
      );
      final itemAfter = c.strip.items[topAfter.index];
      expect(
        itemAfter.chapterIndex,
        itemBefore.chapterIndex,
        reason: '★ 窗口补话后视口顶部仍应是同一话',
      );
      expect(
        itemAfter.imageIndex,
        itemBefore.imageIndex,
        reason: '★ 窗口补话后视口顶部仍应是同一张图（像素级补偿生效）',
      );
      expect(
        (topAfter.itemLeadingEdge - offsetBefore).abs(),
        lessThan(0.2),
        reason: '★ 相对位置偏差应该很小，用户感知不到跳动',
      );
    });

    testWidgets('窗口重建时列表身份保持（Key 稳定，不重建整棵子树）',
        (tester) async {
      final watcher = FakeChapterWatcher();
      final c = buildController(watcher: watcher);
      addTearDown(() { c.onClose(); });
      await loadWindow(c, 0);
      await pumpStrip(tester, c);

      final listFinder = find.byKey(const ValueKey('comic-strip-list'));
      expect(listFinder, findsOneWidget);

      final stateBefore =
          tester.state(find.byType(ScrollablePositionedList));
      c.stripRevision.value++;
      await settle(tester);
      final stateAfter = tester.state(find.byType(ScrollablePositionedList));
      expect(identical(stateBefore, stateAfter), isTrue,
          reason: '★ 稳定 Key 保证列表 State 不被销毁重建');
    });
  });

  group('★ 主动跳章（播放列表 / 恢复进度）', () {
    testWidgets('跳章后当前话对齐到视口顶部', (tester) async {
      final watcher = FakeChapterWatcher();
      final c = buildController(watcher: watcher, playIndex: 0);
      addTearDown(() { c.onClose(); });
      await loadWindow(c, 0);
      await pumpStrip(tester, c);

      // 用户跳到第 3 话。
      c.index.value = 3;
      await c.ensureStripWindow(3);
      c.jumpChapterRequest.value++;
      await settle(tester, maxFrames: 60);

      final positions = c.itemPositionsListener.itemPositions.value;
      final top = positions.reduce(
        (a, b) => a.itemLeadingEdge < b.itemLeadingEdge ? a : b,
      );
      final item = c.strip.items[top.index];
      expect(item.chapterIndex, 3,
          reason: '跳章后视口顶部应该是目标章节');
      expect(item.imageIndex, 0, reason: '跳章应该对齐到该话第一张图');
    });
  });

  group('★ 性能：窗口化与内存收敛', () {
    testWidgets('窗口最多只包含 maxWindowChapters 话', (tester) async {
      final watcher = FakeChapterWatcher();
      final c = buildController(watcher: watcher, playIndex: 3);
      addTearDown(() { c.onClose(); });
      await loadWindow(c, 3);
      await pumpStrip(tester, c);

      final chapters = c.strip.windowChapterIndexes;
      expect(chapters.length,
          lessThanOrEqualTo(ComicStripModel.defaultMaxWindowChapters));
      expect(chapters.contains(3), isTrue);
      expect(chapters, List.generate(chapters.length, (i) => chapters.first + i),
          reason: '窗口必须是连续区间，不能有空洞');
    });

    testWidgets('已装载章节数量收敛到上限（长时间阅读不爆内存）',
        (tester) async {
      final watcher = FakeChapterWatcher();
      final c = buildController(watcher: watcher);
      addTearDown(() { c.onClose(); });
      await loadWindow(c, 0);

      // 模拟读了很远的章节：反复同步窗口。
      for (var chapter = 0; chapter < chapterCount; chapter++) {
        await c.ensureStripWindow(chapter);
      }
      expect(
        c.strip.loadedChapterIndexes.length,
        lessThanOrEqualTo(ComicStripModel.defaultMaxLoadedChapters),
      );
      expect(c.strip.loadedChapterIndexes.length, lessThan(chapterCount + 1));
    });
  });

  group('★ 容错', () {
    testWidgets('某话加载失败：其它章节仍可阅读，错误被记录', (tester) async {
      final watcher = FakeChapterWatcher(failChapters: {2});
      final c = buildController(watcher: watcher);
      addTearDown(() { c.onClose(); });
      await loadWindow(c, 0);
      await pumpStrip(tester, c);

      expect(c.strip.hasChapter(0), isTrue);
      expect(c.strip.hasChapter(2), isFalse, reason: '失败的章节不应被当作已装载');
      expect(c.stripError, isNotEmpty);
      // 连续区间在缺口处截断，不会出现空槽位。
      expect(c.strip.windowChapterIndexes.contains(2), isFalse);
    });

    testWidgets('加载中的章节请求会被串行化（不并发求值 QuickJS）',
        (tester) async {
      final watcher = FakeChapterWatcher();
      final c = buildController(watcher: watcher);
      addTearDown(() {
        c.cacheService.dispose();
      });
      await loadWindow(c, 0);
      expect(watcher.calls.length, greaterThan(1));
      // 串行化保证调用顺序与入队顺序一致（先中心话）。
      expect(watcher.calls.first, contains('ep=0'));
    });
  });

  group('★ 缓存与连续流联动', () {
    testWidgets('配置变更后阅读器立即采用新配置（不用重进阅读器）',
        (tester) async {
      final watcher = FakeChapterWatcher();
      final c = buildController(
        watcher: watcher,
        config: const ComicCacheConfig(
          enabled: false,
          preloadChapterCount: 2,
          chapterInterval: 0,
          imageInterval: 0,
          cacheOnRead: false,
          seamlessChapterSwitch: true,
        ),
      );
      addTearDown(() {
        c.cacheService.dispose();
      });
      await loadWindow(c, 0);
      await pumpStrip(tester, c);
      expect(c.cacheConfig.enabled, isFalse);

      // 设置页保存了新配置 → 广播变更。
      // 间隔用 0 避免在 widget 测试里留下待触发的 Timer
      // （l / m 的实际节流行为由 comic_cache_service_test.dart 覆盖）。
      final store = ComicCacheConfigStoreForTest(
        const ComicCacheConfig(
          enabled: true,
          preloadChapterCount: 4,
          chapterInterval: 0,
          imageInterval: 0,
          maxConcurrent: 5,
          cacheOnRead: false,
          seamlessChapterSwitch: true,
        ),
      );
      addTearDown(store.restore);
      ComicCacheConfigStore.notifyChanged();
      await settle(tester);

      expect(c.cacheConfig.enabled, isTrue);
      expect(c.cacheConfig.preloadChapterCount, 4);
      expect(c.cacheConfig.maxConcurrent, 5);
      expect(c.cacheService.config.preloadChapterCount, 4);
      expect(c.cacheService.config.maxConcurrent, 5,
          reason: '新的并发度应下发到缓存服务');
      expect(c.strip.nextSpan, 4,
          reason: '窗口跨度也应该跟随新的「缓存后 n 话」配置');
    });

    testWidgets('窗口装载后会按配置触发生产者缓存', (tester) async {
      final watcher = FakeChapterWatcher();
      final downloaded = <String>[];
      // 生产端按需从连续流模型里取章节内容（与生产代码路径一致）。
      late final ComicController controllerRef;
      final cacheService = ComicCacheService(
        config: const ComicCacheConfig(
          enabled: true,
          preloadChapterCount: 2,
          chapterInterval: 0,
          imageInterval: 0,
          maxConcurrent: 1,
          cacheOnRead: false,
        ),
        chapterLoader: (chapterIndex) async {
          final chapter = controllerRef.strip.chapterAt(chapterIndex);
          if (chapter == null) {
            return null;
          }
          return ComicCacheChapterTask(
            chapterIndex: chapterIndex,
            urls: chapter.urls,
            headers: chapter.headers,
          );
        },
        fetcher: (url, headers) async {
          downloaded.add(url);
          return true;
        },
        cacheProbe: (url) async => false,
        sleeper: (d) => Future<void>.value(),
      );
      final c = buildController(
        watcher: watcher,
        cacheService: cacheService,
        config: cacheService.config,
      );
      controllerRef = c;
      addTearDown(() { c.onClose(); });
      await loadWindow(c, 0);
      await pumpStrip(tester, c);

      // 等待生产端把后 2 话缓存完（用 pump 推进 fake-async 时区）。
      for (var i = 0; i < 400 && cacheService.isBusy; i++) {
        await tester.pump(const Duration(milliseconds: 5));
      }

      // 第 1、2 话（当前话之后的 2 话）应该都被缓存了。
      expect(
        downloaded.where((u) => u.contains('c1/')).length,
        imagesPerChapter,
      );
      expect(
        downloaded.where((u) => u.contains('c2/')).length,
        imagesPerChapter,
      );
      // 第 0 话是当前话，cacheOnRead=false 时不由消费者缓存。
      expect(downloaded.where((u) => u.contains('c0/')), isEmpty);
    });

    testWidgets('★ 消费者：开启 cacheOnRead 后当前话会被缓存（真实控制器路径）',
        (tester) async {
      final watcher = FakeChapterWatcher();
      final downloaded = <String>[];
      late final ComicController controllerRef;
      final cacheService = ComicCacheService(
        config: const ComicCacheConfig(
          enabled: true,
          preloadChapterCount: 0, // 关掉生产端，只验证消费端
          chapterInterval: 0,
          imageInterval: 0,
          maxConcurrent: 1,
          cacheOnRead: true, // 消费者：阅读时顺带缓存
        ),
        chapterLoader: (chapterIndex) async {
          final chapter = controllerRef.strip.chapterAt(chapterIndex);
          if (chapter == null) {
            return null;
          }
          return ComicCacheChapterTask(
            chapterIndex: chapterIndex,
            urls: chapter.urls,
            headers: chapter.headers,
          );
        },
        fetcher: (url, headers) async {
          downloaded.add(url);
          return true;
        },
        cacheProbe: (url) async => false,
        sleeper: (d) => Future<void>.value(),
      );
      final c = buildController(
        watcher: watcher,
        cacheService: cacheService,
        config: cacheService.config,
      );
      controllerRef = c;
      addTearDown(() { c.onClose(); });
      await loadWindow(c, 0);
      await pumpStrip(tester, c);
      for (var i = 0; i < 400 && cacheService.isBusy; i++) {
        await tester.pump(const Duration(milliseconds: 5));
      }

      // 当前话（第 0 话）的图片应该因为「用户在读」而被缓存。
      expect(
        downloaded.where((u) => u.contains('c0/')).length,
        imagesPerChapter,
        reason: 'cacheOnRead=true 时，用户正在读的那一话应被顺带缓存',
      );
      expect(cacheService.stats.cachedChapters, 1);
    });

    testWidgets('★ 消费者：关闭 cacheOnRead 后当前话不会被缓存（对照组）',
        (tester) async {
      final watcher = FakeChapterWatcher();
      final downloaded = <String>[];
      late final ComicController controllerRef;
      final cacheService = ComicCacheService(
        config: const ComicCacheConfig(
          enabled: true,
          preloadChapterCount: 0,
          chapterInterval: 0,
          imageInterval: 0,
          maxConcurrent: 1,
          cacheOnRead: false,
        ),
        chapterLoader: (chapterIndex) async {
          final chapter = controllerRef.strip.chapterAt(chapterIndex);
          if (chapter == null) {
            return null;
          }
          return ComicCacheChapterTask(
            chapterIndex: chapterIndex,
            urls: chapter.urls,
            headers: chapter.headers,
          );
        },
        fetcher: (url, headers) async {
          downloaded.add(url);
          return true;
        },
        cacheProbe: (url) async => false,
        sleeper: (d) => Future<void>.value(),
      );
      final c = buildController(
        watcher: watcher,
        cacheService: cacheService,
        config: cacheService.config,
      );
      controllerRef = c;
      addTearDown(() { c.onClose(); });
      await loadWindow(c, 0);
      await pumpStrip(tester, c);
      for (var i = 0; i < 200 && cacheService.isBusy; i++) {
        await tester.pump(const Duration(milliseconds: 5));
      }

      expect(downloaded, isEmpty,
          reason: 'cacheOnRead=false 且 n=0 时不应该有任何下载');
    });
  });
}
