import XCTest
@testable import Runner

final class IosLatestPendingGateTests: XCTestCase {
  func testOnlyLatestPayloadWaitsWhileOneRequestIsInFlight() {
    var gate = IosLatestPendingGate<String>(minimumInterval: 0.1)

    assertSend(gate.submit("first", now: 10), payload: "first")
    assertNone(gate.submit("stale", now: 10.01))
    assertNone(gate.submit("latest", now: 10.02))
    assertSchedule(gate.complete(now: 10.03), delay: 0.07)
    assertSend(gate.wake(now: 10.1), payload: "latest")
    assertNone(gate.complete(now: 10.2))
  }

  func testEmptyBarcodeBatchReplacesPendingDetection() {
    var gate = IosLatestPendingGate<[String]>(minimumInterval: 0.1)

    assertSend(gate.submit(["JT1234567890"], now: 10), payload: ["JT1234567890"])
    assertNone(gate.submit(["JT1234567890"], now: 10.01))
    assertNone(gate.submit([], now: 10.02))
    assertSend(gate.complete(now: 10.2), payload: [])
    assertNone(gate.complete(now: 10.3))
  }

  func testSlowCompletionSendsLatestPayloadImmediately() {
    var gate = IosLatestPendingGate<Int>(minimumInterval: 0.1)

    assertSend(gate.submit(1, now: 20), payload: 1)
    assertNone(gate.submit(2, now: 20.02))
    assertNone(gate.submit(3, now: 20.2))
    assertSend(gate.complete(now: 20.2), payload: 3)
  }

  func testDiscardPendingPreservesOutstandingRequest() {
    var gate = IosLatestPendingGate<String>(minimumInterval: 0.1)

    assertSend(gate.submit("first", now: 30), payload: "first")
    assertNone(gate.submit("discarded", now: 30.01))

    gate.discardPending()

    assertNone(gate.submit("after-restart", now: 30.2))
    assertSend(gate.complete(now: 30.2), payload: "after-restart")
  }

  func testResetReleasesOutstandingRequestFromPreviousCameraSession() {
    var gate = IosLatestPendingGate<String>(minimumInterval: 0.1)

    assertSend(gate.submit("previous-session", now: 40), payload: "previous-session")
    gate.reset()

    assertSend(gate.submit("resumed-session", now: 40.01), payload: "resumed-session")
  }

  private func assertNone<Payload>(
    _ action: IosLatestPendingGate<Payload>.Action,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case .none = action else {
      XCTFail("Expected no action", file: file, line: line)
      return
    }
  }

  private func assertSend<Payload: Equatable>(
    _ action: IosLatestPendingGate<Payload>.Action,
    payload: Payload,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case .send(let actual) = action else {
      XCTFail("Expected send action", file: file, line: line)
      return
    }
    XCTAssertEqual(actual, payload, file: file, line: line)
  }

  private func assertSchedule<Payload>(
    _ action: IosLatestPendingGate<Payload>.Action,
    delay: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case .schedule(let actual) = action else {
      XCTFail("Expected schedule action", file: file, line: line)
      return
    }
    XCTAssertEqual(actual, delay, accuracy: 0.000_001, file: file, line: line)
  }
}
