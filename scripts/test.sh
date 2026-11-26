#!/bin/zsh
# Unit + integration tests (real Vision / Translation / ScreenCaptureKit). Non-zero exit if anything fails.
set -e
cd "${0:A:h}/.."
bin=$(mktemp -d)/lensy-tests
swiftc -D TESTING Sources/*.swift Tests/*.swift -o "$bin"
"$bin"
