# SwiftPM is optional: the Command Line Tools on some macOS 27 installs ship a
# PackageDescription library that fails to link, so build with swiftc directly.
BUILD   := .build/make
C_SRC   := $(wildcard Sources/CANEMon/*.c)
C_OBJ   := $(patsubst Sources/CANEMon/%.c,$(BUILD)/%.o,$(C_SRC))
SWIFT   := $(wildcard Sources/anemon/*.swift)
CFLAGS  := -O2 -Wall -ISources/CANEMon/include

BENCH_SWIFT := $(wildcard Sources/anebench/*.swift)
RUN_OBJ     := $(BUILD)/anerun.o

all: $(BUILD)/anemon $(BUILD)/anebench

$(BUILD)/%.o: Sources/CANEMon/%.c Sources/CANEMon/include/canemon.h
	@mkdir -p $(BUILD)
	clang $(CFLAGS) -c $< -o $@

$(BUILD)/anemon: $(C_OBJ) $(SWIFT)
	swiftc -O -swift-version 5 -ISources/CANEMon/include $(SWIFT) $(C_OBJ) \
		-framework CoreFoundation -framework IOKit -o $@

# anebench: ANE workload generator/runner used by calibration/ scripts.
$(RUN_OBJ): Sources/CANERun/anerun.m Sources/CANERun/include/anerun.h
	@mkdir -p $(BUILD)
	clang -O2 -Wall -fobjc-arc -ISources/CANERun/include -c $< -o $@

$(BUILD)/anebench: $(RUN_OBJ) $(BENCH_SWIFT)
	swiftc -O -swift-version 5 -ISources/CANERun/include $(BENCH_SWIFT) $(RUN_OBJ) \
		-framework Foundation -framework IOSurface -o $@

install: all
	install -m 755 $(BUILD)/anemon $(BUILD)/anebench /usr/local/bin/

clean:
	rm -rf $(BUILD)

.PHONY: all install clean
