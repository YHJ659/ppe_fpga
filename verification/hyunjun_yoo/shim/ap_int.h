#pragma once

// Host-only compatibility shim for the submitted C++ testbenches.
// It models signed fixed-width wrap for ap_int<8> and ap_int<32> operations
// used by this branch.  It is not a replacement for Vitis HLS C-sim/co-sim.

#include <cstdint>
#include <type_traits>

template <int W>
class ap_int {
  static_assert(W > 0 && W < 64, "host shim supports widths 1..63");

 public:
  ap_int() : value_(0) {}

  template <typename T, typename = std::enable_if_t<std::is_arithmetic_v<T>>>
  ap_int(T value) {
    set(static_cast<std::int64_t>(value));
  }

  template <typename T, typename = std::enable_if_t<std::is_arithmetic_v<T>>>
  ap_int& operator=(T value) {
    set(static_cast<std::int64_t>(value));
    return *this;
  }

  ap_int& operator+=(std::int64_t value) {
    set(value_ + value);
    return *this;
  }

  int to_int() const { return static_cast<int>(value_); }
  float to_float() const { return static_cast<float>(value_); }
  operator std::int64_t() const { return value_; }

 private:
  void set(std::int64_t value) {
    constexpr std::uint64_t mask = (std::uint64_t{1} << W) - 1;
    std::uint64_t bits = static_cast<std::uint64_t>(value) & mask;
    if (bits & (std::uint64_t{1} << (W - 1)))
      bits |= ~mask;
    value_ = static_cast<std::int64_t>(bits);
  }

  std::int64_t value_;
};

template <int A, int B>
std::int64_t operator*(const ap_int<A>& lhs, const ap_int<B>& rhs) {
  return static_cast<std::int64_t>(lhs) * static_cast<std::int64_t>(rhs);
}
