#!/bin/sh
# LongOS 账号安全测试
#   单元测试（默认）：不修改任何系统密码，用测试钩子模拟 ubus/chpasswd
#   设备联调（--device）：在真实路由器上检查 state/validate/verify 链路（不会改密码）
#
# 用法：
#   sh tests/auth/test-lo-auth.sh
#   sh tests/auth/test-lo-auth.sh --device
# 依赖：jq（验证 JSON）；设备模式还需要 ubus
# 退出码：0 全部通过，1 存在失败，2 环境缺失

set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
LIB="$SELF_DIR/../../overlay/usr/lib/longos/lo-auth.sh"
DEVICE=0
[ "${1:-}" = "--device" ] && DEVICE=1

if ! command -v jq >/dev/null 2>&1; then
	echo "SKIP: 未安装 jq，无法解析 JSON 输出"
	exit 2
fi
[ -f "$LIB" ] || { echo "SKIP: 找不到 $LIB"; exit 2; }
LIB=$(cd "$(dirname "$LIB")" && pwd)/$(basename "$LIB")

pass=0
fail=0
ck() {
	# $1 用例名  $2 期望包含的子串  $3 实际输出
	if printf '%s' "$3" | grep -q -- "$2"; then
		pass=$((pass + 1))
		printf '  ok   %s\n' "$1"
	else
		fail=$((fail + 1))
		printf '  FAIL %s\n       期望包含: %s\n       实际输出: %s\n' "$1" "$2" "$3"
	fi
}

if [ "$DEVICE" = "1" ]; then
	echo "== 设备联调测试（只读，不修改密码）=="
	[ "$(id -u)" = "0" ] || { echo "SKIP: 需要 root"; exit 2; }
	command -v ubus >/dev/null 2>&1 || { echo "SKIP: 需要 ubus"; exit 2; }

	out=$(sh "$LIB" state)
	ck "state 返回合法 JSON" '"ok":true' "$out"

	out=$(sh "$LIB" validate 'Abcdefgh12')
	ck "validate 合规密码通过" '"ok":true' "$out"

	out=$(sh "$LIB" validate 'abc')
	ck "validate 短密码拒绝" '"code":"too_short"' "$out"

	out=$(sh "$LIB" verify longos 'definitely-wrong-password')
	ck "verify 错误旧密码拒绝" '"ok":false' "$out"

	printf '\n通过 %s，失败 %s\n' "$pass" "$fail"
	[ "$fail" = "0" ] || exit 1
	exit 0
fi

echo "== 单元测试（测试钩子模拟，不触碰系统密码）=="

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FLAG="$WORK/pwchange"
LOG="$WORK/chpasswd.log"

export LO_TEST=1
export LO_STATE_FILE="$FLAG"
export LO_TEST_OLD='longos'
export LO_TEST_CHPASSWD="$LOG"

reset_flag() { printf 'longos\n' > "$FLAG"; }

# ---- 密码复杂度 ----
out=$(sh "$LIB" validate 'Abcd1234')
ck "9 位（边界下）拒绝" '"code":"too_short"' "$out"

out=$(sh "$LIB" validate 'Abcd12345!')
ck "10 位 + 4 类通过" '"ok":true' "$out"

out=$(sh "$LIB" validate 'Abcdefgh12')
ck "10 位 + 3 类通过" '"ok":true' "$out"

out=$(sh "$LIB" validate 'Abcdefghij')
ck "仅大小写（2 类）拒绝" '"code":"weak"' "$out"

out=$(sh "$LIB" validate 'abcdefghij')
ck "纯小写拒绝" '"code":"weak"' "$out"

out=$(sh "$LIB" validate 'Abcdefgh 12')
ck "含空格拒绝" '"code":"whitespace"' "$out"

out=$(sh "$LIB" validate 'Longos12345!')
ck "含账号名拒绝" '"code":"contains_user"' "$out"

out=$(sh "$LIB" validate '')
ck "空密码拒绝" '"code":"empty"' "$out"

out=$(sh "$LIB" validate 'Abcdefgh1!Abcdefgh1!Abcdefgh1!Abcdefgh1!Abcdefgh1!Abcdefgh1!Abcd')
ck "64 位（边界上）通过" '"ok":true' "$out"

out=$(sh "$LIB" validate 'Abcdefgh1!Abcdefgh1!Abcdefgh1!Abcdefgh1!Abcdefgh1!Abcdefgh1!Abcde')
ck "65 位拒绝" '"code":"too_long"' "$out"

# ---- 状态查询 ----
reset_flag
out=$(sh "$LIB" state)
ck "存在标记时 must_change=true" '"must_change":true' "$out"
ck "状态包含待改密账号" '"users":\["longos"\]' "$out"

# ---- 修改密码 ----
reset_flag
out=$(sh "$LIB" change '{"user":"longos","old":"longos","new":"NewPass123!","confirm":"NewPass123!"}')
ck "旧密码正确时修改成功" '"ok":true' "$out"
ck "成功后要求重新登录" '"relogin":true' "$out"
[ -f "$FLAG" ] && { fail=$((fail + 1)); echo "  FAIL 成功后标记未清除"; } || { pass=$((pass + 1)); echo "  ok   成功后标记已清除"; }
ck "密码已写入系统" 'longos:NewPass123!' "$(cat "$LOG" 2>/dev/null)"

out=$(sh "$LIB" state)
ck "改密后 must_change=false" '"must_change":false' "$out"

reset_flag
out=$(sh "$LIB" change '{"user":"longos","old":"wrong","new":"NewPass123!","confirm":"NewPass123!"}')
ck "旧密码错误拒绝" '"code":"bad_old"' "$out"

reset_flag
out=$(sh "$LIB" change '{"user":"longos","old":"longos","new":"NewPass123!","confirm":"NewPass124!"}')
ck "两次新密码不一致拒绝" '"code":"mismatch"' "$out"

reset_flag
out=$(sh "$LIB" change '{"user":"longos","old":"longos","new":"longos","confirm":"longos"}')
ck "新旧密码相同拒绝" '"code":"same"' "$out"

reset_flag
out=$(sh "$LIB" change '{"user":"longos","old":"longos","new":"abc123","confirm":"abc123"}')
ck "弱密码拒绝" '"code":"too_short"' "$out"

reset_flag
out=$(sh "$LIB" change '{"user":"root","old":"longos","new":"NewPass123!","confirm":"NewPass123!"}')
ck "非待改密账号拒绝" '"code":"not_allowed"' "$out"

rm -f "$FLAG"
out=$(sh "$LIB" change '{"user":"longos","old":"longos","new":"NewPass123!","confirm":"NewPass123!"}')
ck "重复提交（标记已清）拒绝" '"code":"not_allowed"' "$out"

out=$(sh "$LIB" change '')
ck "空请求体拒绝" '"code":"nodata"' "$out"

out=$(sh "$LIB" change 'not-a-json')
ck "非法 JSON 拒绝" '"ok":false' "$out"

# ---- 标记文件边界 ----
: > "$FLAG"
out=$(sh "$LIB" state)
ck "空标记文件视为无需改密" '"must_change":false' "$out"

rm -f "$FLAG"
out=$(sh "$LIB" state)
ck "标记文件缺失视为无需改密" '"must_change":false' "$out"

printf '\n通过 %s，失败 %s\n' "$pass" "$fail"
[ "$fail" = "0" ] || exit 1
exit 0
