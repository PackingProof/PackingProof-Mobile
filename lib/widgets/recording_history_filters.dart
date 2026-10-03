import 'package:flutter/material.dart';

import 'text_selection_menu.dart';

/// 历史页筛选胶囊的内容：显示名、是否高亮、点击后打开哪个筛选面板。
typedef RecordingHistoryFilterChipData = ({
  String label,
  bool selected,
  VoidCallback onPressed,
});

/// 历史页顶部的搜索框与筛选胶囊。
///
/// 搜索与筛选是一组控件：拆开单独放会让「搜什么」和「筛什么」分散在两处，
/// 所以一起放在这里。筛选状态与分页仍由屏幕持有，这里只负责呈现与回调。
class RecordingHistoryFilters extends StatelessWidget {
  const RecordingHistoryFilters({
    super.key,
    required this.searchController,
    required this.hasQuery,
    required this.onSearchChanged,
    required this.onPasteSearch,
    required this.onClearSearch,
    required this.source,
    required this.date,
    this.onScan,
  });

  final TextEditingController searchController;
  final bool hasQuery;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onPasteSearch;
  final VoidCallback onClearSearch;
  final RecordingHistoryFilterChipData source;
  final RecordingHistoryFilterChipData date;
  final VoidCallback? onScan;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SearchBar(
          key: const Key('recording-search'),
          controller: searchController,
          contextMenuBuilder: buildFlutterTextSelectionMenu,
          hintText: '搜索面单号或日期',
          leading: const Icon(Icons.search_rounded),
          trailing: <Widget>[
            IconButton(
              key: const Key('scan-search-button'),
              tooltip: '扫描条码搜索',
              onPressed: onScan,
              icon: const Icon(Icons.qr_code_scanner_rounded),
            ),
            IconButton(
              key: const Key('paste-search-button'),
              tooltip: '粘贴搜索内容',
              onPressed: onPasteSearch,
              icon: const Icon(Icons.content_paste_rounded),
            ),
            if (hasQuery)
              IconButton(
                tooltip: '清除搜索',
                onPressed: onClearSearch,
                icon: const Icon(Icons.close_rounded),
              ),
          ],
          onChanged: onSearchChanged,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            _buildChip(
              key: const Key('recording-source-filter'),
              icon: Icons.filter_alt_rounded,
              data: source,
            ),
            _buildChip(
              key: const Key('recording-date-filter'),
              icon: Icons.calendar_month_rounded,
              data: date,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildChip({
    required Key key,
    required IconData icon,
    required RecordingHistoryFilterChipData data,
  }) {
    return FilterChip(
      key: key,
      avatar: Icon(icon, size: 18),
      label: Text(data.label),
      selected: data.selected,
      showCheckmark: false,
      onSelected: (_) => data.onPressed(),
    );
  }
}
