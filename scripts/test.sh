#!/bin/sh
# Runs `swift test` with only Command Line Tools installed (no Xcode): points SwiftPM at the
# Swift Testing framework that ships inside the CLT. Extra args are passed to `swift test`.
set -eu
DEV=/Library/Developer/CommandLineTools/Library/Developer
exec swift test \
  -Xswiftc -F -Xswiftc "$DEV/Frameworks" \
  -Xlinker -F -Xlinker "$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/usr/lib" "$@"
