// Copyright 2026 DinoX contributors.
// SPDX-License-Identifier: Apache-2.0
// Proves the real POSIX adapter closes an unrelated non-CLOEXEC parent fd.
#include "vision_process.hpp"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>
#if !defined(_WIN32)
#include <fcntl.h>
#include <unistd.h>
#endif

#define CHECK(value) do { if (!(value)) { std::cerr << "FD_INHERITANCE_FAIL line " << __LINE__ << '\n'; return 1; } } while(false)
int main(int argc,char** argv) {
#if defined(_WIN32)
    (void)argc;(void)argv;
    return 77; // Windows uses its separately reviewed explicit handle allowlist.
#else
    using namespace dinox::vision::process_detail;
    CHECK(argc==2);
    std::string executable;
    // The OS supplies argc valid NUL-terminated arguments.
#if defined(__clang__)
#pragma clang unsafe_buffer_usage begin
#endif
    executable=argv[1];
#if defined(__clang__)
#pragma clang unsafe_buffer_usage end
#endif
    const int original=::open("/dev/null",O_RDONLY);
    CHECK(original>=0);
    const int inherited=::fcntl(original,F_DUPFD,80);
    ::close(original);
    CHECK(inherited>=80);
    CHECK((::fcntl(inherited,F_GETFD)&FD_CLOEXEC)==0);
    auto process=make_process();
    prepare_io_thread();
    CHECK(process->launch(Paths{executable,"normal","normal"}));
    const std::string child_list="/proc/self/task/"+std::to_string(::getpid())+"/children";
    std::ifstream children(child_list);
    int child=0;children>>child;
    CHECK(child>0);
    CHECK(!std::filesystem::exists("/proc/"+std::to_string(child)+"/fd/"+std::to_string(inherited)));
    CHECK(::fcntl(inherited,F_GETFD)>=0); // Parent fd ownership is unchanged.
    process->stop();
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(2);
    while (!process->quiescent()&&std::chrono::steady_clock::now()<deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    CHECK(process->quiescent());
    ::close(inherited);
    std::cout << "FD_INHERITANCE_PASS: child owns stdio only, parent fd preserved\n";
    return 0;
#endif
}
