#include "my_library.h"

#include <iostream>
#include <thread>

int main() {
    std::cout << "Starting thread demo.\n";

    std::thread worker(print_library_message);
    worker.join();

    std::cout << "Thread finished.\n";
    return 0;
}