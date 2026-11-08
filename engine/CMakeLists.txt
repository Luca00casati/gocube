# GoCube voxel engine: a GDExtension for stock Godot 4.5+.
#   cmake -S engine -B engine/build -DCMAKE_BUILD_TYPE=Release
#   cmake --build engine/build -j
# Output: bin/libgocube.linux.<target>.x86_64.so, loaded via bin/gocube.gdextension.
cmake_minimum_required(VERSION 3.17)
project(gocube_engine LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(GODOTCPP_TARGET "template_debug" CACHE STRING "template_debug or template_release")

add_subdirectory(godot-cpp)

file(GLOB GOCUBE_SOURCES CONFIGURE_DEPENDS src/*.cpp)
add_library(gocube SHARED ${GOCUBE_SOURCES})
target_link_libraries(gocube PRIVATE godot::cpp)
target_compile_options(gocube PRIVATE -O2 -Wall)
set_target_properties(gocube PROPERTIES
    PREFIX "lib"
    OUTPUT_NAME "gocube.linux.${GODOTCPP_TARGET}.x86_64"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../bin")
