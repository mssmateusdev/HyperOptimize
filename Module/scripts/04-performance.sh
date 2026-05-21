#!/system/bin/sh
MODDIR="${MODDIR:-${0%/*}/..}"
. "$MODDIR/scripts/lib.sh"

####################################
# Performance Tuning
####################################
# Docs : https://blog.xzr.moe/archives/15/#section-24

set_cpufreq_governor() {
    local policy="$1"
    local governors gov

    [ -d "$policy" ] || return 0
    governors="$(cat "$policy/scaling_available_governors" 2>/dev/null)"

    for gov in schedutil conservative powersave; do
        if echo "$governors" | grep -qw "$gov"; then
            write "$policy/scaling_governor" "$gov"
            return 0
        fi
    done

    return 0
}

cap_cpufreq_policy() {
    local policy="$1"
    local max min cap percent

    [ -d "$policy" ] || return 0
    max="$(cat "$policy/cpuinfo_max_freq" 2>/dev/null)"
    min="$(cat "$policy/scaling_min_freq" 2>/dev/null)"

    echo "$max" | grep -qE '^[0-9]+$' || return 0
    echo "$min" | grep -qE '^[0-9]+$' || min=0

    # Dynamic cluster cap for Dimensity-class layouts such as Poco X7 Pro.
    # Bigger clusters get a stronger cap; no value is locked, so Franco Kernel
    # Manager or PowerHAL may override it later without fighting chmod tricks.
    if [ "$max" -ge 3200000 ]; then
        percent=68
    elif [ "$max" -ge 2800000 ]; then
        percent=72
    elif [ "$max" -ge 2200000 ]; then
        percent=78
    else
        percent=85
    fi

    cap=$((max * percent / 100))
    [ "$cap" -lt "$min" ] && cap="$min"
    write "$policy/scaling_max_freq" "$cap"
}

apply_cpu_energy_profile() {
    local policy

    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$policy" ] || continue
        set_cpufreq_governor "$policy"
        cap_cpufreq_policy "$policy"
        write_if_writable "$policy/schedutil/up_rate_limit_us" "20000"
        write_if_writable "$policy/schedutil/down_rate_limit_us" "5000"
        write_if_writable "$policy/schedutil/hispeed_freq" "0"
        write_if_writable "$policy/schedutil/pl" "0"
        write_if_writable "$policy/schedutil/iowait_boost_enable" "0"
    done
}

set_devfreq_governor() {
    local dev="$1"
    local governors gov

    [ -d "$dev" ] || return 0
    governors="$(cat "$dev/available_governors" 2>/dev/null)"

    for gov in powersave simple_ondemand userspace; do
        if echo "$governors" | grep -qw "$gov"; then
            write "$dev/governor" "$gov"
            return 0
        fi
    done

    return 0
}

cap_devfreq_device() {
    local dev="$1"
    local max min cap

    [ -d "$dev" ] || return 0
    max="$(cat "$dev/max_freq" 2>/dev/null)"
    min="$(cat "$dev/min_freq" 2>/dev/null)"

    echo "$max" | grep -qE '^[0-9]+$' || return 0
    echo "$min" | grep -qE '^[0-9]+$' || min=0

    cap=$((max * 70 / 100))
    [ "$cap" -lt "$min" ] && cap="$min"
    write "$dev/max_freq" "$cap"
}

apply_gpu_energy_profile() {
    local dev base

    for dev in /sys/class/devfreq/*; do
        [ -d "$dev" ] || continue
        base="${dev##*/}"

        case "$base" in
            *gpu*|*mali*|*ged*|*kgsl*)
                set_devfreq_governor "$dev"
                cap_devfreq_device "$dev"
                write_if_writable "$dev/polling_interval" "50"
                ;;
        esac
    done
}

# Vendor Specific Tuning
# Qualcomm Tuning
if [ "$(getprop ro.hardware)" = "qcom" ]; then 
    BUS_DCVS="/sys/devices/system/cpu/bus_dcvs"

    # KGSL Tuning & GPU Tuning(GPU)
    # GPU devfreq min/max are vendor policy knobs. Avoid forcing them globally;
    # PowerHAL, thermal, and game/display modes may need to adjust them.
    # write_in_path_excluding "0" "/sys/devices/platform" "kgsl-3d0/devfreq" "kgsl-busmon" "min_freq"
    write "/sys/class/kgsl/kgsl-3d0/force_bus_on" "0"
    write "/sys/class/kgsl/kgsl-3d0/force_clk_on" "0"
    write "/sys/class/kgsl/kgsl-3d0/force_no_nap" "0"
    write "/sys/class/kgsl/kgsl-3d0/force_rail_on" "0"
    # Heuristic and kernel-specific; leave disabled unless validated on target devices.
    # lock_val "0" /sys/class/kgsl/kgsl-3d0/bus_split
    # Read-protected on some kernels; avoid forcing permissions for this GPU
    # policy knob unless validated on target devices.
    # write "/sys/class/kgsl/kgsl-3d0/popp" "0"
    write "/sys/class/kgsl/kgsl-3d0/bcl" "0"
    # lock_val "100" /sys/class/kgsl/kgsl-3d0/devfreq/mod_percent
    # Heuristic and kernel-specific; leave disabled unless validated on target devices.
    # lock_val "0" /sys/class/kgsl/kgsl-3d0/preemption
    # Heuristic and workload-sensitive; avoid forcing a global idle timer.
    # lock_val "30" /sys/class/kgsl/kgsl-3d0/idle_timer

    # lock_val "2147483647" /sys/kernel/gpu/gpu_max_clock
    write "/sys/kernel/gpu/gpu_min_clock" "0"

    # RCU Tuning
    # https://www.kernel.org/doc/Documentation/RCU/Design/Expedited-Grace-Periods/Expedited-Grace-Periods.html
    write_if_writable "/sys/kernel/rcu_expedited" "0"

    # PELT Multiplier
    # lock_val "4" "/proc/sys/kernel/sched_pelt_multiplier"

    # Enable LPM for all CPUs
    # qcom_lpm controls Qualcomm idle / cluster power-state entry. Forcing
    # these disables to 0 prefers allowing deeper idle states.
    for disable in $(find /sys/devices/system/cpu/qcom_lpm -type f -name '*disable*'); do
        write "$disable" "0"
    done

    # BUS Performance Control
    # bus_dcvs is Qualcomm DDR/L3 bandwidth + memlat scaling, not plain CPU
    # frequency control. Forcing it aggressively is device-sensitive, so only
    # light-touch tuning is left active here.
    # lock_val_in_path "2147483647" "$BUS_DCVS/DDR" "max_freq"
    # lock_val_in_path "2147483647" "$BUS_DCVS/L3" "max_freq"
    # Heuristic and platform-specific; avoid forcing DDRQOS nodes globally.
    # if [ -d "$BUS_DCVS/DDRQOS" ]; then
    #     lock_val_in_path "1" "$BUS_DCVS/DDRQOS" "max_freq"
    #     lock_val_in_path "1" "$BUS_DCVS/DDRQOS" "min_freq"
    #     lock_val "1" "$BUS_DCVS/DDRQOS/boost_freq"
    # fi


    write_in_path "0" "/sys/devices/system/cpu/cpufreq" "hispeed_freq"
    write_in_path "0" "/sys/devices/system/cpu/cpufreq" "rtg_boost_freq"
    write_in_path "5000" "/sys/devices/system/cpu/cpufreq" "up_rate_limit_us"
    write_in_path "1000" "/sys/devices/system/cpu/cpufreq" "down_rate_limit_us"

else 
#Mediatek Tuning
    write  "/sys/kernel/ged/hal/custom_upbound_gpu_freq" "0"
    write  "/sys/module/ged/parameters/is_GED_KPI_enabled" "0"
    write  "/sys/module/mtk_core_ctl/parameters/policy_enable" "0"
    write "/sys/kernel/ged/hal/dcs_mode" "0"
    write "/proc/mtk_lpm/cpuidle/enable" "1"
    write_if_writable "/sys/module/ged/parameters/gpu_idle" "1"
    write_if_writable "/sys/module/ged/parameters/gx_game_mode" "0"
    write_if_writable "/sys/module/ged/parameters/ged_smart_boost" "0"
    write_if_writable "/sys/module/ged/parameters/boost_gpu_enable" "0"
    write_if_writable "/sys/module/ged/parameters/enable_cpu_boost" "0"
    write_if_writable "/sys/module/ged/parameters/ged_boost_enable" "0"
    write_if_writable "/sys/module/ged/parameters/ged_force_mdp_enable" "0"
    write_if_writable "/sys/module/mtk_fpsgo/parameters/boost_affinity" "0"
    write_if_writable "/sys/module/mtk_fpsgo/parameters/bypass_flag" "1"
fi

# WALT
if [ -d /proc/sys/walt/ ]; then

    # WALT disable boost
    for i in /proc/sys/walt/input_boost/* ; do
        write "$i" "0"
    done

    for i in /sys/devices/system/cpu/cpu*/cpufreq/walt/boost ; do
        write "$i" "0" 
    done

    write "/proc/sys/walt/sched_boost" "0"
    write "/proc/sys/walt/sched_ed_boost" "0"
    write "/proc/sys/walt/sched_asymcap_boost" "0"
    write "/proc/sys/walt/input_boost/input_boost_freq" "0 0 0 0 0 0 0 0"

    # Conservative Predict Load
    write "/proc/sys/walt/sched_conservative_pl" "1"

    # Check WINDOW_STATS_RECENT | WINDOW_STATS_MAX | WINDOW_STATS_MAX_RECENT_AVG | WINDOW_STATS_AVG
    write "/proc/sys/walt/sched_window_stats_policy" "0"
    
    write "/proc/sys/walt/walt_rtg_cfs_boost_prio" "99" #99=disabled
    # write "/proc/sys/walt/walt_low_latency_task_threshold" "0"

    # task
    # write "/proc/sys/walt/sched_task_unfilter_period" "20000000"
    write "/proc/sys/walt/sched_min_task_util_for_boost"  "51"
    write "/proc/sys/walt/sched_min_task_util_for_colocation"  "35"
    write "/proc/sys/walt/sched_downmigrate" "50 70"
    write "/proc/sys/walt/sched_upmigrate" "50 90"

    # Reduce the time to consider an idle
    write "/proc/sys/walt/sched_idle_enough" "10"

    # Extra battery-biased WALT policy. Keep this limited to generic scheduler
    # hints and avoid the more aggressive per-task boost knobs.
    write "/proc/sys/walt/sched_sync_hint_enable" "0"
    # On fuxi these two remain at 1 0 after a clean reflash, so treat them as
    # ineffective in this module context unless a device-specific method is
    # proven.
    # The same applies to sched_wake_up_idle, which stayed at 1 0 after test.
    # write "/proc/sys/walt/sched_wake_up_idle" "0 0"
    # write "/proc/sys/walt/sched_low_latency" "0 0"
    # write "/proc/sys/walt/sched_pipeline" "0 0"

    write /proc/sys/walt/sched_pipeline_special "0"
else

# Schedutil config based in this patch: 
# https://patchwork.kernel.org/project/linux-pm/patch/c6248ec9475117a1d6c9ff9aafa8894f6574a82f.1479359903.git.viresh.kumar@linaro.org/
    for i in /sys/devices/system/cpu/cpu*/cpufreq/schedutil/up_rate_limit_us ; do
        write $i "5000"
    done
    for i in /sys/devices/system/cpu/cpu*/cpufreq/schedutil/down_rate_limit_us ; do
        write $i "1000"
    done
fi

# Reassert the battery profile after vendor scheduler blocks so later generic
# rate-limit writes in this script do not undo the final CPU/GPU policy.
apply_cpu_energy_profile
apply_gpu_energy_profile

# Round Robin Timeslice
# write "/proc/sys/kernel/sched_rr_timeslice_ms" "4"

# Boost and up down rate limits
write "/sys/devices/system/cpu/cpufreq/boost" "0"
# lock_val_in_path "10000" "/sys/devices/system/cpu/cpufreq" "up_rate_limit_us"
# lock_val_in_path "10000" "/sys/devices/system/cpu/cpufreq" "down_rate_limit_us"

####################################
# CPUSETS & IRQ
####################################

# Cluster-derived cpuset and IRQ affinity tuning is intentionally disabled.
# CPU topology layouts vary too much across devices, and hard-coded cluster
# assumptions can exclude higher clusters on 4-cluster SoCs.
# /sys/devices/system/cpu/cpu*/cpuidle/state*/disable to 0
# /sys/module/lpm_levels/parameters/sleep_disabled
