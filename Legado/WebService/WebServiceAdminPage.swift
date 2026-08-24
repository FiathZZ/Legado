import Foundation

enum WebServiceAdminPage {
    static let html = #"""
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width,initial-scale=1" />
      <title>Legado 局域网管理</title>
      <style>
        :root {
          color-scheme: light;
          --bg: #f4f0e8;
          --card: rgba(255,255,255,0.88);
          --card-strong: #fffaf2;
          --line: rgba(86, 64, 40, 0.12);
          --text: #2d2015;
          --muted: #7c6550;
          --accent: #c16f2f;
          --accent-soft: rgba(193,111,47,0.12);
          --danger: #b5483a;
          --success: #2f7a54;
          --shadow: 0 20px 60px rgba(83, 54, 28, 0.12);
          font-family: "PingFang SC", "Hiragino Sans GB", sans-serif;
        }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          background:
            radial-gradient(circle at top left, rgba(255,255,255,0.72), transparent 38%),
            linear-gradient(180deg, #efe6d6 0%, var(--bg) 58%, #ece4d7 100%);
          color: var(--text);
        }
        .shell {
          max-width: 1240px;
          margin: 0 auto;
          padding: 28px 18px 40px;
        }
        .panel {
          background: var(--card);
          border: 1px solid var(--line);
          border-radius: 24px;
          box-shadow: var(--shadow);
          backdrop-filter: blur(14px);
        }
        .hero-stat {
          padding: 16px 18px;
          border-radius: 18px;
          background: var(--card-strong);
          border: 1px solid var(--line);
        }
        .hero-stat .label {
          display: block;
          font-size: 12px;
          color: var(--muted);
          margin-bottom: 8px;
        }
        .hero-stat strong {
          display: block;
          font-size: 20px;
          word-break: break-all;
        }
        .notice {
          display: none;
          margin-bottom: 18px;
          padding: 14px 16px;
          border-radius: 16px;
          border: 1px solid transparent;
        }
        .notice.show { display: block; }
        .notice.success {
          background: rgba(47,122,84,0.12);
          color: var(--success);
          border-color: rgba(47,122,84,0.2);
        }
        .notice.error {
          background: rgba(181,72,58,0.1);
          color: var(--danger);
          border-color: rgba(181,72,58,0.18);
        }
        .grid {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
          gap: 18px;
        }
        .panel {
          padding: 22px;
        }
        .panel h2 {
          margin: 0 0 8px;
          font-size: 20px;
        }
        .panel .desc {
          margin: 0 0 18px;
          color: var(--muted);
          font-size: 14px;
          line-height: 1.6;
        }
        .actions {
          display: flex;
          flex-wrap: wrap;
          gap: 10px;
          margin-bottom: 16px;
        }
        button,
        input[type="file"]::file-selector-button {
          border: 0;
          border-radius: 999px;
          padding: 10px 16px;
          background: var(--accent);
          color: #fff;
          cursor: pointer;
          font: inherit;
        }
        button.secondary {
          background: var(--accent-soft);
          color: var(--accent);
        }
        button.ghost {
          background: transparent;
          color: var(--danger);
          border: 1px solid rgba(181,72,58,0.18);
        }
        input[type="file"] {
          width: 100%;
          color: var(--muted);
        }
        .list {
          display: grid;
          gap: 10px;
          margin: 0;
          padding: 0;
          list-style: none;
        }
        .item {
          display: flex;
          align-items: flex-start;
          justify-content: space-between;
          gap: 12px;
          padding: 14px 16px;
          border-radius: 18px;
          border: 1px solid var(--line);
          background: var(--card-strong);
        }
        .item strong {
          display: block;
          margin-bottom: 4px;
        }
        .item > div:first-child {
          min-width: 0;
          flex: 1 1 auto;
        }
        .item small, .pill-row {
          color: var(--muted);
          line-height: 1.5;
          overflow-wrap: anywhere;
          word-break: break-word;
        }
        .pill-row {
          display: flex;
          flex-wrap: wrap;
          gap: 8px;
          margin-top: 8px;
        }
        .pill {
          display: inline-flex;
          align-items: center;
          padding: 4px 10px;
          border-radius: 999px;
          background: var(--accent-soft);
          color: var(--accent);
          font-size: 12px;
        }
        .muted-empty {
          margin: 0;
          color: var(--muted);
          font-size: 14px;
        }
        .scroll-panel {
          max-height: 420px;
          overflow-y: auto;
          padding-right: 4px;
        }
        @media (max-width: 720px) {
          .shell { padding: 18px 14px 30px; }
          .panel { border-radius: 20px; }
          .item { flex-direction: column; }
        }
      </style>
    </head>
    <body>
      <div class="shell">
        <div id="notice" class="notice"></div>

        <section class="grid">
          <article class="panel">
            <h2>主题管理</h2>
            <p class="desc">导入单主题配置，或直接导出当前主题文件给桌面端留档。</p>
            <ul id="themeInfo" class="list" style="margin:0 0 16px;"></ul>
            <div class="actions">
              <button id="downloadTheme">导出当前主题</button>
            </div>
            <input id="themeInput" type="file" accept=".json,.Legado-theme.json" />
          </article>

          <article class="panel">
            <h2>字体库</h2>
            <p class="desc">支持 `.ttf` 与 `.otf`，导入后立即进入 App 的界面字体库。</p>
            <div class="hero-stat" style="margin-bottom:16px;">
              <span class="label">界面字体</span>
              <strong id="fontCurrent">跟随主题</strong>
            </div>
            <input id="fontInput" type="file" accept=".ttf,.otf" />
            <ul id="fontList" class="list" style="margin-top:16px;"></ul>
          </article>

          <article class="panel">
            <h2>本地书上传</h2>
            <p class="desc">支持 TXT / EPUB。上传后自动进入书架，并复用 App 内已有缓存与阅读链路。</p>
            <div class="hero-stat" style="margin-bottom:16px;">
              <span class="label">书架数量</span>
              <strong id="bookshelfCount">0</strong>
            </div>
            <input id="localBookInput" type="file" accept=".txt,.epub" multiple />
            <ul id="bookshelfList" class="list" style="margin-top:16px;"></ul>
          </article>

          <article class="panel">
            <h2>书源管理</h2>
            <p class="desc">上传书源 JSON 文件后直接合并进当前设备数据库，也可以在这里删除已有书源。</p>
            <div class="hero-stat" style="margin-bottom:16px;">
              <span class="label">书源数量</span>
              <strong id="sourceCount">0</strong>
            </div>
            <input id="bookSourceInput" type="file" accept=".json" />
            <div class="scroll-panel" style="margin-top:16px;">
              <ul id="bookSourceList" class="list"></ul>
            </div>
          </article>

          <article class="panel">
            <h2>替换规则</h2>
            <p class="desc">上传替换净化规则 JSON，导入后会立刻参与正文/标题净化。</p>
            <input id="replaceRuleInput" type="file" accept=".json" />
            <ul id="replaceRuleList" class="list" style="margin-top:16px;"></ul>
          </article>
        </section>
      </div>

      <script>
        const notice = document.getElementById("notice");

        function showNotice(message, type = "success") {
          notice.textContent = message;
          notice.className = "notice show " + type;
          window.clearTimeout(showNotice.timer);
          showNotice.timer = window.setTimeout(() => {
            notice.className = "notice";
          }, 3200);
        }

        async function api(path, options = {}) {
          const response = await fetch(path, options);
          const payload = await response.json().catch(() => ({}));
          if (!response.ok || payload.success === false) {
            throw new Error(payload.message || "请求失败");
          }
          return payload.data;
        }

        async function uploadFiles(endpoint, files) {
          for (const file of files) {
            const formData = new FormData();
            formData.append("file", file, file.name);
            await api(endpoint, { method: "POST", body: formData });
          }
        }

        function renderList(node, items, renderer) {
          node.innerHTML = "";
          if (!items.length) {
            node.innerHTML = '<p class="muted-empty">当前没有数据。</p>';
            return;
          }
          items.forEach(item => node.appendChild(renderer(item)));
        }

        function makeItem(primary, secondary, pills = [], trailingButton) {
          const li = document.createElement("li");
          li.className = "item";

          const left = document.createElement("div");
          left.innerHTML = `<strong>${primary}</strong><small>${secondary}</small>`;

          if (pills.length) {
            const pillRow = document.createElement("div");
            pillRow.className = "pill-row";
            pills.forEach(text => {
              const pill = document.createElement("span");
              pill.className = "pill";
              pill.textContent = text;
              pillRow.appendChild(pill);
            });
            left.appendChild(pillRow);
          }

          li.appendChild(left);
          if (trailingButton) li.appendChild(trailingButton);
          return li;
        }

        async function refreshTheme() {
          const theme = await api("/api/theme/current");
          document.getElementById("themeName").textContent = theme.name;
          const list = document.getElementById("themeInfo");
          renderList(list, [theme], item => makeItem(
            item.name,
            `${item.id} · ${item.author || "未知作者"}`,
            item.missingFonts.length ? item.missingFonts.map(font => `缺字: ${font}`) : ["当前已可用"]
          ));
        }

        async function refreshFonts() {
          const payload = await api("/api/fonts");
          document.getElementById("fontCurrent").textContent = payload.currentDisplayName || "跟随主题";
          renderList(document.getElementById("fontList"), payload.items, item => makeItem(
            item.displayName,
            item.postScriptName,
            [item.source].concat(item.isCurrent ? ["当前"] : []),
          ));
        }

        async function refreshBookshelf() {
          const books = await api("/api/bookshelf");
          document.getElementById("bookshelfCount").textContent = String(books.length);
          renderList(document.getElementById("bookshelfList"), books, item => makeItem(
            item.name,
            `${item.author} · ${item.totalChapterCount} 章`,
            [item.sourceName, item.kind || "未标记"]
          ));
        }

        async function refreshSources() {
          const sources = await api("/api/bookSources");
          document.getElementById("sourceCount").textContent = String(sources.length);
          renderList(document.getElementById("bookSourceList"), sources, item => {
            const button = document.createElement("button");
            button.className = "ghost";
            button.textContent = "删除";
            button.onclick = async () => {
              await api("/api/bookSources", {
                method: "DELETE",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ urls: [item.bookSourceUrl] })
              });
              showNotice(`已删除书源：${item.bookSourceName}`);
              refreshSources();
            };
            return makeItem(
              item.bookSourceName,
              item.bookSourceUrl,
              [item.enabled ? "启用" : "禁用"].concat(item.bookSourceGroup ? [item.bookSourceGroup] : []),
              button
            );
          });
        }

        async function refreshReplaceRules() {
          const rules = await api("/api/replaceRules");
          renderList(document.getElementById("replaceRuleList"), rules, item => makeItem(
            item.name || item.pattern,
            item.pattern,
            [item.scope, item.isEnabled ? "启用" : "禁用"]
          ));
        }

        async function refreshAll() {
          await Promise.all([
            refreshTheme(),
            refreshFonts(),
            refreshBookshelf(),
            refreshSources(),
            refreshReplaceRules()
          ]);
        }

        document.getElementById("downloadTheme").onclick = () => {
          window.location.href = "/api/theme/export";
        };

        document.getElementById("themeInput").addEventListener("change", async event => {
          const files = Array.from(event.target.files || []);
          if (!files.length) return;
          await uploadFiles("/api/theme/import", files);
          showNotice("主题导入完成");
          event.target.value = "";
          refreshTheme();
        });

        document.getElementById("fontInput").addEventListener("change", async event => {
          const files = Array.from(event.target.files || []);
          if (!files.length) return;
          await uploadFiles("/api/fonts/import", files);
          showNotice("字体导入完成");
          event.target.value = "";
          refreshFonts();
        });

        document.getElementById("localBookInput").addEventListener("change", async event => {
          const files = Array.from(event.target.files || []);
          if (!files.length) return;
          await uploadFiles("/api/localBooks/import", files);
          showNotice("本地书导入完成");
          event.target.value = "";
          refreshBookshelf();
        });

        document.getElementById("bookSourceInput").addEventListener("change", async event => {
          const files = Array.from(event.target.files || []);
          if (!files.length) return;
          await uploadFiles("/api/bookSources", files);
          showNotice("书源导入完成");
          event.target.value = "";
          refreshSources();
        });

        document.getElementById("replaceRuleInput").addEventListener("change", async event => {
          const files = Array.from(event.target.files || []);
          if (!files.length) return;
          await uploadFiles("/api/replaceRules", files);
          showNotice("替换规则导入完成");
          event.target.value = "";
          refreshReplaceRules();
        });

        refreshAll().catch(error => showNotice(error.message, "error"));
      </script>
    </body>
    </html>
    """#
}
