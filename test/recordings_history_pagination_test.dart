import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/screens/recordings_history_filter.dart';
import 'package:packing_proof_mobile/screens/recordings_history_pagination.dart';

void main() {
  test('缓存页按页码展平，不依赖 Map 插入顺序', () {
    expect(
      flattenRecordingHistoryPages(<int, List<String>>{
        3: <String>['e'],
        1: <String>['a', 'b'],
        2: <String>['c', 'd'],
      }),
      <String>['a', 'b', 'c', 'd', 'e'],
    );
  });

  test('不同来源沿用原有估算总数规则', () {
    int estimate(RecordingSourceFilter sourceFilter) =>
        estimateRecordingHistoryCount(
          sourceFilter: sourceFilter,
          localCount: 4,
          localLogicalCount: 8,
          remoteTotal: 6,
          remoteDeviceTotal: 3,
        );

    expect(estimate(RecordingSourceFilter.local), 4);
    expect(estimate(RecordingSourceFilter.backedUp), 3);
    expect(estimate(RecordingSourceFilter.computer), 6);
    expect(estimate(RecordingSourceFilter.all), 11);
  });

  test('全部来源估算不会扣除超过本地逻辑总数的本机远端数', () {
    expect(
      estimateRecordingHistoryCount(
        sourceFilter: RecordingSourceFilter.all,
        localCount: 2,
        localLogicalCount: 2,
        remoteTotal: 9,
        remoteDeviceTotal: 7,
      ),
      9,
    );
  });

  test('空结果和已有缓存项的页数保持既有回退行为', () {
    expect(
      recordingHistoryPageCount(
        estimatedCount: 0,
        visibleItemCount: 0,
        pageSize: 5,
      ),
      0,
    );
    expect(
      recordingHistoryPageCount(
        estimatedCount: 0,
        visibleItemCount: 2,
        pageSize: 5,
      ),
      1,
    );
    expect(
      recordingHistoryPageCount(
        estimatedCount: 11,
        visibleItemCount: 2,
        pageSize: 5,
      ),
      3,
    );
  });

  test('当前页裁剪到有效范围并返回对应切片', () {
    expect(clampRecordingHistoryPage(requestedPage: -1, pageCount: 3), 0);
    expect(clampRecordingHistoryPage(requestedPage: 4, pageCount: 3), 2);
    expect(clampRecordingHistoryPage(requestedPage: 4, pageCount: 0), 0);
    expect(
      recordingHistoryPageItems(
        items: <int>[1, 2, 3, 4, 5, 6],
        page: 1,
        pageSize: 2,
      ),
      <int>[3, 4],
    );
  });

  test('分页策略组合估算、页码裁剪和当前页切片', () {
    final RecordingHistoryPagination<int> pagination =
        buildRecordingHistoryPagination(
          sourceFilter: RecordingSourceFilter.all,
          localCount: 3,
          localLogicalCount: 6,
          remoteTotal: 5,
          remoteDeviceTotal: 2,
          visibleItems: <int>[1, 2, 3, 4, 5, 6, 7],
          requestedPage: 5,
          pageSize: 3,
        );

    expect(pagination.estimatedCount, 9);
    expect(pagination.pageCount, 3);
    expect(pagination.page, 2);
    expect(pagination.items, <int>[7]);
  });

  test('下一页计划使用零基 UI 页和一基数据页', () {
    expect(recordingHistoryNextPagePlan(currentPage: 0, pageCount: 3), (
      historyPage: 1,
      dataPage: 2,
      prefetchPage: 3,
    ));
    expect(recordingHistoryNextPagePlan(currentPage: 2, pageCount: 3), isNull);
  });

  test('预取仅覆盖总数范围内且尚未缓存的数据页', () {
    expect(
      shouldPrefetchRecordingHistoryPage(
        page: 3,
        total: 12,
        pageSize: 5,
        loadedPages: const <int>[1, 2],
      ),
      isTrue,
    );
    expect(
      shouldPrefetchRecordingHistoryPage(
        page: 3,
        total: 12,
        pageSize: 5,
        loadedPages: const <int>[1, 2, 3],
      ),
      isFalse,
    );
    expect(
      shouldPrefetchRecordingHistoryPage(
        page: 4,
        total: 12,
        pageSize: 5,
        loadedPages: const <int>[],
      ),
      isFalse,
    );
  });
}
