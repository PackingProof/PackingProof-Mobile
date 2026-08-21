import Foundation

final class IosCameraRecordingLifecycle {
  enum Phase: Equatable {
    case idle
    case starting
    case recording
    case splitting
    case stopping
    case disposed
  }

  enum Operation: Equatable {
    case start
    case split
    case stop
  }

  enum Rejection: Error, Equatable {
    case disposed
    case alreadyRecording
    case notRecording
    case transitionInProgress
  }

  struct Request: Equatable {
    fileprivate let id: UInt64
    let operation: Operation
  }

  private struct PendingRequest {
    let request: Request
    let cancellation: () -> Void
  }

  private let lock = NSLock()
  private var storedPhase = Phase.idle
  private var nextRequestId: UInt64 = 0
  private var pendingRequest: PendingRequest?

  var phase: Phase {
    lock.lock()
    defer { lock.unlock() }
    return storedPhase
  }

  var pendingOperation: Operation? {
    lock.lock()
    defer { lock.unlock() }
    return pendingRequest?.request.operation
  }

  func begin(
    _ operation: Operation,
    onCancelled: @escaping () -> Void = {}
  ) -> Result<Request, Rejection> {
    lock.lock()
    defer { lock.unlock() }

    if storedPhase == .disposed {
      return .failure(.disposed)
    }
    switch (storedPhase, operation) {
    case (.idle, .start), (.recording, .split), (.recording, .stop):
      break
    case (.recording, .start):
      return .failure(.alreadyRecording)
    case (.idle, .split), (.idle, .stop):
      return .failure(.notRecording)
    default:
      return .failure(.transitionInProgress)
    }

    nextRequestId &+= 1
    let request = Request(id: nextRequestId, operation: operation)
    pendingRequest = PendingRequest(
      request: request,
      cancellation: onCancelled
    )
    storedPhase = switch operation {
    case .start: .starting
    case .split: .splitting
    case .stop: .stopping
    }
    return .success(request)
  }

  @discardableResult
  func complete(_ request: Request, succeeded: Bool) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard pendingRequest?.request == request else { return false }
    pendingRequest = nil
    storedPhase = switch (request.operation, succeeded) {
    case (.start, true), (.split, true): .recording
    case (.start, false), (.split, false), (.stop, _): .idle
    }
    return true
  }

  func isPending(_ request: Request) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return pendingRequest?.request == request
  }

  func dispose() {
    let cancellation: (() -> Void)?
    lock.lock()
    storedPhase = .disposed
    cancellation = pendingRequest?.cancellation
    pendingRequest = nil
    lock.unlock()
    cancellation?()
  }

  func resetAfterDispose() {
    lock.lock()
    defer { lock.unlock() }
    guard storedPhase == .disposed else { return }
    storedPhase = .idle
    pendingRequest = nil
  }
}
