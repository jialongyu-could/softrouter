#!/bin/sh
# LongOS 账户安全：默认密码强制修改、密码强度校验、旧密码验证
# 调用方：
#   /usr/lib/longos/lo.sh     面板后端（rpcd file.exec，已登录）
#   /www/cgi-bin/longos-auth  公开 CGI（改密页使用，不依赖 LuCI 会话）
# 子命令：
#   state             输出 {"ok":true,"must_change":bool,"users":[...],"min_len":10}
#   verify <user> <pw> 校验旧密码，输出 {"ok":bool}
#   change [json]     修改密码（默认从 stdin 读取 JSON）
#   validate <pw>     仅做密码强度校验（测试用）
# 测试钩子（仅测试脚本使用，生产不设置）：
#   LO_STATE_FILE     改密标记文件，默认 /etc/longos/pwchange
#   LO_TEST=1         跳过 ubus 校验与 chpasswd 写入
#   LO_TEST_OLD       配合 LO_TEST 的期望旧密码
#   LO_TEST_CHPASSWD  配合 LO_TEST 记录 "user:newpass" 的文件

STATE_FILE=${LO_STATE_FILE:-/etc/longos/pwchange}
MIN_LEN=${LO_MIN_LEN:-10}
MAX_LEN=${LO_MAX_LEN:-64}
TEST_MODE=${LO_TEST:-0}

# ---------------- 输出辅助 ----------------

jesc() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$(printf '\t')/ /g" | tr -d '\r\n'
}

jstr() { printf '"%s"' "$(jesc "$1")"; }

fail() { printf '{"ok":false,"code":"%s","msg":"%s"}' "$1" "$2"; }

# ---------------- 标记文件 ----------------

# 输出所有待强制改密的账号（每行一个）
flag_users() {
	[ -f "$STATE_FILE" ] || return 0
	while IFS= read -r line; do
		line=$(printf '%s' "$line" | sed -e 's/[[:space:]]*$//')
		[ -n "$line" ] && printf '%s\n' "$line"
	done < "$STATE_FILE"
}

in_flag() { flag_users | grep -qx "$1"; }

clear_flag() {
	local user="$1" tmp
	[ -f "$STATE_FILE" ] || return 0
	tmp="/tmp/lo_pwflag.$$"
	flag_users | while IFS= read -r line; do
		[ "$line" = "$user" ] || printf '%s\n' "$line"
	done > "$tmp"
	if [ -s "$tmp" ]; then
		cat "$tmp" > "$STATE_FILE"
	else
		rm -f "$STATE_FILE"
	fi
	rm -f "$tmp"
}

# ---------------- 密码强度 ----------------

# 合法返回 0；不合法时输出错误 JSON 并返回 1
pw_validate() {
	local pw="$1" len classes=0
	[ -n "$pw" ] || { fail empty '新密码不能为空'; return 1; }

	len=$(printf '%s' "$pw" | wc -c | tr -d ' ')
	[ "$len" -ge "$MIN_LEN" ] || { printf '{"ok":false,"code":"too_short","msg":"新密码至少 %s 位"}' "$MIN_LEN"; return 1; }
	[ "$len" -le "$MAX_LEN" ] || { printf '{"ok":false,"code":"too_long","msg":"新密码不能超过 %s 位"}' "$MAX_LEN"; return 1; }

	# 禁止空白字符（终端/面板输入容易出问题）
	if printf '%s' "$pw" | grep -q '[[:space:]]'; then
		fail whitespace '新密码不能包含空格或换行'
		return 1
	fi

	# 禁止包含账号名，避免 longos/LongOS123 这类弱口令
	if printf '%s' "$pw" | tr 'A-Z' 'a-z' | grep -q 'longos'; then
		fail contains_user '新密码不能包含账号名 longos'
		return 1
	fi

	printf '%s' "$pw" | grep -q '[a-z]' && classes=$((classes + 1))
	printf '%s' "$pw" | grep -q '[A-Z]' && classes=$((classes + 1))
	printf '%s' "$pw" | grep -q '[0-9]' && classes=$((classes + 1))
	printf '%s' "$pw" | grep -q '[^a-zA-Z0-9]' && classes=$((classes + 1))
	[ "$classes" -ge 3 ] || {
		fail weak '新密码需包含大写字母、小写字母、数字、符号中的至少 3 类'
		return 1
	}

	return 0
}

# ---------------- 系统写入 ----------------

set_passwd() {
	local user="$1" pw="$2"
	if [ "$TEST_MODE" = "1" ]; then
		[ -n "$LO_TEST_CHPASSWD" ] && printf '%s:%s\n' "$user" "$pw" >> "$LO_TEST_CHPASSWD"
		return 0
	fi
	if command -v chpasswd >/dev/null 2>&1; then
		printf '%s:%s\n' "$user" "$pw" | chpasswd 2>/dev/null && return 0
	fi
	printf '%s\n%s\n' "$pw" "$pw" | passwd "$user" >/dev/null 2>&1
}

# 通过 rpcd 登录校验旧密码（成功后立刻销毁临时会话）
verify_old() {
	local user="$1" pw="$2" out sid
	if [ "$TEST_MODE" = "1" ]; then
		[ "$pw" = "$LO_TEST_OLD" ]
		return $?
	fi
	[ -n "$user" ] && [ -n "$pw" ] || return 1
	out=$(ubus call session login "$(printf '{"username":"%s","password":"%s","timeout":60}' "$(jesc "$user")" "$(jesc "$pw")")" 2>/dev/null)
	sid=$(printf '%s' "$out" | jq -r '.ubus_rpc_session // empty' 2>/dev/null)
	[ -n "$sid" ] || return 1
	ubus call session destroy "$(printf '{"ubus_rpc_session":"%s"}' "$sid")" >/dev/null 2>&1
	return 0
}

# 修改完成后清理所有已登录会话，强制回登录页
drop_sessions() {
	[ "$TEST_MODE" = "1" ] && return 0
	(sleep 2; /etc/init.d/rpcd restart) >/dev/null 2>&1 &
}

# ---------------- 子命令 ----------------

cmd_state() {
	local users="" first=1 u
	if [ -f "$STATE_FILE" ]; then
		while IFS= read -r u; do
			u=$(printf '%s' "$u" | sed -e 's/[[:space:]]*$//')
			[ -n "$u" ] || continue
			[ "$first" = "1" ] || users="$users,"
			users="$users$(jstr "$u")"
			first=0
		done < "$STATE_FILE"
	fi
	if [ -n "$users" ]; then
		printf '{"ok":true,"must_change":true,"users":[%s],"min_len":%s}' "$users" "$MIN_LEN"
	else
		printf '{"ok":true,"must_change":false,"users":[],"min_len":%s}' "$MIN_LEN"
	fi
}

cmd_change() {
	local data user old new cf
	data=${1:-}
	[ -n "$data" ] || data=$(cat)
	[ -n "$data" ] || { fail nodata '缺少请求数据'; return; }

	user=$(printf '%s' "$data" | jq -r '.user // empty' 2>/dev/null)
	old=$(printf '%s' "$data" | jq -r '.old // empty' 2>/dev/null)
	new=$(printf '%s' "$data" | jq -r '.new // empty' 2>/dev/null)
	cf=$(printf '%s' "$data" | jq -r '.confirm // empty' 2>/dev/null)

	[ -n "$user" ] || user=longos

	# 只允许修改“首次登录强制改密”名单内的账号，防止公开 CGI 被用来改任意账号
	in_flag "$user" || { fail not_allowed '该账号无需强制改密，请在系统设置中修改密码'; return; }

	[ -n "$old" ] || { fail no_old '请输入旧密码'; return; }
	[ -n "$new" ] || { fail empty '新密码不能为空'; return; }
	[ "$new" = "$cf" ] || { fail mismatch '两次输入的新密码不一致'; return; }
	[ "$new" != "$old" ] || { fail same '新密码不能与旧密码相同'; return; }

	pw_validate "$new" || return 0

	# 先校验旧密码，再写入，避免脏写
	verify_old "$user" "$old" || { fail bad_old '旧密码不正确'; return; }

	set_passwd "$user" "$new" || { fail set_failed '密码写入失败，请重试'; return; }

	clear_flag "$user"
	drop_sessions
	printf '{"ok":true,"msg":"密码修改成功，请使用新密码重新登录","relogin":true}'
}

cmd="$1"
[ $# -gt 0 ] && shift

case "$cmd" in
	state)
		cmd_state
		;;
	verify)
		if verify_old "$1" "$2"; then
			printf '{"ok":true}'
		else
			printf '{"ok":false,"code":"bad_old","msg":"旧密码不正确"}'
		fi
		;;
	validate)
		if pw_validate "$1"; then
			printf '{"ok":true}'
		fi
		;;
	change)
		cmd_change "${1:-}"
		;;
	*)
		printf '{"ok":false,"msg":"unknown auth command"}'
		;;
esac
exit 0
