#!/usr/bin/env bash
# Builds the Hysteria2 client core into ios/Frameworks/Hy2bridge.xcframework (device + simulator) with gomobile.
set -euo pipefail
cd "$(dirname "$0")/../hy2bridge"
go version
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
export PATH="$PATH:$(go env GOPATH)/bin"
gomobile init
go mod tidy
go get golang.org/x/mobile@latest
go mod download
mkdir -p ../Frameworks
rm -rf ../Frameworks/Hy2bridge.xcframework
# verify the dependency is really present (this is what failed before)
go list -m golang.org/x/mobile
gomobile bind -target=ios,iossimulator -iosversion=17.0 -o ../Frameworks/Hy2bridge.xcframework .
ls -R ../Frameworks | head -20
file ../Frameworks/Hy2bridge.xcframework/*/Hy2bridge.framework/Hy2bridge || true
