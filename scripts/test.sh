#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# With only the Command Line Tools installed, Swift Testing ships in a folder SwiftPM does not search on its own.
frameworks=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [[ -d "$frameworks/Testing.framework" ]] && ! xcode-select -p | grep -q "Xcode"; then
    exec swift test -Xswiftc -F -Xswiftc "$frameworks" -Xlinker -F -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib "$@"
fi
exec swift test "$@"
