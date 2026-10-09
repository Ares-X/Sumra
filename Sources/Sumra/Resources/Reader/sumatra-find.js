/* Copyright 2024 the SumatraPDF project authors (see AUTHORS file).
   License: Simplified BSD (see Licenses/Sumatra-BSD-2-Clause.txt). */
// BrowserDocView.cpp kFindInPageJs, pinned 012d997f6a3a5c5c97b878e1a340db3bffde8c0e.
// Matching/Range mapping preserved; cancellation and WK bridge supplied by markdown.js.
(function(){
if (window.__sumatraFind) { return; }
var matches = [];
var cur = -1;
var curHl = null;
var gen = 0;
var styleDone = false;
var kMaxMatches = 5000;
var pendingYields = new Map();
function ensureStyle() {
  if (styleDone) { return; }
  styleDone = true;
  try {
    var ss = new CSSStyleSheet();
    ss.replaceSync("::highlight(sumatra-find){background-color:#ffee70;color:#000;} ::highlight(sumatra-find-cur){background-color:#ff9632;color:#000;}");
    document.adoptedStyleSheets = document.adoptedStyleSheets.concat([ss]);
  } catch (e) {}
}
function post() {
  window.__sumatra__.notify("findResult", gen, cur + 1, matches.length, matches.length >= kMaxMatches);
}
function isWordChar(text, offset, before) {
  var index = before ? offset - 1 : offset;
  // Match and Range offsets remain UTF-16; classify the complete adjacent
  // code point even when its surrogate pair spans text nodes or scan chunks.
  if (before && index > 0) {
    var trailing = text.charCodeAt(index), leading = text.charCodeAt(index - 1);
    if (trailing >= 0xdc00 && trailing <= 0xdfff && leading >= 0xd800 && leading <= 0xdbff) { index--; }
  }
  var code = text.codePointAt(index);
  if (code === undefined) { return false; }
  var c = String.fromCodePoint(code);
  return /[\p{L}\p{N}_]/u.test(c);
}
// Also used for documents parsed by DOMParser, which have no layout, so no
// computed-style checks here. Speech reuses the filter without building the
// search-only concatenated text and offset table.
function eligibleTextNode(n) {
  var p = n.parentElement;
  if (!p) { return false; }
  var tag = p.localName.toUpperCase();
  return tag !== "SCRIPT" && tag !== "STYLE" && tag !== "NOSCRIPT" && tag !== "TEXTAREA";
}
function textWalker(body) {
  return body.ownerDocument.createTreeWalker(body, NodeFilter.SHOW_TEXT, {
    acceptNode: function(n) { return eligibleTextNode(n) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT; }
  });
}
function textFromBody(body, indexed = true) {
  var nodes = [];
  var starts = [];
  var text = "";
  // Keep the same eligibility rule without a WebCore-to-JavaScript callback
  // for every text node while building the search index.
  var walker = body.ownerDocument.createTreeWalker(body, NodeFilter.SHOW_TEXT);
  var n;
  while ((n = walker.nextNode())) {
    if (!eligibleTextNode(n)) { continue; }
    if (indexed) { nodes.push(n); starts.push(text.length); }
    text += n.data;
  }
  return { nodes: nodes, starts: starts, text: text };
}
// Range boundaries identify the first and last eligible nodes once. Comparing
// each body node with a distant endpoint can repeatedly scan its sibling list.
function* textNodesInRange(range, root) {
  if (!range || range.collapsed) { return; }
  root = root || range.commonAncestorContainer;
  var walker = textWalker(root);
  function endpoint(container, offset, first) {
    var n = container, include = n.nodeType === Node.TEXT_NODE && (first || offset > 0);
    if (n.nodeType !== Node.TEXT_NODE) {
      if (first && offset < n.childNodes.length) { n = n.childNodes[offset]; include = true; }
      else if (!first && offset > 0 && offset <= n.childNodes.length) {
        n = n.childNodes[offset - 1];
        while (n.lastChild) { n = n.lastChild; }
        include = true;
      } else if (first) {
        while (n.lastChild) { n = n.lastChild; }
      }
    }
    walker.currentNode = n;
    if (include && n.nodeType === Node.TEXT_NODE && eligibleTextNode(n)) { return n; }
    return first ? walker.nextNode() : walker.previousNode();
  }
  var first = root.contains(range.startContainer)
    ? endpoint(range.startContainer, range.startOffset, true) : endpoint(root, 0, true);
  var last = root.contains(range.endContainer)
    ? endpoint(range.endContainer, range.endOffset, false)
    : endpoint(root, root.nodeType === Node.TEXT_NODE ? root.length : root.childNodes.length, false);
  // A body-root consumer can receive an HTML/head endpoint. Reject an empty
  // intersection before walking; never escape its supplied root.
  if (!first || !last || !range.intersectsNode(first) || !range.intersectsNode(last)) { return; }
  walker.currentNode = first;
  for (var n = first; n; n = walker.nextNode()) {
    yield n;
    if (n === last) { break; }
  }
}
function textFromRange(range) {
  var text = "";
  for (var n of textNodesInRange(range)) {
    var from = n === range.startContainer ? range.startOffset : 0;
    var to = n === range.endContainer ? range.endOffset : n.length;
    text += n.data.slice(from, to);
  }
  return text;
}
// Text scanning and first-visible-match layout traversal share the same input
// yield and cancellation ownership, including delayed message-task release.
function workSlice() {
  var deadline = performance.now() + 8, channel = null;
  return {
    pause: function() {
      if (performance.now() < deadline) { return null; }
      if (!channel) { channel = new MessageChannel(); }
      return new Promise(function(resolve) {
        var resume = function() {
          if (!pendingYields.delete(channel.port1)) { return; }
          deadline = performance.now() + 8;
          resolve();
        };
        pendingYields.set(channel.port1, resume);
        channel.port1.onmessage = resume;
        channel.port2.postMessage(null);
      });
    },
    close: function() {
      if (channel) {
        pendingYields.delete(channel.port1);
        channel.port1.close(); channel.port2.close();
      }
    }
  };
}
// Search the same concatenation of eligible nodes without retaining the whole
// text or a page-wide node index. Literal RegExp matching preserves UTF-16
// offsets in case-insensitive searches.
async function scanText(body, term, matchCase, wholeWord, withRanges, withSnippets, g, onMatch, matchLimit = kMaxMatches) {
  if (!term) { return true; }
  var esc = term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  var re = new RegExp(esc, matchCase ? "g" : "gi");
  var chunkSize = Math.max(65536, 2 * term.length + 81);
  var buffer = "", bufferStart = 0, scanPoint = 0, total = 0, count = 0;
  var pieces = [];
  var work = workSlice();
  function locate(off, isEnd) {
    var lo = 0, hi = pieces.length - 1, found = 0;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      var before = isEnd ? pieces[mid].start < off : pieces[mid].start <= off;
      if (before) { found = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    var piece = pieces[found];
    return [piece.node, piece.offset + off - piece.start];
  }
  async function process(final) {
    // A non-final hit needs one character beyond its trailing context to
    // decide whether its snippet ends with an ellipsis.
    var limit = final ? total : total - term.length - 40;
    var steps = 0;
    while (scanPoint < limit && count < matchLimit) {
      if ((steps++ & 127) === 0) {
        var pending = work.pause();
        if (pending) { await pending; }
        if (g !== gen) { return; }
      }
      re.lastIndex = scanPoint - bufferStart;
      var m = re.exec(buffer);
      if (!m || bufferStart + m.index >= limit) { scanPoint = limit; break; }
      var s = bufferStart + m.index, e = s + m[0].length;
      scanPoint = bufferStart + re.lastIndex;
      if (m.index === re.lastIndex) { scanPoint++; continue; }
      if (wholeWord) {
        if (isWordChar(buffer, s - bufferStart, true) || isWordChar(buffer, e - bufferStart, false)) { continue; }
      }
      count++;
      var from = withRanges ? locate(s, false) : null;
      var to = withRanges ? locate(e, true) : null;
      onMatch(from, to, withSnippets ? makeSnippet(buffer, bufferStart, total, s, e, final) : null);
    }
    if (!final && count < matchLimit) {
      var trimTo = Math.max(bufferStart, scanPoint - 40);
      if (trimTo > bufferStart) {
        buffer = buffer.slice(trimTo - bufferStart);
        bufferStart = trimTo;
        if (withRanges) {
          var drop = 0;
          while (drop < pieces.length && pieces[drop].start < trimTo && pieces[drop].end <= trimTo) { drop++; }
          if (drop) { pieces = pieces.slice(drop); }
        }
      }
    }
  }
  var walker = body.ownerDocument.createTreeWalker(body, NodeFilter.SHOW_TEXT);
  var node, visited = 0;
  try {
    while (count < matchLimit && (node = walker.nextNode())) {
      if ((visited++ & 127) === 0) {
        var pending = work.pause();
        if (pending) { await pending; }
        if (g !== gen) { return false; }
      }
      if (!eligibleTextNode(node)) { continue; }
      var data = node.data;
      if (!data.length) {
        // A start at this offset uses the last empty node; an end at this
        // offset still belongs to the preceding nonempty node.
        if (withRanges) {
          if (pieces.length && pieces[pieces.length - 1].start === total && pieces[pieces.length - 1].end === total) { pieces.pop(); }
          pieces.push({ start: total, end: total, node: node, offset: 0 });
        }
        continue;
      }
      for (var i = 0; i < data.length && count < matchLimit;) {
        var length = Math.min(data.length - i, chunkSize - (total - scanPoint));
        var part = data.slice(i, i + length);
        if (withRanges) { pieces.push({ start: total, end: total + length, node: node, offset: i }); }
        buffer += part;
        total += length;
        i += length;
        if (total - scanPoint >= chunkSize) {
          await process(false);
          if (g !== gen) { return false; }
        }
      }
    }
    if (count < matchLimit) { await process(true); }
    return g === gen;
  } finally {
    work.close();
  }
}
function makeSnippet(buffer, bufferStart, total, s, e, final) {
  var from = Math.max(0, s - 40);
  var to = Math.min(total, e + 40);
  var sn = buffer.slice(from - bufferStart, to - bufferStart).replace(/[\x00-\x1f]+/g, " ").replace(/\s+/g, " ").trim();
  if (from > 0) { sn = "..." + sn; }
  if (to < total || !final) { sn = sn + "..."; }
  return sn;
}
function clearHighlights() {
  // Cancellation must release retained scan work even if a hidden/cached
  // page's queued message task has not been dispatched.
  for (var resume of [...pendingYields.values()]) { resume(); }
  if (window.CSS && CSS.highlights) {
    CSS.highlights.delete("sumatra-find");
    CSS.highlights.delete("sumatra-find-cur");
  }
  matches = [];
  cur = -1;
  curHl = null;
}
function setCur(i, scroll) {
  if (matches.length === 0) { cur = -1; return; }
  cur = ((i % matches.length) + matches.length) % matches.length;
  if (curHl) {
    curHl.clear();
    curHl.add(matches[cur]);
  }
  if (scroll) {
    var r = window.leafFindRangeRect ? window.leafFindRangeRect(matches[cur]) : matches[cur].getBoundingClientRect();
    var viewport = document.compatMode === "BackCompat" ? document.body : document.documentElement;
    var width = viewport.clientWidth, height = viewport.clientHeight;
    var horizontal = r.left < 0 || r.right > width;
    var vertical = r.top < 0 || r.bottom > height;
    if (horizontal || vertical) {
      // Find selects a destination immediately, independently of authored
      // smooth scrolling and any pending asynchronous viewport scroll.
      window.scrollTo({
        left: horizontal ? window.scrollX + r.left - Math.max(0, (width - r.width) / 2) : window.scrollX,
        top: vertical ? window.scrollY + r.top - height / 3 : window.scrollY,
        behavior: "instant"
      });
    }
  }
}
// initIdx >= 0: make that match current (used when jumping to a match on a
// freshly loaded page); otherwise the first match at/below the viewport top
async function start(term, matchCase, wholeWord, g, initIdx, collectSnippets) {
  gen = g;
  clearHighlights();
  ensureStyle();
  if (!term) { post(); return; }
  // Custom Highlights are unavailable in older supported WebKit versions.
  // Matching and navigation still use the same Ranges without changing selection.
  var canHighlight = !!(window.CSS && CSS.highlights && window.Highlight);
  var all = canHighlight ? new Highlight() : null;
  var snippets = collectSnippets ? [] : null;
  var found = [];
  var completed = await scanText(document.body, term, matchCase, wholeWord, true, !!collectSnippets, g, function(st, en, snippet) {
    var r = document.createRange();
    try {
      r.setStart(st[0], st[1]);
      r.setEnd(en[0], en[1]);
      found.push(r);
      if (all) { all.add(r); }
    } catch (e) {}
    if (snippets) { snippets.push(snippet); }
  });
  if (!completed || g !== gen) { return; }
  matches = found;
  if (canHighlight) {
    CSS.highlights.set("sumatra-find", all);
    curHl = new Highlight();
    CSS.highlights.set("sumatra-find-cur", curHl);
  }
  if (matches.length > 0) {
    var first = 0;
    if (initIdx >= 0) {
      first = Math.min(initIdx, matches.length - 1);
    } else {
      var geometryCache = window.leafFindRangeRect ? new WeakMap() : null;
      var work = workSlice();
      try {
        for (var k = 0; k < matches.length; k++) {
          var pending = work.pause();
          if (pending) { await pending; }
          if (g !== gen) { return; }
          var rc = window.leafFindRangeRect ? window.leafFindRangeRect(matches[k], geometryCache) : matches[k].getBoundingClientRect();
          if (rc.bottom >= 0) { first = k; break; }
        }
      } finally {
        work.close();
      }
    }
    setCur(first, true);
  }
  post();
  // Pass only bounded snippets to this query's all-page scan.
  if (collectSnippets) { return snippets; }
}
function gotoMatch(i) {
  if (matches.length === 0) { post(); return; }
  setCur(i, true);
  post();
}
// search every page of the document (urls in page order); pages are fetched
// sequentially so the match records stay in page order
function searchAll(urls, term, matchCase, wholeWord, g, loadDocument, currentSnippets) {
  var recs = [];
  var parser = new DOMParser();
  var chain = Promise.resolve();
  urls.forEach(function(url, pi) {
    chain = chain.then(function() {
      if (g !== gen || recs.length >= kMaxMatches) { return; }
      // The CHM adapter supplies its existing charset/plain-text decoder.
      var loaded = loadDocument ? loadDocument(url) : fetch(url).then(function(r) { return r.text(); })
        .then(function(html) { return parser.parseFromString(html, "text/html"); });
      return loaded.then(async function(doc) {
        if (g !== gen) { return; }
        if (!doc.body) { return; }
        var snippets = currentSnippets;
        if (doc !== document || !snippets) {
          // Sibling documents need only the remaining global result budget,
          // and snippets rather than live-DOM Range positions.
          snippets = [];
          if (!await scanText(doc.body, term, matchCase, wholeWord, false, true, g,
              function(st, en, snippet) { snippets.push(snippet); }, kMaxMatches - recs.length)) { return; }
        }
        if (g !== gen) { return; }
        for (var i = 0; i < snippets.length && recs.length < kMaxMatches; i++) {
          recs.push((pi + 1) + "\x1f" + i + "\x1f" + snippets[i]);
        }
      }, function(error) {
        // An obsolete query's failed fetch is cancellation, but an active
        // scan must not publish a complete count after skipping a page.
        if (g !== gen) { return; }
        var name = new URL(url, location.href).pathname.split('/').pop();
        try { name = decodeURIComponent(name); } catch (e) {}
        throw new Error("Unable to search " + name + ": " + (error.message || String(error)), { cause: error });
      });
    });
  });
  return chain.then(function() {
    if (g !== gen) { return; }
    // Scanning stops at the boundary; the remaining total is unknown even
    // when the document happens to contain exactly this many matches.
    window.__sumatra__.notify("findAllResult", g, recs.length, recs.join("\x1e"), recs.length >= kMaxMatches);
  });
}
// Sumra's existing Find from Selection command uses the same match Ranges;
// it must not search a separately normalized string or overwrite the selection.
function indexFromRange(range, backwards) {
  var anchor = range.cloneRange();
  anchor.collapse(backwards);
  if (backwards) {
    for (var i = matches.length - 1; i >= 0; i--) {
      if (matches[i].compareBoundaryPoints(Range.END_TO_END, anchor) <= 0) { return i; }
    }
  } else {
    for (var i = 0; i < matches.length; i++) {
      if (matches[i].compareBoundaryPoints(Range.START_TO_START, anchor) >= 0) { return i; }
    }
  }
  return -1;
}
// Install Find rules with the initial reader styles so the first scan does not
// trigger a separate full-document style update after yielding.
ensureStyle();
window.__sumatraFind = { start: start, gotoMatch: gotoMatch, searchAll: searchAll, report: post, clear: function() { gen++; clearHighlights(); }, textWalker: textWalker, textNodesInRange: textNodesInRange, textFromBody: textFromBody, textFromRange: textFromRange, currentRange: function() { return matches[cur] || null; }, highlightRanges: function() { return curHl ? [] : matches; }, indexFromRange: indexFromRange };
})();
