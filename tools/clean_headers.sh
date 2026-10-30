#!/bin/bash
set -eu

export ANDROID_BUILD_TOP="$PWD"

./bionic/libc/kernel/tools/clean_header.py -u \
    "$1/usr/include/asm/signal.h" \
    "$1/usr/include/asm-generic/signal.h"

# Let bionic provide the architecture-specific signal context header. The
# device kernel headers are generated for the 64-bit kernel architecture, but
# 32-bit vendor modules also consume them and cannot parse AArch64-only types
# such as __uint128_t in asm/sigcontext.h.
rm -f "$1/usr/include/asm/sigcontext.h"
