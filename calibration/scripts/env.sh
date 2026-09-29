# Shared settings, sourced by the other scripts.
CAL=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN=$CAL/tools/bin                  # built with: (cd tools && go build -o bin/ ./cmd/...)
WORK=${WORK:-$CAL/.work}            # generated models and raw outputs
MODELS=$WORK/models
# dump_ane_pmu_objc from https://github.com/freedomtan/ane_pmu_profiler
PROFILER=${PROFILER:-dump_ane_pmu_objc}
PYTHON=${PYTHON:-python3}           # needs coremltools 9 for the CoreML scripts
mkdir -p "$MODELS"

# Scripts that must run as root start workloads as the invoking user,
# whose ANE compiler cache lives under their own TMPDIR.
as_user() {
  local u=${SUDO_USER:-$USER}
  if [ "$(id -u)" = 0 ] && [ -n "$SUDO_USER" ]; then
    sudo -u "$u" env HOME="/Users/$u" TMPDIR="$(sudo -u "$u" getconf DARWIN_USER_TEMP_DIR)" "$@"
  else
    "$@"
  fi
}
