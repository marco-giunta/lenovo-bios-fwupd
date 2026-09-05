#!/usr/bin/env bash
#
# lenovo-bios-fwupd.sh
# Version 1.0
# Nadim Kobeissi -- https://github.com/nadimkobeissi/lenovo-bios-fwupd
#
# Converts a Lenovo Windows BIOS update .exe (Insyde H2OFFT based) into a
# fwupd-compatible .cab file that can be installed from Linux.
#
# Usage:
#   ./lenovo-bios-fwupd.sh <bios_update.exe>
#
# Requirements: 7z, gcab, fwupdmgr, python3
#
# IMPORTANT: Ensure AC power is connected and battery is above 30% before
# installing. Do NOT interrupt the reboot after installation.

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #
EXE="${1:-}"

if [[ "$EXE" == "--help" || "$EXE" == "-h" ]]; then
    echo "Usage: $0 <bios_update.exe>"
    echo ""
    echo "Converts a Lenovo Windows BIOS .exe into a fwupd .cab file."
    exit 0
fi

[[ -n "$EXE" ]] || die "Usage: $0 <bios_update.exe>"
[[ -f "$EXE" ]] || die "File not found: $EXE"

# --------------------------------------------------------------------------- #
# Dependency checks
# --------------------------------------------------------------------------- #
for cmd in 7z gcab fwupdmgr python3; do
    command -v "$cmd" &>/dev/null || die "'$cmd' is required but not found. Please install it."
done

# --------------------------------------------------------------------------- #
# Set up working directory
# --------------------------------------------------------------------------- #
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> Extracting $EXE ..."
7z x -o"$WORK/extracted" "$EXE" -bso0 -bsp0

# --------------------------------------------------------------------------- #
# Locate the firmware image
# H2OFFT's platform.ini has an [FDFile] section with a FileName key. The Insyde
# documentation embedded in that same file states that when FileName is empty,
# the utility searches the current directory and loads the first .fd file it
# finds. That is the case on the supported Legion and IdeaPad packages.
# Instead, for other devices (like the Yoga Pro 7 14ASP10),
# the package explicitly names a file, which need not be .fd:
#
#    [FDFile]
#    FileName=KLS7A.bin
#
# Therefore we read that section to determine which file to use.
# --------------------------------------------------------------------------- #
PLATFORM_INI=$(find "$WORK/extracted" -maxdepth 1 -iname 'platform.ini')
FD_FILE=""

if [[ -n "$PLATFORM_INI" ]]; then
    # [MULTI_FD] is the other, non-default way a package can say which image to
    # flash; compared to FDFile, it lets several images ship together.
    # We can't reproduce that behavior with a fwupd capsule containing a single
    # image, and just picking the first .fd found would be arbitrary, so refuse
    # rather than guess.
    # Note: all packages examined so far have Flag=0 and conversely ship a single
    # BIOS firmware image.
    MULTI_FD_FLAG=$(awk '/^\[MULTI_FD\]/{f=1;next} f&&/^\[/{exit} f' "$PLATFORM_INI" \
                    | grep -m1 '^Flag=' | cut -d= -f2- | tr -d '\r')
    if [[ "$MULTI_FD_FLAG" == "1" ]]; then
        die "platform.ini enables [MULTI_FD]: this package contains several firmware images selected by hardware detection, which this script cannot reproduce."
    fi

    # Print the [FDFile] section only, then take its FileName key.
    INI_FDFILE=$(sed -n '/^\[FDFile\]/,/^\[/p' "$PLATFORM_INI" \
                 | grep -m1 '^FileName=' | cut -d= -f2- | tr -d '\r')

    if [[ -n "$INI_FDFILE" ]]; then
        echo "==> platform.ini [FDFile] FileName=$INI_FDFILE"
        FD_FILE=$(find "$WORK/extracted" -maxdepth 1 -iname "$INI_FDFILE")
        [[ -n "$FD_FILE" ]] || die "platform.ini names '$INI_FDFILE' but it is not in the archive."
    fi
fi

if [[ -z "$FD_FILE" ]]; then
    FD_FILE=$(find "$WORK/extracted" -maxdepth 1 -iname '*.fd' | head -1) # first .fd file found
    [[ -n "$FD_FILE" ]] || die "No firmware image found: platform.ini named none and no .fd file is present."
fi

FD_BASENAME=$(basename "$FD_FILE")
echo "==> Found firmware: $FD_BASENAME ($(stat -c%s "$FD_FILE") bytes)"

# --------------------------------------------------------------------------- #
# Account for any other firmware blobs in the package.
#
# platform.ini names a single image, and the .cab we build contains only that
# image.
# The Yoga Pro 7 14ASP10 ships Ecb.bin: ITE IT5508 embedded controller
# firmware, identified by the string "UUITE5508-COMPAL01EC-USER0-BS-CODE" it
# carries. It is present byte-for-byte inside the main image, once, at
# 0x1817b0, in both the QFCN28WW and QFCN29WW update packages.
#
# platform.ini's [UpdateEC] section describes how a *separate* EC image would be
# flashed: EC_Path names the file, valid only when Flag=1 ("Flash EC by BIOS").
# Here Flag=0 and EC_Path is empty in every package examined, so that path is
# unused. The EC region is instead written as part of the BIOS image itself.
# Therefore, the standalone copy is redundant and it's safe to ignore it.
#
# Not every secondary blob would be. The same file defines MEFileName for an
# Intel ME image, flashed by a separate tool (FWUpdLcl.exe) inside Windows and
# before the BIOS -- therefore, such a blob would likely be separate from the
# BIOS image. Hence: warn and say what the user is missing.

# Overall the check below implements the following heuristics:
# if a secondary blob is present verbatim inside the main image,
# the capsule already carries it and nothing is lost by ignoring it.
# If it is not, this update may leave that component on its old version.
# That should be recoverable rather than fatal, so warn rather than refuse.
# --------------------------------------------------------------------------- #
mapfile -t EXTRA_IMAGES < <(find "$WORK/extracted" -maxdepth 1 \
    \( -iname '*.bin' -o -iname '*.fd' \) \
    ! -samefile "$FD_FILE" | sort)

for extra in "${EXTRA_IMAGES[@]}"; do
    extra_name=$(basename "$extra")
    offset=$(python3 -c '
import sys
haystack = open(sys.argv[1], "rb").read()
needle = open(sys.argv[2], "rb").read()
print(haystack.find(needle) if needle else -1)
' "$FD_FILE" "$extra" 2>/dev/null || echo -1)

    if [[ "$offset" =~ ^[0-9]+$ ]] && [[ "$offset" -ge 0 ]]; then
        echo "  OK: Secondary firmware $extra_name is contained in $FD_BASENAME at $(printf '0x%x' "$offset")"
    else
        echo "  WARNING: $extra_name ($(stat -c%s "$extra") bytes) is NOT contained verbatim in
$FD_BASENAME. It may be compressed inside the image, or it may be a separate
component that the Windows updater flashes on its own. If the latter, the
update induced by the .cab file produced by this script will not touch it,
and that component will stay on its current version." >&2
    fi
done

# --------------------------------------------------------------------------- #
# Read the BIOS version string
#
# Used for the .cab filename and the metainfo description.
#
# Insyde images carry a BIOS Version Data Table, introduced by a $BVDT tag and
# followed by '$'-prefixed, NUL-terminated records; the first non-empty record
# is the version. Both a Legion and a Yoga package place it identically:
#
#    $BVDT $\0\0\0 $\0\0\0 $Q7CN78WW\0 ... $Legion Pro 7 16IAX10H
#    $BVDT $\0\0\0 $\0\0\0 $QFCN29WW\0 ... $KLS7A
#
# Reading it this way assumes nothing about Lenovo's naming scheme, so it also
# works on models that do not use the four-letter + two-digit + WW form. It is
# also correct on packages whose image is not named after the BIOS version
# (e.g. KLS7A.bin, where the version is QFCN29WW), which the old
# "strip Win, strip .fd" approach would have gotten wrong.
#
# Fall back to the .exe filename if the table is missing or unrecognized.
# --------------------------------------------------------------------------- #
BIOS_VERSION=$(python3 -c '
import sys
d = open(sys.argv[1], "rb").read()
i = d.find(b"$BVDT")
if i >= 0:
    pos = i + 5
    for _ in range(8):
        if d[pos:pos+1] != b"$":
            break
        end = d.find(b"\x00", pos)
        if end < 0:
            break
        token = d[pos+1:end]
        pos = end + 1
        while d[pos:pos+1] == b"\x00":
            pos += 1
        if token:
            print(token.decode("ascii", "replace"))
            break
' "$FD_FILE" 2>/dev/null || true)

if [[ -n "$BIOS_VERSION" ]]; then
    echo "==> BIOS version string: $BIOS_VERSION (from the image)"
else
    BIOS_VERSION=$(basename "${EXE%.*}" | tr '[:lower:]' '[:upper:]')
    echo "==> BIOS version string: $BIOS_VERSION (from the .exe filename)"
fi

# --------------------------------------------------------------------------- #
# Read the System Firmware GUID and current ESRT version from sysfs
#   ESRT entry with fw_type=1 is the system firmware.
# --------------------------------------------------------------------------- #
echo "==> Reading System Firmware info from ESRT ..."
FW_GUID=""
FW_CURRENT_VERSION=""

for entry in /sys/firmware/efi/esrt/entries/entry*; do
    fw_type=$(sudo cat "$entry/fw_type" 2>/dev/null) || continue
    if [[ "$fw_type" == "1" ]]; then
        FW_GUID=$(sudo cat "$entry/fw_class")
        FW_CURRENT_VERSION=$(sudo cat "$entry/fw_version")
        break
    fi
done

[[ -n "$FW_GUID" ]] || die "Could not find System Firmware in ESRT.
Is this a UEFI system with an EFI System Resource Table?"

echo "==> System Firmware GUID: $FW_GUID"
echo "==> Current firmware version (ESRT): $FW_CURRENT_VERSION"

# --------------------------------------------------------------------------- #
# Determine the version number to put in the .cab metadata
#
# We set it to current_version + 1 so fwupd treats this as an upgrade.
# The actual version validation is handled by the UEFI firmware itself
# during the capsule update.
# --------------------------------------------------------------------------- #
# Strip any non-numeric characters (fwupd sometimes returns formatted versions)
NUMERIC_VERSION=$(echo "$FW_CURRENT_VERSION" | tr -cd '0-9')
[[ -n "$NUMERIC_VERSION" ]] || die "Could not parse current firmware version: $FW_CURRENT_VERSION"
NEW_VERSION=$((NUMERIC_VERSION + 1))
echo "==> Metadata version for .cab: $NEW_VERSION"

# --------------------------------------------------------------------------- #
# Get system product name for the metainfo
# --------------------------------------------------------------------------- #
PRODUCT=$(cat /sys/class/dmi/id/product_family 2>/dev/null || echo "Lenovo Laptop")

# --------------------------------------------------------------------------- #
# Build metainfo XML
# --------------------------------------------------------------------------- #
cat > "$WORK/firmware.metainfo.xml" <<METAINFO
<?xml version="1.0" encoding="UTF-8"?>
<component type="firmware">
  <id>com.lenovo.$(cat /sys/class/dmi/id/product_sku 2>/dev/null || echo "unknown").firmware</id>
  <name>$PRODUCT System Firmware</name>
  <summary>Lenovo BIOS Update $BIOS_VERSION</summary>
  <developer_name>Lenovo</developer_name>
  <provides>
    <firmware type="flashed">$FW_GUID</firmware>
  </provides>
  <releases>
    <release version="$NEW_VERSION" date="$(date +%Y-%m-%d)">
      <description>
        <p>Lenovo BIOS update $BIOS_VERSION</p>
      </description>
    </release>
  </releases>
  <custom>
    <value key="LVFS::VersionFormat">plain</value>
  </custom>
</component>
METAINFO

# --------------------------------------------------------------------------- #
# Copy the firmware image as firmware.bin (fwupd convention)
# --------------------------------------------------------------------------- #
cp "$FD_FILE" "$WORK/firmware.bin"

# --------------------------------------------------------------------------- #
# Build the .cab
# --------------------------------------------------------------------------- #
OUTPUT_DIR=$(dirname "$(realpath "$EXE")")
CAB_NAME="${BIOS_VERSION}.cab"
OUTPUT_CAB="${OUTPUT_DIR}/${CAB_NAME}"

(cd "$WORK" && gcab --create "$OUTPUT_CAB" firmware.metainfo.xml firmware.bin)
echo "==> Created: $OUTPUT_CAB"

echo ""
echo "To install the update, run:"
echo "  sudo fwupdmgr install $OUTPUT_CAB --allow-reinstall --no-reboot-check"
echo ""
echo "Then reboot. The UEFI firmware will apply the capsule during boot."
echo "Ensure AC power is connected and battery is above 30%."
