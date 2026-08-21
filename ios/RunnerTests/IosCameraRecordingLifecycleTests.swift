import XCTest
@testable import Runner

final class IosCameraRecordingLifecycleTests: XCTestCase {
  func testDuplicateStartIsRejectedAfterRecordingBegins() throws {
    let lifecycle = IosCameraRecordingLifecycle()
    let start = try accepted(lifecycle.begin(.start))

    XCTAssertEqual(lifecycle.phase, .starting)
    XCTAssertEqual(lifecycle.pendingOperation, .start)
    XCTAssertTrue(lifecycle.complete(start, succeeded: true))
    XCTAssertEqual(lifecycle.phase, .recording)
    XCTAssertEqual(
      rejected(lifecycle.begin(.start)),
      .alreadyRecording
    )
  }

  func testSplitIsAcceptedOnlyWhileRecording() throws {
    let lifecycle = IosCameraRecordingLifecycle()
    XCTAssertEqual(rejected(lifecycle.begin(.split)), .notRecording)

    let start = try accepted(lifecycle.begin(.start))
    XCTAssertTrue(lifecycle.complete(start, succeeded: true))
    let split = try accepted(lifecycle.begin(.split))
    XCTAssertEqual(lifecycle.phase, .splitting)
    XCTAssertEqual(lifecycle.pendingOperation, .split)
    XCTAssertTrue(lifecycle.complete(split, succeeded: true))
    XCTAssertEqual(lifecycle.phase, .recording)
  }

  func testStopCannotOverlapStartSplitOrAnotherTransition() throws {
    let lifecycle = IosCameraRecordingLifecycle()
    let start = try accepted(lifecycle.begin(.start))
    XCTAssertEqual(
      rejected(lifecycle.begin(.stop)),
      .transitionInProgress
    )
    XCTAssertTrue(lifecycle.complete(start, succeeded: true))

    let split = try accepted(lifecycle.begin(.split))
    XCTAssertEqual(
      rejected(lifecycle.begin(.stop)),
      .transitionInProgress
    )
    XCTAssertEqual(
      rejected(lifecycle.begin(.start)),
      .transitionInProgress
    )
    XCTAssertTrue(lifecycle.complete(split, succeeded: true))

    let stop = try accepted(lifecycle.begin(.stop))
    XCTAssertEqual(
      rejected(lifecycle.begin(.split)),
      .transitionInProgress
    )
    XCTAssertEqual(
      rejected(lifecycle.begin(.start)),
      .transitionInProgress
    )
    XCTAssertTrue(lifecycle.complete(stop, succeeded: true))
    XCTAssertEqual(lifecycle.phase, .idle)
  }

  func testFailureClearsPendingRequestAndReturnsToIdle() throws {
    let lifecycle = IosCameraRecordingLifecycle()
    var cancellationCount = 0
    let start = try accepted(
      lifecycle.begin(.start) { cancellationCount += 1 }
    )
    XCTAssertTrue(lifecycle.complete(start, succeeded: false))
    XCTAssertEqual(lifecycle.phase, .idle)
    XCTAssertNil(lifecycle.pendingOperation)
    lifecycle.dispose()
    XCTAssertEqual(cancellationCount, 0)
    lifecycle.resetAfterDispose()

    let retry = try accepted(lifecycle.begin(.start))
    XCTAssertTrue(lifecycle.complete(retry, succeeded: true))
    let split = try accepted(lifecycle.begin(.split))
    XCTAssertTrue(lifecycle.complete(split, succeeded: false))
    XCTAssertEqual(lifecycle.phase, .idle)
    XCTAssertNil(lifecycle.pendingOperation)
  }

  func testDisposeAndCompletionRaceResolvesRequestOnlyOnce() throws {
    for _ in 0..<100 {
      let lifecycle = IosCameraRecordingLifecycle()
      let countLock = NSLock()
      var resolutionCount = 0
      let request = try accepted(
        lifecycle.begin(.start) {
          countLock.lock()
          resolutionCount += 1
          countLock.unlock()
        }
      )
      let group = DispatchGroup()
      group.enter()
      DispatchQueue.global().async {
        lifecycle.dispose()
        group.leave()
      }
      group.enter()
      DispatchQueue.global().async {
        if lifecycle.complete(request, succeeded: true) {
          countLock.lock()
          resolutionCount += 1
          countLock.unlock()
        }
        group.leave()
      }
      group.wait()

      XCTAssertEqual(resolutionCount, 1)
      XCTAssertNil(lifecycle.pendingOperation)
    }
  }

  func testDisposeCancelsPendingCompletionAndRecoveryResetsGate() throws {
    let lifecycle = IosCameraRecordingLifecycle()
    var cancellationCount = 0
    let start = try accepted(
      lifecycle.begin(.start) { cancellationCount += 1 }
    )

    lifecycle.dispose()
    XCTAssertEqual(lifecycle.phase, .disposed)
    XCTAssertNil(lifecycle.pendingOperation)
    XCTAssertEqual(cancellationCount, 1)
    XCTAssertFalse(lifecycle.complete(start, succeeded: true))
    XCTAssertEqual(cancellationCount, 1)
    XCTAssertEqual(rejected(lifecycle.begin(.start)), .disposed)

    lifecycle.resetAfterDispose()
    XCTAssertEqual(lifecycle.phase, .idle)
    XCTAssertNoThrow(try accepted(lifecycle.begin(.start)))
  }

  private func accepted(
    _ result: Result<IosCameraRecordingLifecycle.Request,
      IosCameraRecordingLifecycle.Rejection>
  ) throws -> IosCameraRecordingLifecycle.Request {
    switch result {
    case .success(let request):
      return request
    case .failure(let rejection):
      throw rejection
    }
  }

  private func rejected(
    _ result: Result<IosCameraRecordingLifecycle.Request,
      IosCameraRecordingLifecycle.Rejection>
  ) -> IosCameraRecordingLifecycle.Rejection? {
    guard case .failure(let rejection) = result else { return nil }
    return rejection
  }
}
