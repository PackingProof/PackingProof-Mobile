import 'recordings_history_filter.dart';

List<T> flattenRecordingHistoryPages<T>(Map<int, List<T>> pages) {
  final List<MapEntry<int, List<T>>> entries = pages.entries.toList()
    ..sort(
      (MapEntry<int, List<T>> a, MapEntry<int, List<T>> b) =>
          a.key.compareTo(b.key),
    );
  return entries
      .expand<T>((MapEntry<int, List<T>> entry) => entry.value)
      .toList(growable: false);
}

void trimRecordingHistoryPageCache<T>(
  Map<int, T> pages, {
  required int currentDataPage,
  int radius = 2,
}) {
  assert(currentDataPage >= 1);
  assert(radius >= 0);
  final int firstRetainedPage = (currentDataPage - radius).clamp(
    1,
    currentDataPage,
  );
  final int lastRetainedPage = currentDataPage + radius;
  pages.removeWhere(
    (int page, T _) => page < firstRetainedPage || page > lastRetainedPage,
  );
}

int estimateRecordingHistoryCount({
  required RecordingSourceFilter sourceFilter,
  required int localCount,
  required int localLogicalCount,
  required int remoteTotal,
  required int remoteDeviceTotal,
}) => switch (sourceFilter.kind) {
  RecordingSourceFilterKind.local => localCount,
  RecordingSourceFilterKind.backedUp => remoteDeviceTotal,
  RecordingSourceFilterKind.device => localLogicalCount + remoteTotal,
  RecordingSourceFilterKind.all =>
    localLogicalCount +
        remoteTotal -
        remoteDeviceTotal.clamp(0, localLogicalCount),
};

int recordingHistoryPageCount({
  required int estimatedCount,
  required int visibleItemCount,
  required int pageSize,
}) {
  assert(pageSize > 0);
  if (estimatedCount <= 0) return visibleItemCount == 0 ? 0 : 1;
  return (estimatedCount / pageSize).ceil();
}

int clampRecordingHistoryPage({
  required int requestedPage,
  required int pageCount,
}) {
  if (pageCount <= 0) return 0;
  return requestedPage.clamp(0, pageCount - 1);
}

List<T> recordingHistoryPageItems<T>({
  required Iterable<T> items,
  required int page,
  required int pageSize,
  int firstLoadedPage = 0,
}) {
  assert(page >= 0);
  assert(pageSize > 0);
  assert(firstLoadedPage >= 0);
  final int relativePage = page - firstLoadedPage;
  if (relativePage < 0) return List<T>.empty(growable: false);
  return items
      .skip(relativePage * pageSize)
      .take(pageSize)
      .toList(growable: false);
}

typedef RecordingHistoryNextPagePlan = ({
  int historyPage,
  int dataPage,
  int prefetchPage,
});

RecordingHistoryNextPagePlan? recordingHistoryNextPagePlan({
  required int currentPage,
  required int pageCount,
}) {
  if (currentPage + 1 >= pageCount) return null;
  final int historyPage = currentPage + 1;
  final int dataPage = historyPage + 1;
  return (
    historyPage: historyPage,
    dataPage: dataPage,
    prefetchPage: dataPage + 1,
  );
}

bool shouldPrefetchRecordingHistoryPage({
  required int page,
  required int total,
  required int pageSize,
  required Iterable<int> loadedPages,
}) {
  assert(pageSize > 0);
  return page <= (total / pageSize).ceil() && !loadedPages.contains(page);
}

class RecordingHistoryPagination<T> {
  const RecordingHistoryPagination({
    required this.estimatedCount,
    required this.pageCount,
    required this.page,
    required this.items,
  });

  final int estimatedCount;
  final int pageCount;
  final int page;
  final List<T> items;
}

RecordingHistoryPagination<T> buildRecordingHistoryPagination<T>({
  required RecordingSourceFilter sourceFilter,
  required int localCount,
  required int localLogicalCount,
  required int remoteTotal,
  required int remoteDeviceTotal,
  required Iterable<T> visibleItems,
  required int requestedPage,
  required int pageSize,
  int firstLoadedPage = 0,
}) {
  final List<T> items = visibleItems.toList(growable: false);
  final int estimatedCount = estimateRecordingHistoryCount(
    sourceFilter: sourceFilter,
    localCount: localCount,
    localLogicalCount: localLogicalCount,
    remoteTotal: remoteTotal,
    remoteDeviceTotal: remoteDeviceTotal,
  );
  final int pageCount = recordingHistoryPageCount(
    estimatedCount: estimatedCount,
    visibleItemCount: items.length,
    pageSize: pageSize,
  );
  final int page = clampRecordingHistoryPage(
    requestedPage: requestedPage,
    pageCount: pageCount,
  );
  return RecordingHistoryPagination<T>(
    estimatedCount: estimatedCount,
    pageCount: pageCount,
    page: page,
    items: recordingHistoryPageItems(
      items: items,
      page: page,
      pageSize: pageSize,
      firstLoadedPage: firstLoadedPage,
    ),
  );
}
