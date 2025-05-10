#!/bin/sh
export CC=~/opt/android-ndk-r26d/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android24-clang
export CXX=~/opt/android-ndk-r26d/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android24-clang++
export GOOS=android
export GOARCH=amd64
export CGO_ENABLED=1
go build

# if "no space left on device" run sudo mount -o remount,size=4G /tmp
