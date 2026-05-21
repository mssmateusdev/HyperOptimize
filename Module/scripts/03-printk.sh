#!/system/bin/sh
MODDIR="${MODDIR:-${0%/*}/..}"
. "$MODDIR/scripts/lib.sh"

####################################
# Printk
####################################
write "/proc/sys/kernel/printk" "0 0 0 0"
write "/proc/sys/kernel/printk_delay" "0"
write "/proc/sys/kernel/printk_devkmsg" "off"
write "/proc/sys/kernel/printk_ratelimit" "5" # seconds
write "/proc/sys/kernel/printk_ratelimit_burst" "1" # message count
write "/proc/sys/kernel/tracepoint_printk" "0"
write "/sys/module/printk/parameters/always_kmsg_dump" "N"
write "/sys/module/printk/parameters/console_no_auto_verbose" "Y"
write "/sys/module/printk/parameters/time" "0"
write "/sys/module/printk/parameters/console_suspend" "1"
write "/sys/module/printk/parameters/ignore_loglevel" "0"

# Stop kernel tracing paths when debugfs/tracingfs is mounted. These writes are
# normal runtime knobs and do not mask files from external kernel managers.
write "/sys/kernel/debug/tracing/tracing_on" "0"
write "/sys/kernel/tracing/tracing_on" "0"
write "/sys/kernel/debug/tracing/events/enable" "0"
write "/sys/kernel/tracing/events/enable" "0"
write_if_writable "/proc/sys/kernel/sched_schedstats" "0"
write_if_writable "/proc/sys/kernel/ftrace_enabled" "0"
