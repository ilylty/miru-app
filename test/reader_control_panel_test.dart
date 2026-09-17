import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_i18n/flutter_i18n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:miru_app/controllers/watch/comic_controller.dart';
import 'package:miru_app/models/index.dart';
import 'package:miru_app/router/router.dart';
import 'package:miru_app/utils/comic_cache_config_store.dart';
import 'package:miru_app/views/widgets/platform_widget.dart';
import 'package:miru_app/views/widgets/watch/reader_view.dart';

import 'comic_strip_seamless_test.dart'
    show FakeChapterWatcher, buildController, settle;

/// 漫画内容用刺眼的纯色，采样像素时一眼就能区分「图片」和「面板」。
const contentColor = Color(0xFF7B1FA2);

/// 面板里的 `ControlPanelFooter` 用 `.i18n`，它需要真实的翻译 delegate
/// （用仓库里的 `assets/i18n/en.json`），否则 `Null check operator`。
class _TestI18nDelegate extends FlutterI18nDelegate {
  _TestI18nDelegate()
      : super(
          translationLoader: FileTranslationLoader(
            useCountryCode: false,
            fallbackFile: 'en',
            basePath: 'assets/i18n',
            forcedLocale: const Locale('en'),
          ),
        );
}

/// 面板背景色 = `Theme.of(context).scaffoldBackgroundColor`（Material 深色）。
final panelColor = ThemeData.dark(useMaterial3: true).scaffoldBackgroundColor;

/// ★ 点击呼出的控制面板，其背景必须铺满到屏幕最顶端（含刘海/状态栏区域）。
///
/// 用户报告：
///   「阅读时点击出现的菜单，上面还是透明的然后跟上菜单栏」
///   —— 面板**上方**（刘海那一条）仍是透明的，能看见下面的漫画，
///      再往下才是菜单栏；希望那一条和菜单栏同色。
///
/// 根因：`ControlPanelHeader._buildAndroid` 是
/// ```dart
/// SafeArea(child: Container(height: 60, color: <面板色>, child: AppBar(...)))
/// ```
/// `SafeArea` 包在 `Container` **外面** → 整个带背景色的 `Container`
/// 被 inset 顶下去 → **inset 那一条没有任何背景**，
/// 于是透出下面的漫画图片（沉浸模式下系统栏已隐藏，但刘海仍在，
/// Flutter 仍会通过 `MediaQuery.padding.top` 报告这段 inset）。
///
/// 正确做法是把背景铺到 inset 区域里、只让**内容**避开刘海：
/// 背景 `Container` 在外层，`SafeArea` 在里层。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 模拟真机竖屏：400x800，顶部刘海 30px。
  ///
  /// 沉浸模式下系统栏被隐藏，但刘海（display cutout）依然存在，
  /// Flutter 会继续通过 `MediaQuery.padding.top` 报告它
  /// （`FlutterView.onApplyWindowInsets` 读 `DisplayCutout.getSafeInsetTop`）。
  const cutoutTop = 30.0;

  setUp(() {
    Get.testMode = true;
    debugForceAndroidLayout = true;
  });
  tearDown(() {
    debugForceAndroidLayout = null;
    Get.reset();
  });

  /// 渲染真实 [ReaderView]（含控制面板），并采样若干行的像素。
  ///
  /// 返回 `{行号: 该行中间点的颜色}`。
  Future<Map<int, Color>> pumpReaderAndSample(
    WidgetTester tester, {
    required bool showPanel,
    double topInset = cutoutTop,
    List<int> rows = const [1, 10, 25, 29, 35, 45, 70, 89, 120, 400],
  }) async {
    ComicCacheConfigStore.loaderOverride = () => const ComicCacheConfig(
          enabled: false,
          preloadChapterCount: 2,
          chapterInterval: 0,
          imageInterval: 0,
          cacheOnRead: false,
          seamlessChapterSwitch: true,
        );
    addTearDown(() => ComicCacheConfigStore.loaderOverride = null);

    final c = buildController(watcher: FakeChapterWatcher());
    addTearDown(c.onClose);
    Get.put<ComicController>(c, tag: 'panel');
    addTearDown(() {
      if (Get.isRegistered<ComicController>(tag: 'panel')) {
        Get.delete<ComicController>(tag: 'panel');
      }
    });
    await c.ensureInitialized();

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = FakeViewPadding(top: topInset);
    tester.view.viewPadding = FakeViewPadding(top: topInset);
    addTearDown(tester.view.reset);

    c.isShowControlPanel.value = showPanel;

    const boundaryKey = ValueKey('panel-boundary');

    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          // 面板里的 `ControlPanelFooter` 用 `.i18n`，它读
          // `rootNavigatorKey.currentContext` —— 挂上这个 key 才能取到。
          navigatorKey: rootNavigatorKey,
          localizationsDelegates: [_TestI18nDelegate()],
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: ReaderView<ComicController>(
              'panel',
              // 用纯色代替漫画图片：采样时能明确区分内容与面板。
              content: const ColoredBox(
                color: contentColor,
                child: SizedBox.expand(),
              ),
              buildSettings: (context) => const SizedBox(),
            ),
          ),
        ),
      ),
    );
    // `.animate().fade()` 是隐式动画：必须真的把时钟推完，
    // 否则面板透明度仍是 0，采样到的全是内容色。
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final result = <int, Color>{};
    await tester.runAsync(() async {
      final boundary =
          tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final bytes = data!.buffer.asUint8List();
      final width = image.width;
      for (final y in rows) {
        final o = (y * width + 200) * 4;
        result[y] = Color.fromARGB(
          bytes[o + 3],
          bytes[o],
          bytes[o + 1],
          bytes[o + 2],
        );
      }
    });
    return result;
  }

  /// 是否与 [color] 相同（忽略 alpha）。
  bool sameColor(Color a, Color b) =>
      a.red == b.red && a.green == b.green && a.blue == b.blue;

  group('★ 控制面板的背景铺满到屏幕顶端（刘海区域不透明）', () {
    testWidgets('★ 面板上方那一条（刘海区域）必须是面板色，不能透出漫画',
        (tester) async {
      final px = await pumpReaderAndSample(tester, showPanel: true);

      // 刘海区域（y = 1..29）应当被面板背景覆盖。
      for (final y in [1, 10, 25, 29]) {
        expect(
          sameColor(px[y]!, panelColor),
          isTrue,
          reason: 'y=$y（刘海区域）应是面板背景色 $panelColor，'
              '实际 ${px[y]} —— 透出内容色说明面板背景没有铺到屏幕顶端',
        );
        expect(
          sameColor(px[y]!, contentColor),
          isFalse,
          reason: 'y=$y 仍能看见漫画内容（${px[y]}），面板上方有透明缝',
        );
      }

      // 面板本体依然是面板色。
      expect(sameColor(px[45]!, panelColor), isTrue,
          reason: 'y=45 应为面板背景色，实际 ${px[45]}');
      // 面板下方仍是漫画内容（面板没有盖住整屏）。
      expect(sameColor(px[400]!, contentColor), isTrue,
          reason: 'y=400 应仍是漫画内容，实际 ${px[400]}');
    });

    testWidgets('面板内容（标题/按钮）仍要避开刘海，不被挖孔挡住',
        (tester) async {
      final px = await pumpReaderAndSample(tester, showPanel: true);

      // 面板色连续覆盖 0..(inset + 60)；内容（图标/文字）落在 inset 之后。
      final appBar = tester.getRect(find.byType(AppBar));
      expect(appBar.top, cutoutTop,
          reason: 'AppBar 内容必须从刘海下方开始（实际 top=${appBar.top}）');
      expect(appBar.height, 60,
          reason: 'AppBar 本体高度应保持 60（实际 ${appBar.height}）');

      // 面板背景要覆盖到 y=0（比 AppBar 更靠上）。
      final background = tester.getRect(
        find.descendant(
          of: find.byType(ReaderView<ComicController>),
          matching: find.byType(SafeArea),
        ).first,
      );
      expect(background.top, lessThanOrEqualTo(0.0),
          reason: '面板背景应铺到屏幕最顶端（实际 top=${background.top}）');
      // 采样交叉验证：AppBar 正上方那一条也是面板色。
      expect(sameColor(px[cutoutTop - 1]!, panelColor), isTrue,
          reason: 'AppBar 上方 y=${cutoutTop - 1} 应为面板色，实际 ${px[cutoutTop - 1]}');
    });

    testWidgets('没有刘海 inset 时行为不变（面板仍铺满顶部）', (tester) async {
      final px = await pumpReaderAndSample(
        tester,
        showPanel: true,
        topInset: 0,
      );
      expect(sameColor(px[1]!, panelColor), isTrue,
          reason: 'y=1 应为面板色，实际 ${px[1]}');
      expect(sameColor(px[45]!, panelColor), isTrue,
          reason: 'y=45 应为面板色，实际 ${px[45]}');
      expect(sameColor(px[400]!, contentColor), isTrue,
          reason: 'y=400 应仍是漫画内容，实际 ${px[400]}');
    });

    testWidgets('面板关闭时（对照）刘海区域就是漫画内容', (tester) async {
      final px = await pumpReaderAndSample(tester, showPanel: false);
      expect(sameColor(px[1]!, contentColor), isTrue,
          reason: '面板未打开时 y=1 应是漫画内容，实际 ${px[1]}');
      expect(sameColor(px[45]!, contentColor), isTrue,
          reason: '面板未打开时 y=45 应是漫画内容，实际 ${px[45]}');
    });

    testWidgets('显示 / 隐藏面板来回切换后，背景仍然铺满顶部', (tester) async {
      final c = buildController(watcher: FakeChapterWatcher());
      addTearDown(c.onClose);
      ComicCacheConfigStore.loaderOverride = () => const ComicCacheConfig(
            enabled: false,
            preloadChapterCount: 2,
            chapterInterval: 0,
            imageInterval: 0,
            cacheOnRead: false,
            seamlessChapterSwitch: true,
          );
      addTearDown(() => ComicCacheConfigStore.loaderOverride = null);
      Get.put<ComicController>(c, tag: 'toggle');
      addTearDown(() {
        if (Get.isRegistered<ComicController>(tag: 'toggle')) {
          Get.delete<ComicController>(tag: 'toggle');
        }
      });
      await c.ensureInitialized();

      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(top: cutoutTop);
      tester.view.viewPadding = const FakeViewPadding(top: cutoutTop);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          localizationsDelegates: [_TestI18nDelegate()],
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: ReaderView<ComicController>(
              'toggle',
              content: const ColoredBox(
                color: contentColor,
                child: SizedBox.expand(),
              ),
              buildSettings: (context) => const SizedBox(),
            ),
          ),
        ),
      );
      await settle(tester);

      for (final show in [true, false, true]) {
        c.isShowControlPanel.value = show;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);

        final header = find.byType(AppBar);
        if (show) {
          expect(header, findsOneWidget);
          expect(
            tester.getRect(header).top,
            cutoutTop,
            reason: '第 $show 轮：面板内容仍应避开刘海',
          );
        } else {
          expect(header, findsNothing);
        }
      }
    });
  });
}
