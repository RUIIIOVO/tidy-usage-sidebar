// cc-switch → 配置用量查询 → 预设模板选「自定义」→ 粘贴下面整段
// 必须选「自定义」，其它模板会强制 HTTPS + 同源校验
// （cc-switch src-tauri/src/usage_script.rs 的 validate_request_url / validate_base_url）。
// API Key、请求地址两个输入框留空即可，脚本里写的是完整 URL。
//
// 展示效果：
//   💰 ── Claude ──────────
//   💰 5小时会话             6 分钟后重置             剩余: 55.00 %
//   💰 本周                  6 天 23 小时后重置       剩余: 98.00 %
//   💰 本周 · Fable          6 天 23 小时后重置       剩余: 100.00 %
//   💰 ── Antigravity ─────
//   💰 5小时 · Gemini        4 小时 12 分后重置       剩余: 100.00 %
//   💰 5小时 · Claude/GPT    3 小时 40 分后重置       剩余: 95.23 %
//   💰 本周 · Gemini         6 天 15 小时后重置       剩余: 100.00 %
//   💰 本周 · Claude/GPT     6 天 14 小时后重置       剩余: 98.41 %
//
// 排序：Claude 段在上、Antigravity 段在下；每段内 5 小时窗口在前、
// 一周窗口在后。两段之间插一条分隔行。
//
// 后端 /usage 每个窗口都带 provider 字段（claude / antigravity），
// 两家互不拖累：一家挂了另一家照常显示，挂掉的那家在末尾单列一条提示。
({
  request: {
    url: "http://YOUR_SERVER:8318/usage?token=YOUR_TOKEN",
    method: "GET",
    headers: {
      "User-Agent": "cc-switch/1.0",
    },
  },
  extractor: function (response) {
    if (!response || response.ok !== true) {
      return {
        isValid: false,
        invalidMessage: (response && response.error) || "额度查询失败",
      };
    }

    // ── Claude 官方时间窗口 → 面板标题 ────────────────────────────
    var LABEL = {
      five_hour: "5小时会话",
      seven_day: "本周",
      seven_day_opus: "本周 · Opus",
      seven_day_sonnet: "本周 · Sonnet",
    };

    function claudeLabel(w) {
      var name = w.name;
      // 按模型拆分的周窗口：服务端已从官方 limits 里取出显示名（如 Fable）
      if (name === "weekly_scoped") return "本周" + (w.label ? " · " + w.label : "（分模型）");
      if (LABEL[name]) return LABEL[name];
      if (w.label) return "本周 · " + w.label;
      var parts = String(name).split("_");
      var pretty = [];
      for (var i = 0; i < parts.length; i++) {
        if (!parts[i]) continue;
        pretty.push(parts[i].charAt(0).toUpperCase() + parts[i].slice(1));
      }
      return "本周 · " + pretty.join(" ");
    }

    // ── Antigravity 窗口 ─────────────────────────────────────────
    // name 是 5h / weekly，label 是模型组（Gemini Models /
    // Claude and GPT models）。组名压短，否则一行放不下。
    // 段标题已经写明是 Antigravity，条目里就不再重复 AG 前缀。
    function shortGroup(label) {
      var s = String(label || "").trim();
      if (!s) return "";
      if (/gemini/i.test(s)) return "Gemini";
      if (/claude|gpt/i.test(s)) return "Claude/GPT";
      return s.replace(/\s*models?$/i, "");
    }

    function antigravityLabel(w) {
      var win = String(w.name || "").toLowerCase();
      var head;
      if (win === "5h") head = "5小时";
      else if (win === "weekly") head = "本周";
      else head = String(w.name || "未知");
      var group = shortGroup(w.label);
      return group ? head + " · " + group : head;
    }

    function labelOf(w) {
      return w.provider === "antigravity" ? antigravityLabel(w) : claudeLabel(w);
    }

    // Claude 段在前、Antigravity 段在后；段内 5 小时窗口排在一周窗口之前。
    function providerRank(w) {
      return w.provider === "antigravity" ? 1 : 0;
    }

    function sortKey(w) {
      var win = String(w.name || "").toLowerCase();
      var isFiveHour = win === "5h" || win === "five_hour";
      return providerRank(w) * 100 + (isFiveHour ? 0 : 10);
    }

    // cc-switch 只会渲染 planName / remaining / unit / extra，没有真正的
    // 分组控件，所以用一条没有数值的行当段标题。remaining 给 null，
    // 免得它被当成“剩余 0%”读成额度耗尽。
    function sectionRow(title) {
      return { planName: "── " + title + " ──────────", remaining: null, unit: "" };
    }

    function resetText(iso) {
      if (!iso) return null;
      var ts = Date.parse(iso);
      if (isNaN(ts)) return null;
      var mins = Math.round((ts - Date.now()) / 60000);
      if (mins <= 0) return "即将重置";
      if (mins < 60) return mins + " 分钟后重置";
      var h = Math.floor(mins / 60);
      var m = mins % 60;
      if (h < 24) return h + " 小时" + (m ? " " + m + " 分" : "") + "后重置";
      var d = Math.floor(h / 24);
      var rh = h % 24;
      return d + " 天" + (rh ? " " + rh + " 小时" : "") + "后重置";
    }

    var list = (response.windows || []).slice();
    // 稳定排序：同 key 时保持后端返回顺序，避免每次刷新条目跳来跳去。
    var indexed = [];
    for (var n = 0; n < list.length; n++) indexed.push([list[n], n]);
    indexed.sort(function (a, b) {
      var d = sortKey(a[0]) - sortKey(b[0]);
      return d !== 0 ? d : a[1] - b[1];
    });

    var SECTION = { claude: "Claude", antigravity: "Antigravity" };
    var out = [];
    var lastProvider = null;
    for (var i = 0; i < indexed.length; i++) {
      var w = indexed[i][0];
      // provider 缺失时按 claude 处理，兼容旧版后端返回的窗口。
      var provider = w.provider === "antigravity" ? "antigravity" : "claude";
      if (provider !== lastProvider) {
        out.push(sectionRow(SECTION[provider]));
        lastProvider = provider;
      }
      var used = Math.round(w.utilization * 100) / 100;
      // 只给 remaining + unit：cc-switch 就只渲染「剩余: xx.xx %」这一列
      var item = {
        planName: labelOf(w),
        remaining: Math.round((100 - used) * 100) / 100,
        unit: "%",
      };
      var txt = resetText(w.resets_at);
      if (response.stale) txt = (txt ? txt + " · " : "") + "缓存数据";
      if (txt) item.extra = txt;
      out.push(item);
    }

    // 某一家取数失败时留一条可见提示，否则那家的窗口会静悄悄消失，
    // 容易被误读成「额度没了」。
    var errors = response.errors || {};
    var errorKeys = [];
    for (var key in errors) {
      if (Object.prototype.hasOwnProperty.call(errors, key)) errorKeys.push(key);
    }
    if (errorKeys.length) {
      out.push(sectionRow("查询失败"));
      for (var e = 0; e < errorKeys.length; e++) {
        var k = errorKeys[e];
        out.push({
          planName: SECTION[k] || k,
          remaining: null,
          unit: "",
          extra: String(errors[k]).slice(0, 80),
        });
      }
    }

    if (!out.length) {
      return { isValid: false, invalidMessage: "官方未返回额度窗口" };
    }
    return out;
  },
})
