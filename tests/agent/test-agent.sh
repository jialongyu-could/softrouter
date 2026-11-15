#!/bin/sh
# LongOS 远程 Agent 设备联调测试（只读为主，会临时创建/恢复改密标记）
# 用法：sh tests/agent/test-agent.sh
# 依赖：jq、ubus、/usr/lib/longos/lo.sh、/usr/sbin/longos-agent
# 必须在设备上以 root 运行；退出码 0=全部通过

set -u

pass=0
fail=0
ck() {
	if printf '%s' "$3" | grep -q -- "$2"; then
		pass=$((pass + 1)); printf '  ok   %s\n' "$1"
	else
		fail=$((fail + 1)); printf '  FAIL %s\n       期望包含: %s\n       实际输出: %s\n' "$1" "$2" "$3"
	fi
}

[ "$(id -u)" = "0" ] || { echo "SKIP: 需要 root"; exit 2; }
AV=$(command -v jq) || { echo "SKIP: 需要 jq"; exit 2; }
unset AV
[ -x /usr/sbin/longos-agent ] || { echo "SKIP: 未安装 longos-agent"; exit 2; }
command -v ubus >/dev/null 2>&1 || { echo "SKIP: 需要 ubus"; exit 2; }

echo "== Agent 状态与参数校验 =="
out=$(/usr/sbin/longos-agent state)
ck "state 返回合法 JSON" '"ok":true' "$out"
ck "state 含绑定状态字段" '"bound":' "$out"
printf '%s' "$out" | jq -e . >/dev/null 2>&1 && { pass=$((pass + 1)); echo "  ok   state 可被 jq 解析"; } || { fail=$((fail + 1)); echo "  FAIL state 不是合法 JSON"; }

out=$(/usr/sbin/longos-agent bad-arg)
ck "未知子命令返回错误" '"ok":false' "$out"

out=$(/usr/bin/env sh -c 'uci -q get longos-agent.agent.server')
ck "默认服务器地址为 https" 'https://' "$out"

echo "== 面板命令 =="
out=$(/usr/lib/longos/lo.sh agent_users)
ck "agent_users 返回 JSON" '"users"' "$out"

out=$(/usr/lib/longos/lo.sh agent_state)
ck "agent_state 返回 JSON" '"bound"' "$out"

out=$(/usr/lib/longos/lo.sh agent_bind '{}')
if [ -s /etc/longos/pwchange ]; then
	ck "未改默认密码时面板命令被锁定" '"must_change":true' "$out"
else
	ck "缺少密钥时拒绝绑定" '请输入绑定密钥' "$out"
fi

echo "== 默认密码锁定（临时标记，自动恢复）=="
FLAG=/etc/longos/pwchange
BAK=""
if [ -f "$FLAG" ]; then
	echo "  跳过：当前正在等待改密，不覆盖标记"
else
	out=$(/usr/lib/longos/lo.sh overview)
	ck "无标记时面板正常" '"ok":true' "$out"
	printf 'testuser\n' > "$FLAG"
	out=$(/usr/lib/longos/lo.sh overview)
	ck "有标记时面板命令被拒绝" '"must_change":true' "$out"
	rm -f "$FLAG"
	out=$(/usr/lib/longos/lo.sh overview)
	ck "标记清除后面板恢复" '"ok":true' "$out"
fi

echo "== 权限模型 =="
PERM=/etc/longos/perm.json
[ -f "$PERM" ] && cp -f "$PERM" /tmp/lo-perm.bak
printf '{"remote":false,"status":false,"reboot":true,"multidial":false,"ipv6":false,"users":false,"upgrade":false}\n' > "$PERM"
chmod 600 "$PERM"

out=$(/usr/sbin/longos-agent perm status)
ck "未授权模块拒绝执行" '"ok":false' "$out"
out=$(/usr/sbin/longos-agent perm reboot)
ck "已授权模块允许执行" '"ok":true' "$out"
out=$(/usr/sbin/longos-agent perm multidial_set)
ck "多拨模块按权限拒绝" '"module":"multidial"' "$out"

rm -f "$PERM"
[ -f /tmp/lo-perm.bak ] && mv -f /tmp/lo-perm.bak "$PERM" && rm -f /tmp/lo-perm.bak
out=$(/usr/sbin/longos-agent perm status)
ck "无权限文件时默认放行" '"ok":true' "$out"

printf '\n通过 %s，失败 %s\n' "$pass" "$fail"
[ "$fail" = "0" ] || exit 1
exit 0
