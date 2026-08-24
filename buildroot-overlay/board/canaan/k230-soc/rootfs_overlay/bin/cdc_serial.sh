#!/bin/sh
# Configure the single USB gadget used by the board:
#   CDC ACM serial + RNDIS network + removable mass storage.

GADGET=/sys/kernel/config/usb_gadget/k230usb
CFG=$GADGET/configs/c.1
STR=$GADGET/strings/0x409
RNDIS=$GADGET/functions/rndis.usb0
ACM=$GADGET/functions/acm.GS0
MS=$GADGET/functions/mass_storage.data
LUN=$MS/lun.0
PIDFILE=/var/run/udhcpd-usb.pid
LEASES=/var/lib/misc/udhcpd.leases
USB_IP=10.0.10.1
USB_MASK=255.255.255.0
LOCK=/run/cdc_serial.lock
STATE=/run/ums-data-exported
EXPORT_PIDFILE=/run/cdc_serial.export.pid
NET_PIDFILE=/run/cdc_serial.net.pid

log()
{
    echo "cdc_serial: $*"
}

write_attr()
{
    printf '%s\n' "$1" > "$2" || {
        log "cannot write $2"
        return 1
    }
}

mount_configfs()
{
    [ -d /sys/kernel/config ] || mkdir -p /sys/kernel/config
    if ! grep -q '[[:space:]]/sys/kernel/config[[:space:]]' /proc/mounts; then
        mount -t configfs none /sys/kernel/config || return 1
    fi
    [ -d /sys/kernel/config/usb_gadget ] || return 1
}

other_gadget_active()
{
    for gadget in /sys/kernel/config/usb_gadget/*; do
        [ -d "$gadget" ] || continue
        [ "$gadget" = "$GADGET" ] && continue
        [ -n "$(cat "$gadget/UDC" 2>/dev/null)" ] && return 0
    done
    return 1
}

pick_udc()
{
    for udc in /sys/class/udc/*; do
        [ -e "$udc" ] || continue
        echo "${udc##*/}"
        return 0
    done
    return 1
}

wait_for_udc()
{
    i=0
    while [ "$i" -lt 80 ]; do
        udc=$(pick_udc)
        [ -n "$udc" ] && {
            echo "$udc"
            return 0
        }
        sleep 0.25
        i=$((i + 1))
    done
    return 1
}

stop_dhcp()
{
    pid=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    rm -f "$PIDFILE"
}

kill_pidfile()
{
    pid=$(cat "$1" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    rm -f "$1"
}

refresh_sshd()
{
    [ -x /usr/sbin/sshd ] || return 0
    [ -x /etc/init.d/S50sshd ] || return 0

    mkdir -p /run
    /usr/bin/ssh-keygen -A >/tmp/sshd-usb.err 2>&1 || {
        log "ssh host key generation failed; see /tmp/sshd-usb.err"
        return 1
    }
    /usr/sbin/sshd -t -f /etc/ssh/sshd_config >>/tmp/sshd-usb.err 2>&1 || {
        log "sshd config check failed; see /tmp/sshd-usb.err"
        return 1
    }
    /etc/init.d/S50sshd restart >>/tmp/sshd-usb.err 2>&1 || {
        log "sshd restart failed; see /tmp/sshd-usb.err"
        return 1
    }
}

disable_usb_offload()
{
    command -v ethtool >/dev/null 2>&1 || return 0

    # RNDIS hosts can reject packets whose checksum/segmentation offload
    # metadata is not handled consistently on both sides of the link.
    ethtool -K usb0 rx off tx off 2>/dev/null || :
    ethtool -K usb0 sg off tso off gso off gro off 2>/dev/null || :
}

net_up()
{
    trap 'rm -f "$NET_PIDFILE"' EXIT
    i=0
    while [ "$i" -lt 80 ]; do
        ifconfig usb0 >/dev/null 2>&1 && break
        sleep 0.25
        i=$((i + 1))
    done

    if ! ifconfig usb0 "$USB_IP" netmask "$USB_MASK" up; then
        log "usb0 did not appear; gadget remains available"
        return 0
    fi

    disable_usb_offload
    refresh_sshd || :
    mkdir -p /var/lib/misc /var/run
    : > "$LEASES" 2>/dev/null
    stop_dhcp
    if command -v udhcpd >/dev/null 2>&1; then
        udhcpd /etc/udhcpd-usb.conf >/dev/null 2>&1
        log "usb0 is $USB_IP"
    else
        log "udhcpd is missing; usb0 stays static at $USB_IP"
    fi
}

unbind_gadget()
{
    [ -e "$GADGET/UDC" ] || return 0
    [ -z "$(cat "$GADGET/UDC" 2>/dev/null)" ] && return 0
    echo "" > "$GADGET/UDC" 2>/dev/null
    sleep 1
}

destroy_gadget()
{
    unbind_gadget
    rm -rf "$GADGET"
}

create_gadget()
{
    mkdir -p \
        "$GADGET" \
        "$STR" \
        "$CFG/strings/0x409" \
        "$RNDIS" \
        "$ACM" \
        "$MS" || return 1

    write_attr 0x0525 "$GADGET/idVendor" || return 1
    write_attr 0xa4a8 "$GADGET/idProduct" || return 1
    write_attr 0x0200 "$GADGET/bcdUSB" || return 1
    write_attr 0x0100 "$GADGET/bcdDevice" || return 1
    write_attr 0xef "$GADGET/bDeviceClass" || return 1
    write_attr 0x02 "$GADGET/bDeviceSubClass" || return 1
    write_attr 0x01 "$GADGET/bDeviceProtocol" || return 1

    write_attr K230LABPLUS1956 "$STR/serialnumber" || return 1
    write_attr Canaan "$STR/manufacturer" || return 1
    write_attr "K230 USB composite" "$STR/product" || return 1
    write_attr "ACM + RNDIS + UMS" \
        "$CFG/strings/0x409/configuration" || return 1
    write_attr 0x80 "$CFG/bmAttributes" || return 1
    write_attr 250 "$CFG/MaxPower" || return 1

    write_attr usb%d "$RNDIS/ifname" || return 1
    write_attr 02:11:22:33:44:10 "$RNDIS/dev_addr" || return 1
    write_attr 02:11:22:33:44:11 "$RNDIS/host_addr" || return 1
    write_attr 5 "$RNDIS/qmult" || return 1
    mkdir -p "$RNDIS/os_desc/interface.rndis" || return 1
    write_attr RNDIS \
        "$RNDIS/os_desc/interface.rndis/compatible_id" || return 1
    write_attr 5162001 \
        "$RNDIS/os_desc/interface.rndis/sub_compatible_id" || return 1

    write_attr 1 "$MS/stall" || return 1
    write_attr 1 "$LUN/removable" || return 1
    write_attr 0 "$LUN/cdrom" || return 1
    write_attr 0 "$LUN/ro" || return 1

    write_attr 1 "$GADGET/os_desc/use" || return 1
    write_attr 0xcd "$GADGET/os_desc/b_vendor_code" || return 1
    write_attr MSFT100 "$GADGET/os_desc/qw_sign" || return 1
    # ConfigFS resolves symlink targets from the process working directory.
    # Use absolute targets because this script is launched by init with an
    # unspecified working directory.
    ln -s "$CFG" "$GADGET/os_desc/c.1" || {
        log "cannot link $CFG into $GADGET/os_desc"
        return 1
    }
    ln -s "$RNDIS" "$CFG/rndis.usb0" || {
        log "cannot link $RNDIS into $CFG"
        return 1
    }
    ln -s "$ACM" "$CFG/acm.GS0" || {
        log "cannot link $ACM into $CFG"
        return 1
    }
    ln -s "$MS" "$CFG/mass_storage.data" || {
        log "cannot link $MS into $CFG"
        return 1
    }
}

export_data_later()
{
    trap 'rm -f "$EXPORT_PIDFILE"' EXIT
    i=0
    while [ "$i" -lt 30 ]; do
        if /bin/ums.sh start >/dev/null 2>&1; then
            log "data partition exported as mass storage"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    log "data partition is not ready; ACM/RNDIS remain enabled"
}

safe_unexport_data()
{
    [ -e "$LUN" ] || {
        rm -f "$STATE"
        return 0
    }

    media=$(cat "$LUN" 2>/dev/null)
    [ -n "$media" ] || {
        rm -f "$STATE"
        return 0
    }

    sync
    echo "" > "$LUN" 2>/dev/null || return 1
    sleep 1
    rm -f "$STATE"
}

current_gadget_active()
{
    [ -d "$GADGET" ] || return 1
    [ -n "$(cat "$GADGET/UDC" 2>/dev/null)" ]
}

start_gadget()
{
    current_gadget_active && {
        log "gadget already active"
        return 0
    }

    other_gadget_active && {
        log "another USB gadget is already active"
        return 1
    }

    mount_configfs || {
        log "configfs is unavailable"
        return 1
    }

    udc=$(wait_for_udc) || {
        log "no USB device controller found"
        return 1
    }

    destroy_gadget
    create_gadget || {
        log "failed to create gadget"
        destroy_gadget
        return 1
    }

    # A missing or temporarily busy data partition must not block enumeration.
    /bin/ums.sh start >/dev/null 2>&1 || :

    write_attr "$udc" "$GADGET/UDC" || {
        log "failed to bind $udc"
        destroy_gadget
        return 1
    }
    log "bound $udc"

    export_data_later &
    echo $! > "$EXPORT_PIDFILE"
    net_up &
    echo $! > "$NET_PIDFILE"
    return 0
}

stop_gadget()
{
    kill_pidfile "$EXPORT_PIDFILE"
    kill_pidfile "$NET_PIDFILE"
    sleep 1
    stop_dhcp
    safe_unexport_data >/dev/null 2>&1 || :
    unbind_gadget
    rm -rf "$GADGET"
}

acquire_lock()
{
    while ! mkdir "$LOCK" 2>/dev/null; do
        pid=$(cat "$LOCK/pid" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        rm -rf "$LOCK" 2>/dev/null
        sleep 0.1
    done
    echo $$ > "$LOCK/pid"
    trap 'rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM
}

case "$1" in
  start)
    acquire_lock || exit 0
    start_gadget
    ret=$?
    exit "$ret"
    ;;
  stop)
    stop_gadget
    ;;
  restart|reload|force-reload)
    stop_gadget
    "$0" start
    ;;
  *)
    echo "Usage: cdc_serial.sh start|stop" >&2
    exit 3
    ;;
esac
