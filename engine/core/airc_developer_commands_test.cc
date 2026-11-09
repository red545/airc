// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#include "airc_developer_commands.h"
#include <cstdlib>
#include <limits>

int main() {
  // These remain active in release engine builds too.
  const auto expect = [](bool value) { if (!value) std::abort(); };
  expect(airc::IsDeveloperPanel("console"));
  expect(airc::IsDeveloperPanel("network"));
  expect(airc::IsDeveloperPanel("elements"));
  expect(!airc::IsDeveloperPanel("Console"));
  expect(!airc::IsDeveloperPanel("network'); throw 1; //"));
  expect(airc::IsInspectPoint(0, 0, 800, 600));
  expect(airc::IsInspectPoint(799.5, 599.5, 800, 600));
  expect(!airc::IsInspectPoint(800, 0, 800, 600));
  expect(!airc::IsInspectPoint(-1, 0, 800, 600));
  expect(!airc::IsInspectPoint(0, 600, 800, 600));
  expect(!airc::IsInspectPoint(std::numeric_limits<double>::quiet_NaN(), 0, 800, 600));
  expect(!airc::IsInspectPoint(0, std::numeric_limits<double>::infinity(), 800, 600));
  expect(!airc::IsInspectPoint(0, 0, 0, 0));
}
