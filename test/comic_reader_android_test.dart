import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:miru_app/controllers/watch/comic_controller.dart';
import 'package:miru_app/models/index.dart';
import 'package:miru_app/utils/comic_cache_config_store.dart';
import 'package:miru_app/views/pages/watch/reader/comic/comic_reader_content.dart';
import 'package:miru_app/views/pages/watch/reader/comic/comic_strip_view.dart';
import 'package:miru_app/views/widgets/platform_widget.dart';

import 'comic_strip_seamless_test.dart'
    show FakeChapterWatcher, buildController, settle;

/// ★ 漫画阅读器在 Android（GetMaterialApp / 无 FluentTheme）下的布局。
///
/// Android 上阅读器**不能**依赖 FluentTheme，否则整棵子树渲染失败，
/// 表现为「下方布局异常、出现大片纯黑/纯灰一直延伸到底部」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Get.testMode = true;
    debugForceAndroidLayout = true;
  });

  tearDown(() {
    debugForceAndroidLayout = null;
    Get.reset();
  });

  Future<ComicController> pumpReader(
    WidgetTester tester, {
    required ComicCacheConfig config,
    int playIndex = 0,
  }) async {
    ComicCacheConfigStore.loaderOverride = () => config;
    addTearDown(() => ComicCacheConfigStore.loaderOverride = null);

    final controller = buildController(
      watcher: FakeChapterWatcher(),
      playIndex: playIndex,
      config: config,
    );
    addTearDown(controller.onClose);
    await controller.ensureInitialized();

    Get.put<ComicController>(controller, tag: 'android-reader');
    addTearDown(() {
      if (Get.isRegistered<ComicController>(tag: 'android-reader')) {
        Get.delete<ComicController>(tag: 'android-reader');
      }
    });

    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // Android 真实环境：GetMaterialApp（无 FluentTheme）+ Scaffold + SafeArea。
    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: const Scaffold(
          body: SafeArea(
            child: ComicReaderContent('android-reader'),
          ),
        ),
      ),
    );
    await settle(tester);
    return controller;
  }

  const webtoonConfig = ComicCacheConfig(
    enabled: false,
    preloadChapterCount: 2,
    chapterInterval: 0,
    imageInterval: 0,
    cacheOnRead: false,
    seamlessChapterSwitch: true,
  );

  group('★ Android 漫画阅读器布局', () {
    testWidgets('条漫连续流在 Android（无 FluentTheme）下渲染不报错',
        (tester) async {
      final c = await pumpReader(tester, config: webtoonConfig);

      expect(c.isSeamlessStrip, isTrue);
      expect(tester.takeException(), isNull,
          reason: '阅读器不能依赖 FluentTheme，否则 Android 上会整块渲染失败');
      expect(find.byType(ComicStripView), findsOneWidget);
    });

    testWidgets('阅读器内容铺满可用区域（没有大片空白/异常色块）',
        (tester) async {
      await pumpReader(tester, config: webtoonConfig);
      expect(tester.takeException(), isNull);

      final screenW =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final screenH =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;

      // 连续流视图应铺满整个可用区域。
      final stripRect = tester.getRect(find.byType(ComicStripView));
      expect(stripRect.width, screenW,
          reason: '阅读器宽度应铺满（实际 ${stripRect.width} / $screenW）');
      expect(stripRect.height, screenH,
          reason: '阅读器高度应铺满（实际 ${stripRect.height} / $screenH）');
    });

    testWidgets('关闭无感切换（单话条漫）在 Android 下也正常',
        (tester) async {
      final c = await pumpReader(
        tester,
        config: webtoonConfig.copyWith(seamlessChapterSwitch: false),
      );

      expect(c.isSeamlessStrip, isFalse);
      expect(tester.takeException(), isNull);
      expect(find.byType(ComicStripView), findsNothing);
    });

    testWidgets('阅读器里不应出现任何 fluent 控件（Android 无 FluentTheme）',
        (tester) async {
      await pumpReader(tester, config: webtoonConfig);
      expect(tester.takeException(), isNull);

      expect(find.byType(fluent.ToggleSwitch), findsNothing);
      expect(find.byType(fluent.NumberBox<num>), findsNothing);
    });
  });
}
