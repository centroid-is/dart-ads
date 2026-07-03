# dart_ads C++ golden-frame harness
#
# Self-owned build that compiles a minimal set of Beckhoff/ADS (vendored under
# third_party/ADS, pinned commit) sources DIRECTLY. We deliberately do NOT pull
# in upstream's own build tree: its root CMakeLists requires CMake 3.23
# (FILE_SET HEADERS) and drags in sockets/threads/TcAdsDll probing we do not
# need. Listing the four sources directly lets us hold a 3.16 floor.
#
# Configure/build (dev machine has no ninja -> default Unix Makefiles):
#   cmake -S test_harness -B test_harness/build
#   cmake --build test_harness/build
cmake_minimum_required(VERSION 3.16)
project(dart_ads_harness CXX)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# AdsLib source root, relative to this CMakeLists (test_harness/).
set(ADS "${CMAKE_SOURCE_DIR}/../third_party/ADS/AdsLib")

# STATIC lib built from exactly the four upstream sources needed for framing.
# Frame.cpp -> Log.h -> Log.cpp; AdsDef.cpp provides operators/make_AmsNetId;
# standalone/AmsNetId.cpp provides the AmsNetId(u8...) / AmsNetId(string) ctors.
# No socket/thread sources are required for the golden dumper.
add_library(ads_framing STATIC
    "${ADS}/Frame.cpp"
    "${ADS}/Log.cpp"
    "${ADS}/AdsDef.cpp"
    "${ADS}/standalone/AmsNetId.cpp"
)
target_include_directories(ads_framing PUBLIC
    "${ADS}"
    "${ADS}/standalone"
)
# REQUIRED: Log.cpp references CONFIG_DEFAULT_LOGLEVEL; upstream defines it
# globally via add_compile_definitions, so a direct compile fails without it.
target_compile_definitions(ads_framing PUBLIC CONFIG_DEFAULT_LOGLEVEL=1)

# Golden-frame emitter: reuses AmsHeader.h structs + Frame::prepend to produce
# byte-authoritative reference frames. No sockets, no threads.
add_executable(dump_golden dump_golden.cpp)
target_link_libraries(dump_golden PRIVATE ads_framing)

# NOTE: the mock_server target is added in plan 01-03; do not reference it here.
