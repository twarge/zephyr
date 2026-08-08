# Builds everything Zephyr is: the ZulipKit packages and their tests, and
# the Mac and iOS apps.
#
#   make            everything below
#   make test       ZulipKit package tests (model, API, content, math)
#   make mac        debug app        (make mac-release for optimised)
#   make ios        simulator build  (make ios-device for a signed device build)
#   make run        build and launch the Mac app
#   make generate   regenerate Zephyr.xcodeproj from project.yml (xcodegen)
#   make clean

.PHONY: all test mac mac-release ios ios-device run generate clean

all: test mac ios

test:
	swift test --package-path Packages/ZulipKit

# Exactly what Xcode's own Build does — same scheme, same default
# DerivedData — so a make build and a ⌘B are the same build.
mac:
	xcodebuild -project Zephyr.xcodeproj -scheme Zephyr \
	  -destination "platform=macOS" -quiet build
	@echo "==> Built for macOS"

mac-release:
	xcodebuild -project Zephyr.xcodeproj -scheme Zephyr \
	  -destination "platform=macOS" -configuration Release -quiet build
	@echo "==> Built for macOS (Release)"

ios:
	xcodebuild -project Zephyr.xcodeproj -scheme Zephyr \
	  -destination "generic/platform=iOS Simulator" -quiet build
	@echo "==> Built for iOS Simulator"

ios-device:
	xcodebuild -project Zephyr.xcodeproj -scheme Zephyr \
	  -destination "generic/platform=iOS" -allowProvisioningUpdates -quiet build
	@echo "==> Built for iOS device"

run: mac
	@open "$$(xcodebuild -project Zephyr.xcodeproj -scheme Zephyr \
	  -destination 'platform=macOS' -showBuildSettings build 2>/dev/null \
	  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $$2; exit}')/Zephyr.app"

# The generated project is committed (CI needs no extra step); regenerate
# after editing project.yml.
generate:
	xcodegen generate

clean:
	xcodebuild -project Zephyr.xcodeproj -scheme Zephyr -quiet clean || true
	rm -rf Packages/ZulipKit/.build
