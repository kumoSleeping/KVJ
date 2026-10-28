#!/bin/sh
# KVJ's updater on macOS, written into <data>/updates and started by KVJ just
# before it quits (core/engine/src/update/mod.rs).
#   kvj-update.sh <pid> <installed KVJ.app> <new KVJ.app> <data dir> <version> <old version>
# Waits for KVJ to quit, moves the installed app aside (beside it, so it is a
# rename), copies the new one into its place and opens it. The new KVJ writes
# updates/started-<version> once its window is up; then the old one is deleted.
# Without that word within 90 s (or if the new one exits first, or does not
# appear within 15 s) the new one is
# stopped, the old one put back and opened, and updates/result.txt says why.
# Every step is logged to the day's session log, like the app's own lines.
pid=$1 app=$2 new=$3 data=$4 version=$5 from=$6
updates="$data/updates"
backup="$(dirname "$app")/.KVJ-previous.app"

log() {
    mkdir -p "$data/logs"
    printf '%s.000 [%s] 更新：%s\n' "$(date +%H:%M:%S)" "$1" "$2" >> "$data/logs/kvj-$(date +%Y-%m-%d).log"
}
# The reason for the KVJ that is started next, then that KVJ.
fail() {
    log error "$1"
    printf '%s\n%s\n' "$version" "$1" > "$updates/result.txt"
    rm -f "$updates/pending.json" "$updates/started-$version"
}
# KVJ processes started from this very bundle (compared as text: the path is
# no pattern).
pids() {
    for p in $(pgrep -x KVJ); do
        [ "$(ps -o comm= -p "$p")" = "$app/Contents/MacOS/KVJ" ] && echo "$p"
    done
}
running() {
    [ -n "$(pids)" ]
}
# What open starts gets no environment from here: a KVJ that was given its
# own data folder hands it on (the started-<version> word lands there).
launch() {
    if [ -n "$KVJ_DATA_DIR" ]; then
        open --env "KVJ_DATA_DIR=$KVJ_DATA_DIR" "$app"
    else
        open "$app"
    fi
}

log info "等待 v$from 退出，以安装 v$version（$app）"
# Deadlines by the clock: each check costs time of its own on a busy machine.
until=$(($(date +%s) + 120))
while kill -0 "$pid" 2> /dev/null; do
    if [ "$(date +%s)" -ge "$until" ]; then
        fail "KVJ 两分钟内没有退出，没有更新"
        exit 1
    fi
    sleep 0.2
done

if [ ! -d "$new/Contents/MacOS" ]; then
    fail "找不到准备好的新版（$new）"
    launch
    exit 1
fi
rm -rf "$backup"
if ! mv "$app" "$backup"; then
    fail "无法移开旧版（$app）"
    launch
    exit 1
fi
if ! ditto "$new" "$app"; then
    rm -rf "$app"
    mv "$backup" "$app"
    fail "无法把新版放进 $(dirname "$app")（磁盘满了或没有权限？）"
    launch
    exit 1
fi
xattr -dr com.apple.quarantine "$app" 2> /dev/null
log info "已放入 v$version，启动中"
if ! launch; then
    log warn "open 没有打开新版，再试一次"
    sleep 1
    launch
fi

# Up to 90 s for the word; one that never appears in 15 s, or that ran and
# is gone, is not waited for.
started=$(date +%s) seen=0
while [ ! -e "$updates/started-$version" ]; do
    now=$(date +%s)
    if running; then
        seen=1
    elif [ "$seen" = 1 ] || [ "$now" -ge $((started + 15)) ]; then
        break
    fi
    if [ "$now" -ge $((started + 90)) ]; then
        break
    fi
    sleep 0.2
done

if [ -e "$updates/started-$version" ]; then
    rm -rf "$backup" "$(dirname "$new")" "$updates/$version-"*
    rm -f "$updates/pending.json" "$updates/started-$version"
    log info "已更新到 v$version，旧版 v$from 已删除"
    exit 0
fi

# Back to the old one.
if running; then
    why="新版 v$version 90 秒内没有启动完成，已回到 v$from"
    kill $(pids) 2> /dev/null
    sleep 2
    kill -9 $(pids) 2> /dev/null
    sleep 0.5
elif [ "$seen" = 1 ]; then
    why="新版 v$version 启动后退出了，已回到 v$from"
else
    why="新版 v$version 没有启动，已回到 v$from"
fi
rm -rf "$app"
if ! mv "$backup" "$app"; then
    log error "无法放回旧版：它在 $backup，请手动改回 $(basename "$app")"
    printf '%s\n%s\n' "$version" "无法放回旧版，它在 $backup" > "$updates/result.txt"
    exit 1
fi
fail "$why"
launch
exit 1
