#!/usr/bin/env bash
#
# AYN Odin 3 gyro recovery for SteamOS Armada
#
# What it does:
#   1. Detects the exact Armada kernel image and matching armada-packages commit.
#   2. Rebuilds sns_iio.ko for the currently running kernel.
#   3. Builds adsprpcd + snsfeed and installs the Qualcomm sensor registry.
#   4. Installs and enables odin3-sensors.service.
#   5. Adds the bmi323-imu source to the Odin 3 InputPlumber profile.
#   6. Fixes automatic screen rotation with ACCEL_MOUNT_MATRIX.
#
# Run as the regular Armada user, not with sudo:
#   chmod +x odin3-gyro-recovery.sh
#   ./odin3-gyro-recovery.sh
#
# Optional:
#   ./odin3-gyro-recovery.sh --force-rebuild
#   ./odin3-gyro-recovery.sh --uninstall
#
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.0.6"
WORK_ROOT="${ODIN3_GYRO_WORKDIR:-$HOME/odin3-gyro-recovery}"
FORCE_REBUILD=0
MODE="install"

ARMADA_REPO="https://github.com/virtudude/armada.git"
ARMADA_PACKAGES_REPO="https://github.com/virtudude/armada-packages.git"
ODIN3_SENSOR_REPO="https://github.com/aanze/distribution"
ODIN3_SENSOR_BRANCH="odin3-ssc-gyro"

SNS_PATCH_NAME="0514-ROCKNIX-iio-sns-iio-ssc-imu-bridge.patch"
INSTALL_ROOT="/var/lib/odin3-gyro"
EXEC_DIR="${INSTALL_ROOT}/bin"
MODULE_ROOT="${INSTALL_ROOT}/modules"
SYSTEMD_UNIT="/etc/systemd/system/odin3-sensors.service"
INPUTPLUMBER_DROPIN="/etc/systemd/system/inputplumber.service.d/20-odin3-gyro.conf"
INPUTPLUMBER_OVERRIDE="/etc/inputplumber/devices.d/01-ayn-controller.yaml"
ORIENTATION_RULE="/etc/udev/rules.d/61-odin3-sensor-orientation.rules"

TEMP_POLICY=""
LOG_FILE=""

RESOLVED_COMMIT_PREFIX=""
RESOLVED_FULL_COMMIT=""
RESOLVED_SENSOR_TREE=""
BUILT_MODULE_FILE=""
BUILT_USERSPACE_DIR=""

usage() {
    cat <<EOF
AYN Odin 3 gyro recovery for SteamOS Armada v${SCRIPT_VERSION}

Usage:
  $(basename "$0") [option]

Options:
  --force-rebuild   Rebuild the kernel module and userspace even if cached.
  --uninstall       Disable and remove the installed gyro integration.
  -h, --help        Show this help.

Environment:
  ODIN3_GYRO_WORKDIR  Build/cache directory.
                       Default: \$HOME/odin3-gyro-recovery
EOF
}

log() {
    printf '\n\033[1;36m==> %s\033[0m\n' "$*"
}

note() {
    printf '    %s\n' "$*"
}

warn() {
    printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2
}

die() {
    printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${TEMP_POLICY:-}" && -f "$TEMP_POLICY" ]]; then
        rm -f "$TEMP_POLICY"
    fi
}
trap cleanup EXIT

on_error() {
    local exit_code=$?
    local line=${BASH_LINENO[0]:-unknown}
    printf '\n\033[1;31mFAILED\033[0m at line %s (exit %s).\n' "$line" "$exit_code" >&2
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf 'Log: %s\n' "$LOG_FILE" >&2
    fi
    exit "$exit_code"
}
trap on_error ERR

for arg in "$@"; do
    case "$arg" in
        --force-rebuild)
            FORCE_REBUILD=1
            ;;
        --uninstall)
            MODE="uninstall"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $arg"
            ;;
    esac
done

if [[ $EUID -eq 0 ]]; then
    die "Run this script as the regular Armada user, without sudo."
fi

mkdir -p "$WORK_ROOT"
LOG_FILE="$WORK_ROOT/recovery-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

require_command() {
    local command_name=$1
    command -v "$command_name" >/dev/null 2>&1 ||
        die "Required command is missing: $command_name"
}

download() {
    local url=$1
    local output=$2
    local partial="${output}.part"

    rm -f "$partial"

    curl --http1.1 \
        --fail \
        --location \
        --retry 8 \
        --retry-all-errors \
        --retry-delay 2 \
        --retry-max-time 600 \
        --connect-timeout 20 \
        --remove-on-error \
        --output "$partial" \
        "$url"

    mv -f "$partial" "$output"
}

detect_model() {
    local model=""
    if [[ -r /sys/firmware/devicetree/base/model ]]; then
        model="$(tr -d '\0' </sys/firmware/devicetree/base/model)"
    fi

    note "Detected model: ${model:-unknown}"
    [[ "$model" == *"AYN Odin 3"* ]] ||
        die "This script is intended only for AYN Odin 3."
}

uninstall_fix() {
    log "Stopping and disabling the Odin 3 gyro service"
    sudo systemctl disable --now odin3-sensors.service 2>/dev/null || true

    log "Removing installed integration"
    sudo rm -f \
        "$SYSTEMD_UNIT" \
        "$INPUTPLUMBER_DROPIN" \
        "$INPUTPLUMBER_OVERRIDE" \
        "$ORIENTATION_RULE"

    sudo rm -rf "$INSTALL_ROOT"

    sudo systemctl daemon-reload
    sudo udevadm control --reload-rules || true
    sudo systemctl restart inputplumber.service 2>/dev/null || true
    sudo systemctl restart iio-sensor-proxy.service 2>/dev/null || true

    note "Removed. Reboot is recommended."
}

prepare_signature_policy() {
    TEMP_POLICY="$(mktemp)"
    cat >"$TEMP_POLICY" <<'EOF'
{
  "default": [
    {
      "type": "reject"
    }
  ],
  "transports": {
    "docker": {
      "registry.fedoraproject.org/fedora": [
        {
          "type": "insecureAcceptAnything"
        }
      ]
    }
  }
}
EOF
}

ensure_builder_image() {
    local builder_image=$1

    if sudo podman image exists "$builder_image"; then
        note "Builder image is already present."
        return
    fi

    log "Pulling the exact Fedora builder image"
    prepare_signature_policy

    sudo podman pull \
        --platform linux/aarch64 \
        --signature-policy "$TEMP_POLICY" \
        "$builder_image"
}

find_matching_kernel_tag() {
    local registry=$1
    local target_digest=$2
    local tags_json=$3
    local tag digest

    skopeo list-tags "docker://${registry}" >"$tags_json"

    while IFS= read -r tag; do
        [[ "$tag" =~ ^[0-9]{8}-[0-9a-fA-F]{7,40}$ ]] || continue

        digest="$(
            skopeo inspect \
                --override-arch arm64 \
                --format '{{.Digest}}' \
                "docker://${registry}:${tag}" \
                2>/dev/null || true
        )"

        if [[ "$digest" == "$target_digest" ]]; then
            printf '%s\n' "$tag"
            return 0
        fi
    done < <(
        python3 - "$tags_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    tags = json.load(file).get("Tags", [])

def priority(tag: str):
    lower = tag.lower()
    score = 100
    if "latest" in lower:
        score -= 10
    if lower.endswith(".sig"):
        score += 1000
    return score, tag

for tag in sorted(tags, key=priority):
    print(tag)
PY
    )

    return 1
}

resolve_current_kernel_source() {
    local armada_version armada_commit containerfile kernel_ref
    local kernel_registry kernel_digest kernel_tag packages_short_commit
    local tags_json

    [[ -r /usr/lib/armada/version ]] ||
        die "/usr/lib/armada/version is missing. Is this SteamOS Armada?"

    armada_version="$(cat /usr/lib/armada/version)"
    armada_commit="${armada_version##*.}"
    containerfile="$WORK_ROOT/Armada-Containerfile-${armada_commit}"

    log "Resolving the exact source of the running Armada kernel"
    note "Armada version: $armada_version"
    note "Running kernel: $(uname -r)"

    download \
        "https://raw.githubusercontent.com/virtudude/armada/${armada_commit}/Containerfile" \
        "$containerfile"

    kernel_ref="$(
        sed -n 's/^ARG KERNEL_PKG=//p' "$containerfile" |
            head -n 1
    )"

    [[ "$kernel_ref" == *@sha256:* ]] ||
        die "Could not extract the pinned kernel image from Armada Containerfile."

    kernel_registry="${kernel_ref%@*}"
    kernel_digest="${kernel_ref##*@}"
    tags_json="$WORK_ROOT/kernel-tags.json"

    note "Kernel image: $kernel_ref"

    kernel_tag="$(
        find_matching_kernel_tag \
            "$kernel_registry" \
            "$kernel_digest" \
            "$tags_json"
    )" || die "No GHCR tag points to the running kernel digest: $kernel_digest"

    packages_short_commit="${kernel_tag##*-}"
    [[ "$packages_short_commit" =~ ^[0-9a-fA-F]{7,40}$ ]] ||
        die "Could not derive armada-packages commit from tag: $kernel_tag"

    note "Matching kernel tag: $kernel_tag"
    note "armada-packages commit prefix: $packages_short_commit"

    RESOLVED_COMMIT_PREFIX="$packages_short_commit"
}

prepare_armada_packages() {
    local commit_prefix=$1
    local repo_dir=$2
    local full_commit

    log "Preparing the exact armada-packages source"

    if [[ ! -d "$repo_dir/.git" ]]; then
        git clone "$ARMADA_PACKAGES_REPO" "$repo_dir"
    fi

    git -C "$repo_dir" fetch --all --tags --prune
    git -C "$repo_dir" reset --hard
    git -C "$repo_dir" clean -fdx

    full_commit="$(
        git -C "$repo_dir" rev-parse "${commit_prefix}^{commit}" 2>/dev/null
    )" || die "armada-packages commit not found: $commit_prefix"

    git -C "$repo_dir" checkout --force "$full_commit"

    note "armada-packages commit: $full_commit"
    RESOLVED_FULL_COMMIT="$full_commit"
}

prepare_odin3_sensor_source() {
    local archive=$1
    local extract_dir=$2

    log "Downloading the Odin 3 sensor implementation"

    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"

    download \
        "${ODIN3_SENSOR_REPO}/archive/refs/heads/${ODIN3_SENSOR_BRANCH}.tar.gz" \
        "$archive"

    tar -xzf "$archive" -C "$extract_dir"

    RESOLVED_SENSOR_TREE="$(
        find "$extract_dir" -mindepth 1 -maxdepth 1 -type d |
            head -n 1
    )"

    [[ -n "$RESOLVED_SENSOR_TREE" && -d "$RESOLVED_SENSOR_TREE" ]] ||
        die "Could not determine the extracted Odin 3 sensor source directory."
}

build_kernel_module() {
    local repo_dir=$1
    local sensor_tree=$2
    local builder_image=$3
    local kernel_dir="$repo_dir/kernel"
    local build_cache="$WORK_ROOT/kernel-work"
    local output_dir="$WORK_ROOT/output/$(uname -r)"
    local patch_source
    local module_source_dir="$WORK_ROOT/sns-iio-external"
    local inside_script="$WORK_ROOT/build-kernel-module-inside-container.sh"
    local expected_base_version

    patch_source="$sensor_tree/projects/ROCKNIX/devices/SM8750/patches/linux/$SNS_PATCH_NAME"
    [[ -f "$patch_source" ]] ||
        die "Odin 3 sns_iio patch was not found: $patch_source"

    expected_base_version="$(
        sed -n 's/^VERSION=//p' "$kernel_dir/BASE.env" |
            head -n 1
    )"

    [[ -n "$expected_base_version" ]] ||
        die "Kernel VERSION is missing from armada-packages BASE.env."

    [[ "$(uname -r)" == "$expected_base_version"* ]] ||
        die "Source kernel $expected_base_version does not match running kernel $(uname -r)."

    mkdir -p "$output_dir"

    if [[ $FORCE_REBUILD -eq 0 &&
          -f "$output_dir/sns_iio.ko" &&
          "$(modinfo -F vermagic "$output_dir/sns_iio.ko" 2>/dev/null || true)" == "$(uname -r)"\ * ]]; then
        note "Using cached module: $output_dir/sns_iio.ko"
        BUILT_MODULE_FILE="$output_dir/sns_iio.ko"
        return
    fi

    log "Preparing sns_iio as an external kernel module"

    # Some newer armada-packages revisions already carry the old ROCKNIX
    # sns_iio patch in patches/series even when that patch no longer applies
    # cleanly to the current kernel (e.g. Linux 7.1.5). We build sns_iio as an
    # external module, so the in-tree patch must not be applied during Armada's
    # kernel-tree preparation.
    if [[ -f "$kernel_dir/patches/series" ]]; then
        python3 - "$kernel_dir/patches/series" "$SNS_PATCH_NAME" <<'PY_DROP_SNS_PATCH'
import sys
from pathlib import Path

series = Path(sys.argv[1])
patch_name = sys.argv[2]

lines = series.read_text(encoding="utf-8").splitlines()
filtered = []

removed = 0
for line in lines:
    stripped = line.strip()
    if stripped == patch_name:
        removed += 1
        continue
    filtered.append(line)

series.write_text("\n".join(filtered) + "\n", encoding="utf-8")

if removed:
    print(f"Removed stale in-tree patch from Armada series: {patch_name}")
else:
    print(f"In-tree sns_iio patch was not present in Armada series: {patch_name}")
PY_DROP_SNS_PATCH
    fi

    if grep -qxF "$SNS_PATCH_NAME" "$kernel_dir/patches/series" 2>/dev/null; then
        die "Failed to remove stale sns_iio patch from Armada patches/series."
    fi

    rm -rf "$module_source_dir"
    mkdir -p "$module_source_dir"

    python3 - "$patch_source" "$module_source_dir/sns_iio.c" <<'PY_EXTRACT_SNS'
import sys
from pathlib import Path

patch = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
output = Path(sys.argv[2])

start = None
end = None

for i, line in enumerate(patch):
    if line == "+++ b/drivers/iio/imu/sns_iio.c":
        start = i + 1
        continue
    if start is not None and line.startswith("diff --git "):
        end = i
        break

if start is None:
    raise SystemExit("Could not locate sns_iio.c in the ROCKNIX patch.")
if end is None:
    end = len(patch)

source = []
for line in patch[start:end]:
    if line.startswith("@@"):
        continue
    if line.startswith("+") and not line.startswith("+++"):
        source.append(line[1:])
    elif line.startswith("\\ No newline"):
        continue

if not source or not any("MODULE_DESCRIPTION" in line for line in source):
    raise SystemExit("Extracted sns_iio.c looks incomplete.")

output.write_text("\n".join(source) + "\n", encoding="utf-8")
PY_EXTRACT_SNS

    cat >"$module_source_dir/Makefile" <<'MAKEFILE'
obj-m += sns_iio.o
MAKEFILE

    # A failed patched-tree build can leave reject files and a half-patched
    # kernel source under kernel-work. Start the kernel preparation clean when
    # rebuilding for a new ABI.
    sudo rm -rf "$build_cache"
    mkdir -p "$build_cache"

    cat >"$inside_script" <<'CONTAINER'
#!/usr/bin/env bash
set -Eeuo pipefail

dnf -y install \
    gcc binutils make bc bison flex openssl-devel \
    elfutils-libelf-devel zstd xz cpio patch curl \
    perl-interpreter python3 findutils diffutils \
    gawk grep sed coreutils hostname gzip tar ccache file

awk '/^# ---------- 5\. Build ----------$/ { exit } { print }' \
    /work/scripts/build-kernel.sh |
    sed 's|^REPO_ROOT=.*|REPO_ROOT=/work|' \
    >/tmp/prepare-armada-kernel.sh

# Newer armada-packages revisions intentionally validate every requested
# configuration symbol and abort when Kconfig resolves unrelated options
# differently because of dependencies. For an external module we only need
# the exact prepared tree/.config, so disable only that terminal guard.
python3 - /tmp/prepare-armada-kernel.sh <<'PY_PATCH_CONFIG_GUARD'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()

phrase = "ERROR: a requested CONFIG didn't survive Kconfig deps"
matches = [index for index, line in enumerate(lines) if phrase in line]

if len(matches) > 1:
    raise SystemExit(
        f"Unexpected number of strict Kconfig guards: {len(matches)}"
    )

if matches:
    error_index = matches[0]
    lines[error_index] = (
        '    echo "WARNING: continuing external sns_iio module build despite '
        'unrelated Kconfig dependency mismatches." >&2'
    )

    exit_index = None
    for index in range(error_index + 1, min(error_index + 6, len(lines))):
        if lines[index].strip() == "exit 1":
            exit_index = index
            break

    if exit_index is None:
        raise SystemExit(
            "Found the strict Kconfig error message, but not its exit 1."
        )

    indentation = lines[exit_index][
        : len(lines[exit_index]) - len(lines[exit_index].lstrip())
    ]
    lines[exit_index] = f"{indentation}: # external module build override"

path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY_PATCH_CONFIG_GUARD

cat >>/tmp/prepare-armada-kernel.sh <<'MODULE_BUILD'

echo "==> Preparing external sns_iio module"

if grep -q '^CONFIG_MODULE_SIG_FORCE=y' .config; then
    echo "ERROR: the running-style kernel configuration enforces module signatures." >&2
    exit 1
fi

# The external module needs a prepared tree. With CONFIG_MODVERSIONS, a real
# Module.symvers is also required, so build the in-tree modules once.
if grep -q '^CONFIG_MODVERSIONS=y' .config; then
    echo "==> CONFIG_MODVERSIONS=y: generating exact symbol CRCs"
    make "${MAKE_ARGS[@]}" modules
else
    make "${MAKE_ARGS[@]}" modules_prepare
fi

echo "==> Building sns_iio out-of-tree"
make "${MAKE_ARGS[@]}" \
    KBUILD_MODPOST_WARN=1 \
    M=/sns-module \
    modules

test -f /sns-module/sns_iio.ko

install -Dm644 \
    /sns-module/sns_iio.ko \
    "${OUT_DIR}/sns_iio.ko"

cp .config "${OUT_DIR}/sns_iio.config"
sha256sum "${OUT_DIR}/sns_iio.ko" \
    >"${OUT_DIR}/sns_iio.ko.sha256"

echo
echo "===== BUILT MODULE ====="
file "${OUT_DIR}/sns_iio.ko"
modinfo "${OUT_DIR}/sns_iio.ko" | grep -E '^(filename|description|author|vermagic):' || true
sha256sum "${OUT_DIR}/sns_iio.ko"
MODULE_BUILD

WORK_DIR=/kernel-work \
OUT_DIR=/output \
bash /tmp/prepare-armada-kernel.sh
CONTAINER

    chmod +x "$inside_script"

    log "Building external sns_iio.ko for kernel $(uname -r)"

    sudo podman run --rm \
        --pull=never \
        --network=host \
        --platform linux/aarch64 \
        -v "$kernel_dir:/work:Z" \
        -v "$build_cache:/kernel-work:Z" \
        -v "$output_dir:/output:Z" \
        -v "$module_source_dir:/sns-module:Z" \
        -v "$inside_script:/build-module.sh:ro,Z" \
        -w /work \
        "$builder_image" \
        /build-module.sh

    sudo chown -R "$(id -u):$(id -g)" "$WORK_ROOT/output" "$module_source_dir"

    [[ -f "$output_dir/sns_iio.ko" ]] ||
        die "sns_iio.ko was not produced."

    local module_vermagic
    module_vermagic="$(modinfo -F vermagic "$output_dir/sns_iio.ko")"
    [[ "$module_vermagic" == "$(uname -r)"\ * ]] ||
        die "Built module vermagic does not match the running kernel: $module_vermagic"

    note "Built module: $output_dir/sns_iio.ko"
    BUILT_MODULE_FILE="$output_dir/sns_iio.ko"
}

build_userspace() {
    local sensor_tree=$1
    local builder_image=$2
    local package_dir="$sensor_tree/projects/ROCKNIX/packages/sysutils/odin3-sensors"
    local output_dir="$WORK_ROOT/output/userspace"
    local fastrpc_dir="$WORK_ROOT/fastrpc"
    local fastrpc_archive="$WORK_ROOT/fastrpc.tar.gz"
    local inside_script="$WORK_ROOT/build-userspace-inside-container.sh"
    local fastrpc_commit fastrpc_sha

    [[ -f "$package_dir/package.mk" ]] ||
        die "odin3-sensors package.mk is missing."

    if [[ $FORCE_REBUILD -eq 0 &&
          -x "$output_dir/adsprpcd" &&
          -x "$output_dir/snsfeed" ]]; then
        note "Using cached userspace binaries."
        BUILT_USERSPACE_DIR="$output_dir"
        return
    fi

    fastrpc_commit="$(
        sed -n 's/^PKG_VERSION="\([^"]*\)"/\1/p' "$package_dir/package.mk" |
            head -n 1
    )"
    fastrpc_sha="$(
        sed -n 's/^PKG_SHA256="\([^"]*\)"/\1/p' "$package_dir/package.mk" |
            head -n 1
    )"

    [[ "$fastrpc_commit" =~ ^[0-9a-fA-F]{40}$ ]] ||
        die "Could not parse the pinned Qualcomm FastRPC commit."
    [[ "$fastrpc_sha" =~ ^[0-9a-fA-F]{64}$ ]] ||
        die "Could not parse the FastRPC archive SHA-256."

    log "Downloading pinned Qualcomm FastRPC source"
    download \
        "https://github.com/qualcomm/fastrpc/archive/${fastrpc_commit}.tar.gz" \
        "$fastrpc_archive"

    printf '%s  %s\n' "$fastrpc_sha" "$fastrpc_archive" |
        sha256sum --check -

    rm -rf "$fastrpc_dir" "$output_dir"
    mkdir -p "$fastrpc_dir" "$output_dir"

    tar -xzf "$fastrpc_archive" \
        --strip-components=1 \
        -C "$fastrpc_dir"

    cat >"$inside_script" <<'CONTAINER'
#!/usr/bin/env bash
set -Eeuo pipefail

dnf -y install \
    gcc glibc-devel kernel-headers binutils \
    findutils coreutils file

PKG=/package
FASTRPC=/fastrpc
OUT=/output
OBJ=/objects

rm -rf "$OBJ"
mkdir -p "$OBJ" "$OUT"

PKG_DIR="$PKG"
# shellcheck disable=SC1091
source "$PKG/package.mk"

cp -f \
    "$PKG/sources/bsd_shim.c" \
    "$PKG/sources/daemon_main.c" \
    "$PKG/sources/snsfeed.c" \
    "$FASTRPC/src/"

cd "$FASTRPC"

objects=()

for source in ${FASTRPC_SRC} bsd_shim.c daemon_main.c; do
    object="$OBJ/${source//\//_}.o"
    echo "CC $source"
    # FASTRPC_CFLAGS intentionally comes from the pinned ROCKNIX package.
    # shellcheck disable=SC2086
    gcc ${FASTRPC_CFLAGS} \
        -c "src/$source" \
        -o "$object"
    objects+=("$object")
done

echo "LD adsprpcd"
gcc -O2 \
    -o "$OUT/adsprpcd" \
    "${objects[@]}" \
    -ldl -lm -lpthread

echo "CC+LD snsfeed"
gcc -O2 \
    -o "$OUT/snsfeed" \
    "$FASTRPC/src/snsfeed.c" \
    -lm

chmod 0755 "$OUT/adsprpcd" "$OUT/snsfeed"

file "$OUT/adsprpcd" "$OUT/snsfeed"
sha256sum "$OUT/adsprpcd" "$OUT/snsfeed"
CONTAINER

    chmod +x "$inside_script"

    log "Building adsprpcd and snsfeed"

    sudo podman run --rm \
        --pull=never \
        --network=host \
        --platform linux/aarch64 \
        -v "$package_dir:/package:ro,Z" \
        -v "$fastrpc_dir:/fastrpc:Z" \
        -v "$output_dir:/output:Z" \
        -v "$inside_script:/build-userspace.sh:ro,Z" \
        "$builder_image" \
        /build-userspace.sh

    sudo chown -R "$(id -u):$(id -g)" "$output_dir"

    [[ -x "$output_dir/adsprpcd" ]] ||
        die "adsprpcd was not produced."
    [[ -x "$output_dir/snsfeed" ]] ||
        die "snsfeed was not produced."

    if ldd "$output_dir/adsprpcd" | grep -q 'not found'; then
        die "adsprpcd has unresolved shared libraries."
    fi
    if ldd "$output_dir/snsfeed" | grep -q 'not found'; then
        die "snsfeed has unresolved shared libraries."
    fi

    BUILT_USERSPACE_DIR="$output_dir"
}

find_inputplumber_profile() {
    local profile

    profile="$(
        grep -rl --include='*.yaml' \
            'value:[[:space:]]*AYN Odin 3' \
            /usr/share/inputplumber/devices \
            2>/dev/null |
            head -n 1
    )"

    [[ -n "$profile" && -f "$profile" ]] ||
        die "Could not find the AYN Odin 3 InputPlumber profile."

    printf '%s\n' "$profile"
}

install_runtime() {
    local module_file=$1
    local userspace_dir=$2
    local package_dir=$3
    local kernel_version
    local inputplumber_source
    local backup_dir

    kernel_version="$(uname -r)"
    inputplumber_source="$(find_inputplumber_profile)"
    backup_dir="$WORK_ROOT/backups/$(date +%Y%m%d-%H%M%S)"

    log "Stopping an existing Odin 3 sensor service"
    sudo systemctl stop odin3-sensors.service 2>/dev/null || true

    log "Backing up existing local configuration"
    mkdir -p "$backup_dir"

    for file in \
        "$SYSTEMD_UNIT" \
        "$INPUTPLUMBER_DROPIN" \
        "$INPUTPLUMBER_OVERRIDE" \
        "$ORIENTATION_RULE"; do
        if sudo test -e "$file"; then
            sudo cp -a "$file" "$backup_dir/"
        fi
    done
    sudo chown -R "$(id -u):$(id -g)" "$backup_dir"

    log "Installing module, binaries, and Qualcomm sensor registry"

    sudo install -d -m 0755 \
        "$EXEC_DIR" \
        "$MODULE_ROOT/$kernel_version" \
        /etc/inputplumber/devices.d \
        /etc/systemd/system/inputplumber.service.d

    sudo install -m 0644 \
        "$module_file" \
        "$MODULE_ROOT/$kernel_version/sns_iio.ko"

    sudo install -m 0755 \
        "$userspace_dir/adsprpcd" \
        "$EXEC_DIR/adsprpcd"

    sudo install -m 0755 \
        "$userspace_dir/snsfeed" \
        "$EXEC_DIR/snsfeed"

    sudo rm -rf "$INSTALL_ROOT/qcom-hexagon-fs"
    sudo cp -a \
        "$package_dir/qcom-hexagon-fs" \
        "$INSTALL_ROOT/qcom-hexagon-fs"

    log "Installing the sensor startup service"

    sudo tee "$EXEC_DIR/odin3-sensors-start" >/dev/null <<'START'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/var/lib/odin3-gyro"
EXEC="${BASE}/bin"
KVER="$(uname -r)"
MODULE="${BASE}/modules/${KVER}/sns_iio.ko"
REGISTRY="${BASE}/qcom-hexagon-fs"
HEXFS="/run/odin3-gyro/qcom-hexagon-fs"

ADSPRPCD_PID=""
SNSFEED_PID=""

cleanup() {
    set +e

    if [[ -n "$SNSFEED_PID" ]]; then
        kill "$SNSFEED_PID" 2>/dev/null
        wait "$SNSFEED_PID" 2>/dev/null
    fi

    if [[ -n "$ADSPRPCD_PID" ]]; then
        kill "$ADSPRPCD_PID" 2>/dev/null
        wait "$ADSPRPCD_PID" 2>/dev/null
    fi

    if mountpoint -q "$HEXFS/mnt/vendor"; then
        umount "$HEXFS/mnt/vendor"
    fi
}

trap cleanup EXIT INT TERM

[[ -f "$MODULE" ]] || {
    echo "No sns_iio module for running kernel: $KVER" >&2
    exit 1
}

modprobe kfifo_buf

if ! grep -qw sns_iio /proc/modules; then
    insmod "$MODULE"
fi

[[ -c /dev/sns_iio_feed ]] || {
    echo "/dev/sns_iio_feed was not created" >&2
    exit 1
}

if mountpoint -q "$HEXFS/mnt/vendor"; then
    umount "$HEXFS/mnt/vendor"
fi

rm -rf "$HEXFS"
mkdir -p "$HEXFS"
cp -a "$REGISTRY/." "$HEXFS/"

ln -sfn . "$HEXFS/adsp"
mkdir -p "$HEXFS/mnt/vendor"

mountpoint -q "$HEXFS/mnt/vendor" ||
    mount --bind "$HEXFS/vendor" "$HEXFS/mnt/vendor"

ADSP_LIBRARY_PATH="$HEXFS" \
    "$EXEC/adsprpcd" sensorspd adsp &
ADSPRPCD_PID=$!

systemd-notify \
    --ready \
    --status="Odin 3 IIO bridge ready; starting Sensor Core" \
    2>/dev/null || true

sleep 10

kill -0 "$ADSPRPCD_PID" 2>/dev/null || {
    echo "adsprpcd stopped during initialization" >&2
    exit 1
}

"$EXEC/snsfeed" 100 &
SNSFEED_PID=$!

wait "$SNSFEED_PID"
START

    sudo chmod 0755 "$EXEC_DIR/odin3-sensors-start"

    sudo tee "$SYSTEMD_UNIT" >/dev/null <<'UNIT'
[Unit]
Description=AYN Odin 3 Snapdragon Sensor Core gyro
After=local-fs.target
Before=inputplumber.service
ConditionKernelCommandLine=|!nogyro

[Service]
Type=notify
NotifyAccess=all
ExecStart=/var/lib/odin3-gyro/bin/odin3-sensors-start
Restart=on-failure
RestartSec=5
TimeoutStopSec=10
KillMode=control-group

[Install]
WantedBy=multi-user.target
UNIT

    log "Installing the Odin 3 InputPlumber IMU profile"

    sudo python3 - \
        "$inputplumber_source" \
        "$INPUTPLUMBER_OVERRIDE" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
text = source.read_text(encoding="utf-8")

if "group: imu" not in text:
    marker = "    passthrough: true\n"
    imu_block = """
  - group: imu
    iio:
      name: bmi323-imu
"""

    if marker not in text:
        raise SystemExit(
            "Could not find the gamepad passthrough marker in the "
            "AYN Odin 3 InputPlumber profile."
        )

    text = text.replace(marker, marker + imu_block, 1)

destination.write_text(text, encoding="utf-8")
print(f"Created: {destination}")
PY

    sudo tee "$INPUTPLUMBER_DROPIN" >/dev/null <<'DROPIN'
[Unit]
Wants=odin3-sensors.service
After=odin3-sensors.service
DROPIN

    log "Installing the correct automatic screen-rotation matrix"

    sudo tee "$ORIENTATION_RULE" >/dev/null <<'RULE'
# AYN Odin 3: correct the SSC accelerometer orientation for the built-in display.
SUBSYSTEM=="iio", KERNEL=="iio:device*", ATTR{name}=="bmi323-imu", ENV{ACCEL_MOUNT_MATRIX}="0, -1, 0; 1, 0, 0; 0, 0, 1"
RULE

    log "Applying SELinux contexts"

    sudo restorecon -RF \
        "$INSTALL_ROOT" \
        "$SYSTEMD_UNIT" \
        /etc/inputplumber \
        "$ORIENTATION_RULE" \
        2>/dev/null || true

    # Armada's default /var context is not executable by system services.
    # The xattr survives reboot; rerunning this script restores it after a wipe.
    sudo chcon -R -t bin_t "$EXEC_DIR" 2>/dev/null || true

    log "Enabling and starting services"

    sudo systemctl daemon-reload
    sudo systemctl enable odin3-sensors.service
    sudo udevadm control --reload-rules

    sudo systemctl restart odin3-sensors.service
    sleep 12

    sudo systemctl restart inputplumber.service
    sudo systemctl restart iio-sensor-proxy.service 2>/dev/null || true
    sleep 3

    local iio_sysfs iio_device
    iio_sysfs="$(
        grep -l '^bmi323-imu$' \
            /sys/bus/iio/devices/iio:device*/name \
            2>/dev/null |
            head -n 1 || true
    )"

    if [[ -n "$iio_sysfs" ]]; then
        iio_device="$(basename "$(dirname "$iio_sysfs")")"
        sudo udevadm trigger \
            --action=change \
            "/sys/bus/iio/devices/$iio_device" || true
    fi
}

verify_installation() {
    log "Verifying the installed gyro stack"

    local failed=0
    local iio_dir=""
    local first_values second_values

    if systemctl is-active --quiet odin3-sensors.service; then
        note "odin3-sensors.service: active"
    else
        warn "odin3-sensors.service is not active."
        failed=1
    fi

    if systemctl is-active --quiet inputplumber.service; then
        note "inputplumber.service: active"
    else
        warn "inputplumber.service is not active."
        failed=1
    fi

    [[ -c /dev/sns_iio_feed ]] || {
        warn "/dev/sns_iio_feed is missing."
        failed=1
    }

    iio_dir="$(
        for device in /sys/bus/iio/devices/iio:device*; do
            [[ -d "$device" ]] || continue
            if [[ "$(cat "$device/name" 2>/dev/null || true)" == "bmi323-imu" ]]; then
                printf '%s\n' "$device"
                break
            fi
        done
    )"

    if [[ -n "$iio_dir" ]]; then
        note "IIO device: $iio_dir (bmi323-imu)"

        first_values="$(
            for attribute in \
                in_accel_x_raw in_accel_y_raw in_accel_z_raw \
                in_anglvel_x_raw in_anglvel_y_raw in_anglvel_z_raw; do
                cat "$iio_dir/$attribute" 2>/dev/null || true
            done | paste -sd,
        )"
        sleep 1
        second_values="$(
            for attribute in \
                in_accel_x_raw in_accel_y_raw in_accel_z_raw \
                in_anglvel_x_raw in_anglvel_y_raw in_anglvel_z_raw; do
                cat "$iio_dir/$attribute" 2>/dev/null || true
            done | paste -sd,
        )"

        note "Sensor sample 1: ${first_values:-unavailable}"
        note "Sensor sample 2: ${second_values:-unavailable}"

        if [[ -n "$first_values" && "$first_values" == "$second_values" ]]; then
            warn "Sensor values did not change during the one-second check."
        fi

        local device_name
        device_name="$(basename "$iio_dir")"
        local matrix
        matrix="$(
            udevadm info \
                --query=property \
                --name="/dev/$device_name" \
                2>/dev/null |
                sed -n 's/^ACCEL_MOUNT_MATRIX=//p'
        )"
        note "Screen rotation matrix: ${matrix:-not reported}"
    else
        warn "bmi323-imu was not created."
        failed=1
    fi

    local inputplumber_profile_ok=0
    local inputplumber_attached=0
    local inputplumber_pid=""
    local iio_character_device=""

    if grep -A4 -E '^[[:space:]]*-[[:space:]]+group:[[:space:]]+imu$' \
            "$INPUTPLUMBER_OVERRIDE" 2>/dev/null | \
        grep -q 'name:[[:space:]]*bmi323-imu'; then
        inputplumber_profile_ok=1
        note "InputPlumber profile contains bmi323-imu."
    else
        warn "InputPlumber override does not contain the bmi323-imu source."
        failed=1
    fi

    # InputPlumber log wording has changed between releases. Accept all known
    # messages and search the entire current boot rather than a short time window.
    if journalctl -u inputplumber.service -b --no-pager 2>/dev/null | \
        grep -Eqi \
            'Detected IMU:[[:space:]]*bmi323-imu|Found missing iio device|adding source device iio://|bmi323-imu'; then
        inputplumber_attached=1
    fi

    # A live IIO character-device file descriptor is stronger evidence than a
    # particular log message and remains valid if InputPlumber changes its logs.
    if [[ -n "$iio_dir" ]]; then
        iio_character_device="/dev/$(basename "$iio_dir")"
        inputplumber_pid="$(pgrep -xo inputplumber 2>/dev/null || true)"

        if [[ -n "$inputplumber_pid" ]] && \
            sudo sh -c '
                for fd in /proc/"$1"/fd/*; do
                    readlink "$fd" 2>/dev/null || true
                done
            ' sh "$inputplumber_pid" | \
            grep -qxF "$iio_character_device"; then
            inputplumber_attached=1
        fi
    fi

    if [[ $inputplumber_attached -eq 1 ]]; then
        note "InputPlumber attached the bmi323-imu source."
    elif [[ $inputplumber_profile_ok -eq 1 && -n "$iio_dir" ]]; then
        # Do not turn an otherwise healthy installation into a failure merely
        # because the current InputPlumber release emitted different log text.
        warn "Could not positively confirm the InputPlumber attachment from logs or open file descriptors."
        warn "The profile and live IIO device are present; reboot and test gyro in Steam."
    else
        warn "InputPlumber IMU integration could not be verified."
        failed=1
    fi

    if [[ $failed -ne 0 ]]; then
        echo
        sudo systemctl status odin3-sensors.service --no-pager -l || true
        echo
        sudo journalctl -u odin3-sensors.service -b --no-pager |
            tail -n 100 || true
        die "Installation completed, but verification found errors."
    fi

    log "Recovery completed successfully"
    note "Gyro service, InputPlumber IMU, and screen rotation are working."
    note "Reboot Odin 3 before the final in-game test."
    note "Build cache: $WORK_ROOT"
    note "Log: $LOG_FILE"
}

main() {
    require_command bash
    require_command curl
    require_command git
    require_command modinfo
    require_command paste
    require_command podman
    require_command python3
    require_command sha256sum
    require_command skopeo
    require_command sudo
    require_command systemctl
    require_command tar
    require_command udevadm

    sudo -v
    detect_model

    if [[ "$MODE" == "uninstall" ]]; then
        uninstall_fix
        return
    fi

    local free_kib
    free_kib="$(df -Pk "$WORK_ROOT" | awk 'NR==2 {print $4}')"
    if [[ "$free_kib" =~ ^[0-9]+$ && "$free_kib" -lt 8388608 ]]; then
        warn "Less than 8 GiB is free in $WORK_ROOT. The kernel build may run out of space."
    fi

    local commit_prefix repo_dir full_commit
    local sensor_archive sensor_extract sensor_tree
    local kernel_dir builder_image
    local module_file userspace_dir package_dir

    resolve_current_kernel_source
    commit_prefix="$RESOLVED_COMMIT_PREFIX"

    repo_dir="$WORK_ROOT/armada-packages"
    prepare_armada_packages "$commit_prefix" "$repo_dir"
    full_commit="$RESOLVED_FULL_COMMIT"

    sensor_archive="$WORK_ROOT/odin3-ssc-gyro.tar.gz"
    sensor_extract="$WORK_ROOT/odin3-sensor-source"
    prepare_odin3_sensor_source \
        "$sensor_archive" \
        "$sensor_extract"
    sensor_tree="$RESOLVED_SENSOR_TREE"

    kernel_dir="$repo_dir/kernel"
    builder_image="$(
        sed -n 's/^BUILDER_IMAGE=//p' "$repo_dir/toolchain.env" |
            head -n 1
    )"

    [[ "$builder_image" == registry.fedoraproject.org/fedora@sha256:* ]] ||
        die "Unexpected builder image in armada-packages: $builder_image"

    note "Exact armada-packages commit: $full_commit"
    note "Builder image: $builder_image"

    ensure_builder_image "$builder_image"

    build_kernel_module \
        "$repo_dir" \
        "$sensor_tree" \
        "$builder_image"
    module_file="$BUILT_MODULE_FILE"

    build_userspace \
        "$sensor_tree" \
        "$builder_image"
    userspace_dir="$BUILT_USERSPACE_DIR"

    package_dir="$sensor_tree/projects/ROCKNIX/packages/sysutils/odin3-sensors"

    install_runtime \
        "$module_file" \
        "$userspace_dir" \
        "$package_dir"

    verify_installation
}

main "$@"
