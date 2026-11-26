cmake_minimum_required(VERSION 3.21)
project(LiteDictateWorker VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS deployment version")
set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Target architecture")

set(LITEDICTATE_ENGINE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/Build/Engine" CACHE PATH "Directory containing libtranscribe.dylib and libggml-*.dylib")

find_library(TRANSCRIBE_LIB
    NAMES transcribe
    PATHS "${LITEDICTATE_ENGINE_DIR}"
    NO_DEFAULT_PATH
    REQUIRED
)

add_executable(litedictate-worker
    Worker/src/main.cpp
    Worker/src/engine.cpp
)

target_include_directories(litedictate-worker PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/Worker/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/Worker/src"
)

target_link_libraries(litedictate-worker PRIVATE
    "${TRANSCRIBE_LIB}"
)

target_compile_options(litedictate-worker PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -Wno-unused-parameter
)

set_target_properties(litedictate-worker PROPERTIES
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH "@executable_path/../Frameworks;@executable_path/../Engine"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/Build/Worker"
)

# Phase 1 Probe 1 test harness (posix_spawn FD 3/4 + POSIX_SPAWN_CLOEXEC_DEFAULT)
option(LITEDICTATE_BUILD_PROBE "Build WorkerProbe Phase 1 test executable" ON)
if(LITEDICTATE_BUILD_PROBE)
    add_executable(worker-probe
        Tests/WorkerProbe/main.cpp
    )
    target_include_directories(worker-probe PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/Worker/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/Worker/src"
    )
    target_compile_options(worker-probe PRIVATE
        -Wall
        -Wextra
        -Wpedantic
    )
    set_target_properties(worker-probe PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/Build/Worker"
    )
endif()
