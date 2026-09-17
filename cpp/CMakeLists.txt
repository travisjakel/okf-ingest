cmake_minimum_required(VERSION 3.24)
project(okf_cpp VERSION 0.12.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)
FetchContent_Declare(ryml
  GIT_REPOSITORY https://github.com/biojppm/rapidyaml
  GIT_TAG v0.7.2
  GIT_SHALLOW ON)
FetchContent_Declare(nlohmann_json
  URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
  URL_HASH SHA256=d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d)
FetchContent_MakeAvailable(ryml nlohmann_json)

add_library(okf_cpp STATIC
  okf/parse.cpp
  okf/links.cpp
  okf/validate.cpp
  okf/read.cpp
  okf/ingest.cpp
  okf/graph.cpp
  okf/diff.cpp
  okf/fetch.cpp)
target_include_directories(okf_cpp PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(okf_cpp PUBLIC ryml::ryml nlohmann_json::nlohmann_json)

# Floating-point determinism (PPR scores are parity-locked across bindings):
# never fast-math, never FMA contraction.
if(MSVC)
  target_compile_options(okf_cpp PUBLIC /fp:precise)
else()
  target_compile_options(okf_cpp PUBLIC -ffp-contract=off)
endif()

enable_testing()

add_executable(check_cpp tests/check_conformance.cpp)
target_link_libraries(check_cpp PRIVATE okf_cpp)
add_test(NAME conformance
         COMMAND check_cpp ${CMAKE_CURRENT_SOURCE_DIR}/../conformance)

add_executable(dogfood_cpp tests/dogfood.cpp)
target_link_libraries(dogfood_cpp PRIVATE okf_cpp)
add_test(NAME dogfood
         COMMAND dogfood_cpp ${CMAKE_CURRENT_SOURCE_DIR}/../docs/okf-bundle)
