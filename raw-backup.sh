#!/bin/bash
#
# raw-backup.sh
# Verified, incremental backup of folders to USB drives on macOS.
#
# You define one or more jobs (source folder -> USB drive -> folder on the
# drive) in ~/.config/raw-backup.conf. When a drive is plugged in, launchd
# starts this script, which runs every job for the drives that are mounted:
# new and changed files are copied and every copy is checked with SHA-256.
#
# https://github.com/westruplabs/raw-backup
#
# Compatible with the bash 3.2 that ships with macOS.

set -uo pipefail

# ---------- Defaults (override in ~/.config/raw-backup.conf) ----------
JOBS=""                     # one job per line: source folder | volume name | folder on volume
FULL_VERIFY_DAYS=30         # full read-back check every N days per job (0 = never automatically)
EJECT_WHEN_DONE=false       # eject the drive(s) when everything succeeded
NOTIFY=true                 # macOS notifications
LOG_FILE="$HOME/Library/Logs/raw-backup.log"
MTIME_TOLERANCE=2           # seconds (FAT/exFAT store timestamps coarsely)
VOLUMES_ROOT="/Volumes"
# Legacy single-job settings (v1). Still honoured if JOBS is empty.
SRC=""; VOLUME_NAME=""; DEST_SUBDIR=""
# -----------------------------------------------------------------------

CONFIG_FILE="${RAW_BACKUP_CONFIG:-$HOME/.config/raw-backup.conf}"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

APP="Raw-backup"
LOCK_DIR="/tmp/raw-backup-$(id -u).lock"
STATUS_FILE="$HOME/Library/Logs/raw-backup.status"
EXCLUDE_RE='/(\.DS_Store|\._[^/]*|\.Spotlight-V100|\.Trashes|\.fseventsd|\.TemporaryItems|\.DocumentRevisions-V100|\.raw-backup)(/|$)'
PARTIAL_SUFFIX=".rbpartial"
OS="$(uname)"
if [ "$OS" = "Darwin" ]; then CP_OPTS="-X"; else CP_OPTS=""; fi

# Parsed jobs (indexed arrays work in bash 3.2)
JOB_COUNT=0
JOB_SRC=(); JOB_VOL=(); JOB_DIR=()

# Current job (set by set_job)
JOB_IDX=0; JOB_LABEL=""
VOLUME=""; DEST=""; META_ROOT=""; META=""; MANIFEST=""; LAST_VERIFY_FILE=""; HISTORY=""

WORK=""; JW=""
FAILED=0; COPIED=0; COPIED_BYTES=0; NEW_HASHES=""

# Progress
PROG_LABEL=""; PROG_TOTAL_FILES=0; PROG_TOTAL_BYTES=0; PROG_DONE_FILES=0; PROG_DONE_BYTES=0
PROG_START=0; PROG_LAST_WRITE=-10; PROG_NEXT_MILESTONE=25
MILESTONE_MIN_BYTES=$((2 * 1024 * 1024 * 1024))   # 25/50/75 % notifications only for jobs over 2 GB

# ---------------------------------------------------------------- helpers

log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
    if [ -t 1 ]; then printf '\r\033[K%s\n' "$*"; fi
}

notify() {  # $1 title, $2 message
    [ "$NOTIFY" = "true" ] || return 0
    command -v osascript >/dev/null 2>&1 || return 0
    local t="${1//\"/\'}" m="${2//\"/\'}"
    osascript -e "display notification \"$m\" with title \"$t\"" >/dev/null 2>&1 || true
}

human() {  # bytes -> readable
    awk -v b="$1" 'BEGIN { split("B KB MB GB TB", u, " "); i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i] }'
}

trim() {
    local x="$1"
    x="${x#"${x%%[![:space:]]*}"}"
    x="${x%"${x##*[![:space:]]}"}"
    printf '%s' "$x"
}

file_size() {
    local s
    if [ "$OS" = "Darwin" ]; then s=$(stat -f %z "$1" 2>/dev/null); else s=$(stat -c %s "$1" 2>/dev/null); fi
    echo "${s:-0}"
}

is_mounted() {  # $1 = volume path (defaults to current job's volume)
    # Require a real mount point: a leftover empty folder in /Volumes must never
    # make the backup land on the internal disk.
    local v="${1:-$VOLUME}"
    [ -d "$v" ] || return 1
    mount | grep -F " on $v (" >/dev/null 2>&1
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then echo $$ > "$LOCK_DIR/pid"; return 0; fi
    local pid
    pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 1; fi
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null && echo $$ > "$LOCK_DIR/pid"
}

cleanup() {
    [ -n "$WORK" ] && rm -rf "$WORK"
    if [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then rm -rf "$LOCK_DIR" "$STATUS_FILE"; fi
}

hash_of() { shasum -a 256 < "$1" 2>/dev/null | awk '{print $1}'; }

# Prints "size<TAB>mtime<TAB>./relative/path" for every file under $1
list_files() {
    if [ "$OS" = "Darwin" ]; then
        (cd "$1" && find . -type f -exec stat -f '%z%t%m%t%N' {} +)
    else
        (cd "$1" && find . -type f -printf '%s\t%T@\t%p\n')
    fi | { grep -Ev "$EXCLUDE_RE" || true; }
}

# ---------------------------------------------------------------- jobs

config_error() {
    log "CONFIG ERROR: $*"
    [ -t 1 ] || notify "$APP: config error" "$* (see $CONFIG_FILE)"
    exit 78
}

load_jobs() {
    local jobs="$JOBS" line s v d n=0 seen=$'\n' key
    # v1 config: SRC / VOLUME_NAME / DEST_SUBDIR
    if [ -z "$(trim "$jobs")" ] && [ -n "$SRC" ] && [ -n "$VOLUME_NAME" ]; then
        jobs="$SRC | $VOLUME_NAME | ${DEST_SUBDIR:-$(basename "$SRC")}"
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(trim "$line")
        case "$line" in ""|\#*) continue ;; esac
        case "$line" in *"|"*) ;; *) config_error "job line needs 'source | volume | folder': $line" ;; esac
        s=$(trim "${line%%|*}"); line="${line#*|}"
        if [ "${line#*|}" != "$line" ]; then
            v=$(trim "${line%%|*}"); d=$(trim "${line#*|}")
        else
            v=$(trim "$line"); d=""
        fi
        case "$s" in "~") s="$HOME" ;; "~/"*) s="$HOME/${s#\~/}" ;; esac
        s="${s%/}"
        [ -n "$s" ] && [ -n "$v" ] || config_error "job line is missing source or volume"
        case "$v" in */*) config_error "volume name must be the drive name, not a path: $v" ;; esac
        [ -n "$d" ] || d=$(basename "$s")
        d="${d#/}"; d="${d%/}"; [ -n "$d" ] || d="."
        case "/$d/" in */../*) config_error "folder on volume may not contain '..': $d" ;; esac
        key="$v|$d"
        case "$seen" in *$'\n'"$key"$'\n'*) config_error "two jobs write to the same folder: $v/$d" ;; esac
        seen="$seen$key"$'\n'
        JOB_SRC[n]="$s"; JOB_VOL[n]="$v"; JOB_DIR[n]="$d"
        n=$((n + 1))
    done <<< "$jobs"
    JOB_COUNT=$n
    [ "$JOB_COUNT" -gt 0 ] || config_error "no jobs configured"
}

set_job() {  # $1 = job index
    JOB_IDX="$1"
    SRC="${JOB_SRC[$1]}"; VOLUME_NAME="${JOB_VOL[$1]}"; DEST_SUBDIR="${JOB_DIR[$1]}"
    VOLUME="$VOLUMES_ROOT/$VOLUME_NAME"
    META_ROOT="$VOLUME/.raw-backup"
    local slug
    if [ "$DEST_SUBDIR" = "." ]; then DEST="$VOLUME"; slug="_root"
    else DEST="$VOLUME/$DEST_SUBDIR"; slug=$(printf '%s' "$DEST_SUBDIR" | tr '/' '_'); fi
    META="$META_ROOT/jobs/$slug"
    MANIFEST="$META/manifest.sha256"
    LAST_VERIFY_FILE="$META/last_full_verify"
    HISTORY="$META_ROOT/history.log"
    JOB_LABEL="$(basename "$SRC") → $VOLUME_NAME"
}

list_jobs() {
    local i m
    printf '%-3s %-40s %-16s %-16s %s\n' "#" "SOURCE" "VOLUME" "FOLDER" "MOUNTED"
    for ((i = 0; i < JOB_COUNT; i++)); do
        set_job "$i"
        if is_mounted; then m="yes"; else m="no"; fi
        printf '%-3s %-40s %-16s %-16s %s\n' "$((i + 1))" "$SRC" "$VOLUME_NAME" "$DEST_SUBDIR" "$m"
    done
    echo
    echo "Config: $CONFIG_FILE"
}

# Move checksums written by v1 (one job per drive) into the per-job folder
migrate_legacy_meta() {
    if [ -f "$META_ROOT/manifest.sha256" ] && [ ! -f "$MANIFEST" ]; then
        mv -f "$META_ROOT/manifest.sha256" "$MANIFEST" \
            && { [ -f "$META_ROOT/last_full_verify" ] && mv -f "$META_ROOT/last_full_verify" "$LAST_VERIFY_FILE"; true; } \
            && log "Moved checksums from previous version to $META"
    fi
}

# ---------------------------------------------------------------- progress

progress_start() {  # $1 label, $2 file count, $3 byte count
    PROG_LABEL="[$JOB_LABEL] $1"; PROG_TOTAL_FILES="$2"; PROG_TOTAL_BYTES="$3"
    PROG_DONE_FILES=0; PROG_DONE_BYTES=0; PROG_START=$SECONDS
    PROG_LAST_WRITE=-10; PROG_NEXT_MILESTONE=25
    mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null
    progress_show
}

progress_add() {  # $1 bytes of the file just finished
    PROG_DONE_FILES=$((PROG_DONE_FILES + 1))
    PROG_DONE_BYTES=$((PROG_DONE_BYTES + ${1:-0}))
    progress_show
}

progress_show() {
    local elapsed=$((SECONDS - PROG_START)) out pct long short
    out=$(awk -v d="$PROG_DONE_BYTES" -v t="$PROG_TOTAL_BYTES" -v e="$elapsed" \
              -v fd="$PROG_DONE_FILES" -v ft="$PROG_TOTAL_FILES" '
        function h(b,   u, i) { split("B KB MB GB TB", u, " "); i = 1
            while (b >= 1024 && i < 5) { b /= 1024; i++ }
            return (i == 1) ? sprintf("%d %s", b, u[i]) : sprintf("%.1f %s", b, u[i]) }
        BEGIN {
            pct = (t > 0) ? d * 100 / t : ((ft > 0) ? fd * 100 / ft : 100)
            if (pct > 100) pct = 100
            w = 25; n = int(pct * w / 100 + 0.5); bar = ""
            for (i = 0; i < w; i++) bar = bar ((i < n) ? "#" : "-")
            rate = (e > 0) ? d / e : 0
            if (fd >= ft) eta = "done"
            else if (rate > 0 && d > 0 && e >= 3) {
                r = (t - d) / rate
                if (r < 60) eta = "under 1 min left"
                else if (r < 3600) eta = sprintf("about %d min left", int(r / 60 + 0.5))
                else eta = sprintf("about %d h %d min left", int(r / 3600), int((r - int(r / 3600) * 3600) / 60))
            } else eta = "estimating time..."
            speed = (rate > 0) ? h(rate) "/s" : "-"
            printf "%d\t[%s] %3d%%  %s of %s  %s  %s  (%d/%d files)\t%d%% done, %s of %s. %s.",
                int(pct), bar, pct, h(d), h(t), speed, eta, fd, ft, int(pct), h(d), h(t), eta
        }')
    pct="${out%%$'\t'*}"; out="${out#*$'\t'}"
    long="${out%%$'\t'*}"; short="${out#*$'\t'}"

    if [ -t 1 ]; then
        printf '\r%s %s\033[K' "$PROG_LABEL" "$long"
    fi
    # Status file for 'raw-backup.sh --status' (at most every 2 seconds)
    if [ $((SECONDS - PROG_LAST_WRITE)) -ge 2 ] || [ "$PROG_DONE_FILES" -ge "$PROG_TOTAL_FILES" ]; then
        { printf '%s %s\n' "$PROG_LABEL" "$long" > "$STATUS_FILE"; } 2>/dev/null
        PROG_LAST_WRITE=$SECONDS
    fi
    # Notifications at 25/50/75 % when running in the background
    if [ ! -t 1 ] && [ "$PROG_TOTAL_BYTES" -ge "$MILESTONE_MIN_BYTES" ]; then
        while [ "$PROG_NEXT_MILESTONE" -lt 100 ] && [ "$pct" -ge "$PROG_NEXT_MILESTONE" ]; do
            notify "$APP: $PROG_LABEL" "$short"
            PROG_NEXT_MILESTONE=$((PROG_NEXT_MILESTONE + 25))
        done
    fi
}

progress_end() { [ -t 1 ] && printf '\n'; return 0; }

show_status() {
    local pid
    pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ -f "$STATUS_FILE" ]; then
        cat "$STATUS_FILE"
    elif [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "Backup running (preparing)..."
    else
        echo "No backup is running."
        [ -f "$LOG_FILE" ] && echo "Last: $(grep -v '^ ' "$LOG_FILE" | tail -1)"
    fi
}

# ---------------------------------------------------------------- copy + verify

# Copies one file via a temporary name, verifies with SHA-256, two attempts.
copy_verified() {  # $1 = relative path
    local rel="$1" s="$SRC/$1" d="$DEST/$1" dir tmp hs hd attempt size
    dir=$(dirname "$d")
    tmp="$dir/.$(basename "$d")$PARTIAL_SUFFIX"
    if [ ! -f "$s" ]; then log "SKIPPED (no longer in source): $rel"; return 0; fi
    mkdir -p "$dir" || { log "ERROR: cannot create folder $dir"; return 1; }

    for attempt in 1 2; do
        is_mounted || { log "ERROR: $VOLUME_NAME was disconnected during copy"; return 2; }
        rm -f "$tmp"
        # shellcheck disable=SC2086
        if cp $CP_OPTS "$s" "$tmp" 2>>"$LOG_FILE" && touch -r "$s" "$tmp" && mv -f "$tmp" "$d"; then
            hs=$(hash_of "$s")
            hd=$(hash_of "$d")
            if [ -n "$hs" ] && [ "$hs" = "$hd" ]; then
                size=$(wc -c < "$d" | tr -d ' ')
                COPIED=$((COPIED + 1))
                COPIED_BYTES=$((COPIED_BYTES + size))
                printf '%s  %s\n' "$hs" "$rel" >> "$NEW_HASHES"
                return 0
            fi
            log "WARNING: checksum mismatch (attempt $attempt): $rel"
        else
            log "WARNING: copy failed (attempt $attempt): $rel"
        fi
    done
    rm -f "$tmp"
    log "ERROR: could not copy and verify: $rel"
    return 1
}

# Merges new checksums into the manifest (replacing old lines for the same file)
merge_manifest() {
    [ -s "$NEW_HASHES" ] || return 0
    touch "$MANIFEST"
    awk 'FILENAME == ARGV[1] { upd[substr($0, 67)] = 1; next }
         !(substr($0, 67) in upd)' "$NEW_HASHES" "$MANIFEST" > "$JW/manifest.new"
    cat "$NEW_HASHES" >> "$JW/manifest.new"
    sort -k2 "$JW/manifest.new" > "$JW/manifest.sorted" \
        && cp "$JW/manifest.sorted" "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"
    : > "$NEW_HASHES"
}

run_copy_list() {  # $1 = file with relative paths, one per line
    local rel rc size
    while IFS= read -r -u 3 rel; do
        [ -n "$rel" ] || continue
        size=$(file_size "$SRC/$rel")
        copy_verified "$rel"; rc=$?
        if [ $rc -eq 2 ]; then progress_end; return 2; fi
        [ $rc -eq 0 ] || FAILED=$((FAILED + 1))
        progress_add "$size"
    done 3< "$1"
    progress_end
    return 0
}

# ---------------------------------------------------------------- modes

do_sync() {
    local dry="$1"
    list_files "$SRC" > "$JW/src.lst" 2> "$JW/src.err"
    if [ -s "$JW/src.err" ]; then
        log "WARNING while reading source:"; cat "$JW/src.err" >> "$LOG_FILE"
    fi
    if [ ! -s "$JW/src.lst" ]; then
        log "Source $SRC is empty or unreadable - skipping to be safe."
        notify "$APP: $JOB_LABEL" "Source folder is empty or unreadable. See the log."
        return 1
    fi
    [ -d "$DEST" ] && list_files "$DEST" > "$JW/dst.lst" 2>/dev/null || : > "$JW/dst.lst"

    # Compare size + modification time. Output: size<TAB>path
    awk -F'\t' -v tol="$MTIME_TOLERANCE" '
        { p = $0; sub(/^[^\t]*\t[^\t]*\t/, "", p); sub(/^\.\//, "", p); m = int($2) }
        FILENAME == ARGV[1] { dsz[p] = $1; dmt[p] = m; next }
        { if (!(p in dsz) || dsz[p] != $1 || dmt[p] - m > tol || m - dmt[p] > tol)
              print $1 "\t" p }
    ' "$JW/dst.lst" "$JW/src.lst" | sort -t "$(printf '\t')" -k2 > "$JW/tocopy.lst"

    local n need_bytes free_kb
    n=$(wc -l < "$JW/tocopy.lst" | tr -d ' ')
    need_bytes=$(awk -F'\t' '{ s += $1 } END { printf "%.0f", s }' "$JW/tocopy.lst")
    log "[$JOB_LABEL] Source: $(wc -l < "$JW/src.lst" | tr -d ' ') files. To copy: $n files ($(human "$need_bytes"))."

    if [ "$dry" = "true" ]; then
        [ -t 1 ] || echo "[$JOB_LABEL] $n files to copy ($(human "$need_bytes")):"
        cut -f2 "$JW/tocopy.lst" | sed 's/^/    /'
        return 0
    fi
    [ "$n" -gt 0 ] || { log "[$JOB_LABEL] Everything is up to date."; return 0; }

    free_kb=$(df -k "$VOLUME" | awk 'NR == 2 { print $4 }')
    if [ -n "$free_kb" ] && [ "$(awk -v n="$need_bytes" -v f="$free_kb" 'BEGIN { print (n / 1024 > f * 0.98) ? 1 : 0 }')" = "1" ]; then
        log "ERROR: not enough space on $VOLUME_NAME. Need $(human "$need_bytes"), free $(human $((free_kb * 1024)))."
        notify "$APP: $VOLUME_NAME is full" "Need $(human "$need_bytes"), only $(human $((free_kb * 1024))) free."
        return 1
    fi

    notify "$APP: $JOB_LABEL" "Copying $n files ($(human "$need_bytes"))..."
    cut -f2 "$JW/tocopy.lst" > "$JW/tocopy.paths"
    progress_start "Copying" "$n" "$need_bytes"
    run_copy_list "$JW/tocopy.paths"; local rc=$?
    merge_manifest
    [ $rc -eq 2 ] && return 2
    return 0
}

do_verify_all() {
    log "[$JOB_LABEL] Full check started (reading back the entire copy)..."
    notify "$APP: $JOB_LABEL" "Full check of the copy started..."
    touch "$MANIFEST"
    list_files "$DEST" > "$JW/dst.lst"
    awk -F'\t' '{ p = $0; sub(/^[^\t]*\t[^\t]*\t/, "", p); sub(/^\.\//, "", p); print p }' "$JW/dst.lst" \
        | sort > "$JW/dst.paths"

    # 1. Drop manifest lines for files no longer on the drive
    awk 'FILENAME == ARGV[1] { have[$0] = 1; next } (substr($0, 67) in have)' \
        "$JW/dst.paths" "$MANIFEST" > "$JW/manifest.present"

    # 2. Read back every file and compare with its stored checksum
    local checked bad=0 rel
    checked=$(wc -l < "$JW/manifest.present" | tr -d ' ')
    # File sizes in manifest order, for the progress bar
    awk -F'\t' 'FILENAME == ARGV[1] { p = $0; sub(/^[^\t]*\t[^\t]*\t/, "", p); sub(/^\.\//, "", p); sz[p] = $1; next }
                 { k = substr($0, 67); print ((k in sz) ? sz[k] : 0) }' "$JW/dst.lst" "$JW/manifest.present" > "$JW/sizes"
    local total_bytes line sz
    total_bytes=$(awk '{ s += $1 } END { printf "%.0f", s }' "$JW/sizes")
    : > "$JW/bad.paths"
    # shasum is a Perl script; without autoflush results arrive in bursts and progress stutters
    printf 'package RawBackupAutoflush; $| = 1; 1;\n' > "$JW/RawBackupAutoflush.pm"
    progress_start "Checking" "$checked" "$total_bytes"
    exec 4< "$JW/sizes"
    while IFS= read -r line; do
        IFS= read -r -u 4 sz || sz=0
        case "$line" in
            *": OK") ;;
            *) printf '%s\n' "${line%%: FAILED*}" >> "$JW/bad.paths" ;;
        esac
        progress_add "$sz"
    done < <(cd "$DEST" && PERL5LIB="$JW" PERL5OPT="-MRawBackupAutoflush" \
                 shasum -a 256 -c "$JW/manifest.present" 2>/dev/null)
    exec 4<&-
    progress_end
    is_mounted || { log "ERROR: $VOLUME_NAME was disconnected during the check"; return 2; }
    bad=$(grep -c . "$JW/bad.paths" || true)

    # 3. Files on the drive without a checksum: compare with source and add
    awk '{ print substr($0, 67) }' "$JW/manifest.present" | sort > "$JW/known.paths"
    comm -23 "$JW/dst.paths" "$JW/known.paths" > "$JW/unknown.paths"
    local unknown=0 hs hd
    while IFS= read -r -u 3 rel; do
        [ -n "$rel" ] || continue
        unknown=$((unknown + 1))
        [ -f "$SRC/$rel" ] || continue     # only on the drive (deleted from source) - left alone
        hs=$(hash_of "$SRC/$rel"); hd=$(hash_of "$DEST/$rel")
        if [ "$hs" = "$hd" ]; then
            printf '%s  %s\n' "$hd" "$rel" >> "$NEW_HASHES"
        else
            echo "$rel" >> "$JW/bad.paths"; bad=$((bad + 1))
        fi
    done 3< "$JW/unknown.paths"

    cp "$JW/manifest.present" "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"
    merge_manifest

    log "[$JOB_LABEL] Checked $checked files against checksums, $unknown without a previous checksum. Mismatches: $bad."

    # 4. Repair mismatching files from the source
    if [ "$bad" -gt 0 ]; then
        log "Mismatching files:"; sed 's/^/    /' "$JW/bad.paths" >> "$LOG_FILE"
        local before=$FAILED rb
        rb=$(while IFS= read -r rel; do file_size "$SRC/$rel"; done < "$JW/bad.paths" | awk '{ s += $1 } END { printf "%.0f", s }')
        progress_start "Repairing" "$bad" "$rb"
        run_copy_list "$JW/bad.paths" || return 2
        merge_manifest
        local unrepaired=$((FAILED - before))
        log "[$JOB_LABEL] Repaired $((bad - unrepaired)) of $bad mismatching files."
        if [ $unrepaired -gt 0 ]; then
            notify "$APP: ERROR" "$unrepaired damaged files on $VOLUME_NAME could not be repaired. See the log."
        else
            notify "$APP: $JOB_LABEL" "Check done: $bad damaged files found and copied again."
        fi
    fi
    date +%s > "$LAST_VERIFY_FILE"
    return 0
}

verify_due() {
    [ "$FULL_VERIFY_DAYS" -gt 0 ] 2>/dev/null || return 1
    local last now
    now=$(date +%s)
    # First run: everything just copied is already verified - start the clock now
    if [ ! -f "$LAST_VERIFY_FILE" ]; then echo "$now" > "$LAST_VERIFY_FILE"; return 1; fi
    last=$(cat "$LAST_VERIFY_FILE" 2>/dev/null || echo 0)
    [ $((now - last)) -ge $((FULL_VERIFY_DAYS * 86400)) ]
}

# Runs one job in the given mode. Returns 0 ok, 1 error, 2 drive disconnected.
run_job() {
    local mode="$1" start=$SECONDS rc=0 did_verify=false
    FAILED=0; COPIED=0; COPIED_BYTES=0
    JW="$WORK/job$JOB_IDX"; mkdir -p "$JW"
    NEW_HASHES="$JW/new.sha256"; : > "$NEW_HASHES"

    if [ ! -d "$SRC" ]; then
        log "ERROR: source folder $SRC does not exist."
        notify "$APP: ERROR" "Source folder $SRC not found."
        return 1
    fi
    if [ "$mode" = "dry" ]; then do_sync true; return $?; fi
    if ! mkdir -p "$DEST" "$META" 2>>"$LOG_FILE"; then
        log "ERROR: cannot write to $VOLUME (see macOS permissions in the README)"
        notify "$APP: ERROR" "Cannot write to $VOLUME_NAME. See the log."
        return 1
    fi
    migrate_legacy_meta
    find "$DEST" -name "*$PARTIAL_SUFFIX" -type f -delete 2>/dev/null

    log "=== Start ($mode): $SRC -> $DEST"
    case "$mode" in
        verify) do_verify_all; rc=$?; did_verify=true ;;
        sync)
            do_sync false; rc=$?
            if [ $rc -eq 0 ] && verify_due; then do_verify_all; rc=$?; did_verify=true; fi
            ;;
    esac

    local secs=$((SECONDS - start)) summary
    summary="$COPIED files ($(human "$COPIED_BYTES")) copied and verified in $((secs / 60)) min $((secs % 60)) s."
    [ "$did_verify" = true ] && summary="$summary Full check done."

    if [ $rc -eq 2 ]; then
        notify "$APP: INTERRUPTED" "$VOLUME_NAME was disconnected. The backup continues next time it is plugged in."
        summary="INTERRUPTED. $summary"
    elif [ $rc -ne 0 ] || [ $FAILED -gt 0 ]; then
        notify "$APP: ERROR" "[$JOB_LABEL] $FAILED files failed. See ~/Library/Logs/raw-backup.log"
        summary="ERROR ($FAILED files). $summary"
        rc=1
    else
        notify "$APP done ✓" "[$JOB_LABEL] $summary"
    fi
    log "[$JOB_LABEL] $summary"
    is_mounted && printf '%s  %s  %s  %s\n' "$(date '+%Y-%m-%d %H:%M')" "$(hostname -s)" "$SRC -> $DEST_SUBDIR" "$summary" >> "$HISTORY"
    return $rc
}

usage() {
    cat <<EOF
Usage: raw-backup.sh [option]

  (no option)    copy new/changed files for every job whose drive is mounted,
                 and verify each copy (this is what runs automatically)
  --dry-run      show what would be copied, change nothing
  --verify-all   read back the ENTIRE copy on the drive(s) and compare with
                 stored checksums; damaged files are copied again
  --status       show progress of a running backup
  --list         show configured jobs and whether their drives are mounted
  --help         this text

Jobs are defined in $CONFIG_FILE
Nothing is ever deleted from the drives.
EOF
}

# ---------------------------------------------------------------- main

main() {
    local mode="sync"
    case "${1:-}" in
        "")            mode="sync" ;;
        --dry-run|-n)  mode="dry" ;;
        --verify-all)  mode="verify" ;;
        --status)      show_status; exit 0 ;;
        --list)        load_jobs; list_jobs; exit 0 ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "Unknown option: $1" >&2; usage; exit 64 ;;
    esac

    load_jobs

    # launchd starts the script on EVERY mount - exit quietly if none of our drives is there
    local i any=false
    for ((i = 0; i < JOB_COUNT; i++)); do
        is_mounted "$VOLUMES_ROOT/${JOB_VOL[$i]}" && { any=true; break; }
    done
    if [ "$any" = false ]; then
        [ -t 1 ] && echo "None of the configured drives is mounted. (raw-backup.sh --list shows the jobs.)"
        exit 0
    fi

    if [ "$mode" != "dry" ]; then
        acquire_lock || { log "Another run is already in progress - exiting."; exit 0; }
    fi
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/raw-backup.XXXXXX")
    trap cleanup EXIT

    # Run every job whose drive is mounted. Repeat until no new drive has appeared,
    # so a drive plugged in while another is being backed up is not missed.
    local done_list=" " ran rc overall=0 ok_vols=$'\n' bad_vols=$'\n' v
    while :; do
        ran=false
        for ((i = 0; i < JOB_COUNT; i++)); do
            case "$done_list" in *" $i "*) continue ;; esac
            set_job "$i"
            is_mounted || continue
            done_list="$done_list$i "; ran=true
            run_job "$mode"; rc=$?
            if [ $rc -eq 0 ]; then ok_vols="$ok_vols$VOLUME"$'\n'
            else bad_vols="$bad_vols$VOLUME"$'\n'; overall=1; fi
        done
        [ "$ran" = true ] && [ "$mode" != "dry" ] || break
    done

    if [ "$mode" = "sync" ] && [ "$EJECT_WHEN_DONE" = "true" ] && command -v diskutil >/dev/null; then
        sync
        printf '%s' "$ok_vols" | sort -u | while IFS= read -r v; do
            [ -n "$v" ] || continue
            case "$bad_vols" in *$'\n'"$v"$'\n'*) continue ;; esac
            is_mounted "$v" && diskutil eject "$v" >/dev/null 2>&1 && log "Ejected $v."
        done
    fi
    exit $overall
}

main "$@"
