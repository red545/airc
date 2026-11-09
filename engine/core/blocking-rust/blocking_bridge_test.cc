// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#include "../airc_blocking_ffi.h"
#include <cstdlib>
#define REQUIRE(value) do { if (!(value)) { std::cerr << "FAIL " << #value << "\n"; std::exit(4); } } while (false)
#include <iostream>
#include <string>
const uint8_t* U(const std::string& s) { return reinterpret_cast<const uint8_t*>(s.data()); }
int main() {
  REQUIRE(airc_blocking_abi_version()==1);
  std::string lists="||ads.example^$script,third-party\n@@||ads.example/allowed.js$script\n"
      "||news.example^$removeparam=tracking\n||news.example^$csp=script-src 'none'\nnews.example##.sponsor\n";
  auto* engine=airc_blocking_create(U(lists),lists.size()); REQUIRE(engine);
  std::string source="https://news.example/",type="script",method="GET",url="https://ads.example/banner.js";
  auto check=[&] { return airc_blocking_check(engine,U(url),url.size(),U(source),source.size(),U(type),type.size(),U(method),method.size()); };
  REQUIRE(check()==1);
  type="image"; REQUIRE(check()==0);
  type="script";url="https://ads.example/allowed.js";REQUIRE(check()==0);
  url="https://ads.example.evil.test/banner.js";REQUIRE(check()==0);
  url="https://news.example/article?tracking=secret&keep=1";type="document";
  auto decision=airc_blocking_match(engine,U(url),url.size(),U(source),source.size(),U(type),type.size(),U(method),method.size());
  REQUIRE(decision.valid && !decision.blocked);
  REQUIRE(decision.rewritten_url.data && decision.csp.data);
  std::string rewrite(reinterpret_cast<char*>(decision.rewritten_url.data),decision.rewritten_url.len);
  REQUIRE(rewrite=="https://news.example/article?keep=1");
  std::string csp(reinterpret_cast<char*>(decision.csp.data),decision.csp.len);REQUIRE(csp=="script-src 'none'");
  airc_blocking_bytes_free(decision.rewritten_url);airc_blocking_bytes_free(decision.csp);
  auto cosmetic=airc_blocking_cosmetics(engine,U(source),source.size());REQUIRE(cosmetic.data);
  REQUIRE(std::string(reinterpret_cast<char*>(cosmetic.data),cosmetic.len).find(".sponsor")!=std::string::npos);
  airc_blocking_bytes_free(cosmetic);
  auto wk=airc_blocking_webkit_rules(U(lists),lists.size()); REQUIRE(wk.data);
  std::string converted(reinterpret_cast<char*>(wk.data),wk.len);
  REQUIRE(converted.find("css-display-none")==std::string::npos);
  REQUIRE(converted.find("ignore-previous-rules")!=std::string::npos);
  airc_blocking_bytes_free(wk);airc_blocking_destroy(engine);
  std::cout << "Native GN C ABI + type/party/exceptions + removeparam/CSP + cosmetics PASS\n";
}
