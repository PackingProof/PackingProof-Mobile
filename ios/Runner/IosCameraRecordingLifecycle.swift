import AVFoundation
import Foundation

enum IosAudioSessionOwner: Hashable {
  case camera
  case prompt
  case maxVolume
}

/// 音频会话激活失败时的重试与分类策略。
///
/// `AVAudioSession.setActive(true)` 在麦克风被通话或其他应用占用时会失败，
/// 表现为 `NSOSStatusErrorDomain 561017449（!act）`。刚结束的通话往往一瞬间
/// 就释放麦克风，所以先做有限次重试；仍然失败就抛带专用 code 的错误，交给
/// Dart 明确提示操作员「麦克风被占用」，而不是笼统的摄像头不可用。
enum IosAudioSessionActivationPolicy {
  static let maximumAttempts = 3
  static let retryDelaysSeconds: [TimeInterval] = [0.2, 0.5]
  static let unavailableCode = "audio_session_unavailable"

  static func retryDelay(afterFailedAttempt attempt: Int) -> TimeInterval? {
    guard attempt >= 1, attempt <= retryDelaysSeconds.count else { return nil }
    return retryDelaysSeconds[attempt - 1]
  }

  /// 失败时带上音频会话状态，便于判断是通话占用还是其他冲突。
  static func activationDiagnostics(attempts: Int) -> [String: Any] {
    let session = AVAudioSession.sharedInstance()
    return [
      "attempts": attempts,
      "otherAudioPlaying": session.isOtherAudioPlaying,
      "secondaryAudioShouldBeSilencedHint":
        session.secondaryAudioShouldBeSilencedHint,
      "category": session.category.rawValue,
      "mode": session.mode.rawValue,
    ]
  }
}

protocol IosAudioSessionProtocol: AnyObject {
  func setCategory(
    _ category: AVAudioSession.Category,
    mode: AVAudioSession.Mode,
    options: AVAudioSession.CategoryOptions
  ) throws
  func setActive(
    _ active: Bool,
    options: AVAudioSession.SetActiveOptions
  ) throws
}

extension AVAudioSession: IosAudioSessionProtocol {}

/// 协调相机、提示音和最大音量功能对进程级 AVAudioSession 的共享所有权。
/// 任何 owner 存活时都保持录音会话 active，只有最后一个 owner 释放后才停用。
final class IosSharedAudioSessionCoordinator {
  static let shared = IosSharedAudioSessionCoordinator(
    session: AVAudioSession.sharedInstance()
  )

  private let session: IosAudioSessionProtocol
  private let lock = NSLock()
  private var ownerCounts: [IosAudioSessionOwner: Int] = [:]

  init(session: IosAudioSessionProtocol) {
    self.session = session
  }

  func acquire(_ owner: IosAudioSessionOwner) throws {
    lock.lock()
    defer { lock.unlock() }
    if ownerCounts.isEmpty {
      try activateUnlocked()
    }
    ownerCounts[owner, default: 0] += 1
  }

  func ensureActive(for owner: IosAudioSessionOwner) throws {
    lock.lock()
    defer { lock.unlock() }
    guard (ownerCounts[owner] ?? 0) > 0 else {
      throw pigeonError(
        "音频会话所有权已经释放",
        code: "audio_session_owner_missing"
      )
    }
    try activateUnlocked()
  }

  func release(_ owner: IosAudioSessionOwner) throws {
    lock.lock()
    defer { lock.unlock() }
    guard let count = ownerCounts[owner], count > 0 else { return }
    let totalOwnerCount = ownerCounts.values.reduce(0, +)
    if totalOwnerCount == 1 {
      try session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
    if count == 1 {
      ownerCounts.removeValue(forKey: owner)
    } else {
      ownerCounts[owner] = count - 1
    }
  }

  func ownerCount(_ owner: IosAudioSessionOwner) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return ownerCounts[owner] ?? 0
  }

  /// owner 已销毁且无法再重试停用时，只丢弃其逻辑所有权。下一位 owner
  /// 会重新执行完整激活，避免一次停用失败永久留下无法释放的计数。
  func abandon(_ owner: IosAudioSessionOwner) {
    lock.lock()
    defer { lock.unlock() }
    guard let count = ownerCounts[owner], count > 0 else { return }
    if count == 1 {
      ownerCounts.removeValue(forKey: owner)
    } else {
      ownerCounts[owner] = count - 1
    }
  }

  private func activateUnlocked() throws {
    try session.setCategory(
      .playAndRecord,
      mode: .videoRecording,
      options: [.defaultToSpeaker]
    )
    var lastError: Error?
    for attempt in 1...IosAudioSessionActivationPolicy.maximumAttempts {
      do {
        try session.setActive(true, options: [])
        return
      } catch {
        // broad-catch: 激活失败先重试；最终仍失败会把原始错误和诊断一起抛给
        // Dart，由上层提示「麦克风被占用」。
        lastError = error
        guard
          let delay = IosAudioSessionActivationPolicy.retryDelay(
            afterFailedAttempt: attempt
          )
        else {
          break
        }
        // 通话刚结束时麦克风往往马上释放，等一小会儿再试一次即可恢复，
        // 不必让操作员再看一次「摄像头不可用」。
        Thread.sleep(forTimeInterval: delay)
      }
    }
    throw pigeonError(
      "麦克风可能被通话或其他应用占用：\(lastError?.localizedDescription ?? "未知错误")",
      code: IosAudioSessionActivationPolicy.unavailableCode,
      details: IosAudioSessionActivationPolicy.activationDiagnostics(
        attempts: IosAudioSessionActivationPolicy.maximumAttempts
      )
    )
  }
}

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
