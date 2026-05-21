#!/system/bin/sh
MODDIR="${MODDIR:-${0%/*}/..}"
. "$MODDIR/scripts/lib.sh"

####################################
# VM Tunables
####################################

get_memtotal_mb() {
    awk '/MemTotal:/ { print int($2 / 1024); exit }' /proc/meminfo 2>/dev/null
}

get_swaptotal_mb() {
    awk '/SwapTotal:/ { print int($2 / 1024); exit }' /proc/meminfo 2>/dev/null
}

apply_adaptive_vm_tunables() {
    local mem_mb swap_mb has_swap
    local stat_interval swappiness page_cluster vfs_cache_pressure
    local dirty_ratio dirty_background_ratio dirty_expire dirty_writeback

    mem_mb="$(get_memtotal_mb)"
    swap_mb="$(get_swaptotal_mb)"
    [ -n "$mem_mb" ] || mem_mb=0
    [ -n "$swap_mb" ] || swap_mb=0

    if [ "$swap_mb" -gt 0 ]; then
        has_swap=1
    else
        has_swap=0
    fi

    case "$mem_mb" in
        0)
            stat_interval=60
            swappiness=40
            page_cluster=1
            vfs_cache_pressure=100
            dirty_ratio=12
            dirty_background_ratio=5
            dirty_expire=2000
            dirty_writeback=3000
            ;;
        *)
            if [ "$mem_mb" -le 4096 ]; then
                stat_interval=30
                page_cluster=0
                vfs_cache_pressure=120
                dirty_ratio=8
                dirty_background_ratio=3
                dirty_expire=1000
                dirty_writeback=2000
                [ "$has_swap" = "1" ] && swappiness=70 || swappiness=35
            elif [ "$mem_mb" -le 6144 ]; then
                stat_interval=45
                page_cluster=0
                vfs_cache_pressure=110
                dirty_ratio=10
                dirty_background_ratio=4
                dirty_expire=1500
                dirty_writeback=2500
                [ "$has_swap" = "1" ] && swappiness=60 || swappiness=30
            elif [ "$mem_mb" -le 8192 ]; then
                stat_interval=60
                page_cluster=1
                vfs_cache_pressure=100
                dirty_ratio=12
                dirty_background_ratio=5
                dirty_expire=2000
                dirty_writeback=3000
                [ "$has_swap" = "1" ] && swappiness=50 || swappiness=25
            elif [ "$mem_mb" -le 12288 ]; then
                stat_interval=60
                page_cluster=2
                vfs_cache_pressure=90
                dirty_ratio=14
                dirty_background_ratio=6
                dirty_expire=2000
                dirty_writeback=3000
                [ "$has_swap" = "1" ] && swappiness=40 || swappiness=20
            else
                stat_interval=60
                page_cluster=3
                vfs_cache_pressure=80
                dirty_ratio=16
                dirty_background_ratio=8
                dirty_expire=3000
                dirty_writeback=5000
                [ "$has_swap" = "1" ] && swappiness=30 || swappiness=15
            fi
            ;;
    esac

    write "/proc/sys/vm/stat_interval" "$stat_interval"
    write "/proc/sys/vm/swappiness" "$swappiness"
    write "/proc/sys/vm/page-cluster" "$page_cluster"
    write "/proc/sys/vm/vfs_cache_pressure" "$vfs_cache_pressure"
    write "/proc/sys/vm/dirty_ratio" "$dirty_ratio"
    write "/proc/sys/vm/dirty_background_ratio" "$dirty_background_ratio"
    write "/proc/sys/vm/dirty_expire_centisecs" "$dirty_expire"
    write "/proc/sys/vm/dirty_writeback_centisecs" "$dirty_writeback"
    write "/proc/sys/vm/dirtytime_expire_seconds" "43200"
}

configure_2gb_zram() {
    local zram dev size alg streams

    zram="/sys/block/zram0"
    dev="/dev/block/zram0"
    size="2147483648"
    streams="2"

    [ -d "$zram" ] || return 0

    # Keep zRAM small and predictable for battery-focused profiles. This avoids
    # pushing memory pressure into UFS while staying light enough for 2GB zRAM.
    swapoff "$dev" >/dev/null 2>&1
    write "$zram/reset" "1"

    if [ -f "$zram/comp_algorithm" ]; then
        if grep -qw "lz4" "$zram/comp_algorithm" 2>/dev/null; then
            alg="lz4"
        elif grep -qw "lzo-rle" "$zram/comp_algorithm" 2>/dev/null; then
            alg="lzo-rle"
        elif grep -qw "zstd" "$zram/comp_algorithm" 2>/dev/null; then
            alg="zstd"
        else
            alg=""
        fi
        [ -n "$alg" ] && write "$zram/comp_algorithm" "$alg"
    fi

    write_if_writable "$zram/max_comp_streams" "$streams"
    write "$zram/disksize" "$size"

    # Disable zRAM writeback where exposed; writing cold compressed pages to
    # flash saves RAM but costs wakeups and UFS I/O, which is bad for battery.
    write_if_writable "$zram/writeback_limit_enable" "0"
    write_if_writable "$zram/writeback_limit" "0"

    if command -v mkswap >/dev/null 2>&1 && [ -e "$dev" ]; then
        mkswap "$dev" >/dev/null 2>&1
        swapon -p 32767 "$dev" >/dev/null 2>&1
    fi
}

# Scale VM policy by RAM size and swap/zram availability instead of forcing
# one set of ratios on every device.
apply_adaptive_vm_tunables

# Poco X7 Pro / HyperOS battery profile: assume 2GB zRAM and prefer compressed
# RAM over flash churn, while keeping dirty pages small enough to avoid bursts.
configure_2gb_zram
write "/proc/sys/vm/swappiness" "55"
write "/proc/sys/vm/vfs_cache_pressure" "90"
write "/proc/sys/vm/page-cluster" "0"
write "/proc/sys/vm/dirty_ratio" "8"
write "/proc/sys/vm/dirty_background_ratio" "3"
write "/proc/sys/vm/dirty_expire_centisecs" "1000"
write "/proc/sys/vm/dirty_writeback_centisecs" "3000"
write "/proc/sys/vm/dirtytime_expire_seconds" "43200"
write_if_writable "/proc/sys/vm/compact_unevictable_allowed" "0"
write_if_writable "/proc/sys/vm/watermark_boost_factor" "0"
write_if_writable "/proc/sys/vm/watermark_scale_factor" "125"

write "/sys/kernel/mm/lru_gen/enabled" "7"
# lock_val "1000" "/sys/kernel/mm/lru_gen/min_ttl_ms"
