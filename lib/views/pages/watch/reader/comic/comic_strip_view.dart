import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:miru_app/controllers/watch/comic_controller.dart';
import 'package:miru_app/models/index.dart';
import 'package:miru_app/views/widgets/cache_network_image.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// 条漫「连续流」视图。
///
/// 把相邻章节拼进同一条 [ScrollablePositionedList]，因此：
///   * 翻到下一话 = 继续往下滑，没有页面跳转、没有白屏；
///   * 回拉到上一话 = 继续往上滑，同样是同一条列表；
///   * 章节切换只更新「当前话」这个状态，**不重建列表**，
///     所以滚动位置、已解码的图片、滚动惯性全部保持连续（无感）。
///
/// 性能要点：
///   1. **窗口化**：列表里最多 [ComicStripModel.defaultMaxWindowChapters] 话，
///      避免超长连载一次性铺出上千张图。
///   2. **零重建**：滚动跨话时列表不重建（由控制器侧保证），
///      只有窗口内章节集合真正变化时才重建。
///   3. **像素级锚点补偿**：窗口裁剪/向前补话会让条目下标平移，
///      用「旧视口顶部条目 + 其 leadingEdge」在新列表里
///      `jumpTo(index, alignment)` 做同帧补偿，用户看不到任何跳动。
///   4. 关闭 per-item RepaintBoundary + 1 物理像素出血，消除图片接缝。
///   5. 稳定 Key：列表身份不变，避免整棵子树被销毁重建。
class ComicStripView extends StatefulWidget {
  const ComicStripView({
    super.key,
    required this.controller,
    this.itemBuilder,
  });

  final ComicController controller;

  /// 单张图片的渲染钩子。
  ///
  /// 默认渲染网络图片；测试中可注入固定高度的占位，
  /// 让滚动/锚点补偿可以在无网络环境下被确定性验证。
  final Widget Function(BuildContext context, StripItem item, int index)?
      itemBuilder;

  @override
  State<ComicStripView> createState() => ComicStripViewState();
}

class ComicStripViewState extends State<ComicStripView> {
  ComicController get _c => widget.controller;

  final List<int> _pointer = [];

  /// 上次渲染的窗口签名：只有它变化才重建列表。
  String _windowSignature = '';

  /// 当前**已渲染**的条目列表。
  ///
  /// 锚点换算必须用它（而不是刚更新的模型），否则会把「旧列表里的下标」
  /// 当成「新列表里的下标」来解读，导致位置错乱。
  List<StripItem> _renderedItems = const [];

  /// 已应用的主动跳章请求序号。
  int _appliedJumpRequest = -1;

  @override
  void initState() {
    super.initState();
    _windowSignature = _c.strip.windowSignature;
    _renderedItems = _c.strip.items;
    _appliedJumpRequest = _c.jumpChapterRequest.value;
    _c.stripRevision.listen((_) => _onStripChanged());
    _c.jumpChapterRequest.listen((_) => _onJumpRequested());
  }

  /// 窗口内容变化。
  ///
  /// `setState`（触发重建）与 `jumpTo`（设置新目标下标）在同一帧内发出，
  /// Flutter 会合并成一次 build，因此不会出现「先用旧下标画一帧、
  /// 再跳到正确位置」的闪烁。
  void _onStripChanged() {
    if (!mounted) {
      return;
    }
    final signature = _c.strip.windowSignature;
    if (signature == _windowSignature) {
      return;
    }
    // 用**旧列表**解读旧下标，得到用户视线所在的内容位置。
    final anchor = _currentTopAnchor();
    final newItems = _c.strip.items;
    int? newIndex;
    var alignment = 0.0;
    if (anchor != null) {
      newIndex = ComicStripModel.indexOfItem(
        newItems,
        anchor.chapterIndex,
        anchor.imageIndex,
      );
      alignment = anchor.leadingEdge;
    }
    // 锚点已被裁掉时退回「当前话开头」。
    newIndex ??= _c.strip.itemOffsetOfChapter(_c.index.value) ??
        _c.strip.currentChapterItemOffset;
    if (newItems.isEmpty) {
      newIndex = 0;
    } else if (newIndex >= newItems.length) {
      newIndex = newItems.length - 1;
    }
    setState(() {
      _windowSignature = signature;
    });
    _jumpToIndex(newIndex, alignment);
  }

  /// 用户主动跳章（播放列表 / 恢复进度）：瞬移到该话开头。
  void _onJumpRequested() {
    if (!mounted) {
      return;
    }
    final request = _c.jumpChapterRequest.value;
    if (request == _appliedJumpRequest) {
      return;
    }
    _appliedJumpRequest = request;
    final offset = _c.strip.itemOffsetOfChapter(_c.index.value) ??
        _c.strip.currentChapterItemOffset;
    _jumpToIndex(offset, 0);
  }

  void _jumpToIndex(int index, double alignment) {
    if (!_c.itemScrollController.isAttached) {
      return;
    }
    _c.itemScrollController.jumpTo(index: index, alignment: alignment);
  }

  /// 当前视口顶部条目（用已渲染的条目列表解读下标）。
  StripAnchor? _currentTopAnchor() {
    final positions = _c.itemPositionsListener.itemPositions.value;
    if (positions.isEmpty || _renderedItems.isEmpty) {
      return null;
    }
    final top = positions.reduce(
      (a, b) => a.itemLeadingEdge < b.itemLeadingEdge ? a : b,
    );
    final index = top.index.clamp(0, _renderedItems.length - 1);
    final item = _renderedItems[index];
    return StripAnchor(
      chapterIndex: item.chapterIndex,
      imageIndex: item.imageIndex,
      leadingEdge: top.itemLeadingEdge,
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;
    return SizedBox(
      width: width,
      height: height,
      child: const Center(
        child: Center(
          child: CircularProgressIndicator(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
  /// 依赖 stripRevision：窗口内容变化时才重建。
      _c.stripRevision.value;
      final items = _c.strip.items;
      _renderedItems = items;
      if (items.isEmpty) {
        return const Center(child: CircularProgressIndicator());
      }
      final width = MediaQuery.of(context).size.width;
      final height = MediaQuery.of(context).size.height;
      final viewPadding = width > 800 ? ((width - 800) / 2) : 0.0;
      // 防缝出血：让每张图向下多绘制 1 物理像素，相邻图片互相重叠覆盖接缝，
      // 避免分数像素边界在合成时产生抗锯齿细缝。
      final bleed = 1 / MediaQuery.of(context).devicePixelRatio;
      final headers = _c.watchData.value?.headers;

      return SizedBox(
        width: width,
        height: height,
        child: Listener(
          onPointerDown: (event) {
            _pointer.add(event.pointer);
            if (_pointer.length == 2) {
              _c.isZoom.value = true;
            }
          },
          onPointerUp: (event) {
            _pointer.remove(event.pointer);
            if (_pointer.length == 1) {
              _c.isZoom.value = false;
            }
          },
          child: InteractiveViewer(
            scaleEnabled: _c.isZoom.value,
            child: ScrollablePositionedList.builder(
              key: const ValueKey('comic-strip-list'),
              physics: _c.isZoom.value
                  ? const NeverScrollableScrollPhysics()
                  : null,
              padding: EdgeInsets.symmetric(horizontal: viewPadding),
              // 关闭每个 item 的独立 RepaintBoundary，让所有图片绘制进同一个
              // layer，消除排列在分数像素边界上的相邻图层之间合成的细缝。
              addRepaintBoundaries: false,
              initialScrollIndex: _c.strip.currentChapterItemOffset,
              itemScrollController: _c.itemScrollController,
              itemPositionsListener: _c.itemPositionsListener,
              scrollOffsetController: _c.scrollOffsetController,
              itemBuilder: (context, index) {
                final item = items[index];
                final custom = widget.itemBuilder;
                if (custom != null) {
                  return custom(context, item, index);
                }
                return CacheNetWorkImagePic(
                  item.url,
                  fit: BoxFit.fitWidth,
                  placeholder: _buildPlaceholder(context),
                  headers: headers,
                  layoutInsets: EdgeInsets.only(bottom: -bleed),
                );
              },
              itemCount: items.length,
            ),
          ),
        ),
      );
    });
  }
}
