//
//  PostCommitReporter.swift
//  Squirrel
//
//  Created by Codex on 4/19/26.
//

import Foundation

final class PostCommitReporter {
  struct ConfigSnapshot {
    let enabled: Bool
    let url: URL?
    let batchWindow: TimeInterval
    let maxBatchSize: Int
    let timeout: TimeInterval
    let maxQueueSize: Int
  }

  struct QueueItem: Codable {
    let text: String
    let appBundleID: String
    let timestampMs: Int64
  }

  private struct BatchPayload: Codable {
    let items: [QueueItem]
  }

  private let stateQueue = DispatchQueue(label: "im.rime.squirrel.post-commit-reporter")
  private let session: URLSession

  private var config = ConfigSnapshot(enabled: false, url: nil, batchWindow: 0.3, maxBatchSize: 20, timeout: 1.0, maxQueueSize: 200)
  private var rawQueue = [QueueItem]()
  private var inFlight = false
  private var pendingFlushWorkItem: DispatchWorkItem?

  init() {
    let sessionConfig = URLSessionConfiguration.ephemeral
    sessionConfig.waitsForConnectivity = false
    sessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
    session = URLSession(configuration: sessionConfig)
  }

  func updateConfig(_ config: ConfigSnapshot) {
    stateQueue.async {
      self.config = config
      PostCommitDebugLogger.log("config updated enabled=\(config.enabled) url=\(config.url?.absoluteString ?? "nil") batchWindow=\(config.batchWindow) maxBatchSize=\(config.maxBatchSize) timeout=\(config.timeout) maxQueueSize=\(config.maxQueueSize)")
      if !config.enabled || config.url == nil {
        self.rawQueue.removeAll()
        self.pendingFlushWorkItem?.cancel()
        self.pendingFlushWorkItem = nil
        PostCommitDebugLogger.log("disabled or missing url, queue cleared")
      } else if !self.rawQueue.isEmpty {
        self.scheduleFlushLocked()
      }
    }
  }

  func enqueue(text: String, appBundleID: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    let item = QueueItem(
      text: text,
      appBundleID: appBundleID,
      timestampMs: Int64(Date().timeIntervalSince1970 * 1000)
    )

    stateQueue.async {
      guard self.config.enabled, self.config.url != nil else {
        PostCommitDebugLogger.log("drop enqueue because reporter disabled or url missing")
        return
      }

      self.rawQueue.append(item)
      let overflow = self.rawQueue.count - self.config.maxQueueSize
      if overflow > 0 {
        self.rawQueue.removeFirst(overflow)
        PostCommitDebugLogger.log("queue overflow, dropped \(overflow) items")
      }
      PostCommitDebugLogger.log("enqueued item app=\(item.appBundleID) chars=\(item.text.count) queue=\(self.rawQueue.count)")
      self.scheduleFlushLocked()
    }
  }

  private func scheduleFlushLocked() {
    guard config.enabled, config.url != nil, !inFlight, !rawQueue.isEmpty else { return }
    guard pendingFlushWorkItem == nil else { return }

    let workItem = DispatchWorkItem { [weak self] in
      self?.stateQueue.async {
        self?.pendingFlushWorkItem = nil
        self?.flushLocked()
      }
    }
    pendingFlushWorkItem = workItem
    PostCommitDebugLogger.log("scheduled flush in \(config.batchWindow)s queue=\(rawQueue.count)")
    stateQueue.asyncAfter(deadline: .now() + config.batchWindow, execute: workItem)
  }

  private func flushLocked() {
    guard config.enabled, let url = config.url, !inFlight, !rawQueue.isEmpty else { return }

    let batchCount = min(config.maxBatchSize, rawQueue.count)
    let rawBatch = Array(rawQueue.prefix(batchCount))
    let compressedItems = compress(rawBatch)
    PostCommitDebugLogger.log("flushing rawBatch=\(rawBatch.count) compressed=\(compressedItems.count) queue=\(rawQueue.count)")

    if compressedItems.isEmpty {
      rawQueue.removeFirst(batchCount)
      PostCommitDebugLogger.log("compressed batch empty, removed \(batchCount) queued items")
      scheduleFlushLocked()
      return
    }

    guard let body = try? JSONEncoder().encode(BatchPayload(items: compressedItems)) else {
      PostCommitDebugLogger.log("failed to encode batch payload")
      rawQueue.removeFirst(batchCount)
      scheduleFlushLocked()
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = config.timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body

    inFlight = true
    let requestBatchCount = batchCount
    session.dataTask(with: request) { [weak self] _, response, error in
      self?.stateQueue.async {
        guard let self else { return }
        self.inFlight = false

        if let error {
          PostCommitDebugLogger.log("request failed: \(error.localizedDescription)")
          self.scheduleFlushLocked()
          return
        }

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
          PostCommitDebugLogger.log("unexpected status code: \(httpResponse.statusCode)")
          self.scheduleFlushLocked()
          return
        }

        self.rawQueue.removeFirst(min(requestBatchCount, self.rawQueue.count))
        PostCommitDebugLogger.log("request succeeded, removed \(requestBatchCount) items, remaining=\(self.rawQueue.count)")
        self.scheduleFlushLocked()
      }
    }.resume()
  }

  private func compress(_ items: [QueueItem]) -> [QueueItem] {
    var compressed = [QueueItem]()

    for item in items {
      let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }

      if let last = compressed.last,
         sameContext(last, item) {
        if item.text == last.text {
          continue
        }
        if item.text.hasPrefix(last.text) {
          compressed.removeLast()
        }
      }

      compressed.append(item)
    }

    return compressed
  }

  private func sameContext(_ lhs: QueueItem, _ rhs: QueueItem) -> Bool {
    lhs.appBundleID == rhs.appBundleID
  }
}
