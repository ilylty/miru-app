import 'package:flutter_test/flutter_test.dart';
import 'package:miru_app/models/comic_cache_config.dart';
import 'package:miru_app/models/comic_strip.dart';

ComicStripModel buildModel({
  required int total,
  required int current,
  required List<int> loaded,
  int imagesPerChapter = 3,
  int maxWindowChapters = ComicStripModel.defaultMaxWindowChapters,
}) {
  final model = ComicStripModel(
    currentChapter: current,
    totalChapters: total,
    maxWindowChapters: maxWindowChapters,
  );
  for (final index in loaded) {
    model.putChapter(StripChapter(
      index: index,
      urls: List.generate(imagesPerChapter, (i) => 'c$index-i$i'),
    ));
  }
  return model;
}

void main() {
  group('窗口计算', () {
    test('窗口是包含当前话的连续已装载区间', () {
      final model = buildModel(
        total: 10,
        current: 3,
        loaded: [1, 2, 3, 4, 5, 7, 8],
      );
      expect(model.windowChapterIndexes, [1, 2, 3, 4, 5]);
      expect(model.windowStart, 1);
      expect(model.windowEnd, 5);
    });

    test('窗口不会出现空洞（章节不连续时在缺口处截断）', () {
      final model = buildModel(
        total: 10,
        current: 3,
        loaded: [0, 1, 3, 4, 5],
      );
      // 0、1 与 3 之间缺 2，所以向前只能取到 3。
      expect(model.windowChapterIndexes, [3, 4, 5]);
    });

    test('未装载的章节 hasChapter 为 false', () {
      final model = buildModel(total: 5, current: 0, loaded: [0, 1]);
      expect(model.hasChapter(0), isTrue);
      expect(model.hasChapter(1), isTrue);
      expect(model.hasChapter(2), isFalse);
      expect(model.hasChapter(-1), isFalse);
      expect(model.hasChapter(99), isFalse);
    });

    test('空 urls 的章节视为未装载（避免出现空槽位导致滚动跳变）', () {
      final model = ComicStripModel(currentChapter: 0, totalChapters: 3);
      model.putChapter(const StripChapter(index: 0, urls: []));
      expect(model.hasChapter(0), isFalse);
    });

    test('超过 maxWindowChapters 时裁剪，且当前话一定在窗口内', () {
      final model = buildModel(
        total: 60,
        current: 30,
        loaded: List.generate(60, (i) => i),
        maxWindowChapters: 10,
      );
      final window = model.windowChapterIndexes;
      expect(window.length, 10);
      expect(window.contains(30), isTrue);
      expect(window, List.generate(10, (i) => window.first + i),
          reason: '窗口必须是连续区间');
    });

    test('裁剪后仍为当前话保留向下的阅读余量', () {
      final model = buildModel(
        total: 60,
        current: 0,
        loaded: List.generate(60, (i) => i),
        maxWindowChapters: 8,
      );
      expect(model.windowChapterIndexes.first, 0);
      expect(model.windowChapterIndexes.length, 8);
    });
  });

  group('条目扁平化与下标换算', () {
    test('items 按章节顺序展开，itemOffsetOfChapter 正确', () {
      final model = buildModel(
        total: 5,
        current: 1,
        loaded: [0, 1, 2],
        imagesPerChapter: 4,
      );
      final items = model.items;
      expect(items.length, 12);
      expect(model.itemOffsetOfChapter(0), 0);
      expect(model.itemOffsetOfChapter(1), 4);
      expect(model.itemOffsetOfChapter(2), 8);
      expect(model.itemOffsetOfChapter(3), isNull);
    });

    test('★ itemOffsetOfPage 精确定位「第几话第几页」', () {
      final model = buildModel(
        total: 5,
        current: 1,
        loaded: [0, 1, 2],
        imagesPerChapter: 4,
      );
      // 第 2 话从下标 8 开始，所以它的第 3 张图是 11。
      expect(model.itemOffsetOfPage((chapterIndex: 2, imageIndex: 3)), 11);
      expect(model.itemOffsetOfPage((chapterIndex: 0, imageIndex: 0)), 0);
      expect(model.itemOffsetOfPage((chapterIndex: 1, imageIndex: 2)), 6);
    });

    test('★ itemOffsetOfPage 越界 / 未装载 / null 时返回 null', () {
      final model = buildModel(
        total: 5,
        current: 1,
        loaded: [0, 1],
        imagesPerChapter: 4,
      );
      expect(model.itemOffsetOfPage(null), isNull,
          reason: '没有页级目标时应回退到话首');
      expect(model.itemOffsetOfPage((chapterIndex: 3, imageIndex: 0)), isNull,
          reason: '该话不在窗口内');
      expect(model.itemOffsetOfPage((chapterIndex: 1, imageIndex: -1)), isNull,
          reason: '页码不能为负');
      expect(model.itemOffsetOfPage((chapterIndex: 1, imageIndex: 4)), isNull,
          reason: '页码不能超过该话张数');
    });

    test('★ 页级下标 = 话首下标 + 页内偏移（恢复位置的基础）', () {
      final model = buildModel(
        total: 5,
        current: 2,
        loaded: [0, 1, 2],
        imagesPerChapter: 5,
      );
      final chapterOffset = model.itemOffsetOfChapter(2)!;
      expect(chapterOffset, 10);
      for (var page = 0; page < 5; page++) {
        expect(
          model.itemOffsetOfPage((chapterIndex: 2, imageIndex: page)),
          chapterOffset + page,
        );
      }
    });

    test('indexOfItem 能定位任意 (章节, 图片)', () {
      final model = buildModel(
        total: 5,
        current: 1,
        loaded: [0, 1, 2],
        imagesPerChapter: 4,
      );
      final items = model.items;
      expect(ComicStripModel.indexOfItem(items, 0, 0), 0);
      expect(ComicStripModel.indexOfItem(items, 1, 0), 4);
      expect(ComicStripModel.indexOfItem(items, 2, 3), 11);
      expect(ComicStripModel.indexOfItem(items, 9, 0), isNull);
    });

    test('★ 向前补话后，同一内容的新下标 = 旧下标 + 前置条目数', () {
      final before = buildModel(
        total: 10,
        current: 2,
        loaded: [2, 3, 4],
        imagesPerChapter: 5,
      );
      final oldItems = before.items;
      final oldIndex = ComicStripModel.indexOfItem(oldItems, 2, 3);
      expect(oldIndex, 3);

      final after = buildModel(
        total: 10,
        current: 2,
        loaded: [0, 1, 2, 3, 4],
        imagesPerChapter: 5,
      );
      final newItems = after.items;
      final newIndex = ComicStripModel.indexOfItem(newItems, 2, 3);
      expect(newIndex, 13, reason: '前置 2 话 * 5 图 = 10，3 + 10 = 13');
      expect(newIndex! - oldIndex!, 10);
    });

    test('★ 向后裁剪后，同一内容的新下标 = 旧下标 - 被裁掉的条目数', () {
      final before = buildModel(
        total: 40,
        current: 20,
        loaded: List.generate(40, (i) => i),
        imagesPerChapter: 2,
        maxWindowChapters: 30,
      );
      final oldIndex = ComicStripModel.indexOfItem(before.items, 20, 1);
      final after = buildModel(
        total: 40,
        current: 20,
        loaded: List.generate(40, (i) => i),
        imagesPerChapter: 2,
        maxWindowChapters: 10,
      );
      final newIndex = ComicStripModel.indexOfItem(after.items, 20, 1);
      expect(oldIndex, isNotNull);
      expect(newIndex, isNotNull);
      expect(newIndex! < oldIndex!, isTrue,
          reason: '窗口向前裁剪后下标应该变小');
    });
  });

  group('当前话更新', () {
    test('updateCurrentChapter 只在真的变化时返回 true', () {
      final model = buildModel(total: 5, current: 0, loaded: [0, 1, 2]);
      expect(model.updateCurrentChapter(0), isFalse);
      expect(model.updateCurrentChapter(1), isTrue);
      expect(model.currentChapter, 1);
      expect(model.updateCurrentChapter(1), isFalse);
    });

    test('越界的章节会被 clamp 到合法范围', () {
      final model = buildModel(total: 5, current: 0, loaded: [0, 1]);
      model.updateCurrentChapter(99);
      expect(model.currentChapter, 4);
      model.updateCurrentChapter(-5);
      expect(model.currentChapter, 0);
    });

    test('jumpToChapter 用于用户主动跳转 / 恢复进度', () {
      final model = buildModel(total: 10, current: 0, loaded: [0, 5]);
      model.jumpToChapter(5);
      expect(model.currentChapter, 5);
      expect(model.windowChapterIndexes, [5]);
    });
  });

  group('预取范围', () {
    test('prefetchRange 覆盖前后缓冲', () {
      final model = ComicStripModel(
        currentChapter: 5,
        totalChapters: 20,
        previousSpan: 1,
        nextSpan: 3,
      );
      expect(model.prefetchRange(), [4, 5, 6, 7, 8]);
    });

    test('prefetchRange 不会越界', () {
      final model = ComicStripModel(
        currentChapter: 0,
        totalChapters: 3,
        previousSpan: 1,
        nextSpan: 5,
      );
      expect(model.prefetchRange(), [0, 1, 2]);
    });

    test('applyConfig 让窗口跨度跟随「缓存后 n 话」', () {
      final model = ComicStripModel(currentChapter: 5, totalChapters: 20);
      model.applyConfig(const ComicCacheConfig(preloadChapterCount: 4));
      expect(model.prefetchRange(), [4, 5, 6, 7, 8, 9]);
    });

    test('n 很小时仍保留至少 2 话向下缓冲（保证滑动不撞边界）', () {
      final model = ComicStripModel(currentChapter: 5, totalChapters: 20);
      model.applyConfig(const ComicCacheConfig(preloadChapterCount: 0));
      expect(model.nextSpan, greaterThanOrEqualTo(2));
    });

    test('rangeFor 可针对任意中心章节计算范围', () {
      final model = ComicStripModel(currentChapter: 0, totalChapters: 20);
      expect(model.rangeFor(center: 10, back: 1, forward: 2),
          [9, 10, 11, 12]);
    });
  });

  group('内存收敛（长时间阅读不爆内存）', () {
    test('已装载数量超过上限时，丢弃离当前话最远的章节', () {
      final model = buildModel(
        total: 100,
        current: 50,
        loaded: List.generate(100, (i) => i),
      );
      expect(model.loadedChapterIndexes.length, 100);
      final removed = model.pruneOutsideWindow(maxKeep: 20);
      expect(model.loadedChapterIndexes.length, 20);
      expect(removed.length, 80);
      expect(model.hasChapter(50), isTrue);
      expect(model.hasChapter(51), isTrue);
      expect(model.hasChapter(0), isFalse);
      expect(model.hasChapter(99), isFalse);
    });

    test('未超过上限时不丢弃任何章节', () {
      final model = buildModel(total: 5, current: 0, loaded: [0, 1, 2]);
      expect(model.pruneOutsideWindow(maxKeep: 20), isEmpty);
      expect(model.loadedChapterIndexes.length, 3);
    });
  });

  group('windowSignature 语义（决定是否重建列表）', () {
    test('章节集合不变 → 签名不变（滚动跨话不触发重建）', () {
      final model = buildModel(total: 10, current: 3, loaded: [2, 3, 4, 5]);
      final before = model.windowSignature;
      // 模拟滚动跨话：只改当前话，章节集合不变。
      model.jumpToChapter(4);
      expect(model.windowSignature, before);
    });

    test('新增章节 → 签名变化（需要重建列表）', () {
      final model = buildModel(total: 10, current: 3, loaded: [3]);
      final before = model.windowSignature;
      model.putChapter(const StripChapter(index: 4, urls: ['x']));
      expect(model.windowSignature, isNot(before));
    });

    test('空窗口签名稳定', () {
      final model = ComicStripModel(currentChapter: 0, totalChapters: 5);
      expect(model.windowSignature, 'empty');
      expect(model.items, isEmpty);
    });
  });

  group('StripAnchor', () {
    test('锚点保存内容位置与相对偏移', () {
      const anchor = StripAnchor(
        chapterIndex: 3,
        imageIndex: 7,
        leadingEdge: -0.25,
      );
      expect(anchor.chapterIndex, 3);
      expect(anchor.imageIndex, 7);
      expect(anchor.leadingEdge, -0.25);
    });
  });
}
