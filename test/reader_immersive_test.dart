import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:miru_app/controllers/watch/comic_controller.dart';
import 'package:miru_app/controllers/watch/novel_controller.dart';
import 'package:miru_app/data/services/database_service.dart';
import 'package:miru_app/models/index.dart';
import 'package:miru_app/utils/comic_cache_config_store.dart';
import 'package:miru_app/utils/immersive_mode.dart';
import 'package:miru_app/utils/miru_storage.dart';
import 'package:miru_app/views/pages/watch/reader/comic/comic_reader_content.dart';
import 'package:miru_app/views/pages/watch/reader/comic/comic_strip_view.dart';
import 'package:miru_app/views/pages/watch/reader/novel/novel_reader_content.dart';
import 'package:miru_app/views/widgets/platform_widget.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'comic_strip_seamless_test.dart'
    show FakeChapterWatcher, FakeExtensionService, buildController, settle;

/// ★ 阅读时状态栏与底部「小白条」（手势导航条）必须隐藏 —— 沉浸式阅读。
///
/// 用户报告：Android 上阅读漫画时状态栏和底部小白条没有沉浸。
///
/// 这条链路的真实形态是：
///   `ComicReader`/`NovelReader` → `Get.put(<Reader>Controller)`
///   → `ReaderController.onInit()` → 隐藏系统栏
///   → 退出阅读器 → `ReaderController.onClose()` → 恢复系统栏
///
/// 验证手段有两层：
///   1. **平台通道**：`SystemChrome.setEnabledSystemUIMode` 最终会走
///      `SystemChannels.platform`，拦截它就能确定「到底有没有要求隐藏系统栏、
///      隐藏成哪种模式」。这是本测试的核心证据。
///   2. **真实渲染几何**：把系统栏 inset（`tester.view.padding`）设成非 0，
///      再断言阅读内容铺满整屏。只要代码里还残留 `SafeArea`，内容就会被
///      缩进 inset 那么多 —— 那正是「状态栏位置一条黑边」的成因。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 小说控制器会读 `novelFontSize` 设置。用真实的 Hive（临时目录）代替
  // `MiruStorage.ensureInitialized()`（那还会拉起 Isar / path_provider，
  // 在单测环境里不可用）。
  late Directory hiveDir;
  setUpAll(() async {
    hiveDir = Directory.systemTemp.createTempSync('miru_immersive_hive');
    Hive.init(hiveDir.path);
    MiruStorage.settings = await Hive.openBox('settings');
    await MiruStorage.settings.put(SettingKey.novelFontSize, 18.0);
  });
  tearDownAll(() async {
    await Hive.close();
    try {
      hiveDir.deleteSync(recursive: true);
    } catch (_) {
      // 临时目录清理失败不影响测试结论。
    }
  });

  /// 拦截 `SystemChannels.platform` 上发出的所有调用。
  List<MethodCall> installSystemChromeSpy() {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    return calls;
  }

  /// 最后一次「设置系统 UI 模式」请求的参数（没有则返回 null）。
  String? lastUiMode(List<MethodCall> calls) {
    final modes = calls
        .where((c) => c.method == 'SystemChrome.setEnabledSystemUIMode')
        .map((c) => c.arguments as String)
        .toList();
    return modes.isEmpty ? null : modes.last;
  }

  setUp(() {
    Get.testMode = true;
    ImmersiveMode.reset();
    debugForceAndroidLayout = true;
  });

  tearDown(() {
    ImmersiveMode.reset();
    debugForceAndroidLayout = null;
    DatabaseService.historyLoaderOverride = null;
    Get.reset();
  });

  const webtoonConfig = ComicCacheConfig(
    enabled: false,
    preloadChapterCount: 2,
    chapterInterval: 0,
    imageInterval: 0,
    cacheOnRead: false,
    seamlessChapterSwitch: true,
  );

  /// 造一个真实接入 GetX 生命周期的漫画控制器（`Get.put` → `onInit`）。
  Future<ComicController> putComicController(WidgetTester tester,
      {String tag = 'immersive-comic'}) async {
    ComicCacheConfigStore.loaderOverride = () => webtoonConfig;
    addTearDown(() => ComicCacheConfigStore.loaderOverride = null);

    final controller = buildController(
      watcher: FakeChapterWatcher(),
      config: webtoonConfig,
    );
    addTearDown(controller.onClose);

    Get.put<ComicController>(controller, tag: tag);
    addTearDown(() {
      if (Get.isRegistered<ComicController>(tag: tag)) {
        Get.delete<ComicController>(tag: tag);
      }
    });
    await controller.ensureInitialized();
    await tester.pump();
    return controller;
  }

  group('★ Android 阅读器沉浸模式（隐藏状态栏 + 底部小白条）', () {
    testWidgets('进入漫画阅读器会要求隐藏系统栏（immersiveSticky）',
        (tester) async {
      final calls = installSystemChromeSpy();

      await putComicController(tester);

      expect(
        lastUiMode(calls),
        'SystemUiMode.immersiveSticky',
        reason: '阅读时状态栏与底部小白条都应被隐藏',
      );
    });

    testWidgets('退出阅读器会恢复系统栏（edgeToEdge）', (tester) async {
      final calls = installSystemChromeSpy();

      final c = await putComicController(tester);
      expect(lastUiMode(calls), 'SystemUiMode.immersiveSticky');

      c.onClose();
      await tester.pump();

      expect(
        lastUiMode(calls),
        'SystemUiMode.edgeToEdge',
        reason: '退出阅读器必须把系统栏还回来，否则整个 App 都会少一条',
      );
    });

    testWidgets('★ 阅读内容铺满整屏：不再被系统栏 inset 缩进（黑边的成因）',
        (tester) async {
      installSystemChromeSpy();

      final c = await putComicController(tester);

      // 模拟真机：状态栏 30、底部小白条 20。
      // immersiveSticky 下 Flutter 的 `MediaQuery.padding` 仍会报告这些 inset，
      // 所以只要代码里还留着 `SafeArea`，内容就会被缩进 30/20 ——
      // 屏幕上表现为阅读器顶部/底部各一条黑边。
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(top: 30, bottom: 20);
      tester.view.viewPadding = const FakeViewPadding(top: 30, bottom: 20);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        GetMaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          // 与真机一致：`Scaffold(body: ComicReaderContent(...))`，没有 SafeArea。
          home: const Scaffold(
            body: ComicReaderContent('immersive-comic'),
          ),
        ),
      );
      await settle(tester);

      expect(tester.takeException(), isNull);
      expect(c.isSeamlessStrip, isTrue);

      final rect = tester.getRect(find.byType(ComicStripView));
      expect(rect.top, 0,
          reason: '顶部不能有状态栏宽度的空白（实际 ${rect.top}）');
      expect(rect.height, 800,
          reason: '内容高度应等于整屏（实际 ${rect.height}）');
      expect(rect.bottom, 800,
          reason: '底部不能有小白条宽度的空白（实际 ${rect.bottom}）');
    });

    testWidgets('小说阅读器同样进入沉浸模式', (tester) async {
      final calls = installSystemChromeSpy();

      final runtime = FakeExtensionService(
        (url) async => ExtensionFikushonWatch(
          content: List.generate(20, (i) => '第 $i 段内容'),
          title: 'Test Novel',
        ),
      );
      // 小说控制器在 watchData 就绪后会读历史记录（真实环境走 Isar，
      // 单测里用注入点代替）。
      DatabaseService.historyLoaderOverride = (package, url) async => null;
      final c = NovelController(
        title: 'Test Novel',
        playList: List.generate(
          3,
          (i) => ExtensionEpisode(
            name: 'Chapter ${i + 1}',
            url: 'https://example.com/novel?ep=$i',
          ),
        ),
        detailUrl: 'https://example.com/novel',
        playIndex: 0,
        episodeGroupId: 0,
        runtime: runtime,
        cover: null,
        anilistID: '',
      );

      // 直接跑真实生命周期入口，避免依赖 GetX 的删除流程（小说控制器关闭时
      // 会写历史记录，需要 Isar）。
      c.onInit();
      await tester.pump();
      expect(lastUiMode(calls), 'SystemUiMode.immersiveSticky',
          reason: '小说阅读同样应隐藏系统栏');

      Get.put<NovelController>(c, tag: 'immersive-novel');
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(top: 30, bottom: 20);
      tester.view.viewPadding = const FakeViewPadding(top: 30, bottom: 20);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        GetMaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: const Scaffold(
            body: NovelReaderContent('immersive-novel'),
          ),
        ),
      );
      await settle(tester);

      expect(tester.takeException(), isNull);
      final listRect = tester.getRect(find.byType(ScrollablePositionedList));
      expect(listRect.top, 0,
          reason: '小说正文顶部不能有状态栏宽度的空白（实际 ${listRect.top}）');
      expect(listRect.height, 800,
          reason: '小说正文高度应等于整屏（实际 ${listRect.height}）');
    });

    testWidgets('阅读器叠着打开时，只有最后一个关闭才恢复系统栏', (tester) async {
      final calls = installSystemChromeSpy();

      final first = buildController(
        watcher: FakeChapterWatcher(),
        config: webtoonConfig,
      );
      final second = buildController(
        watcher: FakeChapterWatcher(),
        config: webtoonConfig,
      );
      ComicCacheConfigStore.loaderOverride = () => webtoonConfig;
      addTearDown(() => ComicCacheConfigStore.loaderOverride = null);
      addTearDown(first.onClose);
      addTearDown(second.onClose);

      Get.put<ComicController>(first, tag: 'immersive-a');
      Get.put<ComicController>(second, tag: 'immersive-b');
      await tester.pump();
      expect(lastUiMode(calls), 'SystemUiMode.immersiveSticky');

      first.onClose();
      await tester.pump();
      expect(
        lastUiMode(calls),
        'SystemUiMode.immersiveSticky',
        reason: '还有一个阅读器开着时，系统栏不能提前弹回来',
      );

      second.onClose();
      await tester.pump();
      expect(lastUiMode(calls), 'SystemUiMode.edgeToEdge');
    });

    testWidgets('桌面平台不会去动系统栏（Android 专属行为）', (tester) async {
      debugForceAndroidLayout = false;
      final calls = installSystemChromeSpy();

      await putComicController(tester, tag: 'immersive-desktop');

      expect(
        lastUiMode(calls),
        isNull,
        reason: '桌面窗口没有状态栏/小白条，不应发出 Android 专属调用',
      );
    });
  });
}
