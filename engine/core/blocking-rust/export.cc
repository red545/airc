// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Release conversion of the two CC BY-SA seed lists. No network, no browser.
#include "../airc_blocking_ffi.h"
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>

bool Write(const char* path, AircBlockingBytes bytes) {
  if (!bytes.data || !bytes.len) return false;
  std::ofstream file(path, std::ios::binary);
  file.write(reinterpret_cast<const char*>(bytes.data), bytes.len);
  const bool good = file.good();
  airc_blocking_bytes_free(bytes);
  return good;
}
int main(int argc, char** argv) {
  if (argc != 5) { std::cerr << "Usage: export-rules SEED_DIRECTORY WEBKIT_JSON NATIVE_RULESET DIAGNOSTICS_JSON\n"; return 2; }
  std::string text;
  for (const auto* name : {"easylist.txt", "easyprivacy.txt"}) {
    std::ifstream file(std::string(argv[1]) + "/" + name, std::ios::binary);
    if (!file) return 3;
    text.append(std::istreambuf_iterator<char>(file), {}); text.push_back('\n');
  }
  const auto* bytes = reinterpret_cast<const uint8_t*>(text.data());
  auto* engine = airc_blocking_create(bytes, text.size());
  if (!engine) return 4;
  const bool native = Write(argv[3], airc_blocking_serialize(engine));
  const bool wk = Write(argv[2], airc_blocking_webkit_rules(bytes, text.size()));
  const bool diagnostics = Write(argv[4], airc_blocking_webkit(bytes, text.size()));
  airc_blocking_destroy(engine);
  return native && wk && diagnostics ? 0 : 5;
}
