import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:miru_app/controllers/watch/comic_controller.dart';
import 'package:miru_app/data/services/database_service.dart';
import 'package:miru_app/models/index.dart';
import 'package:miru_app/utils/comic_cache_config_store.dart';
import 'package:miru_app/views/pages/watch/reader/comic/comic_reader_content.dart';
import 'package:miru_app/views/pages/watch/reader/comic/comic_strip_view.dart';
import 'package:miru_app/views/widgets/platform_widget.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'comic_strip_seamless_test.dart'
    show FakeChapterWatcher, buildController, imagesPerChapter, settle;

/// ★ 恢复上次阅读位置：必须能定位到「第几话的第几页」，而不只是「第几话开头」。
///
/// 这条链路在真实 App 里是：
///   `detail_continue_play` 用 `history.episodeId` 打开对应话
///   → `ComicController` 在 `watchData` 就绪后读历史
///   → `currentPage = history.progress` → `_jumpPage(page)`
///
/// 其中 `_jumpPage` 走的是 `ItemScrollController.jumpTo`，
/// 而该控制器在列表**挂载之前**是未 attach 的（`isAttached == false`），
/// 此时 jumpTo 会被静默丢弃。列表首次构建又只用了「当前话开头」
/// （`initialScrollIndex: currentChapterItemOffset`），
/// 于是恢复出来的位置永远停在该话第一张图 —— 正是用户报告的现象。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Get.testMode = true;
    // 阅读器在桌面路径会读 FluentTheme；测试里走 Material 路径，
    // 这样不依赖 FluentTheme 也能验证真实阅读器渲染。
    debugForceAndroidLayout = true;
  });
  tearDown(() {
    debugForceAndroidLayout = null;
    Get.reset();
    DatabaseService.historyLoaderOverride = null;
  });

  /// 构造一条「上次读到第 [chapterIndex] 话第 [page] 页」的历史记录。
  History buildHistory({
    required int chapterIndex,
    required int page,
    int episodeGroupId = 0,
  }) {
    return History()
      ..package = 'test.comic'
      ..url = 'https://example.com/detail'
      ..type = ExtensionType.manga
      ..episodeGroupId = episodeGroupId
      ..episodeId = chapterIndex
      ..title = 'Test Comic'
      ..episodeTitle = 'Chapter ${chapterIndex + 1}'
      ..progress = page.toString()
      ..totalProgress = imagesPerChapter.toString();
  }

  const webtoonConfig = ComicCacheConfig(
    enabled: false,
    preloadChapterCount: 2,
    chapterInterval: 0,
    imageInterval: 0,
    cacheOnRead: false,
    seamlessChapterSwitch: true,
  );

  /// 让阅读器真实地跑一遍「进入 → 恢复历史」的流程。
  Future<ComicController> pumpReaderWithHistory(
    WidgetTester tester, {
    required History history,
    required int playIndex,
    required String tag,
    ComicCacheConfig config = webtoonConfig,
  }) async {
    ComicCacheConfigStore.loaderOverride = () => config;
    addTearDown(() => ComicCacheConfigStore.loaderOverride = null);
    DatabaseService.historyLoaderOverride = (package, url) async => history;

    final controller = buildController(
      watcher: FakeChapterWatcher(),
      playIndex: playIndex,
      config: config,
    );
    addTearDown(controller.onClose);

    // ★ 顺序必须与真实 App 一致：
    //   `ComicReader.initState` 先 `Get.put`（→ `onInit` 注册 `ever(watchData)`
    //   与启动 `ensureInitialized`），然后才渲染视图。
    //   如果反过来先 `ensureInitialized()`，watchData 会在监听器注册之前
    //   就被写入，恢复逻辑永远不会触发 —— 那测的就不是真实链路了。
    Get.put<ComicController>(controller, tag: tag);
    addTearDown(() {
      if (Get.isRegistered<ComicController>(tag: tag)) {
        Get.delete<ComicController>(tag: tag);
      }
    });
    await controller.ensureInitialized();

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: SafeArea(
            // key 必须随 tag 变化：否则 Flutter 会复用上一个阅读器的 State，
            // 而 State 里 `late final _c` 已经绑定了旧的（已关闭的）控制器。
            child: ComicReaderContent(tag, key: ValueKey(tag)),
          ),
        ),
      ),
    );
    // 多 pump 几帧：历史读取是异步的，恢复动作可能落在首帧之后。
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await settle(tester, maxFrames: 60);
    return controller;
  }

  /// 视口顶部当前对应的 (章节, 图片下标)。
  ({int chapter, int image}) viewportTop(ComicController c) {
    final positions = c.itemPositionsListener.itemPositions.value;
    expect(positions, isNotEmpty, reason: '列表应至少布局出一张图');
    final top = positions.reduce(
      (a, b) => a.itemLeadingEdge < b.itemLeadingEdge ? a : b,
    );
    // 连续流用条漫条目表；单话条漫的条目表就是当前话的图片。
    final items = c.isSeamlessStrip
        ? c.strip.items
        : c.watchData.value!.urls
            .asMap()
            .entries
            .map((e) => StripItem(
                  chapterIndex: c.index.value,
                  imageIndex: e.key,
                  url: e.value,
                ))
            .toList();
    final index = top.index.clamp(0, items.length - 1);
    final item = items[index];
    return (chapter: item.chapterIndex, image: item.imageIndex);
  }

  group('★ 恢复上次阅读位置（条漫连续流）', () {
    testWidgets('恢复到「第 2 话第 3 页」而不是该话开头', (tester) async {
      final c = await pumpReaderWithHistory(
        tester,
        history: buildHistory(chapterIndex: 2, page: 3),
        playIndex: 2,
        tag: 'restore-strip',
      );

      expect(c.isSeamlessStrip, isTrue);
      expect(find.byType(ComicStripView), findsOneWidget);

      final top = viewportTop(c);
      expect(top.chapter, 2, reason: '应恢复到上次阅读的那一话');
      expect(
        top.image,
        3,
        reason: '★ 必须恢复到第 3 页（下标 3），而不是第 2 话的开头（下标 0）',
      );
      expect(c.currentPage.value, 3, reason: 'currentPage 应反映恢复出来的页码');
    });

    testWidgets('恢复到「第 1 话最后一张图」', (tester) async {
      final c = await pumpReaderWithHistory(
        tester,
        history: buildHistory(chapterIndex: 1, page: imagesPerChapter - 1),
        playIndex: 1,
        tag: 'restore-strip-last',
      );

      final top = viewportTop(c);
      expect(top.chapter, 1);
      expect(top.image, imagesPerChapter - 1, reason: '★ 恢复的是话内具体页码，不是话首');
    });

    testWidgets('对照：没有历史记录时从该话第一页开始', (tester) async {
      DatabaseService.historyLoaderOverride = (package, url) async => null;
      final c = buildController(
        watcher: FakeChapterWatcher(),
        playIndex: 2,
        config: webtoonConfig,
      );
      addTearDown(c.onClose);
      Get.put<ComicController>(c, tag: 'restore-none');
      addTearDown(() {
        if (Get.isRegistered<ComicController>(tag: 'restore-none')) {
          Get.delete<ComicController>(tag: 'restore-none');
        }
      });
      await c.ensureInitialized();

      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        GetMaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: const Scaffold(
            body: SafeArea(
              child: ComicReaderContent('restore-none',
                  key: ValueKey('restore-none')),
            ),
          ),
        ),
      );
      await settle(tester, maxFrames: 60);

      final top = viewportTop(c);
      expect(top.chapter, 2);
      expect(top.image, 0, reason: '没有历史时不应凭空跳到某页');
    });

    testWidgets('恢复后仍可继续无感滚动（跨话不重建）', (tester) async {
      final c = await pumpReaderWithHistory(
        tester,
        history: buildHistory(chapterIndex: 1, page: 2),
        playIndex: 1,
        tag: 'restore-scroll',
      );
      expect(viewportTop(c).image, 2);

      final revisionBefore = c.stripRevision.value;
      // 往下滑一话多（占位图高度 = 视口高度，所以按屏幕高度算拖动距离）。
      await tester.drag(
        find.byType(ScrollablePositionedList),
        const Offset(0, -800 * 3),
      );
      await settle(tester, maxFrames: 60);

      expect(c.index.value, greaterThanOrEqualTo(2), reason: '恢复位置之后应能正常继续往下读');
      expect(c.stripRevision.value, revisionBefore, reason: '正常滚动依旧不应重建列表');
    });
  });

  group('★ 滚动跨话时的页码一致性', () {
    testWidgets('跨话后 currentPage 立刻等于视口顶部图片下标（不能被打回 0）', (tester) async {
      final c = await pumpReaderWithHistory(
        tester,
        history: buildHistory(chapterIndex: 1, page: 0),
        playIndex: 1,
        tag: 'page-consistency',
      );

      // 取一个「下一话中间」的条目。
      final target = c.strip.items.firstWhere(
        (e) => e.chapterIndex == 2 && e.imageIndex == 2,
      );
      c.onTopItemChanged(target);

      // ★ 同步断言：不 pump，避开 120ms 节流后的重复上报。
      //
      // 这个不变量很重要：`ever(index)` 里无条件 `currentPage = 0`
      // 会把刚算好的页内下标抹掉（本章切换章节的副作用），
      // 而 `currentPage` 正是关闭阅读器时写进历史的页码 ——
      // 被抹掉就意味着「下次恢复又退化成话首」。
      expect(c.index.value, 2, reason: '当前话应跟随跨话更新');
      expect(c.currentPage.value, 2, reason: '★ 跨话后页码必须立刻是视口顶部那张图，不能被重置为 0');
    });

    testWidgets('手动切章（非滚动）依旧从第 0 页开始', (tester) async {
      final c = await pumpReaderWithHistory(
        tester,
        history: buildHistory(chapterIndex: 0, page: 3),
        playIndex: 0,
        tag: 'page-manual',
      );
      expect(c.currentPage.value, 3, reason: '先恢复到第 3 页');

      // 播放列表跳章：这是真正的「换一话」，应从该话第一页开始。
      c.index.value = 2;
      await settle(tester, maxFrames: 30);
      expect(c.currentPage.value, 0, reason: '手动切章后应从新的一话第一页开始');
    });
  });

  group('★ 完整往返：读 → 滚动 → 关闭存历史 → 再进恢复', () {
    testWidgets('第二次进入能回到上次离开的那一页（而不是话首）', (tester) async {
      History? saved;
      DatabaseService.putHistoryOverride = (history) async {
        saved = history;
      };
      addTearDown(() => DatabaseService.putHistoryOverride = null);

      // ---- 第一次进入：从第 1 话第 1 页开始 ----
      DatabaseService.historyLoaderOverride = (package, url) async => null;
      final first = buildController(
        watcher: FakeChapterWatcher(),
        playIndex: 1,
        config: webtoonConfig,
      );
      Get.put<ComicController>(first, tag: 'roundtrip-1');
      await first.ensureInitialized();
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        GetMaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: const Scaffold(
            body: SafeArea(
              child: ComicReaderContent(
                'roundtrip-1',
                key: ValueKey('roundtrip-1'),
              ),
            ),
          ),
        ),
      );
      await settle(tester, maxFrames: 60);

      // 真正把视口滑到第 2 话第 3 张图（而不是手动调回调）：
      // 位置监听器才是「当前页」的权威来源，手动调会被它覆盖。
      final targetIndex =
          first.strip.itemOffsetOfPage((chapterIndex: 2, imageIndex: 2))!;
      first.itemScrollController.jumpTo(index: targetIndex);
      await settle(tester, maxFrames: 60);
      expect(first.index.value, 2, reason: '滑到第 2 话后当前话应更新');
      expect(first.currentPage.value, 2,
          reason: '★ 滚动跨话后 currentPage 应指向视口顶部那张图（不能被打回 0）');

      // ---- 关闭：历史被写入（页码 = 离开时的页） ----
      first.onClose();
      // `onClose` 里的保存是 unawaited 的，pump 几次让它落地。
      for (var i = 0; i < 10 && saved == null; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(saved, isNotNull, reason: '关闭阅读器应把进度写进历史');
      expect(saved!.episodeId, 2, reason: '历史应记录离开时的那一话');
      expect(saved!.progress, '2', reason: '★ 历史必须记录话内页码，而不是只记「第几话」');

      if (Get.isRegistered<ComicController>(tag: 'roundtrip-1')) {
        Get.delete<ComicController>(tag: 'roundtrip-1');
      }

      // ---- 第二次进入：用刚存下的历史恢复 ----
      final savedHistory = saved!;
      DatabaseService.historyLoaderOverride =
          (package, url) async => savedHistory;
      final second = buildController(
        watcher: FakeChapterWatcher(),
        playIndex: 2,
        config: webtoonConfig,
      );
      addTearDown(second.onClose);
      Get.put<ComicController>(second, tag: 'roundtrip-2');
      addTearDown(() {
        if (Get.isRegistered<ComicController>(tag: 'roundtrip-2')) {
          Get.delete<ComicController>(tag: 'roundtrip-2');
        }
      });
      await second.ensureInitialized();
      await tester.pumpWidget(
        GetMaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: const Scaffold(
            body: SafeArea(
              child: ComicReaderContent(
                'roundtrip-2',
                key: ValueKey('roundtrip-2'),
              ),
            ),
          ),
        ),
      );
      await settle(tester, maxFrames: 60);

      final top = viewportTop(second);
      expect(top.chapter, 2, reason: '应回到上次离开的那一话');
      expect(top.image, 2, reason: '★ 应回到上次离开的那一页（完整往返不丢页码）');
    });
  });

  group('★ 真实渲染几何：哪一张图被画在了视口顶部', () {
    testWidgets('恢复到第 2 话第 3 页时，第 3 张图确实贴在视口顶部', (tester) async {
      ComicCacheConfigStore.loaderOverride = () => webtoonConfig;
      addTearDown(() => ComicCacheConfigStore.loaderOverride = null);
      DatabaseService.historyLoaderOverride =
          (package, url) async => buildHistory(chapterIndex: 2, page: 3);

      final c = buildController(
        watcher: FakeChapterWatcher(),
        playIndex: 2,
        config: webtoonConfig,
      );
      addTearDown(c.onClose);
      Get.put<ComicController>(c, tag: 'geometry');
      addTearDown(() {
        if (Get.isRegistered<ComicController>(tag: 'geometry')) {
          Get.delete<ComicController>(tag: 'geometry');
        }
      });
      await c.ensureInitialized();

      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // 每个条目高度固定 200，并用文字标出「第几话第几页」，
      // 这样可以直接用渲染出来的位置验证首帧落在哪一页。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ComicStripView(
              controller: c,
              itemBuilder: (context, item, index) => SizedBox(
                key: ValueKey('item-${item.chapterIndex}-${item.imageIndex}'),
                height: 200,
                child: ColoredBox(
                  color: Colors
                      .primaries[item.chapterIndex % Colors.primaries.length],
                  child: Center(
                    child: Text('c${item.chapterIndex}i${item.imageIndex}'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await settle(tester, maxFrames: 60);

      // 目标页那一张必须真的被布局出来，且贴在视口顶部（top == 0）。
      final targetFinder = find.byKey(const ValueKey('item-2-3'));
      expect(targetFinder, findsOneWidget, reason: '第 2 话第 3 页应该已经被渲染出来');
      final targetRect = tester.getRect(targetFinder);
      expect(targetRect.top, closeTo(0.0, 0.5),
          reason: '目标页上边缘应贴视口顶部（实际 ${targetRect.top}）');
      expect(targetRect.bottom, greaterThan(0.0),
          reason: '目标页必须真的占据视口（而不是被滚过去）');

      // 话首的那一张不应该还占着视口顶部（即不能退化到「话开头」）。
      final firstPage = find.byKey(const ValueKey('item-2-0'));
      if (firstPage.evaluate().isNotEmpty) {
        expect(tester.getRect(firstPage).bottom, lessThanOrEqualTo(0.5),
            reason: '话首应该已经被滑过去，而不是停在视口里');
      }

      // 排空位置上报的 120ms 节流定时器，避免测试结束时报「Timer still pending」。
      await tester.pump(const Duration(milliseconds: 200));
    });
  });

  group('★ 恢复上次阅读位置（关闭无感切换的单话条漫）', () {
    testWidgets('单话条漫也恢复到指定页（不是话首）', (tester) async {
      final c = await pumpReaderWithHistory(
        tester,
        history: buildHistory(chapterIndex: 1, page: 2),
        playIndex: 1,
        tag: 'restore-plain',
        config: webtoonConfig.copyWith(seamlessChapterSwitch: false),
      );

      expect(c.isSeamlessStrip, isFalse);
      // 单话条漫是另一条渲染路径（`_buildPlainWebtoon`），
      // 它同样面临「列表挂载前 jumpTo 被丢弃」的问题。
      final top = viewportTop(c);
      expect(top.image, 2, reason: '★ 单话条漫也要恢复到第 2 页，而不是第 1 话开头');
    });
  });
}
