#!/bin/sh
# LongOS 监控采集守护进程
# - 每 5 秒采样 WAN 速率写入历史（供面板趋势图）
# - 每 30 秒对每条线路做 IPv4 / IPv6 延迟与丢包探测
# 输出：/tmp/sr_hist.tsv（ts rx tx），/tmp/sr_line.json（按线路的探测结果）

. /lib/functions.sh

SR="srouter"
HIST="/tmp/sr_hist.tsv"
LINE_JSON="/tmp/sr_line.json"
PREV="/tmp/sr_mon_rates.prev"
NOW="/tmp/sr_mon_rates.now"
RATES="/tmp/sr_mon_rates.json"

[ -f "/etc/config/$SR" ] || exit 0

wan_ids() {
	uci -q show "$SR" 2>/dev/null | sed -n "s/^$SR\.\([^.=]*\)=wan$/\1/p"
}

l3_of() {
	local st dev
	st=$(ifstatus "$1" 2>/dev/null) || { printf '%s' "$1"; return; }
	dev=$(printf '%s' "$st" | jq -r '.l3_device // .device // ""' 2>/dev/null)
	[ -n "$dev" ] || dev="$1"
	printf '%s' "$dev"
}

sample_rates() {
	local now
	now=$(date +%s)
	awk 'NR>2 { gsub(":", "", $1); print $1, $2, $10 }' /proc/net/dev > "$NOW"
	if [ -s "$PREV" ]; then
		awk -v now="$now" '
			NR == FNR { if (FNR == 1) { pts = $1; next } prx[$1] = $2; ptx[$1] = $3; next }
			{
				if (!($1 in prx)) next
				dt = now - pts; if (dt < 1) dt = 1
				rx = ($2 - prx[$1]) * 8 / dt; tx = ($3 - ptx[$1]) * 8 / dt
				if (rx < 0 || rx > 1e11) rx = 0
				if (tx < 0 || tx > 1e11) tx = 0
				printf "%s %.0f %.0f\n", $1, rx, tx
			}' "$PREV" "$NOW" > "$RATES"
	else
		: > "$RATES"
	fi
	{ echo "$now"; cat "$NOW"; } > "$PREV"
}

append_hist() {
	local now="$1" total_rx=0 total_tx=0 id dev line rx tx
	for id in $(wan_ids); do
		dev=$(l3_of "$id")
		[ -n "$dev" ] || continue
		line=$(awk -v n="$dev" '$1 == n { print $2, $3; exit }' "$RATES" 2>/dev/null)
		[ -n "$line" ] || continue
		rx=$(echo "$line" | awk '{print $1}')
		tx=$(echo "$line" | awk '{print $2}')
		total_rx=$((total_rx + ${rx%.*}))
		total_tx=$((total_tx + ${tx%.*}))
	done
	echo "$now $total_rx $total_tx" >> "$HIST"
	# 只保留最近 360 条（30 分钟）
	if [ "$(wc -l < "$HIST")" -gt 360 ]; then
		tail -n 360 "$HIST" > "$HIST.tmp" && mv "$HIST.tmp" "$HIST"
	fi
}

probe_one() {
	local iface="$1" target="$2" out loss lat cmd
	[ -n "$iface" ] && [ -n "$target" ] || { printf '0 100'; return; }
	case "$target" in
		*:*) if command -v ping6 >/dev/null 2>&1; then cmd="ping6"; else cmd="ping -6"; fi ;;
		*) cmd="ping" ;;
	esac
	out=$($cmd -c 3 -W 2 -I "$iface" "$target" 2>/dev/null)
	loss=$(printf '%s' "$out" | sed -n 's/.*, \([0-9]*\)% packet loss.*/\1/p' | head -1)
	lat=$(printf '%s' "$out" | sed -n 's/.*= [0-9.]*\/\([0-9.]*\)\/.*/\1/p' | head -1)
	[ -n "$loss" ] || loss=100
	[ -n "$lat" ] || lat=0
	printf '%s %s' "$lat" "$loss"
}

probe_all() {
	local id name iface up mode v6 target4 target6 data lat4 loss4 lat6 loss6 tmp
	config_load "$SR"
	config_get target4 settings ping4 '223.5.5.5'
	config_get target6 settings ping6 '2400:3200::1'

	data='{}'
	for id in $(wan_ids); do
		config_get_bool up "$id" enabled 0
		config_get_bool v6 "$id" v6 1
		iface=$(l3_of "$id")
		if [ "$up" = 1 ] && [ -d "/sys/class/net/$iface" ] && \
		   [ "$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)" != "down" ]; then
			set -- $(probe_one "$iface" "$target4")
			lat4="$1"; loss4="$2"
			if [ "$v6" = 1 ]; then
				set -- $(probe_one "$iface" "$target6")
				lat6="$1"; loss6="$2"
			else
				lat6=0; loss6=100
			fi
		else
			lat4=0; loss4=100; lat6=0; loss6=100
		fi
		tmp=$(jq -cn --argjson up "$([ "$up" = 1 ] && echo true || echo false)" \
			--argjson lat4 "$(awk -v v="$lat4" 'BEGIN{printf "%.1f", v+0}')" \
			--argjson loss4 "$(awk -v v="$loss4" 'BEGIN{printf "%d", v+0}')" \
			--argjson lat6 "$(awk -v v="$lat6" 'BEGIN{printf "%.1f", v+0}')" \
			--argjson loss6 "$(awk -v v="$loss6" 'BEGIN{printf "%d", v+0}')" \
			'{up:$up,ipv4:{latency:$lat4,loss:$loss4},ipv6:{latency:$lat6,loss:$loss6}}')
		data=$(printf '%s' "$data" | jq -c --arg id "$id" --argjson v "$tmp" '. + {($id):$v}')
	done
	printf '%s' "$data" > "$LINE_JSON.tmp" && mv "$LINE_JSON.tmp" "$LINE_JSON"
}

tick=0
while true; do
	sample_rates
	append_hist "$(date +%s)"
	if [ $((tick % 6)) -eq 0 ]; then
		probe_all
	fi
	tick=$((tick + 1))

	local_int=""
	config_load "$SR"
	config_get local_int settings monitor_interval '5'
	case "$local_int" in ''|*[!0-9]*) local_int=5 ;; esac
	[ "$local_int" -ge 3 ] 2>/dev/null || local_int=5
	sleep "$local_int"
done
