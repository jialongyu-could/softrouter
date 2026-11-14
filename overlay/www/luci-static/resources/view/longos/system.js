'use strict';
'require view';
'require longos.api as api';

function v(box, n) { var e = box.querySelector('[data-f="' + n + '"]'); return e ? e.value.trim() : ''; }
function cb(box, n) { var e = box.querySelector('[data-f="' + n + '"] input[type="checkbox"]'); return !!(e && e.checked); }

return view.extend({
	load: function() { return Promise.all([ api.call('settings'), api.call('trea'), api.call('status') ]); },

	render: function(res) {
		var self = this;
		if (!document.querySelector('link[data-lo]'))
			document.head.appendChild(E('link', { 'rel': 'stylesheet', 'href': L.resource('longos/lo.css'), 'data-lo': '1' }));

		this.s = res[0] || {};
		this.t = res[1] || {};
		this.st = res[2] || {};
		this.elTrea = E('div', {});
		this.elLog = E('pre', { 'class': 'lo-log' });

		var s = this.s;
		var setBox = E('div', {}, [
			E('div', { 'class': 'lo-two' }, [
				api.field('主机名', api.input({ 'data-f': 'hostname', 'value': s.hostname || '' })),
				api.field('监控采样间隔（秒）', api.input({ 'data-f': 'monitor_interval', 'type': 'number', 'value': s.monitor_interval || 5 }))
			]),
			E('div', { 'class': 'lo-two' }, [
				api.field('首选 DNS', api.input({ 'data-f': 'dns1', 'value': s.dns1 || '' })),
				api.field('备用 DNS', api.input({ 'data-f': 'dns2', 'value': s.dns2 || '' }))
			]),
			E('div', { 'class': 'lo-two' }, [
				api.field('IPv4 探测目标', api.input({ 'data-f': 'ping4', 'value': s.ping4 || '' })),
				api.field('IPv6 探测目标', api.input({ 'data-f': 'ping6', 'value': s.ping6 || '' }))
			]),
			E('div', { 'class': 'lo-toolbar' }, [
				api.btn('保存设置', 'cbi-button-action', function() {
					api.call('settings_save', {
						hostname: v(setBox, 'hostname'), monitor_interval: v(setBox, 'monitor_interval'),
						dns1: v(setBox, 'dns1'), dns2: v(setBox, 'dns2'),
						ping4: v(setBox, 'ping4'), ping6: v(setBox, 'ping6')
					}).then(function() { api.notify('系统设置已保存', 'info'); })
					  .catch(function(e) { api.notify(e.message, 'error'); });
				})
			])
		]);

		var pwBox = E('div', {}, [
			E('div', { 'class': 'lo-two' }, [
				api.field('新密码', api.input({ 'data-f': 'pw1', 'type': 'password', 'value': '' })),
				api.field('确认新密码', api.input({ 'data-f': 'pw2', 'type': 'password', 'value': '' }))
			]),
			E('div', { 'class': 'lo-toolbar' }, [
				api.btn('修改管理员密码', 'cbi-button-action', function() {
					var p1 = v(pwBox, 'pw1'), p2 = v(pwBox, 'pw2');
					if (!p1 || p1 !== p2) { api.notify('两次输入的密码不一致', 'error'); return; }
					api.call('password_save', { password: p1 }).then(function() {
						api.notify('管理员密码已修改', 'info');
					}).catch(function(e) { api.notify(e.message, 'error'); });
				})
			])
		]);

		var t = this.t;
		var wanOpts = [ { value: '', label: '自动选择（默认路由）' } ].concat(
			((this.st.wans) || []).map(function(w) { return { value: w.id, label: w.name || w.id }; }));

		this.treaBox = E('div', {}, [
			E('div', { 'class': 'lo-toolbar' }, [
				api.badge(t.installed ? '已安装' : '未安装 /usr/bin/trea', t.installed ? 'ok' : 'warn'),
				api.badge(t.running ? ('运行中 PID ' + t.pid) : '未运行', t.running ? 'ok' : 'off'),
				t.version ? api.badge(t.version, 'info') : ''
			]),
			E('div', { 'class': 'lo-two' }, [
				api.field('上报服务器地址', api.input({ 'data-f': 'server', 'value': t.server || '', 'placeholder': '按麻雀云官方文档填写' })),
				api.field('节点令牌 Token', api.input({ 'data-f': 'token', 'type': 'password', 'value': t.token || '' }))
			]),
			E('div', { 'class': 'lo-two' }, [
				api.field('绑定出站线路', api.sel(wanOpts, t.iface || '', { 'data-f': 'iface' }), '建议显式绑定线路，便于多线路上报'),
				api.field('上报间隔（秒）', api.input({ 'data-f': 'interval', 'type': 'number', 'value': t.interval || 60 }))
			]),
			api.field('附加配置（原样写入 /etc/trea.conf）', E('textarea', {
				'class': 'lo-input', 'data-f': 'extra', 'rows': 4, 'style': 'width:100%;font-family:ui-monospace,monospace'
			}, [ t.extra || '' ])),
			api.field('启用 trea 并开机自启', api.switchBox(!!t.enabled, 'enabled')),
			E('div', { 'class': 'lo-toolbar' }, [
				api.btn('保存 trea 配置', 'cbi-button-action', function() { self.saveTrea(); }),
				api.btn('启动', '', function() { self.treaAction('start'); }),
				api.btn('停止', '', function() { self.treaAction('stop'); }),
				api.btn('重启', '', function() { self.treaAction('restart'); }),
				E('span', { 'class': 'grow' }),
				api.btn('刷新日志', '', function() { self.loadTrea(); })
			]),
			this.elLog
		]);

		var sys = this.st.sys || {};
		var cpu = sys.cpu || {}, mem = sys.mem || {};
		var infoRows = [
			[ '固件版本', s.version || sys.version || '--' ],
			[ '架构', s.arch || sys.arch || '--' ],
			[ '主机名', sys.hostname || s.hostname || '--' ],
			[ '运行时长', api.dur(sys.uptime || 0) ],
			[ 'CPU', (cpu.model || '--') + ' · ' + (cpu.cores || 0) + ' 核' ],
			[ '内存', (mem.pct || 0) + '% · ' + api.bytes((mem.used || 0) * 1024) + ' / ' + api.bytes((mem.total || 0) * 1024) ]
		].map(function(r) {
			return E('tr', {}, [ E('td', {}, [ r[0] ]), E('td', { 'class': 'lo-mono' }, [ r[1] ]) ]);
		});

		var root = E('div', { 'class': 'lo-wrap' }, [
			E('div', { 'class': 'lo-card' }, [ E('h3', {}, [ '系统信息' ]), api.table([ '项目', '值' ], infoRows) ]),
			E('div', { 'class': 'lo-card' }, [ E('h3', {}, [ '基础设置' ]), setBox ]),
			E('div', { 'class': 'lo-card' }, [ E('h3', {}, [ '管理员密码' ]), pwBox ]),
			E('div', { 'class': 'lo-card' }, [
				E('h3', {}, [ '麻雀云 trea 客户端', api.badge('调度 / 上报', 'info') ]),
				E('p', { 'class': 'lo-desc' }, [ 'trea 为麻雀云提供的调度客户端，需自行将官方二进制放到 /usr/bin/trea 并赋予执行权限；本页负责生成配置、启动与查看日志。' ]),
				this.treaBox
			]),
			E('div', { 'class': 'lo-card' }, [
				E('h3', {}, [ '系统操作' ]),
				E('div', { 'class': 'lo-toolbar' }, [
					api.btn('重启设备', 'cbi-button-negative', function() {
						api.confirm('确定重启 LongOS？', function() {
							api.call('reboot').then(function() {
								api.notify('设备正在重启，请稍候重新连接', 'warning');
							});
						});
					})
				]),
				E('p', { 'class': 'lo-hint' }, [ '配置备份/恢复请使用 LuCI 顶部「系统 - 备份/升级」功能。' ])
			])
		]);

		this.renderLog(t.log || '');
		return root;
	},

	renderLog: function(log) {
		this.elLog.textContent = log || '(暂无日志)';
		this.elLog.scrollTop = this.elLog.scrollHeight;
	},

	loadTrea: function() {
		var self = this;
		api.call('trea').then(function(t) {
			self.t = t;
			self.renderLog(t.log || '');
		});
	},

	saveTrea: function() {
		var self = this, box = this.treaBox;
		api.call('trea_save', {
			enabled: cb(box, 'enabled'), server: v(box, 'server'), token: v(box, 'token'),
			iface: v(box, 'iface'), interval: v(box, 'interval'), extra: v(box, 'extra')
		}).then(function() {
			api.notify('trea 配置已保存', 'info');
			self.loadTrea();
		}).catch(function(e) { api.notify(e.message, 'error'); });
	},

	treaAction: function(action) {
		var self = this;
		api.call('trea_action', { action: action }).then(function() {
			api.notify('trea ' + action + ' 已执行', 'info');
			window.setTimeout(function() { self.loadTrea(); }, 800);
		}).catch(function(e) { api.notify(e.message, 'error'); });
	}
});
