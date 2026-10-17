#!/bin/sh
# Rebuild the mount programs (run inside the mount folder)
cd "$(dirname "$0")"
gcc -O2 -Wall -o mounttest mounttest.c && echo "built ./mounttest"
gcc -O2 -Wall -o mountjog mountjog.c -lm && echo "built ./mountjog"
