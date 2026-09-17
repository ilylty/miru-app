import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:miru_app/models/index.dart';
import 'package:miru_app/views/pages/watch/reader/comic/comic_strip_view.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'comic_strip_seamless_test.dart'
    show
        FakeChapterWatcher,
        buildController,
        itemHeight,
        imagesPerChapter,
        settle;

/// ★ 长距离连续滚动压力测试。
///
/// 这是「像瀑布流一样无感」的核心验收：
/// 用户一直往下滑（或一直往上回拉），必须**永远有内容**，
/// 不能滑到列表尽头变成死路，也不能出现位置跳变。
void main() {
  setUp(() => Get.testMode = true);
  tearDown(() => Get.reset());

  /// 把控制器接入 GetX（触发 onInit，滚动监听器才会被挂上）。
  void register(dynamic controller) {
    Get.put<dynamic>(controller, tag: 'stress');
    addTearDown(() {
      if (Get.isRegistered<dynamic>(tag: 'stress')) {
        Get.delete<dynamic>(tag: 'stress');
      }
    });
  }

  /// 记录列表被重建（setState 导致 itemCount 变化）的次数。
  Future<ComicStripViewState> pumpStrip(
    WidgetTester tester, dynamic controller,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
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
                color: Colors.primaries[
                    item.chapterIndex % Colors.primaries.length],
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    return tester.state<ComicStripViewState>(find.byType(ComicStripView));
  }

  /// 连续向下滑动 [steps] 次，每次滑动一个图片高度。
  ///
  /// 每次滑动后都要把 fake 时钟推进超过控制器的滚动节流窗口
  /// （120ms），否则「顶部条目变化」的回调不会被触发。
  Future<void> scrollDown(WidgetTester tester, int steps) async {
    for (var i = 0; i < steps; i++) {
      await tester.drag(
        find.byType(ScrollablePositionedList),
        const Offset(0, -itemHeight),
      );
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
    }
  }

  Future<void> scrollUp(WidgetTester tester, int steps) async {
    for (var i = 0; i < steps; i++) {
      await tester.drag(
        find.byType(ScrollablePositionedList),
        const Offset(0, itemHeight),
      );
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
    }
  }

  group('★ 长距离滚动压力：永远不会滑到尽头', () {
    testWidgets('连续下滑 5 话：窗口持续向前扩展，始终还有后续内容',
        (tester) async {
      final watcher = FakeChapterWatcher();
      final c = buildController(watcher: watcher);
      addTearDown(c.onClose);
      register(c);
      await c.ensureInitialized();
      await c.ensureStripWindow(0);
      await pumpStrip(tester, c);

      // 每滑过一话，窗口末端都必须还在「当前话」之后至少一话
      // （除非已经读到最后一话）。
      final last = c.playList.length - 1;
      for (var chapter = 0; chapter < 5; chapter++) {
        // 滑过一整话（4 张图）再多滑一点，跨到下一话。
        await scrollDown(tester, imagesPerChapter + 1);

        final current = c.index.value;
        final windowEnd = c.strip.windowEnd;
        expect(current, greaterThanOrEqualTo(chapter),
            reason: '滚动应该推进当前话');
        if (current < last) {
          expect(windowEnd, greaterThan(current),
              reason: '当前话 $current 之后必须还有已装载的章节，'
                  '否则用户会滑到尽头（窗口 $windowEnd）');
        }
        expect(c.strip.hasChapter(current), isTrue,
            reason: '当前话必须始终是已装载的');
      }

      // 确实读到了后面的章节（不是停在原地）。
      expect(c.index.value, greaterThanOrEqualTo(4));
      expect(c.strip.loadedChapterIndexes.length, greaterThanOrEqualTo(5));
    });

    testWidgets('一直往下滑 12 话：不越界、不卡死、内存不爆', (tester) async {
      final watcher = FakeChapterWatcher();
      final c = buildController(watcher: watcher);
      addTearDown(c.onClose);
      register(c);
      await c.ensureInitialized();
      await c.ensureStripWindow(0);
      await pumpStrip(tester, c);

      // 一共 6 话，滑 12 话的量：应该在最后一话自然停住，不抛异常。
      await scrollDown(tester, (imagesPerChapter + 1) * 12);

      expect(c.index.value, lessThanOrEqualTo(c.playList.length - 1));
      expect(c.strip.loadedChapterIndexes.length,
          lessThanOrEqualTo(ComicStripModel.defaultMaxLoadedChapters),
          reason: '长距离阅读后已装载章节数必须收敛（内存不爆）');
      expect(tester.takeException(), isNull);
    });

    testWidgets('★ 连续回拉：往上滑回第 0 话，位置与内容都正确',
        (tester) async {
      final watcher = FakeChapterWatcher();
      final c = buildController(watcher: watcher, playIndex: 4);
      addTearDown(c.onClose);
      register(c);
      await c.ensureInitialized();
      await c.ensureStripWindow(4);
      await pumpStrip(tester, c);

      expect(c.index.value, 4);

      // 一直往回拉，应该能回到第 0 话。
      await scrollUp(tester, (imagesPerChapter + 1) * 6);

      expect(c.index.value, 0,
          reason: '回拉应该能一路回到第一话，中途不能卡住');
      expect(c.strip.hasChapter(0), isTrue);
      // 第 0 话的内容确实在列表里。
      expect(c.strip.windowStart, 0);
    });

    testWidgets('★ 来回横跳（下一话→上一话→下一话）不丢内容、不报错',
        (tester) async {
      final watcher = FakeChapterWatcher();
      final c = buildController(watcher: watcher, playIndex: 2);
      addTearDown(c.onClose);
      register(c);
      await c.ensureInitialized();
      await c.ensureStripWindow(2);
      await pumpStrip(tester, c);

      for (var round = 0; round < 4; round++) {
        await scrollDown(tester, imagesPerChapter + 1);
        await settle(tester);
        await tester.pump(const Duration(milliseconds: 200));
        await settle(tester);
        final down = c.index.value;
        expect(c.strip.hasChapter(down), isTrue,
            reason: '第 $round 轮下滑后当前话必须已装载');

        await scrollUp(tester, imagesPerChapter + 1);
        await settle(tester);
        await tester.pump(const Duration(milliseconds: 200));
        await settle(tester);
        final up = c.index.value;
        expect(c.strip.hasChapter(up), isTrue,
            reason: '第 $round 轮回拉后当前话必须已装载');
      }

      expect(tester.takeException(), isNull);
      expect(c.strip.loadedChapterIndexes.length,
          lessThanOrEqualTo(ComicStripModel.defaultMaxLoadedChapters));
    });

    testWidgets('★ 快速长距离滚动不会因为窗口装载而抛异常（并最终稳定）',
        (tester) async {
      final watcher = FakeChapterWatcher();
      final c = buildController(watcher: watcher);
      addTearDown(c.onClose);
      register(c);
      await c.ensureInitialized();
      await c.ensureStripWindow(0);
      await pumpStrip(tester, c);

      // 连续的大幅度 fling（模拟用户猛滑）。
      for (var i = 0; i < 6; i++) {
        await tester.fling(
          find.byType(ScrollablePositionedList),
          const Offset(0, -itemHeight * 6),
          4000,
        );
        await settle(tester, maxFrames: 60);
        await tester.pump(const Duration(milliseconds: 200));
        await settle(tester, maxFrames: 60);
      }

      expect(tester.takeException(), isNull);
      expect(c.index.value, inInclusiveRange(0, c.playList.length - 1));
      expect(c.strip.hasChapter(c.index.value), isTrue);
    });
  });
}
