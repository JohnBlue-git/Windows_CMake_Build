#include "my_library.h"

#include <iostream>

void print_library_message() {
    std::cout << "Hello from the shared library on a worker thread.\n";
}