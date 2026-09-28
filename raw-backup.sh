#!/bin/bash
#
# raw-backup.sh
# Kopierar nya och ändrade filer från ~/WORK/Raw till USB-minnet "USB_1TB"
# och verifierar varje kopierad fil med SHA-256. Startas automatiskt av
# launchd när en volym monteras (se install.sh).
#
# https://github.com/westruplabs/raw-backup
#
# Användning:
#   raw-backup.sh                kopiera nytt/ändrat och verifiera kopiorna
#   raw-backup.sh --dry-run      visa vad som skulle kopieras, ändra ingenting
#   raw-backup.sh --verify-all   läs tillbaka HELA kopian på USB-minnet och
#                                jämför mot sparade checksummor (reparerar fel)
#   raw-backup.sh --help
#
# Skriptet raderar aldrig något på USB-minnet. Filer du tar bort i Raw ligger
# kvar på minnet.
#
# Kompatibelt med macOS inbyggda bash 3.2.

set -uo pipefail

# ---------- Standardinställningar (skriv över i ~/.config/raw-backup.conf) ----------
SRC="$HOME/WORK/Raw"                 # källmapp
VOLUME_NAME="USB_1TB"                # USB-minnets namn
DEST_SUBDIR="Raw"                    # mapp på USB-minnet som kopian hamnar i
FULL_VERIFY_DAYS=30                  # fullständig kontroll var N:e dag (0 = aldrig automatiskt)
EJECT_WHEN_DONE=false                # mata ut minnet när allt gått bra
NOTIFY=true                          # macOS-notiser
LOG_FILE="$HOME/Library/Logs/raw-backup.log"
MTIME_TOLERANCE=2                    # sekunder (FAT/exFAT sparar tider grovt)
VOLUMES_ROOT="/Volumes"
# -------------------------------------------------------------------------------------

CONFIG_FILE="${RAW_BACKUP_CONFIG:-$HOME/.config/raw-backup.conf}"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

VOLUME="$VOLUMES_ROOT/$VOLUME_NAME"
DEST="$VOLUME/$DEST_SUBDIR"
META="$VOLUME/.raw-backup"
MANIFEST="$META/manifest.sha256"
LAST_VERIFY_FILE="$META/last_full_verify"
HISTORY="$META/history.log"
LOCK_DIR="/tmp/raw-backup-$(id -u).lock"
EXCLUDE_RE='/(\.DS_Store|\._[^/]*|\.Spotlight-V100|\.Trashes|\.fseventsd|\.TemporaryItems|\.DocumentRevisions-V100)(/|$)'
PARTIAL_SUFFIX=".rbpartial"

if [ "$(uname)" = "Darwin" ]; then CP_OPTS="-X"; else CP_OPTS=""; fi

WORK=""
FAILED=0
COPIED=0
COPIED_BYTES=0
NEW_HASHES=""

# ---------------------------------------------------------------- hjälpfunktioner

log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
    if [ -t 1 ]; then printf '%s\n' "$*"; fi
}

notify() {  # $1 rubrik, $2 text
    [ "$NOTIFY" = "true" ] || return 0
    command -v osascript >/dev/null 2>&1 || return 0
    local t="${1//\"/\'}" m="${2//\"/\'}"
    osascript -e "display notification \"$m\" with title \"$t\"" >/dev/null 2>&1 || true
}

human() {  # byte -> läsbart
    awk -v b="$1" 'BEGIN { split("B KB MB GB TB", u, " "); i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i] }'
}

is_mounted() {
    # Kräver att volymen verkligen är monterad – annars kan en kvarglömd tom
    # mapp i /Volumes göra att backupen hamnar på den interna disken.
    [ -d "$VOLUME" ] || return 1
    mount | grep -F " on $VOLUME (" >/dev/null 2>&1
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
    if [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then rm -rf "$LOCK_DIR"; fi
}

hash_of() { shasum -a 256 < "$1" 2>/dev/null | awk '{print $1}'; }

# Skriver "storlek<TAB>mtime<TAB>./relativ/sökväg" för alla filer under $1
list_files() {
    if [ "$(uname)" = "Darwin" ]; then
        (cd "$1" && find . -type f -exec stat -f '%z%t%m%t%N' {} +)
    else
        (cd "$1" && find . -type f -printf '%s\t%T@\t%p\n')
    fi | { grep -Ev "$EXCLUDE_RE" || true; }
}

# Kopierar en fil via temporärt namn, verifierar med SHA-256, försöker två gånger.
copy_verified() {  # $1 = relativ sökväg
    local rel="$1" s="$SRC/$1" d="$DEST/$1" dir tmp hs hd attempt size
    dir=$(dirname "$d")
    tmp="$dir/.$(basename "$d")$PARTIAL_SUFFIX"
    if [ ! -f "$s" ]; then log "HOPPAR ÖVER (försvann ur källan): $rel"; return 0; fi
    mkdir -p "$dir" || { log "FEL: kan inte skapa mapp $dir"; return 1; }

    for attempt in 1 2; do
        is_mounted || { log "FEL: USB-minnet försvann under kopieringen"; return 2; }
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
            log "VARNING: checksumma stämmer inte (försök $attempt): $rel"
        else
            log "VARNING: kopiering misslyckades (försök $attempt): $rel"
        fi
    done
    rm -f "$tmp"
    log "FEL: kunde inte kopiera och verifiera: $rel"
    return 1
}

# Lägger in nya checksummor i manifestet (ersätter gamla rader för samma fil)
merge_manifest() {
    [ -s "$NEW_HASHES" ] || return 0
    touch "$MANIFEST"
    awk 'FILENAME == ARGV[1] { upd[substr($0, 67)] = 1; next }
         !(substr($0, 67) in upd)' "$NEW_HASHES" "$MANIFEST" > "$WORK/manifest.new"
    cat "$NEW_HASHES" >> "$WORK/manifest.new"
    sort -k2 "$WORK/manifest.new" > "$WORK/manifest.sorted" \
        && cp "$WORK/manifest.sorted" "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"
    : > "$NEW_HASHES"
}

run_copy_list() {  # $1 = fil med relativa sökvägar, en per rad
    local rel rc
    while IFS= read -r -u 3 rel; do
        [ -n "$rel" ] || continue
        copy_verified "$rel"; rc=$?
        if [ $rc -eq 2 ]; then return 2; fi
        [ $rc -eq 0 ] || FAILED=$((FAILED + 1))
    done 3< "$1"
    return 0
}

# ---------------------------------------------------------------- lägen

do_sync() {
    local dry="$1"
    list_files "$SRC" > "$WORK/src.lst" 2> "$WORK/src.err"
    if [ -s "$WORK/src.err" ]; then
        log "VARNING vid läsning av källan:"; cat "$WORK/src.err" >> "$LOG_FILE"
    fi
    if [ ! -s "$WORK/src.lst" ]; then
        log "Källan $SRC är tom eller oläsbar – avbryter för säkerhets skull."
        notify "Raw-backup" "Källmappen är tom eller oläsbar. Se loggen."
        return 1
    fi
    list_files "$DEST" > "$WORK/dst.lst" 2>/dev/null

    # Jämför storlek + ändringstid. Utskrift: storlek<TAB>sökväg
    awk -F'\t' -v tol="$MTIME_TOLERANCE" '
        { p = $0; sub(/^[^\t]*\t[^\t]*\t/, "", p); sub(/^\.\//, "", p); m = int($2) }
        FILENAME == ARGV[1] { dsz[p] = $1; dmt[p] = m; next }
        { if (!(p in dsz) || dsz[p] != $1 || dmt[p] - m > tol || m - dmt[p] > tol)
              print $1 "\t" p }
    ' "$WORK/dst.lst" "$WORK/src.lst" | sort -t "$(printf '\t')" -k2 > "$WORK/tocopy.lst"

    local n need_bytes free_kb
    n=$(wc -l < "$WORK/tocopy.lst" | tr -d ' ')
    need_bytes=$(awk -F'\t' '{ s += $1 } END { printf "%.0f", s }' "$WORK/tocopy.lst")
    log "Källa: $(wc -l < "$WORK/src.lst" | tr -d ' ') filer. Att kopiera: $n filer ($(human "$need_bytes"))."

    if [ "$dry" = "true" ]; then
        cut -f2 "$WORK/tocopy.lst"
        return 0
    fi
    [ "$n" -gt 0 ] || { log "Allt är redan uppdaterat."; return 0; }

    free_kb=$(df -k "$VOLUME" | awk 'NR == 2 { print $4 }')
    if [ -n "$free_kb" ] && [ "$(awk -v n="$need_bytes" -v f="$free_kb" 'BEGIN { print (n / 1024 > f * 0.98) ? 1 : 0 }')" = "1" ]; then
        log "FEL: för lite plats på USB-minnet. Behövs $(human "$need_bytes"), ledigt $(human $((free_kb * 1024)))."
        notify "Raw-backup: fullt" "Behövs $(human "$need_bytes"), bara $(human $((free_kb * 1024))) ledigt."
        return 1
    fi

    notify "Raw-backup" "Kopierar $n filer ($(human "$need_bytes"))…"
    cut -f2 "$WORK/tocopy.lst" > "$WORK/tocopy.paths"
    run_copy_list "$WORK/tocopy.paths"; local rc=$?
    merge_manifest
    [ $rc -eq 2 ] && return 2
    return 0
}

do_verify_all() {
    log "Fullständig kontroll startar (läser hela kopian på USB-minnet)…"
    notify "Raw-backup" "Fullständig kontroll av USB-kopian startar…"
    touch "$MANIFEST"
    list_files "$DEST" | awk -F'\t' '{ p = $0; sub(/^[^\t]*\t[^\t]*\t/, "", p); sub(/^\.\//, "", p); print p }' \
        | sort > "$WORK/dst.paths"

    # 1. Ta bort manifest-rader för filer som inte längre finns på minnet
    awk 'FILENAME == ARGV[1] { have[$0] = 1; next } (substr($0, 67) in have)' \
        "$WORK/dst.paths" "$MANIFEST" > "$WORK/manifest.present"

    # 2. Läs tillbaka varje fil och jämför med sparad checksumma
    local checked bad=0 rel
    checked=$(wc -l < "$WORK/manifest.present" | tr -d ' ')
    ( cd "$DEST" && shasum -a 256 -c "$WORK/manifest.present" 2>/dev/null ) \
        | grep -v ': OK$' | sed 's/: FAILED.*$//' > "$WORK/bad.paths"
    is_mounted || { log "FEL: USB-minnet försvann under kontrollen"; return 2; }
    bad=$(grep -c . "$WORK/bad.paths" || true)

    # 3. Filer på minnet som saknar checksumma: jämför mot källan och lägg till
    awk '{ print substr($0, 67) }' "$WORK/manifest.present" | sort > "$WORK/known.paths"
    comm -23 "$WORK/dst.paths" "$WORK/known.paths" > "$WORK/unknown.paths"
    local unknown=0 hs hd
    while IFS= read -r -u 3 rel; do
        [ -n "$rel" ] || continue
        unknown=$((unknown + 1))
        [ -f "$SRC/$rel" ] || continue     # finns bara på minnet (raderad i källan) – lämnas orörd
        hs=$(hash_of "$SRC/$rel"); hd=$(hash_of "$DEST/$rel")
        if [ "$hs" = "$hd" ]; then
            printf '%s  %s\n' "$hd" "$rel" >> "$NEW_HASHES"
        else
            echo "$rel" >> "$WORK/bad.paths"; bad=$((bad + 1))
        fi
    done 3< "$WORK/unknown.paths"

    cp "$WORK/manifest.present" "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"
    merge_manifest

    log "Kontrollerade $checked filer mot checksumma, $unknown utan tidigare checksumma. Avvikelser: $bad."

    # 4. Reparera avvikande filer från källan
    if [ "$bad" -gt 0 ]; then
        log "Avvikande filer:"; sed 's/^/    /' "$WORK/bad.paths" >> "$LOG_FILE"
        local before=$FAILED
        run_copy_list "$WORK/bad.paths" || return 2
        merge_manifest
        local unrepaired=$((FAILED - before))
        log "Reparerade $((bad - unrepaired)) av $bad avvikande filer."
        if [ $unrepaired -gt 0 ]; then
            notify "Raw-backup: FEL" "$unrepaired filer på USB-minnet är skadade och kunde inte repareras. Se loggen."
        else
            notify "Raw-backup" "Kontroll klar: $bad skadade filer hittades och kopierades om."
        fi
    fi
    date +%s > "$LAST_VERIFY_FILE"
    return 0
}

verify_due() {
    [ "$FULL_VERIFY_DAYS" -gt 0 ] 2>/dev/null || return 1
    local last now
    now=$(date +%s)
    # Första körningen: allt som kopierats är redan verifierat – starta klockan nu
    if [ ! -f "$LAST_VERIFY_FILE" ]; then echo "$now" > "$LAST_VERIFY_FILE"; return 1; fi
    last=$(cat "$LAST_VERIFY_FILE" 2>/dev/null || echo 0)
    [ $((now - last)) -ge $((FULL_VERIFY_DAYS * 86400)) ]
}

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------- huvudprogram

main() {
    local mode="sync"
    case "${1:-}" in
        "")            mode="sync" ;;
        --dry-run|-n)  mode="dry" ;;
        --verify-all)  mode="verify" ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "Okänt argument: $1" >&2; usage; exit 64 ;;
    esac

    # launchd startar skriptet vid ALLA monteringar – tyst avslut om det inte är vårt minne
    if ! is_mounted; then
        [ -t 1 ] && echo "$VOLUME är inte monterad."
        exit 0
    fi
    acquire_lock || { log "En annan körning pågår redan – avslutar."; exit 0; }
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/raw-backup.XXXXXX")
    trap cleanup EXIT
    NEW_HASHES="$WORK/new.sha256"; : > "$NEW_HASHES"

    if [ ! -d "$SRC" ]; then
        log "FEL: källmappen $SRC finns inte."
        notify "Raw-backup: FEL" "Källmappen $SRC hittas inte."
        exit 1
    fi
    if [ "$mode" = "dry" ]; then do_sync true; exit $?; fi
    mkdir -p "$DEST" "$META" || { log "FEL: kan inte skriva till $VOLUME"; notify "Raw-backup: FEL" "Kan inte skriva till USB-minnet. Se loggen."; exit 1; }
    find "$DEST" -name "*$PARTIAL_SUFFIX" -type f -delete 2>/dev/null

    local start=$SECONDS rc=0 did_verify=false
    log "=== Start ($mode): $SRC -> $DEST"

    case "$mode" in
        verify) do_verify_all; rc=$?; did_verify=true ;;
        sync)
            do_sync false; rc=$?
            if [ $rc -eq 0 ] && verify_due; then do_verify_all; rc=$?; did_verify=true; fi
            ;;
    esac

    local secs=$((SECONDS - start)) summary
    summary="$COPIED filer ($(human "$COPIED_BYTES")) kopierade och verifierade på $((secs / 60)) min $((secs % 60)) s."
    [ "$did_verify" = true ] && summary="$summary Fullständig kontroll gjord."

    if [ $rc -eq 2 ]; then
        notify "Raw-backup: AVBRUTEN" "USB-minnet togs bort. Kopieringen fortsätter nästa gång det sätts i."
        summary="AVBRUTEN. $summary"
    elif [ $rc -ne 0 ] || [ $FAILED -gt 0 ]; then
        notify "Raw-backup: FEL" "$FAILED filer misslyckades. Se ~/Library/Logs/raw-backup.log"
        summary="FEL ($FAILED filer). $summary"
    else
        notify "Raw-backup klar ✓" "$summary"
    fi
    log "$summary"
    is_mounted && printf '%s  %s  %s\n' "$(date '+%Y-%m-%d %H:%M')" "$(hostname -s)" "$summary" >> "$HISTORY"

    if [ "$EJECT_WHEN_DONE" = "true" ] && [ $rc -eq 0 ] && [ $FAILED -eq 0 ] && command -v diskutil >/dev/null; then
        sync
        diskutil eject "$VOLUME" >/dev/null 2>&1 && log "USB-minnet utmatat."
    fi
    [ $rc -eq 0 ] && [ $FAILED -eq 0 ]
}

main "$@"
