#!/bin/sh
# Export the K230_DATA partition through the mass-storage LUN.
# The partition must never be mounted on the board while it is exported.

GADGET=/sys/kernel/config/usb_gadget/k230usb
LUN=$GADGET/functions/mass_storage.data/lun.0/file
STATE=/run/ums-data-exported

data_dev()
{
    for dev in /dev/mmcblk*p3; do
        [ -b "$dev" ] || continue
        case "$(blkid "$dev" 2>/dev/null)" in
            *'LABEL="K230_DATA"'*)
                echo "$dev"
                return 0
                ;;
        esac
    done

    rootdev=$(sed -n \
        's#.*root=\(/dev/mmcblk[0-9][0-9]*\)p[0-9][^ ]*.*#\1#p' \
        /proc/cmdline)
    if [ -n "$rootdev" ] && [ -b "${rootdev}p3" ]; then
        echo "${rootdev}p3"
        return 0
    fi

    # Keep UMS usable even when the kernel command line uses PARTUUID.
    for dev in /dev/mmcblk*p3; do
        [ -b "$dev" ] || continue
        echo "$dev"
        return 0
    done
    return 1
}

data_mounted()
{
    grep -q '[[:space:]]/data[[:space:]]' /proc/mounts
}

mount_data()
{
    dev=$(data_dev)
    [ -b "$dev" ] || {
        echo "ums: data partition not found"
        return 1
    }

    mkdir -p /data
    data_mounted && return 0
    mount -t vfat -o iocharset=utf8,shortname=mixed "$dev" /data
}

unmount_data()
{
    data_mounted || return 0
    sync
    umount /data
}

export_data()
{
    dev=$(data_dev)
    [ -b "$dev" ] || {
        echo "ums: data partition not found"
        return 1
    }
    [ -e "$LUN" ] || {
        echo "ums: mass-storage function is not configured"
        return 1
    }

    echo "ums: exporting $dev to $LUN" >&2
    media=$(cat "$LUN" 2>/dev/null)
    [ -z "$media" ] || [ "$media" = "$dev" ] || {
        echo "ums: LUN already contains $media"
        return 1
    }

    unmount_data || {
        echo "ums: /data is busy"
        return 1
    }
    sync

    echo "$dev" > "$LUN" || {
        echo "ums: failed to insert $dev"
        mount_data
        return 1
    }
    media=$(cat "$LUN" 2>/dev/null)
    [ "$media" = "$dev" ] || {
        echo "ums: LUN verification failed"
        mount_data
        return 1
    }

    mkdir -p /run
    : > "$STATE"
    echo "ums: exported $dev"
}

unexport_data()
{
    [ -e "$LUN" ] || {
        mount_data
        return $?
    }

    sync
    echo "" > "$LUN" || {
        echo "ums: failed to eject media"
        return 1
    }
    sleep 1
    rm -f "$STATE"
    mount_data
}

case "$1" in
  start)
    export_data
    ;;
  stop)
    unexport_data
    ;;
  status)
    echo "media: $(cat "$LUN" 2>/dev/null || echo none)"
    echo "gadget: UDC=$(cat "$GADGET/UDC" 2>/dev/null)"
    if data_mounted; then
        echo "data: mounted"
    else
        echo "data: exported or unmounted"
    fi
    ;;
  *)
    echo "Usage: ums.sh start|stop|status" >&2
    exit 3
    ;;
esac
