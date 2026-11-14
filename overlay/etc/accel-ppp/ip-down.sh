#!/bin/sh
# accel-ppp 会话下线钩子：清理在线记录与限速
IFACE="${1:-$PPP_IFACE}"
[ -n "$IFACE" ] || exit 0
rm -f "/tmp/sr_ppp/$IFACE"
tc qdisc del dev "$IFACE" root 2>/dev/null
tc qdisc del dev "$IFACE" ingress 2>/dev/null
exit 0
