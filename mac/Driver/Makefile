# Builds build/MixdeckDriver.driver (ad-hoc signed; enough for local use, see docs/decisions.md)
BUNDLE := build/MixdeckDriver.driver
BIN    := $(BUNDLE)/Contents/MacOS/MixdeckDriver
CFLAGS := -O2 -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations -fvisibility=hidden -mmacosx-version-min=14.4

all: $(BUNDLE)

$(BUNDLE): MixdeckDriver.c Info.plist
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	clang $(CFLAGS) -bundle -o $(BIN) MixdeckDriver.c -framework CoreAudio -framework CoreFoundation
	codesign --force --sign - $(BUNDLE)
	@touch $(BUNDLE)

clean:
	rm -rf build

.PHONY: all clean

build/driver_test: tests/driver_test.c
	mkdir -p build
	clang -Wall -Wno-deprecated-declarations -o $@ $< -framework CoreAudio -framework CoreFoundation

test: $(BUNDLE) build/driver_test
	build/driver_test $(BIN)

.PHONY: test
