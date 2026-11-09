// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#include "airc_discard_request.h"
#include <cstdio>

int main() {
  using airc::DiscardRequest;
  int failures = 0;
  auto expect = [&](bool value, const char* scenario) {
    std::printf("%s %s\n", value ? "PASS" : "FAIL", scenario);
    failures += !value;
  };
  {
    DiscardRequest r;
    expect(!r.Begin(0) && !r.pending(), "no renderer cannot authorize discard");
    auto token = *r.Begin(3);
    expect(!r.Acknowledge(token, 2) && !r.Acknowledge(token, 0),
           "out-of-order acknowledgements wait for every renderer");
    expect(!r.Acknowledge(token, 0) && !r.Acknowledge(token, 3),
           "duplicate or foreign renderer cannot complete discard");
    expect(r.Acknowledge(token, 1) && !r.Acknowledge(token, 1),
           "completion is emitted exactly once");
  }
  {
    DiscardRequest r;
    auto first = *r.Begin(2);
    expect(!r.Begin(1), "concurrent request cannot replace a pending discard");
    r.Acknowledge(first, 0);
    r.Cancel();  // Showing the page, navigation or destruction.
    expect(!r.pending() && !r.Acknowledge(first, 1),
           "cancellation prevents a late reply from discarding the page");
    auto second = *r.Begin(1);
    expect(!r.Acknowledge(first, 0) && !r.Acknowledge(first, 1) && r.pending(),
           "old replies cannot complete or cancel a new request");
    expect(r.Acknowledge(second, 0), "new request can complete after cancellation");
    r.Cancel();
    expect(!r.pending(), "completion cleanup leaves no pending work");
  }
  {
    DiscardRequest r;
    auto old = *r.Begin(1);
    expect(r.RetryAfterTimeout() == 1 && !r.pending(),
           "an expired acknowledgement schedules a retry without retaining an attempt");
    auto next = *r.Begin(1);
    expect(!r.Acknowledge(old, 0) && r.pending() && r.Acknowledge(next, 0),
           "a late ACK cannot finish the retry; its own ACK can");
    r.Cancel();
    expect(!r.RetryAfterTimeout(), "a cancelled unload cannot schedule a retry");
    r.Begin(1);
    expect(r.RetryAfterTimeout() == 1,
           "selection or successful completion clears failure backoff");
    for (unsigned delay : {2u, 4u, 8u, 16u, 30u, 30u, 30u}) {
      r.Begin(1);
      expect(r.RetryAfterTimeout() == delay, "unresponsive renderer retries back off with a cap");
    }
    r.Cancel();
    r.Begin(1);
    expect(r.RetryAfterTimeout() == 1, "a later unload starts with a short retry again");
  }
  {
    DiscardRequest r;
    expect(!r.CanFallback(1000), "no unload intent cannot authorize fallback");
    auto token = *r.Begin(1);
    expect(!r.CanFallback(59.99) && r.CanFallback(60),
           "fallback waits for its full deadline while an ACK is pending");
    r.RetryAfterTimeout();
    expect(r.active() && !r.pending() && r.CanFallback(60),
           "fallback remains armed while a retry waits on an unresponsive form query");
    r.Cancel();
    expect(!r.active() && !r.CanFallback(1000) && !r.Acknowledge(token, 0),
           "selection, edits or navigation cancel fallback and late ACKs together");
    r.Begin(1);
    expect(!r.CanFallback(0), "a later unload gets a new full fallback deadline");
  }
  {
    DiscardRequest r;
    for (unsigned n = 1; n <= DiscardRequest::kMaxTimeouts; ++n) {
      r.Begin(1);
      r.RetryAfterTimeout();
      expect(r.CanFallback(0) == (n == DiscardRequest::kMaxTimeouts),
             "three missed ACKs cap retries even before the wall-clock deadline");
    }
    r.Cancel();
    r.Begin(1);
    expect(!r.CanFallback(0), "cancellation clears the ACK-timeout limit for a new request");
  }
  return failures ? 1 : 0;
}
