import 'package:miru_app/models/comic_cache_config.dart';

/// 条漫（webtoon）连续阅读的纯数据模型。
///
/// 目标：把相邻章节拼成一条**连续的图片流**，
/// 用户从一话末尾继续往下滑就自然进入下一话，
/// 往上回拉就自然回到上一话，中间没有跳转、没有白屏、没有位置突变。
///
/// 这个文件不依赖 Flutter，方便单元测试覆盖窗口计算与锚点换算。
class StripChapter {
  const StripChapter({
    required this.index,
    required this.urls,
    this.title = '',
    this.headers,
  });

  /// 章节在播放列表中的序号。
  final int index;

  /// 该章节的全部图片地址。
  final List<String> urls;

  /// 章节标题（仅用于 UI 展示）。
  final String title;

  /// 该章节请求所需的 headers。
  final Map<String, String>? headers;

  int get length => urls.length;

  StripChapter copyWith({
    int? index,
    List<String>? urls,
    String? title,
    Map<String, String>? headers,
  }) {
    return StripChapter(
      index: index ?? this.index,
      urls: urls ?? this.urls,
      title: title ?? this.title,
      headers: headers ?? this.headers,
    );
  }

  @override
  String toString() => 'StripChapter($index, ${urls.length} images)';
}

/// 连续流中的一个条目：属于哪一话的第几张图。
class StripItem {
  const StripItem({
    required this.chapterIndex,
    required this.imageIndex,
    required this.url,
  });

  final int chapterIndex;
  final int imageIndex;
  final String url;

  @override
  bool operator ==(Object other) =>
      other is StripItem &&
      other.chapterIndex == chapterIndex &&
      other.imageIndex == imageIndex &&
      other.url == url;

  @override
  int get hashCode => Object.hash(chapterIndex, imageIndex, url);

  @override
  String toString() => 'StripItem(c$chapterIndex#$imageIndex)';
}

/// 滚动锚点：视口顶部对应的条目及其相对位置。
class StripAnchor {
  const StripAnchor({
    required this.chapterIndex,
    required this.imageIndex,
    required this.leadingEdge,
  });

  final int chapterIndex;
  final int imageIndex;

  /// 条目上边缘相对视口上边缘的比例（0 = 正好贴顶，负值 = 已滚过去一部分）。
  final double leadingEdge;

  @override
  String toString() =>
      'StripAnchor(c$chapterIndex#$imageIndex, edge: $leadingEdge)';
}

/// 连续流的窗口模型。
///
/// 窗口 = **包含当前话的最大连续已装载章节区间**，并按 [maxWindowChapters]
/// 裁剪。因为是连续区间，列表里永远不会出现空洞，
/// 滚动过程中不会因为「缺一话」而跳变。
///
/// 裁剪（或向前补话）导致条目下标变化时，用 [indexOfItem] 精确换算新下标，
/// 配合 `jumpTo(index, alignment)` 在同一帧内做像素级补偿，
/// 用户感知不到列表被重建。
class ComicStripModel {
  ComicStripModel({
    Map<int, StripChapter>? chapters,
    int currentChapter = 0,
    int totalChapters = 1,
    int previousSpan = 2,
    int nextSpan = 2,
    int maxWindowChapters = defaultMaxWindowChapters,
  })  : _chapters = chapters ?? <int, StripChapter>{},
        _currentChapter = currentChapter,
        _totalChapters = totalChapters < 1 ? 1 : totalChapters,
        _previousSpan = previousSpan < 0 ? 0 : previousSpan,
        _nextSpan = nextSpan < 1 ? 1 : nextSpan,
        _maxWindowChapters =
            maxWindowChapters < 1 ? 1 : maxWindowChapters;

  /// 窗口最多包含多少话，防止超长连载把列表撑得过大。
  static const int defaultMaxWindowChapters = 20;

  final Map<int, StripChapter> _chapters;
  int _currentChapter;
  int _totalChapters;
  int _previousSpan;
  int _nextSpan;
  final int _maxWindowChapters;

  int get currentChapter => _currentChapter;
  int get totalChapters => _totalChapters;
  int get previousSpan => _previousSpan;
  int get nextSpan => _nextSpan;
  int get maxWindowChapters => _maxWindowChapters;

  int get lastChapter => _totalChapters - 1;

  Map<int, StripChapter> get chapters => Map.unmodifiable(_chapters);

  Set<int> get loadedChapterIndexes => _chapters.keys.toSet();

  bool hasChapter(int index) {
    if (index < 0 || index > lastChapter) {
      return false;
    }
    final chapter = _chapters[index];
    return chapter != null && chapter.urls.isNotEmpty;
  }

  StripChapter? chapterAt(int index) => _chapters[index];

  /// 登记（或更新）一个章节。
  void putChapter(StripChapter chapter) {
    if (chapter.index < 0 || chapter.index > lastChapter) {
      return;
    }
    _chapters[chapter.index] = chapter;
  }

  void removeChapter(int index) {
    _chapters.remove(index);
  }

  void updateTotalChapters(int total) {
    _totalChapters = total < 1 ? 1 : total;
  }

  /// 按生产者配置（缓存后 n 话）推导窗口跨度。
  void applyConfig(ComicCacheConfig config) {
    // 前方至少留 2 话缓冲，保证「往下滑继续读」不会撞到边界。
    _nextSpan = config.preloadChapterCount < 2 ? 2 : config.preloadChapterCount;
    _previousSpan = 1;
  }

  /// 装载时实际使用的余量。
  ///
  /// 比「当前话 ± span」再多取一话，保证用户往回拉时
  /// **在真正碰到窗口边界之前**就已经有内容了（无感切换的关键）。
  static const int prefetchMargin = 1;

  /// 需要提前拿到 URL 的章节范围（含当前话），返回闭区间 [start, end]。
  ///
  /// [forwardExtra] / [backwardExtra] 是在 [nextSpan] / [previousSpan]
  /// 之外**额外**多取的缓冲话数（余量）。
  List<int> prefetchRange({int forwardExtra = 0, int backwardExtra = 0}) =>
      rangeFor(
        center: _currentChapter,
        back: _previousSpan + (backwardExtra < 0 ? 0 : backwardExtra),
        forward: _nextSpan + (forwardExtra < 0 ? 0 : forwardExtra),
      );

  /// 任意中心章节的闭区间范围。
  List<int> rangeFor({
    required int center,
    required int back,
    required int forward,
  }) {
    final start = (center - (back < 0 ? 0 : back)).clamp(0, lastChapter);
    final end = (center + (forward < 0 ? 0 : forward)).clamp(0, lastChapter);
    final result = <int>[];
    for (var i = start; i <= end; i++) {
      result.add(i);
    }
    return result;
  }

  /// 包含当前话的最大连续已装载区间（未裁剪）。
  ({int start, int end}) get contiguousRun {
    var start = _currentChapter;
    while (start - 1 >= 0 && hasChapter(start - 1)) {
      start--;
    }
    var end = _currentChapter;
    while (end + 1 <= lastChapter && hasChapter(end + 1)) {
      end++;
    }
    return (start: start, end: end);
  }

  /// 窗口内的章节序号（升序、连续、最多 [maxWindowChapters] 话）。
  List<int> get windowChapterIndexes {
    final run = contiguousRun;
    final all = <int>[];
    for (var i = run.start; i <= run.end; i++) {
      if (hasChapter(i)) {
        all.add(i);
      }
    }
    if (all.length <= _maxWindowChapters) {
      return all;
    }
    final currentPosition = all.indexOf(_currentChapter);
    // 向前方倾斜：保留下滑继续阅读的余量。
    var from = currentPosition - (_maxWindowChapters ~/ 4);
    from = from.clamp(0, all.length - _maxWindowChapters);
    return all.sublist(from, from + _maxWindowChapters);
  }

  int get windowStart {
    final indexes = windowChapterIndexes;
    return indexes.isEmpty ? _currentChapter : indexes.first;
  }

  int get windowEnd {
    final indexes = windowChapterIndexes;
    return indexes.isEmpty ? _currentChapter : indexes.last;
  }

  /// 窗口签名：**只看章节集合**（不含图片数量）。
  ///
  /// 章节内容是追加式的（已装载的章节不会被改写），所以列表重建的唯一
  /// 原因就是「窗口里有哪些章节」变了。这样滚动跨话时不会触发任何重建。
  String get windowSignature {
    final indexes = windowChapterIndexes;
    if (indexes.isEmpty) {
      return 'empty';
    }
    return indexes.join(',');
  }

  /// 窗口展开后的扁平条目列表。
  List<StripItem> get items {
    final result = <StripItem>[];
    for (final chapterIndex in windowChapterIndexes) {
      final chapter = _chapters[chapterIndex]!;
      for (var i = 0; i < chapter.urls.length; i++) {
        result.add(StripItem(
          chapterIndex: chapterIndex,
          imageIndex: i,
          url: chapter.urls[i],
        ));
      }
    }
    return result;
  }

  int get itemCount => items.length;

  /// 该章节在窗口中的起始扁平下标；不在窗口内返回 null。
  int? itemOffsetOfChapter(int chapterIndex) {
    var offset = 0;
    for (final index in windowChapterIndexes) {
      if (index == chapterIndex) {
        return offset;
      }
      offset += _chapters[index]!.urls.length;
    }
    return null;
  }

  /// 当前话在窗口中的起始扁平下标；当前话不在窗口时返回 0。
  int get currentChapterItemOffset =>
      itemOffsetOfChapter(_currentChapter) ?? 0;

  /// 在条目列表中查找某个 (章节, 图片) 的下标。
  static int? indexOfItem(
    List<StripItem> items,
    int chapterIndex,
    int imageIndex,
  ) {
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.chapterIndex == chapterIndex &&
          item.imageIndex == imageIndex) {
        return i;
      }
    }
    return null;
  }

  /// 根据视口顶部锚点更新「当前话」，返回是否变化。
  bool updateCurrentChapter(int topChapter) {
    final clamped = topChapter.clamp(0, lastChapter);
    if (clamped == _currentChapter) {
      return false;
    }
    _currentChapter = clamped;
    return true;
  }

  /// 用户手动跳转（播放列表 / 上一话下一话按钮 / 恢复阅读进度）。
  void jumpToChapter(int chapterIndex) {
    _currentChapter = chapterIndex.clamp(0, lastChapter);
  }

  /// 需要保留的章节（渲染窗口 + 一点余量）。
  Set<int> get retainChapterIndexes {
    final indexes = windowChapterIndexes;
    if (indexes.isEmpty) {
      return {_currentChapter};
    }
    final result = <int>{};
    for (var i = indexes.first - 1; i <= indexes.last + 1; i++) {
      if (i >= 0 && i <= lastChapter) {
        result.add(i);
      }
    }
    return result;
  }

  /// 已装载章节数量的默认上限。
  ///
  /// 生产端会预先拿到「后 n 话」的 URL，这些章节不一定与当前话连续，
  /// 所以这里不用「窗口内/外」做判定，而是用总量上限 + 离当前话距离排序，
  /// 既不会误删生产端刚拿到的数据，也不会让内存无限增长。
  static const int defaultMaxLoadedChapters = 40;

  /// 丢弃离当前话最远的章节，把已装载数量收敛到 [maxKeep]。
  ///
  /// 返回被移除的章节序号。
  List<int> pruneOutsideWindow({
    int maxKeep = defaultMaxLoadedChapters,
  }) {
    if (_chapters.length <= maxKeep) {
      return const [];
    }
    final sorted = _chapters.keys.toList()
      ..sort((a, b) =>
          (b - _currentChapter).abs().compareTo((a - _currentChapter).abs()));
    final removed = <int>[];
    for (final index in sorted) {
      if (_chapters.length <= maxKeep) {
        break;
      }
      _chapters.remove(index);
      removed.add(index);
    }
    return removed;
  }

  ComicStripModel copyWith({int? currentChapter, int? totalChapters}) {
    return ComicStripModel(
      chapters: Map<int, StripChapter>.from(_chapters),
      currentChapter: currentChapter ?? _currentChapter,
      totalChapters: totalChapters ?? _totalChapters,
      previousSpan: _previousSpan,
      nextSpan: _nextSpan,
      maxWindowChapters: _maxWindowChapters,
    );
  }

  @override
  String toString() => 'ComicStripModel(current: $_currentChapter, '
      'window: $windowStart..$windowEnd, loaded: ${_chapters.keys.toList()})';
}
