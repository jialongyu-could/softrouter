'use strict';
'require view';
'require longos.api as api';

function v(box, n) { var e = box.querySelector('[data-f="' + n + '"]'); return e ? e.value.trim() : ''; }

function ago(ts) {
	ts = Number(ts) || 0;
	if (!ts) return '从未';
	var d = Math.max(0, Math.floor(Date.now() / 1000) - ts);
	if (d < 60) return d + ' 秒前';
	if (d < 3600) return Math.floor(d / 60) + ' 分钟前';
	if (d < 86400) return Math.floor(d / 3600) + ' 小时前';
	return Math.floor(d / 86400) + ' 天前';
}

function mask(s) {
	s = String(s || '');
	if (s.length <= 8) return s;
	return s.slice(0, 4) + '****' + s.slice(-4);
}

return view.extend({
	load: function() {
		return Promise.all([ api.call('agent_state'), api.call('agent_users') ]);
	},

	render: function(res) {
		var self = this;
		if (!document.querySelector('link[data-lo]'))
			document.head.appendChild(E('link', { 'rel': 'stylesheet', 'href': L.resource('longos/lo.css'), 'data-lo': '1' }));

		this.st = res[0] || {};
		this.users = (res[1] && res[1].users) || [];

		var st = this.st;
		var bound = !!st.bound;

		var bindBox = E('div', {}, [
			api.field('服务器地址', api.input({ 'data-f': 'server', 'value': st.server || 'https://www.yjlxxcc.top', 'placeholder': 'https://www.yjlxxcc.top' }), '必须是带 https 的 LongOS 服务端地址'),
			api.field('绑定密钥', api.input({ 'data-f': 'key', 'value': '', 'placeholder': 'LK-XXXXXXXXXXXX' }), '在网站管理后台「LongOS软路由 → 绑定密钥」中生成'),
			E('div', { 'class': 'lo-toolbar' }, [
				api.btn('立即绑定', 'cbi-button-action', function(ev) {
					var btn = ev.currentTarget;
					btn.disabled = true;
					api.call('agent_bind', { server: v(bindBox, 'server'), key: v(bindBox, 'key') })
						.then(function(r) {
							btn.disabled = false;
							if (r && r.ok === false) { api.notify(r.msg || '绑定失败', 'error'); return; }
							api.notify('绑定成功，远程通道正在建立', 'info');
							self.reload();
						})
						.catch(function(e) { btn.disabled = false; api.notify(e.message, 'error'); });
				})
			])
		]);

		this.elUsers = E('div', {});

		var root = E('div', { 'class': 'lo-wrap' }, [
			E('div', { 'class': 'lo-card' }, [
				E('h3', {}, [ '远程 Agent', api.badge(bound ? '已绑定' : '未绑定', bound ? 'ok' : 'warn') ]),
				E('div', { 'class': 'lo-stats' }, [
					this.stat('服务器', st.server || '-'),
					this.stat('设备 ID', mask(st.device_id)),
					this.stat('最近心跳', ago(st.last_poll)),
					this.stat('同步用户', String(st.users || 0)),
					this.stat('WireGuard', st.wg_address ? (st.wg_address + (st.wg_up ? '（在线）' : '（未连通）')) : '未启用'),
					this.stat('frp 映射端口', st.frp_port ? String(st.frp_port) : '未启用')
				]),
				E('div', { 'class': 'lo-toolbar' }, [
					api.btn('刷新状态', 'lo-btn', function() { self.reload(); }),
					api.btn('打开注册页', 'lo-btn', function() { window.open('/longos/register.html', '_blank'); }),
					bound ? api.btn('解除绑定', 'cbi-button-negative', function() {
						api.confirm('解除绑定后本机将无法被远程管理，需在网站后台重新生成密钥绑定，确定继续？', function() {
							api.call('agent_unbind').then(function() {
								api.notify('已解除绑定', 'info');
								self.reload();
							}).catch(function(e) { api.notify(e.message, 'error'); });
						});
					}) : ''
				])
			]),

			E('div', { 'class': 'lo-card' }, [
				E('h3', {}, [ bound ? '更换绑定密钥' : '绑定到管理后台', api.badge('免公网 IP', 'info') ]),
				bindBox,
				E('ul', { 'class': 'lo-list' }, [
					E('li', {}, [ '所有连接由设备主动出站，设备位于 NAT 后、没有公网 IP 也能被远程管理。' ]),
					E('li', {}, [ '控制通道使用 HTTPS + 设备令牌；安装 wireguard-tools 后自动建立 10.66.0.x 直连隧道，延迟更低。' ]),
					E('li', {}, [ '存在 frpc 时自动启用端口映射，用于临时访问 Web 管理页或 SSH。' ])
				])
			]),

			E('div', { 'class': 'lo-card' }, [
				E('h3', {}, [ '已同步的 LongOS 用户', api.badge(String(this.users.length) + ' 个', 'info') ]),
				this.elUsers
			])
		]);

		this.renderUsers();
		return root;
	},

	stat: function(label, value) {
		return E('div', { 'class': 'lo-stat' }, [
			E('div', { 'class': 'lo-stat-label' }, [ label ]),
			E('div', { 'class': 'lo-stat-value' }, [ value ])
		]);
	},

	renderUsers: function() {
		var users = this.users || [];
		var box = this.elUsers;
		box.innerHTML = '';
		if (!users.length) {
			box.appendChild(E('div', { 'class': 'lo-empty' }, [ '暂无同步用户，可在注册页创建账号，或等待下一次心跳同步' ]));
			return;
		}
		var rows = users.map(function(u) {
			return E('tr', {}, [
				E('td', {}, [ u.username || '-' ]),
				E('td', {}, [ u.role === 'admin' ? '管理员' : '普通用户' ]),
				E('td', {}, [ api.badge(u.status === 'active' ? '已激活' : (u.status || '-'), u.status === 'active' ? 'ok' : 'warn') ]),
				E('td', {}, [ Array.isArray(u.perms) ? (u.perms.join('、') || '默认') : '默认' ])
			]);
		});
		box.appendChild(E('table', { 'class': 'lo-table' }, [
			E('thead', {}, [ E('tr', {}, [
				E('th', {}, [ '用户名' ]), E('th', {}, [ '角色' ]), E('th', {}, [ '状态' ]), E('th', {}, [ '权限模块' ])
			]) ]),
			E('tbody', {}, rows)
		]));
	},

	reload: function() {
		var self = this;
		Promise.all([ api.call('agent_state'), api.call('agent_users') ]).then(function(r) {
			self.st = r[0] || {};
			self.users = (r[1] && r[1].users) || [];
			self.renderUsers();
			location.reload();
		}).catch(function(e) { api.notify(e.message, 'error'); });
	}
});
