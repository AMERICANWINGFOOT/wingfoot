#!/bin/sh
# Build libpmmount.so (mount control) for PMQBauto (PoleMasterQB v2).
# Run this inside the PoleMasterQB folder:   sh build_pmmount.sh
set -e
cd "$(dirname "$0")"
[ -f pmmount.c ] || { echo "missing pmmount.c"; exit 1; }
gcc -O2 -Wall -shared -fPIC -o libpmmount.so pmmount.c -lpthread -lm
echo "built libpmmount.so"
