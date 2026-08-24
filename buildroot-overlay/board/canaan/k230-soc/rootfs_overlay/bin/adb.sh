#!/bin/sh
# The board has one USB device controller and reserves it for the composite
# ACM/RNDIS/mass-storage gadget. An independent ADB gadget would steal UDC.

case "$1" in
  start)
    echo "adb: disabled; USB UDC is reserved for ACM/RNDIS/UMS" >&2
    exit 1
    ;;
  stop)
    exit 0
    ;;
  *)
    echo "Usage: adb.sh start|stop" >&2
    exit 3
    ;;
esac
