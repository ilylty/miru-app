import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_i18n/flutter_i18n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miru_app/models/index.dart';
import 'package:miru_app/utils/comic_cache_config_store.dart';
import 'package:miru_app/views/widgets/settings/comic_cache_settings.dart';

/// 测试用翻译 delegate：用真实的 `assets/i18n/en.json`。
///
/// 这样设置面板走的是**生产代码同一条 i18n 链路**，
/// 标题文本就是用户真正看到的英文文案，测试可以按文案定位控件。
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ComicCacheConfig saved;
  var saveCount = 0;

  setUp(() {
    saved = const ComicCacheConfig();
    saveCount = 0;
    ComicCacheConfigStore.loaderOverride = () => saved;
    ComicCacheConfigStore.saveOverride = (config) async {
      saved = config;
      saveCount++;
    };
  });

  tearDown(() {
    ComicCacheConfigStore.loaderOverride = null;
    ComicCacheConfigStore.saveOverride = null;
  });

  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.pumpWidget(
      fluent.FluentApp(
        localizationsDelegates: [_TestI18nDelegate()],
        home: const fluent.ScaffoldPage(
          header: fluent.PageHeader(title: Text('settings')),
          content: SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: ComicCacheSettings(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 按可见文案定位某个配置行的 NumberBox。
  fluent.NumberBox<num> numberBoxFor(WidgetTester tester, String label) {
    final row = find.ancestor(
      of: find.text(label),
      matching: find.byType(Row),
    );
    expect(row, findsWidgets, reason: '没找到文案为 "$label" 的配置行');
    return tester.widget<fluent.NumberBox<num>>(
      find
          .descendant(
              of: row.first, matching: find.byType(fluent.NumberBox<num>))
          .first,
    );
  }

  /// 按可见文案定位开关。
  fluent.ToggleSwitch toggleFor(WidgetTester tester, String label) {
    final row = find.ancestor(
      of: find.text(label),
      matching: find.byType(Row),
    );
    expect(row, findsWidgets, reason: '没找到文案为 "$label" 的开关行');
    return tester.widget<fluent.ToggleSwitch>(
      find
          .descendant(
              of: row.first, matching: find.byType(fluent.ToggleSwitch))
          .first,
    );
  }

  const kPreload = 'Preload following chapters (n)';
  const kChapterInterval = 'Chapter cache interval (l, seconds)';
  const kImageInterval = 'Image cache interval (m, seconds)';
  const kEnabled = 'Enable comic cache';
  const kCacheOnRead = 'Cache while reading';
  const kSeamless = 'Seamless webtoon chapter switching';

  group('★ 设置页：漫画缓存配置面板（真实 i18n 链路）', () {
    testWidgets('面板渲染出全部可配置项，且 n / l / m 三项都在界面上',
        (tester) async {
      await pumpPanel(tester);

      // n / l / m 三个关键配置项必须真实可见（用户能配到）。
      expect(find.text(kPreload), findsOneWidget);
      expect(find.text(kChapterInterval), findsOneWidget);
      expect(find.text(kImageInterval), findsOneWidget);
      expect(find.text(kEnabled), findsOneWidget);
      expect(find.text(kCacheOnRead), findsOneWidget);
      expect(find.text(kSeamless), findsOneWidget);

      // 5 个数字项：n、l、m、并发、磁盘上限。
      expect(find.byType(fluent.NumberBox<num>), findsNWidgets(5));
      // 3 个开关：启用、阅读时缓存、条漫无感切换。
      expect(find.byType(fluent.ToggleSwitch), findsNWidgets(3));
    });

    testWidgets('n / l / m 的取值范围被正确约束', (tester) async {
      await pumpPanel(tester);

      final n = numberBoxFor(tester, kPreload);
      expect(n.min, ComicCacheConfig.minPreloadChapterCount);
      expect(n.max, ComicCacheConfig.maxPreloadChapterCount);
      expect(n.value, ComicCacheConfig.defaultPreloadChapterCount);

      final l = numberBoxFor(tester, kChapterInterval);
      expect(l.min, 0, reason: 'l 可以为 0（不限速）');
      expect(l.max, ComicCacheConfig.maxIntervalSeconds);

      final m = numberBoxFor(tester, kImageInterval);
      expect(m.min, 0, reason: 'm 可以为 0（不限速）');
      expect(m.max, ComicCacheConfig.maxIntervalSeconds);
    });

    testWidgets('修改「后 n 话」会写入存储并广播变更', (tester) async {
      await pumpPanel(tester);

      numberBoxFor(tester, kPreload).onChanged!(7);
      await tester.pumpAndSettle();

      expect(saved.preloadChapterCount, 7);
      expect(saveCount, 1);
    });

    testWidgets('修改话间隔 l 会写入存储', (tester) async {
      await pumpPanel(tester);

      numberBoxFor(tester, kChapterInterval).onChanged!(11);
      await tester.pumpAndSettle();

      expect(saved.chapterInterval, 11);
    });

    testWidgets('修改图间隔 m 会写入存储', (tester) async {
      await pumpPanel(tester);

      numberBoxFor(tester, kImageInterval).onChanged!(3);
      await tester.pumpAndSettle();

      expect(saved.imageInterval, 3);
    });

    testWidgets('n / l / m 三者互不干扰（改一个不影响其它两个）', (tester) async {
      await pumpPanel(tester);

      numberBoxFor(tester, kPreload).onChanged!(9);
      await tester.pumpAndSettle();
      numberBoxFor(tester, kChapterInterval).onChanged!(5);
      await tester.pumpAndSettle();
      numberBoxFor(tester, kImageInterval).onChanged!(2);
      await tester.pumpAndSettle();

      expect(saved.preloadChapterCount, 9);
      expect(saved.chapterInterval, 5);
      expect(saved.imageInterval, 2);
      // 三次修改各自落盘一次。
      expect(saveCount, 3);
    });

    testWidgets('切换「启用漫画缓存」会写入存储', (tester) async {
      await pumpPanel(tester);
      expect(saved.enabled, isTrue, reason: '默认开启');

      final toggle = toggleFor(tester, kEnabled);
      toggle.onChanged!(!toggle.checked);
      await tester.pumpAndSettle();

      expect(saved.enabled, isFalse);
    });

    testWidgets('切换「条漫无感切换」会写入存储', (tester) async {
      await pumpPanel(tester);

      final toggle = toggleFor(tester, kSeamless);
      expect(toggle.checked, isTrue, reason: '默认开启无感切换');
      toggle.onChanged!(!toggle.checked);
      await tester.pumpAndSettle();

      expect(saved.seamlessChapterSwitch, isFalse);
    });

    testWidgets('切换「阅读时顺带缓存」会写入存储', (tester) async {
      await pumpPanel(tester);

      final toggle = toggleFor(tester, kCacheOnRead);
      expect(toggle.checked, isTrue, reason: '默认开启阅读时缓存');
      toggle.onChanged!(!toggle.checked);
      await tester.pumpAndSettle();

      expect(saved.cacheOnRead, isFalse);
    });

    testWidgets('面板展示的是当前存储里的值（重进设置页能恢复）', (tester) async {
      saved = const ComicCacheConfig(
        enabled: false,
        preloadChapterCount: 6,
        chapterInterval: 9,
        imageInterval: 4,
        seamlessChapterSwitch: false,
      );
      await pumpPanel(tester);

      expect(numberBoxFor(tester, kPreload).value, 6);
      expect(numberBoxFor(tester, kChapterInterval).value, 9);
      expect(numberBoxFor(tester, kImageInterval).value, 4);
      expect(toggleFor(tester, kEnabled).checked, isFalse);
      expect(toggleFor(tester, kSeamless).checked, isFalse);
    });
  });

  group('★ 端到端：设置页 → 存储 → 阅读器', () {
    testWidgets('在设置面板改 n / l / m 后，存储往返一致且订阅者被唤醒',
        (tester) async {
      await pumpPanel(tester);

      // 1) 用户操作设置面板。
      numberBoxFor(tester, kPreload).onChanged!(5);
      await tester.pumpAndSettle();
      numberBoxFor(tester, kChapterInterval).onChanged!(12);
      await tester.pumpAndSettle();
      numberBoxFor(tester, kImageInterval).onChanged!(6);
      await tester.pumpAndSettle();

      expect(saved.preloadChapterCount, 5);
      expect(saved.chapterInterval, 12);
      expect(saved.imageInterval, 6);

      // 2) 序列化往返：写出去的内容能原样读回来。
      final roundTripped =
          ComicCacheConfigStore.decode(ComicCacheConfigStore.encode(saved));
      expect(roundTripped.preloadChapterCount, 5);
      expect(roundTripped.chapterInterval, 12);
      expect(roundTripped.imageInterval, 6);

      // 3) 变更通知：阅读器监听 revision → 会重新 load() 拿到新配置。
      //    把回调里读到的值收集起来，等 pump 结束后再断言
      //    （不在 notifyListeners 同步回调里做 expect，避免测试守卫报错）。
      var notified = 0;
      final seenByReader = <ComicCacheConfig>[];
      void listener() {
        notified++;
        seenByReader.add(ComicCacheConfigStore.load());
      }

      ComicCacheConfigStore.revision.addListener(listener);
      addTearDown(() => ComicCacheConfigStore.revision.removeListener(listener));

      numberBoxFor(tester, kImageInterval).onChanged!(7);
      await tester.pumpAndSettle();

      expect(notified, greaterThan(0),
          reason: '保存配置必须通知阅读器，否则设置不能即时生效');
      expect(seenByReader, isNotEmpty);
      // 阅读器在被唤醒时读到的是最新配置。
      expect(seenByReader.last.preloadChapterCount, 5);
      expect(seenByReader.last.chapterInterval, 12);
      expect(seenByReader.last.imageInterval, 7);
      expect(saved.imageInterval, 7);
    });
  });
}
