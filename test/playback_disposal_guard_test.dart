import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/screens/video_playback_screen.dart';

void main() {
  test('等待播放器释放完成并合并重复释放请求', () async {
    final Completer<void> release = Completer<void>();
    int disposeCount = 0;
    final PlaybackDisposalGuard guard = PlaybackDisposalGuard(() async {
      disposeCount++;
      await release.future;
    });

    bool completed = false;
    final Future<void> first = guard.dispose();
    final Future<void> second = guard.dispose();
    first.then((_) => completed = true);

    await Future<void>.delayed(Duration.zero);
    expect(disposeCount, 1);
    expect(completed, isFalse);

    release.complete();
    await Future.wait(<Future<void>>[first, second]);

    expect(completed, isTrue);
    expect(disposeCount, 1);
  });

  test('等待播放器监听组件解除依赖后再释放', () async {
    final Completer<void> dependentsDetached = Completer<void>();
    bool disposed = false;
    final PlaybackDisposalGuard guard = PlaybackDisposalGuard(() async {
      disposed = true;
    });

    final Future<void> disposal = guard.disposeAfter(dependentsDetached.future);
    await Future<void>.delayed(Duration.zero);
    expect(disposed, isFalse);

    dependentsDetached.complete();
    await disposal;

    expect(disposed, isTrue);
  });
}
