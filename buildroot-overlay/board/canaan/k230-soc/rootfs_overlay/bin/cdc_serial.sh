#!/bin/sh
# USB Gadget CDC ACM 虚拟串口, 使用 usb0(OTG) 口, 生成 /dev/ttyGS0
# PC 端识别: Linux 为 /dev/ttyACM0; Windows 10+ 自动加载 usbser 驱动
# 注意: 与 adb.sh 的 gadget 不能同时绑定同一 UDC, 本脚本使用独立的 gadget 目录 cdc

GADGET=/sys/kernel/config/usb_gadget/cdc

case "$1" in
  start)
    modprobe libcomposite 2>/dev/null
    modprobe usb_f_acm 2>/dev/null

    test -d /sys/kernel/config || mkdir /sys/kernel/config
    mount -t configfs none /sys/kernel/config 2>/dev/null

    if [ -d $GADGET ]; then
        echo "cdc serial gadget already exists"
        exit 0
    fi

    mkdir $GADGET
    cd $GADGET

    echo 0x0525 > idVendor
    echo 0xa4a7 > idProduct

    mkdir strings/0x409
    echo "0123456789ABCDEF" > strings/0x409/serialnumber
    echo "canaan"            > strings/0x409/manufacturer
    echo "k230 cdc serial"  > strings/0x409/product

    mkdir configs/b.1
    mkdir configs/b.1/strings/0x409
    echo "cdc_serial" > configs/b.1/strings/0x409/configuration

    mkdir functions/acm.GS0
    ln -s functions/acm.GS0 configs/b.1/acm.GS0

    cd /
    UDC=$(ls /sys/class/udc/ | awk 'NR==1 {print $1}')
    if [ -n "$UDC" ]; then
        echo $UDC > $GADGET/UDC
        echo "cdc serial: bind $UDC -> /dev/ttyGS0"
    else
        echo "cdc serial: no UDC found"
    fi
    ;;
  stop)
    echo none > $GADGET/UDC 2>/dev/null
    ;;
  restart|reload|force-reload)
    $0 stop
    $0 start
    ;;
  *)
    echo "Usage: cdc_serial.sh start|stop" >&2
    exit 3
    ;;
esac
