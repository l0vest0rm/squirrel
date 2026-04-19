# Post-Commit HTTP Reporting Design

## Background

This project is a macOS input method based on Squirrel / Rime.

There is a new requirement: after the user finishes one round of input and confirms it, the input method should asynchronously send the current input field content to a backend service through HTTP POST.

The backend cares about content state, not every intermediate input event.

## Goals

1. Trigger reporting only when input is confirmed as complete.
2. Read the current full input field content and enqueue it for delivery.
3. Deliver asynchronously and do not block current input interaction.
4. Make delivery configurable:
   - configurable enable switch
   - configurable backend URL
5. Avoid unnecessary repeated delivery:
   - repeated items can stay in the raw queue
   - dedupe and compression happen before sending
6. Send requests serially.
7. Support batch sending.

## Non-Goals

1. Do not report every key press.
2. Do not report every preedit update.
3. Do not guarantee that every macOS app exposes full text content in exactly the same way.
4. Do not build a complex reliable message queue with persistent local storage in the first version.
5. Do not block the input method waiting for network completion.

## Requirement Summary

### Functional Requirements

1. Reporting is enabled by configuration.
2. Backend URL is configured by configuration.
3. When the user confirms input completion, capture the current full input field content.
4. Push captured content into an in-memory queue.
5. A background sender drains the queue asynchronously.
6. Before a batch is sent, queue items are deduplicated and compressed.
7. Batch HTTP POST is sent serially.

### Performance Requirements

1. Input interaction must not wait for HTTP response.
2. Queue push should stay lightweight.
3. Sending side may do queue compression because it is off the main interaction path.

## Trigger Semantics

### What should trigger enqueue

Enqueue should happen only when one round of input is confirmed as complete.

This means:

1. User presses Return / Enter to confirm input.
2. Or an equivalent final commit action occurs in the input method.

### What should not trigger enqueue

1. Preedit text changes.
2. Candidate list changes.
3. Every character typed.
4. Every temporary marked text update.
5. Intermediate composition states.

### Important Clarification

The product wording may say "after pressing Enter".

At implementation level, the safer rule is:

Enqueue on final commit, not on every displayed character.

This avoids coupling the behavior too tightly to one physical key while still matching the intended user action.

## Data Semantics

Each queue item represents a content snapshot, not an input event log.

The backend cares about content, so the queue stores "what the input field looks like now" when the user confirms input.

## Full Input Field Content

The preferred behavior is:

1. Try to read the full current input field content from the client.
2. If full content is not available in some apps, use a fallback strategy defined in implementation.

Current design assumption:

- first target is full input field content
- implementation may need a fallback path for clients that do not expose full text reliably

This document focuses on the queueing and delivery behavior, not on the exact text extraction API details.

## Proposed Configuration

Suggested config section:

```yaml
extension:
  post_commit:
    enabled: true
    url: "http://127.0.0.1:8080/api/input"
    batch_window_ms: 300
    max_batch_size: 20
    timeout_ms: 1000
    max_queue_size: 200
```

### Config Keys

`extension/post_commit/enabled`

- boolean
- default: `false`
- if `false`, feature is completely disabled

`extension/post_commit/url`

- string
- backend HTTP endpoint
- empty or missing means disabled

`extension/post_commit/batch_window_ms`

- integer
- optional
- short batching window for collecting multiple queue items before one send

`extension/post_commit/max_batch_size`

- integer
- optional
- max number of raw queue items to process in one batch

`extension/post_commit/timeout_ms`

- integer
- optional
- HTTP timeout

`extension/post_commit/max_queue_size`

- integer
- optional
- queue size upper bound to avoid unbounded growth when backend is unavailable

## Queue Design

### Core Decision

Queue push stays simple.

Do not perform dedupe or prefix-compression while enqueueing.

Instead:

1. capture snapshot
2. append to raw queue
3. perform dedupe and compression only before sending

### Why this approach

1. Input-side logic stays lightweight.
2. Main input interaction path stays simple.
3. Compression rules are centralized in one place.
4. Compression policy can evolve later without changing the enqueue path.
5. Raw queue is easier to inspect during debugging.

## Queue Item Shape

Recommended fields for each queue item:

```json
{
  "text": "current full input field content",
  "app": "com.apple.TextEdit",
  "timestamp_ms": 1770000000000
}
```

### Field Meaning

`text`

- current full input field content snapshot

`app`

- current app bundle identifier

`timestamp_ms`

- enqueue time

## Sending Model

### High-Level Flow

1. Final commit happens.
2. Capture full input field content.
3. Append raw item to in-memory queue.
4. Background sender is scheduled.
5. When sender flushes:
   - fetch a raw batch from queue
   - dedupe and compress the batch
   - send one HTTP POST request
6. Sending is serial:
   - only one request in flight at a time

### Serial Sending

Sending should be serial, not parallel.

Reason:

1. User input flow is naturally serial.
2. Backend only cares about content.
3. Parallel sends add unnecessary request disorder.
4. Serial sending simplifies state management.

## Batch Compression Rules

Compression is done only right before send.

### Rule 1: Drop empty text

If `text` is empty, discard it.

### Rule 2: Exact dedupe

If two consecutive effective items have the same `text`, keep only one.

Example:

- `你好`
- `你好`

Compressed result:

- `你好`

### Rule 3: Prefix coverage compression

If a later item text starts with an earlier item text, the later item covers the earlier item.

Example:

- `你好`
- `你好世界`

Compressed result:

- `你好世界`

### Important Limitation

Use prefix coverage, not generic substring containment.

Allowed:

- `newText.hasPrefix(oldText)`

Not allowed:

- `newText.contains(oldText)`

Reason:

Substring containment is too aggressive and may wrongly collapse unrelated content states.

### Ordered Compression

Compression must preserve the content progression order.

Do not perform global set-style dedupe.

Example:

Raw queue:

- `你好`
- `你好`
- `你好世界`
- `天气`
- `天气不错`

Compressed result:

- `你好世界`
- `天气不错`

## Batch Sending

One HTTP request may contain multiple compressed items.

Suggested request body:

```json
{
  "items": [
    {
      "text": "你好世界",
      "app": "com.apple.TextEdit",
      "timestamp_ms": 1770000000000
    },
    {
      "text": "天气不错",
      "app": "com.apple.TextEdit",
      "timestamp_ms": 1770000001200
    }
  ]
}
```

## Failure Handling

First version should stay simple.

Suggested policy:

1. Send asynchronously.
2. If request fails, log the error.
3. Optionally retry once after a short delay.
4. Do not block user interaction.
5. Do not allow unlimited in-memory growth.

Queue size limit should protect against backend outages.

## Suggested Implementation Structure

### Recommended New Component

Add a dedicated sender component, for example:

`sources/PostCommitReporter.swift`

Responsibilities:

1. Read config.
2. Accept raw queue items.
3. Manage in-memory queue.
4. Compress queue before send.
5. Send HTTP POST requests.
6. Ensure serial sending.

### Integration Point

The enqueue trigger should be attached at final commit.

The current codebase already has a central commit path in:

- `sources/SquirrelInputController.swift`

That commit path is the correct place to hook reporting behavior.

## Processing Pipeline

Suggested pipeline:

1. Final commit occurs.
2. Try reading current full input field content.
3. If feature disabled, return immediately.
4. If URL missing, return immediately.
5. If captured content is empty, skip enqueue.
6. Append raw item to queue.
7. Schedule background flush.
8. If a request is already in flight, do not start another one.
9. When flush starts:
   - take at most `max_batch_size` raw items
   - compress them
   - if compressed result is empty, discard raw batch
   - otherwise send one POST request
10. On success:
   - remove sent raw items
11. On failure:
   - apply simple retry or keep for next flush according to implementation choice

## Tradeoff Decision Record

### Why not compress on enqueue

This was discussed and intentionally rejected for the first version.

Reason:

1. enqueue path should stay simple
2. avoid extra logic on commit path
3. centralize all compression in sender
4. easier debugging of raw queue contents

### Why serial sending

This was discussed and accepted.

Reason:

1. user input is serial
2. backend cares about content, not concurrent event throughput
3. serial sending is simpler and more predictable

### Why batch before send

This was discussed and accepted.

Reason:

1. reduces request count
2. enables unified dedupe and compression
3. keeps enqueue path minimal

## Open Questions

1. How reliably can full input field content be extracted from all target apps?
2. If full content cannot be read in some clients, what exact fallback should be used?
3. Should failed batches be retried once or simply dropped with logging?
4. Should queue compression consider only text, or also isolate by app / client context?

## Final Agreed Direction

The first version should follow this design:

1. enqueue only when input is finally committed
2. enqueue raw content snapshots directly
3. do not compress while enqueueing
4. compress only before sending
5. send in serial
6. support batch POST
7. support config switch and backend URL
8. keep input interaction non-blocking
