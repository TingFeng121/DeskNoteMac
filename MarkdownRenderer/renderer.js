/*
 DeskNote 富阅读层。

 链路只有一条：markdown-it 解析 → DOMPurify 清洗 → 挂进 DOM → 后处理（callout、任务框、
 表格横滚、标题锚点、公式、Mermaid）。清洗在挂进 DOM 之前，后处理只搬运已经清洗过的节点，
 绝不再把正文里的字符串当 HTML 塞回去。

 和 Swift 侧的三个约定（改这里要同时改 LibraryRichReader.swift）：
   window.deskNoteRender({text, notePath, revision, fontSize, dark, palette})
   window.deskNoteSetOptions({fontSize, dark, palette})
   回消息：{action:'ready'} 桥通了 / {action:'open', target} 库内链接 / {action:'external', url} 外部链接

 链接和路径的口径跟原生阅读器保持一致：送出去的 target 是**一次**百分号编码后的原文，
 LibraryWorkspace.openLink 只解一次；图片 src 交给 desknote-image://local，由 Swift 侧
 先按文档目录、再按库根解析，并挡住跳出库外的路径。
*/
(function () {
  'use strict';

  var body = document.getElementById('note-body');
  var SCHEME_IMAGE = 'desknote-image://local';
  var CALLOUT_TYPES = {
    note: 1, abstract: 1, summary: 1, tldr: 1, info: 1,
    tip: 1, hint: 1, important: 1, success: 1, check: 1, done: 1,
    question: 1, help: 1, faq: 1, example: 1, quote: 1, cite: 1,
    warning: 1, caution: 1, attention: 1, todo: 1,
    failure: 1, danger: 1, error: 1, bug: 1, missing: 1
  };
  // 图片扩展名要跟 Swift 那边 UTType 认下来的一致；svg 单独处理，因为 Swift 侧的
  // scheme handler 明确屏蔽 public.svg-image（正文里手写的 svg 标签能渲染，附件里的不行）。
  var IMAGE_EXT = /(?:png|jpe?g|gif|webp|bmp|tiff?|heic|heif|avif|ico)$/i;
  var SVG_EXT = /\.svg$/i;
  var SCHEME_RE = /^[A-Za-z][A-Za-z0-9+.-]*:/;

  var current = { text: '', notePath: '', revision: -1 };
  var options = { fontSize: 14, dark: false };
  var renderSeq = 0;

  // ---------- markdown-it ----------

  var md = window.markdownit({
    html: true,          // 正文里的裸 HTML 交给 DOMPurify，而不是当场解析成文本
    linkify: false,      // Obsidian 也不把裸链接自动变蓝，保持字面
    breaks: false,
    langPrefix: 'desknote-lang-',
    typographer: false
  });
  if (window.markdownitFootnote) md.use(window.markdownitFootnote);

  var esc = md.utils.escapeHtml;
  var unescapeAll = md.utils.unescapeAll;

  function attrValue(token, name) {
    var list = token.attrs || [];
    for (var i = 0; i < list.length; i++) if (list[i][0] === name) return list[i][1];
    return '';
  }

  // 图片：库内相对路径改写进自定义 scheme，data: 与 http(s) 原样留着
  function imageHref(src) {
    var value = unescapeAll((src || '').trim());
    if (!value) return '';
    if (value.charCodeAt(0) === 0x23 /* # */) return value;
    if (SCHEME_RE.test(value)) return value;              // data: / http: / https: / mailto:
    if (value.charCodeAt(0) === 0x2F /* / */) return value;  // 绝对路径交给 Swift 判定，不在这里猜
    // markdown-it 在解析目的地时已经 encodeURI 过一次了，直接再编码会把 % 变成 %25。
    // 这里先解回来、再按 scheme 的参数编一次：Swift 侧解一次，拿到的就是原文，
    // 和原生阅读器 safeLocalImageURL 的 removingPercentEncoding 同一个口径。
    return SCHEME_IMAGE + '?note=' + encodeURIComponent(current.notePath) +
           '&target=' + encodeURIComponent(tryDecode(value));
  }

  function tryDecode(value) {
    try { return decodeURIComponent(value); } catch (e) { return value; }
  }

  md.renderer.rules.image = function (tokens, idx) {
    var token = tokens[idx];
    var alt = attrValue(token, 'alt') || '';
    var src = imageHref(attrValue(token, 'src'));
    if (!src) return esc(alt);
    // SVG 附件读不进来（Swift 侧挡），老实说一句，不摆破图
    if (SVG_EXT.test(src) && src.indexOf('data:') !== 0) {
      return '<span class="desknote-unsupported">SVG 附件暂不显示</span>';
    }
    return '<img class="desknote-img" src="' + esc(src) + '" alt="' + esc(alt) + '"' +
           (attrValue(token, 'title') ? ' title="' + esc(attrValue(token, 'title')) + '"' : '') +
           ' loading="lazy">';
  };

  // 代码块：mermaid 只留一个空壳，正文由后处理用 textContent 填回去（不进 HTML 字符串，少一处转义面）
  md.renderer.rules.fence = function (tokens, idx, options, env) {
    var token = tokens[idx];
    var info = unescapeAll(token.info || '').trim();
    var lang = info.split(/\s+/)[0].toLowerCase();
    if (lang === 'mermaid') {
      var slot = (env.__mermaid || (env.__mermaid = [])).push(token.content) - 1;
      return '<div class="desknote-mermaid" data-desknote-src="' + slot + '"></div>';
    }
    return codeBlock(token.content, lang);
  };

  md.renderer.rules.code_block = function (tokens, idx) {
    return codeBlock(tokens[idx].content, '');
  };

  function codeBlock(content, lang) {
    var known = lang && window.hljs && hljs.getLanguage(lang);
    var inner = esc(content);
    if (known) {
      try {
        inner = hljs.highlight(content, { language: lang, ignoreIllegals: true }).value;
      } catch (e) {
        inner = esc(content);
      }
    }
    return '<pre class="desknote-code"><code class="hljs' +
           (lang ? ' desknote-lang-' + esc(lang) : '') + '">' + inner + '</code></pre>';
  }

  // ---------- [[双向链接]] 与 ![[嵌入]] ----------

  function wikilink(state, silent) {
    var start = state.pos;
    var embed = state.src.charCodeAt(start) === 0x21 /* ! */;
    var open = embed ? start + 1 : start;
    if (state.src.charCodeAt(open) !== 0x5B /* [ */ || state.src.charCodeAt(open + 1) !== 0x5B) return false;
    var close = -1;
    for (var i = open + 2; i < state.posMax; i++) {
      var c = state.src.charCodeAt(i);
      if (c === 0x0A /* \n */) break;                     // 不跨行
      if (c === 0x5D && state.src.charCodeAt(i + 1) === 0x5D) { close = i; break; }
    }
    if (close < 0) return false;
    var raw = state.src.slice(open + 2, close);
    if (!raw.trim()) return false;
    if (silent) return true;

    var bar = raw.indexOf('|');
    var target = (bar < 0 ? raw : raw.slice(0, bar)).trim();
    var alias = bar < 0 ? '' : raw.slice(bar + 1).trim();
    if (!target) return false;

    var token = state.push('desknote_wiki', 'span', 0);
    token.meta = { embed: embed, target: target, alias: alias };
    state.pos = close + 2;
    return true;
  }
  // 排在 link 之后：[[x]] 走不通 link 的解析（label 后面等不到 '('），让 wikilink 接手
  md.inline.ruler.after('link', 'desknote_wiki', wikilink);

  md.renderer.rules.desknote_wiki = function (tokens, idx) {
    var m = tokens[idx].meta;
    // 带协议的 target 不做链接：Obsidian 的 [[…]] 只指库内笔记，写个 javascript: 也点不动
    if (SCHEME_RE.test(m.target)) return esc(m.alias || m.target);
    var hash = m.target.indexOf('#');
    var stem = hash < 0 ? m.target : m.target.slice(0, hash);
    var heading = hash < 0 ? '' : m.target.slice(hash + 1);

    if (m.embed && IMAGE_EXT.test(stem)) {
      var sizing = /^\d+(?:x\d+)?$/i.test(m.alias) ? m.alias : '';
      var width = sizing ? parseInt(sizing.split(/[xX]/)[0], 10) : 0;
      var src = imageHref(stem);
      if (!src) return esc(m.target);
      return '<img class="desknote-img"' + (width ? ' width="' + esc(String(width)) + '"' : '') +
             ' src="' + esc(src) + '" alt="' + esc(sizing ? '' : m.alias) + '" loading="lazy">';
    }
    if (m.embed) {
      // ![[某篇笔记]] 的转插在 DeskNote 里没实现，退化成一条点得动的链接
      return '<a class="desknote-internal desknote-embed" href="' + esc(wikiHref(m.target)) + '">' +
             esc('嵌入 ' + (heading || stem)) + '</a>';
    }
    return '<a class="desknote-internal" href="' + esc(wikiHref(m.target)) + '">' +
           esc(m.alias || m.target) + '</a>';
  };

  function wikiHref(target) {
    return encodeURI(target);
  }

  // ---------- 公式 ----------

  // 不让 auto-render 去全量扫 `$…$`：那会把「价格 $5 和 $10」也认成公式。
  // 这里自己定口径，跟 Obsidian / markdown-it-katex 一致：开 $ 后紧跟非空白、
  // 闭 $ 前不留空白，且闭 $ 后面不能是数字。auto-render 只留着处理 \( \) 与 \[ \]。
  var INLINE_MATH_RE = /^\$(?![\s$])((?:\\.|[^\\$\n])+?)(?<![\s\\])\$(?!\d)/;
  var INLINE_DISPLAY_RE = /^\$\$((?:\\.|[^\\$])+)\$\$/;

  function inlineMath(state, silent) {
    if (state.src.charCodeAt(state.pos) !== 0x24 /* $ */) return false;
    var rest = state.src.slice(state.pos);
    var display = INLINE_DISPLAY_RE.exec(rest);
    if (display && display[1].trim()) {
      // 一行里写完的 $$x$$：按展示式排，别退化成「行内公式 + 一个多的 $」
      if (silent) return true;
      var block = state.push('math_inline', 'span', 0);
      block.content = display[1].trim();
      block.meta = { display: true };
      block.markup = '$$';
      state.pos += display[0].length;
      return true;
    }
    var match = INLINE_MATH_RE.exec(rest);
    if (!match) return false;
    if (silent) return true;
    var token = state.push('math_inline', 'span', 0);
    token.content = match[1];
    token.markup = '$';
    state.pos += match[0].length;
    return true;
  }
  md.inline.ruler.after('image', 'math_inline', inlineMath);

  function mathBlock(state, startLine, endLine, silent) {
    var line = state.src.slice(state.bMarks[startLine] + state.tShift[startLine],
                               state.eMarks[startLine]);
    if (line.slice(0, 2) !== '$$') return false;
    if (silent) return true;

    var token;
    var tail = line.slice(2);
    if (tail.length >= 2 && tail.slice(-2) === '$$' && tail.slice(0, -2).trim()) {
      // $$E=mc^2$$ 写在一行里
      token = state.push('math_block', 'span', 0);
      token.block = true;
      token.content = tail.slice(0, -2).trim();
      token.map = [startLine, startLine + 1];
      state.line = startLine + 1;
      return true;
    }

    var lines = tail.trim() ? [tail.trim()] : [];
    var next = startLine + 1;
    for (; next < endLine; next++) {
      var text = state.src.slice(state.bMarks[next] + state.tShift[next], state.eMarks[next]);
      if (text.trim() === '$$') {
        token = state.push('math_block', 'span', 0);
        token.block = true;
        token.content = lines.join('\n');
        token.map = [startLine, next + 1];
        state.line = next + 1;
        return true;
      }
      lines.push(text);
    }
    // 找不到闭合的 $$ 不当公式：宁可这一行照段落排，也不把后面整篇吞进数学里
    return false;
  }
  md.block.ruler.before('fence', 'math_block', mathBlock, { alt: ['paragraph', 'blockquote'] });

  function katexHTML(source, display) {
    if (!window.katex) return display ? '<p>' + esc(source) + '</p>' : esc(source);
    try {
      return katex.renderToString(source, {
        displayMode: !!display,
        throwOnError: false,
        strict: 'ignore',
        output: 'html'
      });
    } catch (e) {
      return '<span class="katex-error">' + esc(source) + '</span>';
    }
  }
  md.renderer.rules.math_inline = function (tokens, idx) {
    var meta = tokens[idx].meta;
    return katexHTML(tokens[idx].content, !!(meta && meta.display));
  };
  md.renderer.rules.math_block = function (tokens, idx) { return katexHTML(tokens[idx].content, true) + '\n'; };

  // ---------- 清洗 ----------

  var PURIFY_CONFIG = {
    FORBID_TAGS: ['style', 'link', 'meta', 'base', 'title', 'form', 'input', 'button',
                  'textarea', 'select', 'option', 'iframe', 'object', 'embed',
                  'audio', 'video', 'source', 'track'],
    FORBID_ATTR: ['srcset', 'formaction', 'ping', 'xlink:href'],
    ALLOW_DATA_ATTR: true,
    ADD_ATTR: ['loading', 'target', 'rel', 'colspan', 'rowspan', 'align',
               'data-desknote-src'],
    // DOMPurify 默认只放行 http/https/mailto 那一组，自家的 desknote-image: 和正文里的
    // data:image 不在里面，<img> 的 src 会被整条删掉。这条是在**默认式样上追加**三个协议：
    // 默认的 `[^a-z]` 与 `[a-z+.-]+(?:[^a-z+.-:]|$)` 两支必须留着，否则「其它文档.md」这类
    // 相对路径会被当成不合法 URI 整条删掉，链接和图片一起点不动。
    // 放行 data:/blob: 的风险由另外两道闸兜住：链接一律走点击代理（未知协议直接不动），
    // 导航则由 Swift 的 decidePolicyFor 全数拦下。
    ALLOWED_URI_REGEXP: /^(?:(?:desknote-image|data|blob):|(?:(?:f|ht)tps?|mailto|tel|callto|sms|cid|xmpp):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i
  };

  // RETURN_DOM：清洗结果直接是节点，省掉「拼字符串再 innerHTML 解析一遍」这一步——
  // 少一次解析就少一处能被绕开的地方。
  function sanitizeInto(html, target) {
    while (target.firstChild) target.removeChild(target.firstChild);
    if (!window.DOMPurify) return false;
    var config = Object.assign({ RETURN_DOM: true, WHOLE_DOCUMENT: false }, PURIFY_CONFIG);
    var clean = DOMPurify.sanitize(html, config);
    while (clean.firstChild) target.appendChild(clean.firstChild);
    return true;
  }

  // ---------- 后处理 ----------

  function hydrate(root, env) {
    rewriteRawImages(root);
    wrapImages(root);
    wrapTables(root);
    foldCallouts(root);
    markTaskItems(root);
    labelHeadings(root);
    renderMath(root);
    renderMermaid(root, env.__mermaid || []);
  }

  function wrapTables(root) {
    var tables = root.querySelectorAll('table');
    for (var i = 0; i < tables.length; i++) {
      var wrapper = document.createElement('div');
      wrapper.className = 'desknote-table-scroll';
      tables[i].parentNode.insertBefore(wrapper, tables[i]);
      wrapper.appendChild(tables[i]);
    }
  }

  // GFM / Obsidian 的 > [!类型] 块引用。markdown-it 已经渲染成 blockquote，这里把标记摘掉、
  // 标题按第一行切开，剩下的留在原位当正文。搬运的是已清洗节点，不重拼 HTML 字符串。
  // 标记只在纯文本里出现，所以按字符数从第一个文本节点往后扣。
  // 行尾故意不加 $：`(.*)` 到换行为止，而 JS 的 $ 只认整串结尾，加了就永远匹配不上。
  var CALLOUT_RE = /^(\s*\[!([A-Za-z]+)\]([+-]?)[ \t]*)(.*)/;

  function foldCallouts(root) {
    var quotes = Array.prototype.slice.call(root.querySelectorAll('blockquote'));
    for (var i = 0; i < quotes.length; i++) {
      var quote = quotes[i];
      var first = quote.firstElementChild;
      if (!first || !/^p$/i.test(first.tagName)) continue;
      var match = CALLOUT_RE.exec(first.textContent || '');
      if (!match) continue;
      var type = match[2].toLowerCase();
      if (!CALLOUT_TYPES[type]) continue;

      var title = document.createElement('div');
      title.className = 'desknote-callout-title';
      moveToTitle(first, title, match[1].length);
      if (!title.childNodes.length) title.appendChild(document.createTextNode(capitalize(type)));

      // 标记把整段用完了（`> [!note]` 光杆一个），空段落不留在正文里
      if (!first.childNodes.length) quote.removeChild(first);

      var content = document.createElement('div');
      content.className = 'desknote-callout-body';
      while (quote.firstChild) content.appendChild(quote.firstChild);

      var card = document.createElement('div');
      card.className = 'desknote-callout';
      card.setAttribute('data-type', type);
      card.appendChild(title);
      if (content.firstChild) card.appendChild(content);

      if (match[3]) {
        card.classList.add('is-foldable');
        if (match[3] === '-') card.classList.add('is-collapsed');
        title.addEventListener('click', toggleCallout);
      }
      quote.parentNode.replaceChild(card, quote);
    }
  }

  /// 从段落开头扣掉 markerLength 个字符，把剩下**第一行**的节点搬进 title。
  /// 碰到换行就收口，换行后的内容留在段落里当正文。
  function moveToTitle(paragraph, title, markerLength) {
    var skip = markerLength;
    while (paragraph.firstChild) {
      var node = paragraph.firstChild;
      var isText = node.nodeType === 3;
      if (skip > 0) {
        if (!isText) { paragraph.removeChild(node); continue; }
        var text = node.nodeValue || '';
        if (text.length > skip) { node.nodeValue = text.slice(skip); skip = 0; }
        else { skip -= text.length; paragraph.removeChild(node); continue; }
      }
      if (isText) {
        var line = node.nodeValue || '';
        var brk = line.indexOf('\n');
        // 标题只取第一行；换行之后的一律留回段落里当正文
        if (brk >= 0) {
          title.appendChild(document.createTextNode(line.slice(0, brk)));
          node.nodeValue = line.slice(brk + 1);
          return;
        }
      }
      paragraph.removeChild(node);
      title.appendChild(node);
    }
  }

  function toggleCallout(event) {
    event.currentTarget.parentNode.classList.toggle('is-collapsed');
  }

  function capitalize(text) { return text.charAt(0).toUpperCase() + text.slice(1); }

  var TASK_RE = /^\s*\[([ xX])\][ \t]?/;

  function markTaskItems(root) {
    var items = root.querySelectorAll('li');
    for (var i = 0; i < items.length; i++) {
      var li = items[i];
      var holder = li.firstElementChild && /^p$/i.test(li.firstElementChild.tagName) ? li.firstElementChild : li;
      var node = holder.firstChild;
      if (!node || node.nodeType !== 3) continue;
      var match = TASK_RE.exec(node.nodeValue || '');
      if (!match) continue;
      var done = match[1].toLowerCase() === 'x';
      node.nodeValue = node.nodeValue.slice(match[0].length);
      if (!node.nodeValue) holder.removeChild(node);
      li.classList.add('desknote-task');
      if (done) li.classList.add('is-done');
      var box = document.createElement('span');
      box.className = 'desknote-box';
      // 只读视图：勾是画出来的，不是点出来的（改正文是编辑器的事）
      box.textContent = done ? '☑' : '☐';
      holder.insertBefore(box, holder.firstChild);
    }
  }

  function labelHeadings(root) {
    var heads = root.querySelectorAll('h1, h2, h3, h4, h5, h6');
    for (var i = 0; i < heads.length; i++) {
      var head = heads[i];
      head.setAttribute('data-desknote-heading', (head.textContent || '').trim());
      if (!head.id) head.id = 'desknote-h-' + i;
    }
  }

  function renderMath(root) {
    if (!window.renderMathInElement) return;
    // $ 与 $$ 已经在解析阶段处理过了，这里只剩 LaTeX 括号写法
    try {
      renderMathInElement(root, {
        delimiters: [
          { left: '\\[', right: '\\]', display: true },
          { left: '\\(', right: '\\)', display: false }
        ],
        ignoredTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code', 'option', 'kbd'],
        throwOnError: false,
        errorColor: '#b83d2e'
      });
    } catch (e) { /* 公式坏了不影响正文 */ }
  }

  // 正文里手写的 <img src="附件/a.png"> 不经过 markdown-it 的图片规则，相对路径会按
  // renderer 目录去解析，读不到库内附件。这里补上同一条 scheme 口径。
  function rewriteRawImages(root) {
    var images = root.querySelectorAll('img');
    for (var i = 0; i < images.length; i++) {
      var raw = images[i].getAttribute('src');
      if (!raw || SCHEME_RE.test(raw) || raw.charAt(0) === '#') continue;
      images[i].setAttribute('src', imageHref(raw));
      images[i].classList.add('desknote-img');
    }
    for (var j = 0; j < images.length; j++) {
      // 用属性而不是 HTML 里的 loading="lazy"：清洗环节会不会留下这个属性不由我们定
      images[j].loading = 'lazy';
      images[j].addEventListener('error', markImageMissing);
    }
  }

  // 附件被移走 / SVG / 超出限额时，Swift 那边返回失败。破图标换成一句实话。
  function markImageMissing(event) {
    var image = event.currentTarget;
    var note = document.createElement('span');
    note.className = 'desknote-unsupported';
    note.textContent = image.getAttribute('alt')
      ? '读不到「' + image.getAttribute('alt') + '」'
      : '这张图读不到了';
    // 图片若是被包在缩放框里，整框一起摘掉，免得留下一个空框加把手
    var frame = image.closest ? image.closest('.desknote-img-frame') : null;
    if (frame && frame.parentNode) frame.parentNode.replaceChild(note, frame);
    else if (image.parentNode) image.parentNode.replaceChild(note, image);
  }

  // 图片缩放：每张 .desknote-img 包一层固定宽度的框，右下角挂拖拽把手，
  // 跟原生阅读器 ResizableImageFrame 一个手感（只改视图宽度，不落盘正文）。
  var MIN_IMG_WIDTH = 60;
  var MAX_IMG_WIDTH = 720;

  function wrapImages(root) {
    var images = root.querySelectorAll('img.desknote-img');
    for (var i = 0; i < images.length; i++) {
      var img = images[i];
      if (img.closest && img.closest('.desknote-img-frame')) continue;   // 已包过，不重复
      var frame = document.createElement('span');
      frame.className = 'desknote-img-frame';
      img.parentNode.insertBefore(frame, img);
      frame.appendChild(img);

      var attrWidth = parseInt(img.getAttribute('width') || '0', 10);
      var initial = (attrWidth >= MIN_IMG_WIDTH && attrWidth <= MAX_IMG_WIDTH) ? attrWidth : 480;
      frame.style.width = initial + 'px';

      var handle = document.createElement('span');
      handle.className = 'desknote-img-resize';
      handle.title = '拖拽右下角缩放图片宽度';
      handle.innerHTML = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" ' +
        'stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">' +
        '<path d="M12 6 L6 12"/><path d="M14 10 L10 14"/><path d="M9 4 L4 9"/></svg>';
      frame.appendChild(handle);
      attachResize(handle, frame);
    }
  }

  function attachResize(handle, frame) {
    handle.addEventListener('mousedown', function (event) {
      event.preventDefault();
      var startX = event.clientX;
      var startWidth = frame.getBoundingClientRect().width;
      var prevSelect = document.body.style.userSelect;
      document.body.style.userSelect = 'none';
      document.body.style.cursor = 'ew-resize';
      function onMove(e) {
        var delta = e.clientX - startX;
        var next = Math.min(MAX_IMG_WIDTH, Math.max(MIN_IMG_WIDTH, startWidth + delta));
        frame.style.width = next + 'px';
      }
      function onUp() {
        document.removeEventListener('mousemove', onMove);
        document.removeEventListener('mouseup', onUp);
        document.body.style.userSelect = prevSelect;
        document.body.style.cursor = '';
      }
      document.addEventListener('mousemove', onMove);
      document.addEventListener('mouseup', onUp);
    });
  }


  // ---------- Mermaid ----------

  var mermaidPromise = null;
  function mermaidLibrary() {
    if (window.mermaid) return Promise.resolve(window.mermaid);
    var script = document.getElementById('desknote-mermaid-script');
    if (!script) return Promise.resolve(null);
    if (!mermaidPromise) {
      mermaidPromise = new Promise(function (resolve) {
        script.addEventListener('load', function () { resolve(window.mermaid || null); }, { once: true });
        script.addEventListener('error', function () { resolve(null); }, { once: true });
      });
    }
    return mermaidPromise;
  }

  function mermaidTargets(root) {
    var nodes = root.querySelectorAll('.desknote-mermaid');
    var targets = [];
    for (var i = 0; i < nodes.length; i++) {
      var slot = nodes[i].getAttribute('data-desknote-src');
      if (slot === null) continue;
      targets.push(nodes[i]);
    }
    return targets;
  }

  function renderMermaid(root, sources) {
    var targets = mermaidTargets(root);
    if (!targets.length) return;
    for (var i = 0; i < targets.length; i++) {
      var source = sources[parseInt(targets[i].getAttribute('data-desknote-src'), 10)] || '';
      // 先落原文：mermaid 取不到、加载失败或语法坏了，读者看到的至少是那段代码，不是一块空白
      targets[i].textContent = source;
      targets[i].setAttribute('data-source', source);
    }
    mermaidLibrary().then(function (mermaid) {
      if (!mermaid) return;
      runMermaid(mermaid, targets);
    }).catch(function () { markMermaidFailed(targets); });
  }

  function runMermaid(mermaid, targets) {
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      theme: options.dark ? 'dark' : 'default',
      fontFamily: '-apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif'
    });
    var settled;
    try {
      settled = mermaid.run({ nodes: targets });
    } catch (e) {
      markMermaidFailed(targets);
      return Promise.resolve();
    }
    if (!settled || typeof settled.then !== 'function') return Promise.resolve();
    return settled.catch(function () { markMermaidFailed(targets); });
  }

  function markMermaidFailed(nodes) {
    for (var i = 0; i < nodes.length; i++) nodes[i].classList.add('is-error');
  }

  // 深浅色切换后重画：mermaid 的图是烘进 SVG 的，跟着主题重来一轮比打补丁干净
  function repaintMermaidTheme() {
    var targets = mermaidTargets(body);
    if (!targets.length) return;
    mermaidLibrary().then(function (mermaid) {
      if (!mermaid) return;
      for (var i = 0; i < targets.length; i++) {
        targets[i].innerHTML = '';
        targets[i].textContent = targets[i].getAttribute('data-source') || '';
      }
      runMermaid(mermaid, targets);
    });
  }

  // ---------- 点击 ----------

  function post(message) {
    var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.deskNoteReader;
    if (handler && handler.postMessage) handler.postMessage(message);
  }

  body.addEventListener('click', function (event) {
    var link = event.target && event.target.closest ? event.target.closest('a') : null;
    if (!link || !body.contains(link)) return;
    var href = link.getAttribute('href');
    if (href === null) return;
    event.preventDefault();

    if (href.charAt(0) === '#') {                       // 页内锚点：标题、脚注、回跳
      scrollToHeading(decodeFragment(href.slice(1)));
      return;
    }
    if (/^(?:https?|mailto):/i.test(href) || href.indexOf('//') === 0) {
      post({ action: 'external', url: href });
      return;
    }
    if (SCHEME_RE.test(href)) return;                   // javascript: 之类走到这里一律不动
    // 库内链接：把一次编码后的原文交给 Swift，和原生阅读器同一个口径
    post({ action: 'open', target: href });
  });

  function decodeFragment(value) {
    try { return decodeURIComponent(value); } catch (e) { return value; }
  }

  function scrollToHeading(text) {
    if (!text) { window.scrollTo(0, 0); return; }
    var heads = body.querySelectorAll('h1, h2, h3, h4, h5, h6');
    var squeezed = text.replace(/\s+/g, '');
    for (var i = 0; i < heads.length; i++) {
      var label = heads[i].getAttribute('data-desknote-heading') || '';
      if (label === text || label.replace(/\s+/g, '') === squeezed) {
        heads[i].scrollIntoView({ block: 'start' });
        return;
      }
    }
    var direct = document.getElementById(text);
    if (direct) direct.scrollIntoView({ block: 'start' });
  }

  // ---------- 对外接口 ----------

  function applyOptions(next) {
    if (typeof next.fontSize === 'number' && isFinite(next.fontSize)) {
      options.fontSize = Math.min(Math.max(next.fontSize, 8), 48);
    }
    if (typeof next.dark === 'boolean') options.dark = next.dark;
    var root = document.documentElement;
    root.style.setProperty('--note-size', options.fontSize + 'px');
    root.setAttribute('data-tone', options.dark ? 'dark' : 'light');
    if (next.palette) applyPalette(next.palette);
  }

  // 颜色字符串来自 Swift，理论上永远是 #rrggbb；仍按不可信输入处理，不许它塞进 style
  function applyPalette(palette) {
    var root = document.documentElement;
    setIfColor(root, '--panel', palette.panel);
    setIfColor(root, '--ink', palette.ink);
    setIfColor(root, '--meta', palette.meta);
    setIfColor(root, '--accent', palette.accent);
  }

  function setIfColor(element, name, value) {
    if (typeof value === 'string' && /^#[0-9A-Fa-f]{6}$/.test(value)) element.style.setProperty(name, value);
  }

  function render(payload) {
    var data = payload || {};
    var text = typeof data.text === 'string' ? data.text : '';
    var notePath = typeof data.notePath === 'string' ? data.notePath : '';
    var revision = typeof data.revision === 'number' ? data.revision : -1;
    if (text === current.text && notePath === current.notePath && revision === current.revision) return;

    var seq = ++renderSeq;
    if (data.palette) applyPalette(data.palette);
    applyOptions({ fontSize: data.fontSize, dark: data.dark });
    current = { text: text, notePath: notePath, revision: revision };

    if (!text.trim()) {
      body.className = 'is-empty';
      while (body.firstChild) body.removeChild(body.firstChild);
      body.appendChild(document.createTextNode('这篇文档还没有正文。'));
      return;
    }
    body.className = '';
    var env = {};
    var html;
    try {
      html = md.render(text, env);
    } catch (e) {
      html = '<p>' + esc(text) + '</p>';
    }
    if (!sanitizeInto(html, body)) return;
    // 连点两篇时旧的那版不能盖住新的
    if (seq !== renderSeq) return;
    hydrate(body, env);
  }

  window.deskNoteRender = render;
  window.deskNoteSetOptions = function (next) {
    var data = next || {};
    var wasDark = options.dark;
    applyOptions(data);
    if (typeof data.dark === 'boolean' && data.dark !== wasDark) repaintMermaidTheme();
  };
  // 给 Swift 侧一个「桥通了」的凭据：Coordinator 收到这条才开始送正文
  post({ action: 'ready' });
})();
