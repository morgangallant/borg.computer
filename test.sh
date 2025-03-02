#!/bin/bash

# Helper script for running tests on my Linux devbox.
# Specifically, I use the cached Zig version from the Github Actions runner.

sudo /home/mg/actions-runner/_work/_tool/zig/0.14.0-dev.3223/x64/zig build test
