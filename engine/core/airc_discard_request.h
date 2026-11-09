// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#ifndef AIRC_CORE_AIRC_DISCARD_REQUEST_H_
#define AIRC_CORE_AIRC_DISCARD_REQUEST_H_
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

namespace airc {
// Ordinary discard waits for every renderer to acknowledge its state. A final
// bounded fallback uses the last received checkpoint, subject to native vetoes.
// Cancellation invalidates replies and the fallback without affecting a later request.
class DiscardRequest {
 public:
  DiscardRequest();
  ~DiscardRequest();
  DiscardRequest(const DiscardRequest&) = delete;
  DiscardRequest& operator=(const DiscardRequest&) = delete;
  using Token = uint64_t;
  static constexpr unsigned kFallbackSeconds = 60;
  static constexpr unsigned kMaxTimeouts = 3;
  bool pending() const { return pending_; }
  bool active() const { return active_; }
  bool CanFallback(double elapsed_seconds) const {
    return active_ && (timeouts_ >= kMaxTimeouts || elapsed_seconds >= kFallbackSeconds);
  }
  std::optional<Token> Begin(size_t renderers) {
    if (pending_ || renderers == 0) return std::nullopt;
    ++generation_;
    acknowledged_.assign(renderers, false);
    remaining_ = renderers;
    pending_ = true;
    active_ = true;
    return generation_;
  }
  bool Acknowledge(Token token, size_t renderer) {
    if (!pending_ || token != generation_ || renderer >= acknowledged_.size() ||
        acknowledged_[renderer]) return false;
    acknowledged_[renderer] = true;
    return --remaining_ == 0;
  }
  // A renderer missing the acknowledgement deadline invalidates this attempt,
  // not the unload intent. Back off retries while a renderer remains unresponsive.
  std::optional<unsigned> RetryAfterTimeout() {
    if (!pending_) return std::nullopt;
    Invalidate();
    ++timeouts_;
    retry_seconds_ = std::min(retry_seconds_ ? retry_seconds_ * 2 : 1u, 30u);
    return retry_seconds_;
  }
  void Cancel() {
    Invalidate();
    retry_seconds_ = 0;
    timeouts_ = 0;
    active_ = false;
  }
 private:
  void Invalidate() {
    ++generation_;
    pending_ = false;
    remaining_ = 0;
    acknowledged_.clear();
  }
  unsigned retry_seconds_ = 0;
  unsigned timeouts_ = 0;
  Token generation_ = 0;
  bool pending_ = false;
  bool active_ = false;
  size_t remaining_ = 0;
  std::vector<bool> acknowledged_;
};
}  // namespace airc
#endif
