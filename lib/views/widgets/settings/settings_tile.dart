import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:miru_app/views/widgets/platform_widget.dart';

class SettingsTile extends StatefulWidget {
  const SettingsTile({
    super.key,
    this.icon,
    required this.title,
    this.trailing,
    this.buildSubtitle,
    this.onTap,
    this.isCard = false,
  });
  final Widget? icon;
  final String title;
  final String Function()? buildSubtitle;
  final Function()? onTap;
  final Widget? trailing;
  final bool isCard;

  @override
  State<SettingsTile> createState() => _SettingsTileState();
}

class _SettingsTileState extends State<SettingsTile> {
  Widget _buildAndroid(BuildContext context) {
    return ListTile(
      leading: widget.icon,
      title: Text(widget.title),
      subtitle: widget.buildSubtitle != null
          ? Text(widget.buildSubtitle!.call())
          : null,
      trailing: widget.trailing,
      onTap: widget.onTap,
    );
  }

  Widget _buildDesktop(BuildContext context) {
    Widget content = Row(
      children: [
        if (widget.icon != null) ...[
          widget.icon!,
          const SizedBox(width: 16),
        ],
        // 用 Expanded 包裹：副标题较长的设置项（如漫画缓存）
        // 在窄窗口下会被挤压而不是溢出。
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.title,
                overflow: TextOverflow.ellipsis,
              ),
              if (widget.buildSubtitle != null)
                Text(
                  widget.buildSubtitle!.call(),
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                )
            ],
          ),
        ),
        const SizedBox(width: 12),
        widget.trailing ?? const SizedBox(),
      ],
    );

    if (widget.onTap != null) {
      content = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: content,
        ),
      );
    }

    if (widget.isCard) {
      return fluent.Card(
        child: content,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: content,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PlatformBuildWidget(
      androidBuilder: _buildAndroid,
      desktopBuilder: _buildDesktop,
    );
  }
}
