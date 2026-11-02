#pragma once

// Windows DLLs need to distinguish exported symbols from imported symbols.
#ifdef _WIN32
    // CMake defines MYDLL_EXPORTS only while compiling the MyLibrary target.
    #ifdef MYDLL_EXPORTS
        #define MYDLL_API __declspec(dllexport)
    #else
        #define MYDLL_API __declspec(dllimport)
    #endif
#else
    // This demo uses the platform's default symbol visibility on Linux.
    #define MYDLL_API
#endif

// Public function provided by the shared library.
MYDLL_API void print_library_message();