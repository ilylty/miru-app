import 'package:flutter/material.dart';
import 'package:flutter_i18n/flutter_i18n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:miru_app/models/index.dart';
import 'package:miru_app/utils/comic_cache_config_store.dart';
import 'package:miru_app/views/widgets/platform_widget.dart';
import 'package:miru_app/views/widgets/settings/comic_cache_settings.dart';
import 'package:miru_app/views/widgets/settings/settings_expander_tile.dart';

/// 测试用翻译 delegate：用真实的 `assets/i18n/en.json`。
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

/// Android 真机上的「漫画阅读器」设置页结构：
///
///   GetMaterialApp（**没有 FluentTheme**）
///     → SettingsExpanderTile(noPage: false) 的 onTap
///     → Get.to(Scaffold(appBar, body: <content>))
///
/// 这个测试走的就是这条真实路径，所以任何一环（缺少 FluentTheme、
/// 缺少内边距、内容超出屏幕）出问题都会被抓到。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ComicCacheConfig saved;

  setUp(() {
    Get.testMode = true;
    // `Platform.isAndroid` 在 Windows/CI 上恒为 false，
    // 用它强制走 Android 分支（复刻真机布局）。
    debugForceAndroidLayout = true;
    saved = const ComicCacheConfig();
    ComicCacheConfigStore.loaderOverride = () => saved;
    ComicCacheConfigStore.saveOverride = (config) async {
      saved = config;
    };
  });

  tearDown(() {
    debugForceAndroidLayout = null;
    ComicCacheConfigStore.loaderOverride = null;
    ComicCacheConfigStore.saveOverride = null;
    Get.reset();
  });

  /// 打开「漫画阅读器」设置页（与真机一致：点一下 → Get.to 新页面）。
  Future<void> openComicReaderPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      GetMaterialApp(
        localizationsDelegates: [_TestI18nDelegate()],
        home: Scaffold(
          body: ListView(
            children: const [
              SettingsExpanderTile(
                androidIcon: Icons.image,
                title: 'Comic reader',
                subTitle: 'Comic reader subtitle',
                content: ComicCacheSettings(),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 点开进入二级页面。
    await tester.tap(find.text('Comic reader'));
    await tester.pumpAndSettle();
  }

  group('★ Android 设置页：漫画缓存面板（真实二级页面路径）', () {
    testWidgets('能在 Android（GetMaterialApp / 无 FluentTheme）下正常渲染',
        (tester) async {
      await openComicReaderPage(tester);

      expect(tester.takeException(), isNull,
          reason: 'Android 没有 FluentTheme，面板里不能用 fluent.NumberBox / '
              'fluent.ToggleSwitch 等依赖 FluentTheme.of() 的控件');

      // n / l / m 三项必须真实可见。
      expect(find.text('Preload following chapters (n)'), findsOneWidget);
      expect(find.text('Chapter cache interval (l, seconds)'), findsOneWidget);
      expect(find.text('Image cache interval (m, seconds)'), findsOneWidget);
    });

    testWidgets('n / l / m 用的是 Material 控件（不是 fluent 控件）',
        (tester) async {
      await openComicReaderPage(tester);
      expect(tester.takeException(), isNull);

      // 3 个开关：启用 / 阅读时缓存 / 无感切换。
      expect(find.byType(Switch), findsNWidgets(3));
      // 5 个数字输入：n / l / m / 并发 / 磁盘上限。
      expect(find.byType(TextField), findsNWidgets(5));
    });

    testWidgets('★ 内容比一屏高时不会 RenderFlex overflow（二级页面可滚动）',
        (tester) async {
      await openComicReaderPage(tester);

      expect(tester.takeException(), isNull,
          reason: '面板比一屏高，二级页面必须可滚动，否则会 overflow '
              '（表现为下方大片异常色块一直延伸到底部）');
      // 页面里存在可滚动容器。
      expect(find.byType(Scrollable), findsWidgets);
      // 滚到底部，确认最后一个开关可达且不报错。
      await tester.dragUntilVisible(
        find.text('Seamless webtoon chapter switching'),
        find.byType(Scrollable).last,
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Seamless webtoon chapter switching'), findsOneWidget);
    });

    testWidgets('★ 面板左右有间距，且与开关行对齐（不出现缩进不一致）',
        (tester) async {
      await openComicReaderPage(tester);

      final screen =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;

      for (final label in [
        'Preload following chapters (n)',
        'Chapter cache interval (l, seconds)',
        'Image cache interval (m, seconds)',
      ]) {
        final rect = tester.getRect(find.text(label));
        expect(rect.left, greaterThanOrEqualTo(16),
            reason: '「$label」左间距不足（屏幕宽 $screen，left=${rect.left}）');
        expect(rect.right, lessThanOrEqualTo(screen - 16),
            reason: '「$label」右间距不足（屏幕宽 $screen，right=${rect.right}）');
      }

      // 输入框也不能超出屏幕。
      final field = tester.getRect(find.byType(TextField).first);
      expect(field.right, lessThanOrEqualTo(screen),
          reason: '输入框超出屏幕右边缘');

      // 标题（裸 Text）与开关行标题（ListTile 自带 16px）必须左对齐，
      // 否则面板看起来是「错位」的。
      final headerLeft =
          tester.getRect(find.text('Comic Cache')).left;
      final numberRowLeft =
          tester.getRect(find.text('Preload following chapters (n)')).left;
      final switchRowLeft =
          tester.getRect(find.text('Enable comic cache')).left;
      expect(headerLeft, closeTo(switchRowLeft, 0.5),
          reason: '面板标题与开关行应左对齐（$headerLeft vs $switchRowLeft）');
      expect(numberRowLeft, closeTo(switchRowLeft, 0.5),
          reason: '数字行与开关行应左对齐（$numberRowLeft vs $switchRowLeft）');
    });

    testWidgets('Android 下修改「后 n 话」会写入存储', (tester) async {
      await openComicReaderPage(tester);

      await tester.enterText(find.byType(TextField).first, '7');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(saved.preloadChapterCount, 7);
    });

    testWidgets('Android 下修改话间隔 l / 图间隔 m 会写入存储', (tester) async {
      await openComicReaderPage(tester);

      await tester.enterText(find.byType(TextField).at(1), '12');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(2), '6');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(saved.chapterInterval, 12);
      expect(saved.imageInterval, 6);
    });

    testWidgets('Android 下输入非法值不会写坏配置（回退到当前值）',
        (tester) async {
      await openComicReaderPage(tester);

      await tester.enterText(find.byType(TextField).first, '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(saved.preloadChapterCount,
          ComicCacheConfig.defaultPreloadChapterCount,
          reason: '空输入不应把配置改成 0/异常值');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Android 下开关「启用漫画缓存」会写入存储', (tester) async {
      await openComicReaderPage(tester);
      expect(saved.enabled, isTrue, reason: '默认开启');

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(saved.enabled, isFalse);
    });
  });
}
