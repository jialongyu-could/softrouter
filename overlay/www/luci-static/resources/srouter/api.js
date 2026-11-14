'use strict';
'require fs';
'require ui';
'require poll';

var API = {
	call: function(cmd, data) {
		var args = [ cmd ];
		if (data != null)
			args.push(JSON.stringify(data));

		return fs.exec('/usr/lib/srouter/sr.sh', args).then(function(res) {
			if (res.code !== 0)
				throw new Error((res.stderr || '').trim() || ('命令失败: ' + res.code));
			try {
				return JSON.parse((res.stdout || '{}').trim() || '{}');
			} catch (e) {
				throw new Error('返回数据解析失败: ' + (res.stdout || ''));
			}
		});
	},

	rate: function(bps) {
		bps = Number(bps) || 0;
		if (bps >= 1000000000) return (bps / 1000000000).toFixed(2) + ' Gbps';
		if (bps >= 1000000) return (bps / 1000000).toFixed(2) + ' Mbps';
		if (bps >= 1000) return (bps / 1000).toFixed(1) + ' Kbps';
		return bps + ' bps';
	},

	kbps: function(k) {
		k = Number(k) || 0;
		if (k >= 1000000) return (k / 1000000).toFixed(1) + ' Gbps';
		if (k >= 1000) return (k / 1000).toFixed(1) + ' Mbps';
		return k + ' Kbps';
	},

	bytes: function(v) {
		var u = [ 'B', 'KB', 'MB', 'GB', 'TB' ], i = 0;
		v = Number(v) || 0;
		while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
		return v.toFixed(i ? 1 : 0) + ' ' + u[i];
	},

	dur: function(s) {
		s = Math.max(0, Number(s) || 0);
		var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600),
		    m = Math.floor(s % 3600 / 60), ss = Math.floor(s % 60);
		if (d > 0) return d + '天' + h + '小时';
		if (h > 0) return h + '小时' + m + '分';
		if (m > 0) return m + '分' + ss + '秒';
		return ss + '秒';
	},

	notify: function(msg, type) {
		ui.addNotification(null, E('p', {}, [ msg ]), type || 'info');
	},

	field: function(label, node, hint) {
		return E('div', { 'class': 'sr-field' }, [
			E('label', { 'class': 'sr-label' }, [ label ]),
			node,
			hint ? E('div', { 'class': 'sr-hint' }, [ hint ]) : ''
		]);
	},

	input: function(attrs) {
		var a = { 'class': 'sr-input', 'style': 'width:100%' };
		for (var k in attrs) a[k] = attrs[k];
		return E('input', a);
	},

	sel: function(options, value, attrs) {
		var a = { 'class': 'sr-input', 'style': 'width:100%' };
		for (var k in (attrs || {})) a[k] = attrs[k];
		return E('select', a, options.map(function(o) {
			var val = (typeof o === 'string') ? o : o.value;
			var text = (typeof o === 'string') ? o : o.label;
			return E('option', { 'value': val, 'selected': (String(val) === String(value)) ? '' : null }, [ text ]);
		}));
	},

	switchBox: function(checked, name) {
		var node = E('label', { 'class': 'sr-switch' }, [
			E('input', { 'type': 'checkbox', 'checked': checked ? '' : null }),
			E('span', { 'class': 'sr-slider' })
		]);
		return name ? E('div', { 'data-f': name }, [ node ]) : node;
	},

	isOn: function(node) {
		var cb = node.querySelector('input[type="checkbox"]');
		return !!(cb && cb.checked);
	},

	btn: function(text, cls, onclick) {
		return E('button', {
			'class': 'btn cbi-button ' + (cls || 'sr-btn'),
			'click': onclick
		}, [ text ]);
	},

	badge: function(text, tone) {
		return E('span', { 'class': 'sr-badge ' + (tone || '') }, [ text ]);
	},

	confirm: function(text, onOk) {
		ui.showModal('请确认', [
			E('p', {}, [ text ]),
			E('div', { 'class': 'sr-modal-actions' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ '取消' ]),
				E('button', { 'class': 'btn cbi-button-negative', 'click': function() {
					ui.hideModal();
					onOk();
				} }, [ '确定' ])
			])
		]);
	},

	modal: function(title, body, onSave) {
		var box = E('div', { 'class': 'sr-modal' }, [].concat(body));
		ui.showModal(title, [
			box,
			E('div', { 'class': 'sr-modal-actions' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ '取消' ]),
				E('button', { 'class': 'btn cbi-button-action', 'click': function(ev) {
					Promise.resolve(onSave(ev)).then(function(ok) {
						if (ok !== false) ui.hideModal();
					}).catch(function(e) {
						API.notify(e.message || '保存失败', 'error');
					});
				} }, [ '保存' ])
			])
		]);
		return box;
	},

	statusDot: function(up) {
		return E('span', { 'class': 'sr-dot ' + (up ? 'up' : 'down') });
	},

	table: function(headers, rows, empty) {
		if (!rows || !rows.length)
			return E('div', { 'class': 'sr-empty' }, [ empty || '暂无数据' ]);
		return E('table', { 'class': 'sr-table' }, [
			E('thead', {}, [ E('tr', {}, headers.map(function(h) { return E('th', {}, [ h ]); })) ]),
			E('tbody', {}, rows)
		]);
	},

	// 延迟/丢包展示
	probe: function(p) {
		if (!p) return E('span', { 'class': 'sr-muted' }, [ '--' ]);
		var lat = Number(p.latency || 0), loss = Number(p.loss || 0);
		if (loss >= 100 || lat <= 0)
			return E('span', { 'class': 'sr-bad' }, [ '不可达' ]);
		var tone = loss > 0 ? 'warn' : (lat > 100 ? 'warn' : 'ok');
		return E('span', { 'class': 'sr-' + tone }, [
			lat.toFixed(1) + ' ms',
			loss > 0 ? E('span', { 'class': 'sr-muted' }, [ ' / 丢包 ' + loss + '%' ]) : ''
		]);
	},

	chart: function(canvas, series, maxPoints) {
		var ctx = canvas.getContext('2d');
		var w = canvas.clientWidth || 600, h = canvas.clientHeight || 170;
		var dpr = window.devicePixelRatio || 1;
		canvas.width = w * dpr; canvas.height = h * dpr;
		ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
		ctx.clearRect(0, 0, w, h);

		var max = 1;
		series.forEach(function(s) {
			s.data.forEach(function(v) { if (v > max) max = v; });
		});
		max *= 1.2;

		ctx.strokeStyle = 'rgba(148,163,184,0.15)';
		ctx.lineWidth = 1;
		for (var i = 0; i <= 4; i++) {
			var y = 8 + (h - 24) * i / 4;
			ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke();
		}

		series.forEach(function(s) {
			var data = s.data.slice(-maxPoints);
			if (data.length < 2) return;
			var step = w / Math.max(1, maxPoints - 1);
			var startX = w - step * (data.length - 1);
			ctx.beginPath();
			data.forEach(function(v, idx) {
				var x = startX + idx * step;
				var y = (h - 16) - (v / max) * (h - 24);
				if (idx === 0) ctx.moveTo(x, y);
				else {
					var px = startX + (idx - 1) * step;
					var py = (h - 16) - (data[idx - 1] / max) * (h - 24);
					var cx = (px + x) / 2;
					ctx.bezierCurveTo(cx, py, cx, y, x, y);
				}
			});
			ctx.strokeStyle = s.color;
			ctx.lineWidth = 2;
			ctx.stroke();
			ctx.lineTo(startX + (data.length - 1) * step, h);
			ctx.lineTo(startX, h);
			ctx.closePath();
			ctx.fillStyle = s.fill;
			ctx.fill();
		});

		ctx.fillStyle = 'rgba(148,163,184,0.75)';
		ctx.font = '11px system-ui';
		ctx.fillText(API.rate(max), 6, 12);
	}
};

return API;
