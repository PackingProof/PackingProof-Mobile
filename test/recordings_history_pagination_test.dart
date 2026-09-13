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

  test('本地页缓存仅保留当前页前后各两页', () {
    final Map<int, String> pages = <int, String>{
      for (var page = 1; page <= 12; page++) page: 'page-$page',
    };

    trimRecordingHistoryPageCache(pages, currentDataPage: 7);

    expect(pages.keys, <int>[5, 6, 7, 8, 9]);
    expect(pages, hasLength(5));
  });

  test('靠近首屏时页缓存不会为凑足五页越过当前页后两页', () {
    final Map<int, String> pages = <int, String>{
      for (var page = 1; page <= 8; page++) page: 'page-$page',
    };

    trimRecordingHistoryPageCache(pages, currentDataPage: 1);

    expect(pages.keys, <int>[1, 2, 3]);
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

    expect(estimate(const RecordingSourceFilter.local()), 4);
    expect(estimate(const RecordingSourceFilter.backedUp()), 3);
    // 单台设备的估算只能给出上界（本地逻辑数 + 远端总数），精确数量由实际可见项决定。
    expect(estimate(const RecordingSourceFilter.device('device-1')), 14);
    expect(estimate(const RecordingSourceFilter.all()), 11);
  });

  test('全部来源估算不会扣除超过本地逻辑总数的本机远端数', () {
    expect(
      estimateRecordingHistoryCount(
        sourceFilter: const RecordingSourceFilter.all(),
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

  test('缓存窗口从深页开始时按相对页码切片', () {
    expect(
      recordingHistoryPageItems(
        items: <int>[30, 31, 40, 41, 50, 51],
        page: 4,
        pageSize: 2,
        firstLoadedPage: 3,
      ),
      <int>[40, 41],
    );
  });

  test('分页策略组合估算、页码裁剪和当前页切片', () {
    final RecordingHistoryPagination<int> pagination =
        buildRecordingHistoryPagination(
          sourceFilter: const RecordingSourceFilter.all(),
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
