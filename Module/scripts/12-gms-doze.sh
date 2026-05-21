#!/system/bin/sh
MODDIR="${MODDIR:-${0%/*}/..}"
. "$MODDIR/scripts/lib.sh"

####################################
# GMS Doze / App Standby
####################################

run_cmd() {
    "$@" >/dev/null 2>&1
    local code="$?"

    : "${RUN_LOG:=/dev/null}"
    if [ "$HYPEROPTIMIZE_DEBUG" = "1" ]; then
        if [ "$code" = "0" ]; then
            echo "cmd ok: $*" >> "$RUN_LOG"
        else
            echo "cmd failed($code): $*" >> "$RUN_LOG"
        fi
    fi

    return 0
}

pkg_exists() {
    pm path "$1" >/dev/null 2>&1
}

set_appop() {
    local pkg="$1"
    local op="$2"
    local mode="$3"

    pkg_exists "$pkg" || return 0
    run_cmd cmd appops set "$pkg" "$op" "$mode"
}

restrict_background_package() {
    local pkg="$1"

    # These appops are intentionally aggressive. Unsupported ops fail silently
    # on older builds, so the script remains safe across HyperOS revisions.
    set_appop "$pkg" "WAKE_LOCK" "ignore"
    set_appop "$pkg" "RUN_IN_BACKGROUND" "ignore"
    set_appop "$pkg" "RUN_ANY_IN_BACKGROUND" "ignore"
    set_appop "$pkg" "START_FOREGROUND" "ignore"
    set_appop "$pkg" "SCHEDULE_EXACT_ALARM" "ignore"
    set_appop "$pkg" "USE_EXACT_ALARM" "ignore"
    set_appop "$pkg" "ALARM_WAKEUP" "ignore"
}

apply_gms_restrictions() {
    local pkg

    for pkg in \
        com.google.android.gms \
        com.google.android.gsf \
        com.android.vending
    do
        restrict_background_package "$pkg"
        run_cmd cmd appops set "$pkg" "AUTO_START" "ignore"
        run_cmd cmd appops set "$pkg" "MIUI_START_BACKGROUND" "ignore"
        run_cmd cmd appops set "$pkg" "MIUI_WAKE_PATH" "ignore"
        run_cmd am set-inactive "$pkg" true
        run_cmd cmd jobscheduler timeout "$pkg"
    done

    # Remove Google packages from idle whitelists where the framework permits it.
    # System whitelists may reject removal; failures are logged but ignored.
    run_cmd dumpsys deviceidle whitelist -com.google.android.gms
    run_cmd dumpsys deviceidle whitelist -com.google.android.gsf
    run_cmd dumpsys deviceidle whitelist -com.android.vending
    run_cmd dumpsys deviceidle except-idle-whitelist -com.google.android.gms
    run_cmd dumpsys deviceidle except-idle-whitelist -com.google.android.gsf
    run_cmd dumpsys deviceidle except-idle-whitelist -com.android.vending
    run_cmd dumpsys deviceidle sys-whitelist -com.google.android.gms
    run_cmd dumpsys deviceidle sys-whitelist -com.google.android.gsf
    run_cmd dumpsys deviceidle sys-whitelist -com.android.vending
}

apply_xiaomi_restrictions() {
    local pkg

    for pkg in \
        com.miui.analytics \
        com.miui.bugreport \
        com.miui.msa.global \
        com.miui.systemAdSolution \
        com.miui.contentcatcher \
        com.miui.daemon \
        com.miui.yellowpage \
        com.xiaomi.joyose \
        com.xiaomi.mipicks
    do
        pkg_exists "$pkg" || continue

        # Per-user disable keeps the system image intact and is easy to revert.
        # Core push, telephony, updater, permission, and security packages are
        # deliberately left alone to reduce bootloop and notification risk.
        run_cmd pm disable-user --user 0 "$pkg"
        restrict_background_package "$pkg"
        run_cmd cmd appops set "$pkg" "AUTO_START" "ignore"
        run_cmd cmd appops set "$pkg" "MIUI_START_BACKGROUND" "ignore"
        run_cmd cmd appops set "$pkg" "MIUI_WAKE_PATH" "ignore"
        run_cmd am set-inactive "$pkg" true
    done
}

apply_deviceidle_tuning() {
    # Push DeviceIdle toward Deep Doze quickly after the display turns off. These
    # constants are framework-level knobs and do not lock kernel tunables, so app
    # or kernel managers can still override their own domains later.
    run_cmd dumpsys deviceidle enable
    run_cmd dumpsys deviceidle enabled all
    run_cmd dumpsys deviceidle constants inactive_to=30000,sensing_to=0,locating_to=0,motion_inactive_to=30000,idle_after_inactive_to=60000,idle_pending_to=10000,max_idle_pending_to=30000,idle_pending_factor=1.2,idle_to=1800000,max_idle_to=21600000,idle_factor=2.0,min_time_to_alarm=600000,light_after_inactive_to=30000,light_pre_idle_to=15000,light_idle_to=60000,light_idle_factor=1.5,light_max_idle_to=900000,light_idle_maintenance_min_budget=10000,light_idle_maintenance_max_budget=30000
}

screen_is_on() {
    dumpsys power 2>/dev/null | grep -qiE "mWakefulness=Awake|Display Power: state=ON|mScreenOn=true|state=ON"
}

on_battery() {
    ! dumpsys battery 2>/dev/null | grep -qiE "AC powered: true|USB powered: true|Wireless powered: true"
}

start_doze_monitor() {
    local lock

    [ "$HYPEROPTIMIZE_DOZE_MONITOR" = "0" ] && return 0

    lock="$MODDIR/config/doze-monitor.lock"
    if ! mkdir "$lock" 2>/dev/null; then
        [ "$HYPEROPTIMIZE_DEBUG" = "1" ] && echo "doze monitor already running" >> "$RUN_LOG"
        return 0
    fi

    (
        trap 'rmdir "$lock" 2>/dev/null' EXIT
        off_ticks=0

        while true; do
            if screen_is_on || ! on_battery; then
                off_ticks=0
                sleep 45
                continue
            fi

            off_ticks=$((off_ticks + 1))
            if [ "$off_ticks" -ge 2 ]; then
                run_cmd dumpsys deviceidle step deep
                run_cmd dumpsys deviceidle force-idle deep
                sleep 300
            else
                sleep 45
            fi
        done
    ) &
}

apply_deviceidle_tuning
apply_gms_restrictions
apply_xiaomi_restrictions
start_doze_monitor
