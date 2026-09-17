import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:miru_app/controllers/watch/comic_controller.dart';
import 'package:miru_app/models/index.dart';
import 'package:miru_app/utils/comic_cache_config_store.dart';
import 'package:miru_app/views/pages/watch/reader/comic/comic_reader_content.dart';
import 'package:miru_app/views/pages/watch/reader/comic/comic_strip_view.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'comic_strip_seamless_test.dart'
    show FakeChapterWatcher, buildController, settle;

/// 端到端：真实 `ComicReaderContent` + 真实配置读取路径。
///
/// 覆盖链路：
///   设置存储（ComicCacheConfigStore） → ComicController（读到配置）
///   → ComicReaderContent（按配置选择渲染路径）
///   → ComicStripView（条漫连续流）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => Get.testMode = true);
  tearDown(() => Get.reset());

  Future<ComicController> pumpReader(
    WidgetTester tester, {
    required ComicCacheConfig config,
    FakeChapterWatcher? watcher,
    int playIndex = 0,
  }) async {
    // 让控制器从「存储」读到指定配置（等价于用户在设置页配好后的状态）。
    ComicCacheConfigStore.loaderOverride = () => config;
    addTearDown(() => ComicCacheConfigStore.loaderOverride = null);

    final controller = buildController(
      watcher: watcher,
      playIndex: playIndex,
      config: config,
    );
    addTearDown(controller.onClose);
    await controller.ensureInitialized();

    Get.put<ComicController>(controller, tag: 'e2e');
    addTearDown(() {
      if (Get.isRegistered<ComicController>(tag: 'e2e')) {
        Get.delete<ComicController>(tag: 'e2e');
      }
    });

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const fluent.FluentApp(
        home: fluent.ScaffoldPage(
          header: fluent.PageHeader(title: Text('reader')),
          content: ComicReaderContent('e2e'),
        ),
      ),
    );
    await settle(tester);
    return controller;
  }

  group('★ 端到端：真实阅读器按配置渲染', () {
    testWidgets('配置启用条漫无感切换 → 阅读器走连续流（ComicStripView）',
        (tester) async {
      final c = await pumpReader(
        tester,
        config: const ComicCacheConfig(
          enabled: false,
          preloadChapterCount: 2,
          chapterInterval: 0,
          imageInterval: 0,
          cacheOnRead: false,
          seamlessChapterSwitch: true,
        ),
      );

      expect(c.isSeamlessStrip, isTrue);
      expect(find.byType(ComicStripView), findsOneWidget,
          reason: '无感切换开启时必须使用连续流视图');
      // 连续流里应当已经装载了不止一话（可跨话滚动）。
      expect(c.strip.items.map((e) => e.chapterIndex).toSet().length,
          greaterThanOrEqualTo(2));
    });

    testWidgets('配置关闭条漫无感切换 → 阅读器退回单话滚动（不渲染连续流）',
        (tester) async {
      final c = await pumpReader(
        tester,
        config: const ComicCacheConfig(
          enabled: false,
          preloadChapterCount: 2,
          chapterInterval: 0,
          imageInterval: 0,
          cacheOnRead: false,
          seamlessChapterSwitch: false,
        ),
      );

      expect(c.isSeamlessStrip, isFalse);
      expect(find.byType(ComicStripView), findsNothing,
          reason: '关闭无感切换后不应再走连续流路径');
      // 单话滚动仍然是一张列表（只是不含相邻话）。
      expect(find.byType(ScrollablePositionedList), findsOneWidget);
    });

    testWidgets('★ 设置改动后阅读器即时切换渲染路径（无需重进阅读器）',
        (tester) async {
      var config = const ComicCacheConfig(
        enabled: false,
        preloadChapterCount: 2,
        chapterInterval: 0,
        imageInterval: 0,
        cacheOnRead: false,
        seamlessChapterSwitch: true,
      );
      ComicCacheConfigStore.loaderOverride = () => config;
      addTearDown(() => ComicCacheConfigStore.loaderOverride = null);

      final watcher = FakeChapterWatcher();
      final c = buildController(watcher: watcher, config: config);
      addTearDown(c.onClose);
      await c.ensureInitialized();

      Get.put<ComicController>(c, tag: 'e2e2');
      addTearDown(() {
        if (Get.isRegistered<ComicController>(tag: 'e2e2')) {
          Get.delete<ComicController>(tag: 'e2e2');
        }
      });

      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const fluent.FluentApp(
          home: fluent.ScaffoldPage(
            header: fluent.PageHeader(title: Text('reader')),
            content: ComicReaderContent('e2e2'),
          ),
        ),
      );
      await settle(tester);
      expect(find.byType(ComicStripView), findsOneWidget);

      // 用户在设置页关掉「条漫无感切换」→ 广播变更。
      config = config.copyWith(seamlessChapterSwitch: false);
      ComicCacheConfigStore.notifyChanged();
      await settle(tester);

      expect(c.cacheConfig.seamlessChapterSwitch, isFalse);
      expect(find.byType(ComicStripView), findsNothing,
          reason: '关掉开关后阅读器应立刻退回单话滚动，不用重进阅读器');
    });
  });
}
