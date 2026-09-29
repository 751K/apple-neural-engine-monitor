# SwiftPM is optional: the Command Line Tools on some macOS 27 installs ship a
# PackageDescription library that fails to link, so build with swiftc directly.
BUILD   := .build/make
C_SRC   := $(wildcard Sources/CANEMon/*.c)
C_OBJ   := $(patsubst Sources/CANEMon/%.c,$(BUILD)/%.o,$(C_SRC))
SWIFT   := $(wildcard Sources/anemon/*.swift)
CFLAGS  := -O2 -Wall -ISources/CANEMon/include

all: $(BUILD)/anemon

$(BUILD)/%.o: Sources/CANEMon/%.c Sources/CANEMon/include/canemon.h
	@mkdir -p $(BUILD)
	clang $(CFLAGS) -c $< -o $@

$(BUILD)/anemon: $(C_OBJ) $(SWIFT)
	swiftc -O -swift-version 5 -ISources/CANEMon/include $(SWIFT) $(C_OBJ) \
		-framework CoreFoundation -framework IOKit -o $@

install: $(BUILD)/anemon
	install -m 755 $(BUILD)/anemon /usr/local/bin/anemon

clean:
	rm -rf $(BUILD)

.PHONY: all install clean
