#!/usr/bin/env bash
#
#  Copyright (c) 2025 Sameer Al Sahab
#  Licensed under the MIT License. See LICENSE file for details.
#
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
#


HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASTROROM=$HERE

# Versioning
VERSION_MAJOR="2"
VERSION_MINOR="1"
VERSION_PATCH="2"
VERSION_SUFFIX="-ramadan"
ROM_VERSION=$(echo "${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}${VERSION_SUFFIX}" | sed -E 's/\.+/./g; s/\.$//')

# Defaults
BETA_ASSERT=false
BETA_OTA_URL=""
DEBUG_BUILD=false
TARGET=""
PLATFORM=""
CODENAME=""

# Directories 
PREBUILTS=$ASTROROM/prebuilts
PROJECT_DIR="$ASTROROM/astro"
OBJECTIVES_DIR="$ASTROROM/objectives"
BLOBS_DIR="$ASTROROM/blobs"
WORKDIR="$ASTROROM/firmware/unpacked"
WORKSPACE="$ASTROROM/workspace"
DIROUT="$ASTROROM/out"

SOURCE_FW="${WORKDIR}/${MODEL}"
STOCK_FW="${WORKDIR}/${STOCK_MODEL}"
EXTRA_FW="${WORKDIR}/${EXTRA_MODEL}"

MARKER_FILE="$WORKSPACE/.build_markers"



AVAILABLE_TARGETS=()

if [[ -d "$OBJECTIVES_DIR" ]]; then
    for D in "$OBJECTIVES_DIR"/*/; do
        [[ -d "$D" ]] || continue
        AVAILABLE_TARGETS+=("$(basename "$D")")
    done
fi


shopt -s globstar
for UTIL in "$ASTROROM"/scripts/**/*.sh; do
    if [[ -f "$UTIL" ]]; then
        source "$UTIL"
    fi
done

GET_THREAD_COUNT() {
    local CPU_CORES
    local TOTAL_MEM_GB
    local THREADS
    local RAM_LIMIT

    CPU_CORES="$(nproc)"
    TOTAL_MEM_GB="$(free -g | awk '/^Mem:/{print $2}')"

    if IS_GITHUB_ACTIONS; then
        THREADS="$CPU_CORES"
    else
        THREADS="$((CPU_CORES - 1))"
    fi

    RAM_LIMIT="$((TOTAL_MEM_GB / 2))"

    if (( THREADS > RAM_LIMIT )); then
        THREADS="$RAM_LIMIT"
    fi

    (( THREADS < 1 )) && THREADS=1

    echo "$THREADS"
}

USABLE_THREADS="$(GET_THREAD_COUNT)"

PARSE_MODULE_PROP() {
    local PROP_FILE="$1"
    local KEY="$2"
    if [[ -f "$PROP_FILE" ]]; then
        grep "^${KEY}=" "$PROP_FILE" | cut -d'=' -f2- | sed "s/['\"]//g"
    fi
}

EXEC_SCRIPT() {
    local SCRIPT_FILE="$1"
    local MARKER="$2"
    local MOD_NAME="$3"
    local MOD_AUTHOR="$4"

    local CURRENT_HASH
    CURRENT_HASH=$(md5sum "$SCRIPT_FILE" 2>/dev/null | awk '{print $1}')
    
    if grep -q "$SCRIPT_FILE $CURRENT_HASH" "$MARKER" 2>/dev/null; then
        LOG_INFO "Skipping $MOD_NAME (already applied)"
        return 0
    fi

    LOG "Applying $MOD_NAME"
    [[ -n "$MOD_AUTHOR" ]] && LOG "    └─ by $MOD_AUTHOR"

    export SCRPATH && SCRPATH=$(cd "$(dirname "$SCRIPT_FILE")" && pwd)
    
    if ! source "$SCRIPT_FILE"; then
        ERROR_EXIT "Failed to apply $MOD_NAME"
    fi

    unset SCRPATH
    mkdir -p "$(dirname "$MARKER")"
    sed -i "\|^$SCRIPT_FILE |d" "$MARKER" 2>/dev/null || true
    echo "$SCRIPT_FILE $CURRENT_HASH" >> "$MARKER"
}



_BUILD_ROM() {
    rm -rf "$DIROUT" && mkdir -p "$DIROUT"
    
    # Check for available objectives
    AVAILABLE_TARGETS=()
    if [[ -d "$OBJECTIVES_DIR" ]]; then
        for D in "$OBJECTIVES_DIR"/*/; do
            [[ -d "$D" ]] && AVAILABLE_TARGETS+=("$(basename "$D")")
        done
    fi

    if [[ -z "$TARGET" ]]; then
        [[ ${#AVAILABLE_TARGETS[@]} -eq 0 ]] && ERROR_EXIT "No objectives found."
        local CHOICE
        CHOICE=$(PROMPT_CHOICE "Select Target TARGET" "${AVAILABLE_TARGETS[@]}")
        TARGET="${AVAILABLE_TARGETS[CHOICE-1]}"
    fi

    OBJECTIVE="$OBJECTIVES_DIR/$TARGET"
    export OBJECTIVE
    source "$OBJECTIVE/$TARGET.sh" || ERROR_EXIT "TARGET config load failed"

    # Setup Environment
    if [[ ! -f "$MARKER_FILE" ]] || [[ "$(grep "last_objective" "$MARKER_FILE" | awk '{print $2}')" != "$TARGET" ]]; then
        LOG_INFO "Initializing environment for $TARGET..."
        SETUP_TARGET_ENV || ERROR_EXIT "Setup failed"
        echo "last_objective $TARGET" > "$MARKER_FILE"
    fi

    local LAYERS=()
    [[ -n "$PLATFORM" ]] && LAYERS+=("$ASTROROM/platform/$PLATFORM")
    LAYERS+=("$PROJECT_DIR" "$OBJECTIVE")

    for LAYER in "${LAYERS[@]}"; do
        [[ ! -d "$LAYER" ]] && continue

        find "$LAYER" -type f -name "customize.sh" -print0 | sort -z | while IFS= read -r -d '' SH; do
            DIR="$(dirname "$SH")"
            
            PARENT="$DIR"
            while [[ "$PARENT" != "$LAYER" && "$PARENT" != "/" ]]; do
                if [[ -f "$PARENT/.no" ]]; then continue 2; fi
                PARENT="$(dirname "$PARENT")"
            done

            # Metadata extraction
            local PROP="$DIR/module.prop"
            local NAME AUTHOR
            NAME=$(PARSE_MODULE_PROP "$PROP" "name")
            AUTHOR=$(PARSE_MODULE_PROP "$PROP" "author")
            
            [[ -z "$NAME" ]] && NAME=$(basename "$DIR")

            EXEC_SCRIPT "$SH" "$MARKER_FILE" "$NAME" "$AUTHOR"
        done
    done

    _APKTOOL_PATCH || ERROR_EXIT "APK patching failed"
    REPACK_ROM "$FILESYSTEM" || ERROR_EXIT "Repack failed"
    LOG_END "Build Successful for $TARGET"
}

show_usage()
{
cat <<EOF
AstroROM v${ROM_VERSION} - Samsung Android ROM Build System
Copyright (c) 2025 Sameer Al Sahab
Licensed under MIT License

Usage:
  build.sh [options] <command> [objective]

Commands:
  build,   -b [objective]      Build ROM for specified objective.
  clean,   -c [options]     Remove build artifacts.
  help,    -h               Show this help message.
  version, -v               Show version information.

Build Options:
  -d, --debug               Enable debug build mode.
      --ota-url <url>       Use beta firmware from OTA URL.

Clean Options:
  -f, --firmware            Remove downloaded firmware.
  -w, --workspace           Remove workspace directory.
      --workdir             Remove unpacked firmware.
      --all                 Remove firmware + workspace + workdir + out.

Available TARGETs:
  ${AVAILABLE_TARGETS[*]:-  (No TARGETs found in $OBJECTIVES_DIR)}

Environment:
  Root privileges are required for build and clean operations.

Project Home:
  https://github.com/SameerAlSahab/AstroROM

EOF
}

cleanup_workspace() {
    local TARGETS=()
    local ALL=false

    for arg in "$@"; do
        case "$arg" in
            -f|--firmware)  TARGETS+=("$WORKDIR") ;;
            -w|--workspace) TARGETS+=("$WORKSPACE") ;;
            --workdir)     TARGETS+=("$WORKDIR") ;;
            --all)          ALL=true ;;
        esac
    done

    if $ALL; then
        TARGETS=("$WORKSPACE" "$WORKDIR" "$DIROUT")
    fi

    [[ ${#TARGETS[@]} -eq 0 ]] && { LOG_WARN "Nothing to clean. Try --all"; return 0; }

    for P in "${TARGETS[@]}"; do
        if [[ -d "$P" ]]; then
            LOG_INFO "Cleaning: $(basename "$P")"
            rm -rf "$P"
        fi
    done
    rm -f "$MARKER_FILE"
    LOG_INFO "Cleanup finished."
}

COMMAND=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug|-d) DEBUG_BUILD=true; shift ;;
        build|-b)   COMMAND="build"; [[ -n "$2" && "$2" != -* ]] && { TARGET="$2"; shift; }; shift ;;
        clean|-c)   COMMAND="clean"; shift; break ;;
        version|-v) echo "AstroROM v$ROM_VERSION"; exit 0 ;;
        help|-h)    COMMAND="help"; break ;;
        *)          [[ -z "$TARGET" ]] && TARGET="$1"; shift ;;
    esac
done

[[ $EUID -ne 0 ]] && ERROR_EXIT "Root privileges required."

case "$COMMAND" in
    clean) cleanup_workspace "$@" ;;
    help)  _SHOW_USAGE ;;
    *)     _BUILD_ROM ;;
esac

[[ $EUID -ne 0 ]] && ERROR_EXIT "Root required"

_BUILD_ROM
