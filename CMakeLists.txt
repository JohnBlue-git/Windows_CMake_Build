cmake_minimum_required(VERSION 3.16)

project(CMakeThreadDemo VERSION 1.0 LANGUAGES CXX)

find_package(Threads REQUIRED)

add_library(MyLibrary SHARED
    src/my_library.cpp
)

target_include_directories(MyLibrary
    PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_compile_features(MyLibrary PUBLIC cxx_std_17)
target_compile_definitions(MyLibrary PRIVATE MYDLL_EXPORTS)

add_executable(ThreadDemo
    src/main.cpp
)

target_link_libraries(ThreadDemo
    PRIVATE
        MyLibrary
        Threads::Threads
)

set_target_properties(MyLibrary ThreadDemo PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)

if(UNIX AND NOT APPLE)
    set_target_properties(MyLibrary PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    )
endif()