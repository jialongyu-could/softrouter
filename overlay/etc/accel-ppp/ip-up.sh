#!/bin/sh
# accel-ppp 会话上线钩子：登记在线会话并按账号下发限速
# 参数：1=ifname 4=服务端 IPv4 5=客户端 IPv4
# 环境变量：PEERNAME 用户名，IPV6_PREFIX 客户端 IPv6 前缀，IPV6_DELEGATED_PREFIX 委派前缀
IFACE="${1:-$PPP_IFACE}"
PEER="${PEERNAME:-$USER}"
IP4="${4:-$IP4}"
IP6="${IPV6_PREFIX:-}"
[ -n "$IFACE" ] || exit 0

mkdir -p /tmp/lo_ppp
echo "${PEER}|${IFACE}|${IP4:-0.0.0.0}|${5:-$IP4}|$(date +%s)|${IP6}" > "/tmp/lo_ppp/$IFACE"
# 委派前缀单独留档，供面板展示 DHCPv6-PD 分配结果
if [ -n "$IPV6_DELEGATED_PREFIX" ]; then
	echo "${IPV6_DELEGATED_PREFIX}" > "/tmp/lo_ppp/$IFACE.pd"
fi

[ -f /etc/longos/limits ] || exit 0
LINE=$(awk -v u="$PEER" '$1 == u { print $2, $3; exit }' /etc/longos/limits)
[ -n "$LINE" ] || exit 0
DOWN=$(echo "$LINE" | awk '{print $1}')
UP=$(echo "$LINE" | awk '{print $2}')

# 出口方向（服务端 -> 客户端，即用户下载）
if [ "$(printf '%s' "$DOWN" | tr -dc '0-9')" != "" ] && [ "$DOWN" -gt 0 ] 2>/dev/null; then
	tc qdisc replace dev "$IFACE" root cake bandwidth "${DOWN}kbit" nat dual-ack 2>/dev/null || \
		tc qdisc replace dev "$IFACE" root tbf rate "${DOWN}kbit" burst 64k latency 50ms 2>/dev/null
fi

# 入口方向（客户端 -> 服务端，即用户上传）
if [ "$(printf '%s' "$UP" | tr -dc '0-9')" != "" ] && [ "$UP" -gt 0 ] 2>/dev/null; then
	tc qdisc add dev "$IFACE" handle ffff: ingress 2>/dev/null
	tc filter add dev "$IFACE" parent ffff: protocol all prio 1 u32 match u32 0 0 \
		police rate "${UP}kbit" burst 64k drop flowid :1 2>/dev/null
fi

exit 0
