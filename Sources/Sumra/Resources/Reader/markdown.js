// BrowserDocView / MarkdownModel bridge, SumatraPDF 012d997f6a3a5c5c97b878e1a340db3bffde8c0e.
// GPL-3.0-or-later. WebKit owns the ordinary scrolling document; no pagination layer.
(() => {
    const config = window.sumraDocument, initial = config.initial, pages = config.pages
    const mainFrame = window === window.top
    const post = (type, values = {}) => window.webkit.messageHandlers.leaf.postMessage({ type, ...values })
    const localURL = value => {
        if (!config.chm) return new URL(value, location.href)
        const path = String(value).replace(/^(?:mk:@MSITStore:|ms-its:|its:).*?::\/?/i, '/')
            .replace(/\\/g, '/').replace(/%(?![\da-f]{2})/gi, '%25')
        const url = path.startsWith('/') ? new URL(path.replace(/^\/+/, ''), 'leaf://book/entry/') : new URL(path, location.href)
        const page = pages.find(page => new URL(page).pathname.toLowerCase() === url.pathname.toLowerCase())
        if (page) { const canonical = new URL(page); canonical.hash = url.hash; return canonical }
        return url
    }
    const childReaders = () => [...document.querySelectorAll('frame,iframe')].flatMap(frame => {
        try { return frame.contentWindow?.leafCommand ? [frame.contentWindow] : [] } catch { return [] }
    })
    const focusedReader = () => {
        try { return document.activeElement?.contentWindow?.leafCommand ? document.activeElement.contentWindow : null } catch { return null }
    }
    const withoutHash = value => { const url = new URL(value, location.href); url.hash = ''; return url.href }
    const currentPage = (() => {
        const here = new URL(location.href).pathname
        const exact = pages.findIndex(page => config.chm ? new URL(page).pathname.toLowerCase() === here.toLowerCase() : new URL(page).pathname === here)
        if (exact >= 0) return exact
        // MarkdownModel's generated .html links are aliases for actual Markdown files.
        const canonical = value => new URL(value, location.href).pathname.replace(/\.(md|markdown|html)$/i, '')
        const alias = pages.findIndex(page => canonical(page) === canonical(here))
        return alias >= 0 ? alias : config.page
    })()
    const pageIndex = () => currentPage
    const pageURL = () => pages[pageIndex()] || withoutHash(location.href)
    const finder = window.__sumatraFind
    let typography = initial.text, userCSS = initial.userCSS || '', useDocumentCSS = initial.useDocumentCSS !== false
    let margins = initial.pageMargins || [], interaction = {}, linkDigits = '', pointer = null
    let searchGeneration = 0, searchKey = '', searchOptions = null, hits = [], hitsCapped = false, selected = -1, scan = null, searchAbort = null
    let speechNodes = [], speechRange = null, restoring = false, ready = false
    let activationRevision = 0, restoreRevision = 0
    let printViewport = null
    let readingViewport = null
    let previewLink = null, previewTitle = null
    let outlineLoad = null, outlineDemand = false
    const searchPrefix = '#sumra-search='
    const searchTarget = (page, index, options = searchOptions) => {
        const url = new URL(pages[page]); url.hash = 'sumra-search=' + encodeURIComponent(JSON.stringify({ ...options, index }))
        return url.href
    }
    const selection = () => window.getSelection()
    const selectionReader = () => focusedReader() || (selection()?.isCollapsed
        ? childReaders().find(reader => reader.leafHasSelection()) : null)
    const selectedText = () => selectionReader()?.leafSelectedText() || selection()?.toString() || ''
    window.leafSelectedText = selectedText
    const hasSelection = () => selectionReader()?.leafHasSelection() || !!selection()?.rangeCount && !selection().isCollapsed
    window.leafHasSelection = hasSelection
    const reportSelection = () => mainFrame ? post('selection', { selected: hasSelection() }) : window.top.leafReportSelection?.()
    window.leafReportSelection = reportSelection
    // Older supported WebKit versions lack Custom Highlights. Keep the DOM
    // and Selection intact; AppKit paints these visible viewport rectangles.
    let highlightZoom = initial.zoom || 1
    const viewportClip = (points, width, height) => {
        const clip = (poly, axis, value, greater) => {
            const output=[];
            for(let i=0;i<poly.length;i++) {
                const a=poly[i],b=poly[(i+1)%poly.length];
                const inside=p=>greater?p[axis]>=value:p[axis]<=value;
                const ai=inside(a),bi=inside(b);
                if(ai)output.push(a);
                if(ai!==bi){const t=(value-a[axis])/(b[axis]-a[axis]);output.push([a[0]+t*(b[0]-a[0]),a[1]+t*(b[1]-a[1])]);}
            }
            return output;
        };
        for(const [axis,value,greater] of [[0,0,true],[1,0,true],[0,width,false],[1,height,false]])points=clip(points,axis,value,greater);
        return points.length>=3?points:[];
    };
    const mapFramePolygon = (frame, points, zoom) => {
        const win=frame.ownerDocument.defaultView,style=win.getComputedStyle(frame);
        if(!win.webkitConvertPointFromNodeToPage || !win.WebKitPoint)throw Error('Frame point conversion unavailable');
        const left=(parseFloat(style.borderLeftWidth)||0)+(parseFloat(style.paddingLeft)||0);
        const top=(parseFloat(style.borderTopWidth)||0)+(parseFloat(style.paddingTop)||0);
        return viewportClip(points.map(([x,y])=>{
            // WebKit's renderer-local input and absolute-page output use zoomed units.
            const p=win.webkitConvertPointFromNodeToPage(frame,new win.WebKitPoint((left+x)*zoom,(top+y)*zoom));
            const viewport=win.visualViewport;
            return [p.x/zoom-(viewport ? viewport.pageLeft-viewport.offsetLeft : win.scrollX),
                p.y/zoom-(viewport ? viewport.pageTop-viewport.offsetTop : win.scrollY)];
        }),win.innerWidth,win.innerHeight);
    };
    const svgTextNode = node => node?.nodeType === Node.TEXT_NODE &&
        node.parentElement?.closest('text,tspan,textPath')?.namespaceURI === 'http://www.w3.org/2000/svg';
    const rangeContainsSVGText = range => {
        const start = range.startContainer, end = range.endContainer;
        if (svgTextNode(start) || svgTextNode(end)) return true;
        if (start.nodeType !== Node.TEXT_NODE || end.nodeType !== Node.TEXT_NODE || start === end) return false;
        const walker = start.ownerDocument.createTreeWalker(range.commonAncestorContainer, NodeFilter.SHOW_TEXT);
        walker.currentNode = start;
        let node;
        while ((node = walker.nextNode())) {
            if (svgTextNode(node)) return true;
            if (node === end) break;
        }
        return false;
    };
    // WebKit's SVG Range rect can be above the painted glyph. Map DOM UTF-16
    // offsets through SVG's whitespace handling, then let SVG own glyph layout.
    // Reject modes we cannot map and verify the expected addressable count.
    const svgTextIndex = (node, cache) => {
        const doc = node.ownerDocument, win = doc.defaultView;
        const element = node.parentElement?.closest('text');
        if (!(element instanceof win.SVGTextContentElement) || element.namespaceURI !== 'http://www.w3.org/2000/svg') return null;
        if (cache?.has(element)) return cache.get(element);
        const whiteSpace = win.getComputedStyle(element).whiteSpace;
        if (!['normal', 'nowrap', 'pre', 'pre-wrap', 'break-spaces'].includes(whiteSpace) ||
            [...element.querySelectorAll('tspan,textPath')].some(child => win.getComputedStyle(child).whiteSpace !== whiteSpace)) return null;
        const walker = doc.createTreeWalker(element, NodeFilter.SHOW_TEXT), starts = new Map();
        let raw = '', part;
        while ((part = walker.nextNode())) { starts.set(part, raw.length); raw += part.data; }
        const indices = Array(raw.length).fill(-1);
        let rendered = 0;
        if (['pre', 'pre-wrap', 'break-spaces'].includes(whiteSpace)) {
            for (let i = 0; i < raw.length; i++) indices[i] = rendered++;
        } else {
            for (let i = 0; i < raw.length;) {
                if (/[ \t\n\r\f]/.test(raw[i])) {
                    let end = i + 1;
                    while (end < raw.length && /[ \t\n\r\f]/.test(raw[end])) end++;
                    if (rendered && end < raw.length) {
                        for (let j = i; j < end; j++) indices[j] = rendered;
                        rendered++;
                    }
                    i = end;
                } else indices[i++] = rendered++;
            }
        }
        const result = rendered === element.getNumberOfChars() ? {element, starts, indices} : null;
        cache?.set(element, result);
        return result;
    };
    const svgGlyphRects = (node, from, to, cache) => {
        const doc = node.ownerDocument, win = doc.defaultView;
        const indexed = svgTextIndex(node, cache);
        if (!indexed) return null;
        const {element, starts, indices} = indexed;
        const offset = starts.get(node);
        if (offset === undefined) return null;
        const matrix = element.getScreenCTM();
        if (!matrix) return null;
        const rects = [];
        try {
            for (let i = from; i < to; i++) {
                const index = indices[offset + i];
                if (index < 0) continue; // Collapsed leading/trailing whitespace.
                const glyph = element.getExtentOfChar(index);
                const corners = [[glyph.x, glyph.y], [glyph.x + glyph.width, glyph.y],
                    [glyph.x + glyph.width, glyph.y + glyph.height], [glyph.x, glyph.y + glyph.height]];
                const points = corners.map(([x, y]) => new win.DOMPoint(x, y).matrixTransform(matrix));
                const left = Math.min(...points.map(p => p.x)), top = Math.min(...points.map(p => p.y));
                const right = Math.max(...points.map(p => p.x)), bottom = Math.max(...points.map(p => p.y));
                if (![left, top, right, bottom].every(Number.isFinite)) return null;
                const last = rects.at(-1);
                if (last && Math.abs(last.top - top) < 0.5 && Math.abs(last.bottom - bottom) < 0.5 &&
                    left <= last.right + 0.5 && right >= last.left - 0.5) {
                    last.left = Math.min(last.left, left); last.right = Math.max(last.right, right);
                } else rects.push({left, top, right, bottom});
            }
        } catch { return null; }
        return rects;
    };
    window.leafFindRangeRect = (range, svgIndexCache) => {
        if (!rangeContainsSVGText(range)) return range.getBoundingClientRect();
        const doc = range.startContainer.ownerDocument, root = range.commonAncestorContainer;
        const walker = root.nodeType === Node.TEXT_NODE ? null : doc.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        if (walker) walker.currentNode = range.startContainer;
        const rects = [];
        let node = range.startContainer;
        do {
            if (node.nodeType !== Node.TEXT_NODE) return range.getBoundingClientRect();
            const from = node === range.startContainer ? range.startOffset : 0;
            const to = node === range.endContainer ? range.endOffset : node.length;
            if (to > from) {
                const part = doc.createRange(); part.setStart(node, from); part.setEnd(node, to);
                const glyphs = svgTextNode(node) ? svgGlyphRects(node, from, to, svgIndexCache) : null;
                for (const rect of glyphs || part.getClientRects()) rects.push(rect);
            }
            if (node === range.endContainer) break;
            node = walker?.nextNode();
        } while (node);
        if (!rects.length) return range.getBoundingClientRect();
        const left = Math.min(...rects.map(rect => rect.left)), top = Math.min(...rects.map(rect => rect.top));
        const right = Math.max(...rects.map(rect => rect.right)), bottom = Math.max(...rects.map(rect => rect.bottom));
        return {left, top, right, bottom, x: left, y: top, width: right - left, height: bottom - top};
    };
    const ordinaryVisibleRangePolygons = (range, svgOnly = false, svgIndexCache) => {
        const doc=range.startContainer.ownerDocument,win=doc.defaultView,result={polygons:[],unsupported:[]};
        const bounds=range.getBoundingClientRect();
        const hasSVG = svgOnly || rangeContainsSVGText(range);
        if(!hasSVG && (bounds.right<=0 || bounds.bottom<=0 || bounds.left>=win.innerWidth || bounds.top>=win.innerHeight))return result;
        if(hasSVG && range.startContainer===range.endContainer && svgTextNode(range.startContainer)) {
            const box=range.startContainer.parentElement.closest('text,tspan,textPath').getBoundingClientRect();
            if(box.right<=0 || box.bottom<=0 || box.left>=win.innerWidth || box.top>=win.innerHeight)return result;
        }
        const root=range.commonAncestorContainer;
        // Existing Find/speech Ranges have text-node endpoints. Visit only their
        // intersecting segment, not a separately parsed or normalized text stream.
        const walker=root.nodeType===3?null:doc.createTreeWalker(root,NodeFilter.SHOW_TEXT);
        if(walker)walker.currentNode=range.startContainer;
        let node=range.startContainer;
        do {
            if(node.nodeType!==3){result.unsupported.push('Non-text Range endpoint');break;}
            const element=node.parentElement,leafStyle=win.getComputedStyle(element);
            if((!svgOnly || svgTextNode(node)) && leafStyle.visibility!=='hidden' && leafStyle.visibility!=='collapse') {
                const part=doc.createRange();part.setStart(node,node===range.startContainer?range.startOffset:0);part.setEnd(node,node===range.endContainer?range.endOffset:node.length);
                let allowed=true,clips=[];
                for(let parent=element;parent;parent=parent.parentElement) {
                    const style=win.getComputedStyle(parent);
                    if(Number(style.opacity)===0){allowed=false;break;}
                    // Range.getClientRects has already lost the true quad of text
                    // rotated inside this document. Do not call that exact support.
                    if(style.rotate && style.rotate!=='none' || style.perspective && style.perspective!=='none'){allowed=false;result.unsupported.push('Independent rotation or perspective on text');break;}
                    if(style.transform!=='none') {
                        const m=new win.DOMMatrixReadOnly(style.transform);
                        if(!m.is2D || Math.abs(m.b)>1e-7 || Math.abs(m.c)>1e-7){allowed=false;result.unsupported.push('Transformed text inside its own document');break;}
                    }
                    if(style.clipPath && style.clipPath!=='none' || style.maskImage && style.maskImage!=='none' || style.webkitMaskImage && style.webkitMaskImage!=='none') {
                        allowed=false;result.unsupported.push('CSS clipping mask requires nonrectangular geometry');break;
                    }
                    const x=['hidden','clip','auto','scroll'].includes(style.overflowX),y=['hidden','clip','auto','scroll'].includes(style.overflowY);
                    if(x||y) {
                        // Verified ordinary axis-aligned container path. Preserve
                        // per-axis clipping. client dimensions exclude scrollbars.
                        const box=parent.getBoundingClientRect();
                        if(parent instanceof win.SVGSVGElement) clips.push({x,y,left:box.left,top:box.top,right:box.right,bottom:box.bottom});
                        else {
                            const sx=box.width/parent.offsetWidth,sy=box.height/parent.offsetHeight;
                            clips.push({x,y,left:box.left+parent.clientLeft*sx,top:box.top+parent.clientTop*sy,right:box.left+(parent.clientLeft+parent.clientWidth)*sx,bottom:box.top+(parent.clientTop+parent.clientHeight)*sy});
                        }
                    }
                }
                if(allowed) {
                    const svg = svgTextNode(node);
                    const glyphs = svg ? svgGlyphRects(node, part.startOffset, part.endOffset, svgIndexCache) : null;
                    if(svg && glyphs === null) result.unsupported.push('SVG glyph geometry unavailable');
                    const rects = svg ? glyphs || [] : part.getClientRects();
                    for(const rect of rects) {
                        let left=Math.max(0,rect.left),top=Math.max(0,rect.top),right=Math.min(win.innerWidth,rect.right),bottom=Math.min(win.innerHeight,rect.bottom);
                        for(const clip of clips){if(clip.x){left=Math.max(left,clip.left);right=Math.min(right,clip.right);}if(clip.y){top=Math.max(top,clip.top);bottom=Math.min(bottom,clip.bottom);}}
                        if(right>left&&bottom>top)result.polygons.push([[left,top],[right,top],[right,bottom],[left,bottom]]);
                    }
                }
            }
            if(node===range.endContainer)break;
            node=walker?.nextNode();
        }while(node);
        return result;
    };
    // A rotated iframe transports each corner/polygon, not the corners of an
    // intermediate axis-aligned bounding box. Native consumer must draw paths.
    // Current four-number rectangle protocol alone cannot represent that geometry.
    // Existing protocol can remain a visible-shape union: rect4 or quad8.
    // Clip-created convex polygons with >4 vertices are triangulated into quad8
    // with a repeated final corner, preserving exact clipped geometry.
    const encodeVisibleShapes = polygons => polygons.flatMap(poly => {
        if(poly.length<3)return [];
        if(poly.length===4) {
            const [[x0,y0],[x1,y1],[x2,y2],[x3,y3]]=poly;
            if(Math.abs(y0-y1)<1e-6&&Math.abs(x1-x2)<1e-6&&Math.abs(y2-y3)<1e-6&&Math.abs(x3-x0)<1e-6) {
                return [[Math.min(x0,x2),Math.min(y0,y2),Math.abs(x2-x0),Math.abs(y2-y0)]];
            }
            return [poly.flat()];
        }
        return poly.slice(1,-1).map((point,i)=>[...poly[0],...point,...poly[i+2],...poly[i+2]]);
    });
    const svgHighlightRanges = name => [...(CSS.highlights.get(name) || [])].filter(rangeContainsSVGText)
    window.leafRangeHighlights = (zoom = highlightZoom) => {
        const custom = !!(window.Highlight && CSS.highlights)
        const svgIndexCache = new WeakMap()
        const visible = range => ordinaryVisibleRangePolygons(range, custom, svgIndexCache).polygons
        const ranges = custom ? svgHighlightRanges('sumatra-find') : finder.highlightRanges()
        const current = finder.currentRange()
        const polygons = { find: ranges.flatMap(visible),
            current: current && (!custom || rangeContainsSVGText(current)) ? visible(current) : [],
            speech: custom ? svgHighlightRanges('sumra-speech').flatMap(visible)
                : speechRange ? visible(speechRange) : [] }
        for (const frame of document.querySelectorAll('frame,iframe')) {
            try {
                if (!frame.contentWindow?.leafRangeHighlights) continue
                const child = frame.contentWindow.leafRangeHighlights(zoom)
                for (const kind of ['find', 'current', 'speech']) for (const shape of child[kind]) {
                    const points = shape.length === 4
                        ? [[shape[0],shape[1]], [shape[0]+shape[2],shape[1]],
                           [shape[0]+shape[2],shape[1]+shape[3]], [shape[0],shape[1]+shape[3]]]
                        : [shape.slice(0,2), shape.slice(2,4), shape.slice(4,6), shape.slice(6,8)]
                    const mapped = mapFramePolygon(frame, points, zoom)
                    if (mapped.length) polygons[kind].push(mapped)
                }
            } catch { /* Cross-origin or unsupported frames cannot supply visible geometry. */ }
        }
        return Object.fromEntries(Object.entries(polygons).map(([kind, points]) => [kind, encodeVisibleShapes(points)]))
    }
    let highlightTimer = 0, hadRangeHighlights = false, hasSVGRangeHighlights = false
    const publishRangeHighlights = (force = false, fromChild = false) => {
        const custom = !!(window.Highlight && CSS.highlights)
        if (custom) {
            if (force) hasSVGRangeHighlights = !!(svgHighlightRanges('sumatra-find').length || svgHighlightRanges('sumra-speech').length)
            else if (!CSS.highlights.get('sumatra-find') && !CSS.highlights.get('sumra-speech')) hasSVGRangeHighlights = false
        }
        if (!mainFrame) {
            const wasActive = hadRangeHighlights;
            hadRangeHighlights = !custom || !!speechRange || hasSVGRangeHighlights || !!finder.highlightRanges().length;
            if (hadRangeHighlights || wasActive) window.top.leafPublishRangeHighlights?.(true, true)
            return
        }
        if (custom && !hasSVGRangeHighlights && !hadRangeHighlights && !speechRange && !fromChild) return
        if (!ready) return
        const rects = window.leafRangeHighlights(), hasRects = Object.values(rects).some(rects => rects.length)
        if (hasRects || hadRangeHighlights) post('rangeHighlights', rects)
        hadRangeHighlights = hasRects
    }
    window.leafPublishRangeHighlights = publishRangeHighlights
    const scheduleRangeHighlights = (force = false, fromChild = false) => {
        if (!mainFrame) {
            if (force || !window.Highlight || !CSS.highlights || speechRange || hasSVGRangeHighlights || hadRangeHighlights || finder.highlightRanges().length) window.top.leafScheduleRangeHighlights?.(true, true)
            return
        }
        if (window.Highlight && CSS.highlights && !hasSVGRangeHighlights && !hadRangeHighlights && !speechRange && !fromChild) return
        if (highlightTimer) return
        // A hidden WKWebView can suspend animation frames after WebKit settles
        // a zoomed programmatic scroll. A single timer keeps its native overlay
        // in sync with the final viewport without polling.
        highlightTimer = setTimeout(() => {
            highlightTimer = 0
            publishRangeHighlights(force, fromChild)
        }, 16)
    }
    window.leafScheduleRangeHighlights = scheduleRangeHighlights
    let reportedLayoutLimit = false
    const reportPosition = () => {
        if (!mainFrame || !ready || restoring || printViewport) return
        rememberReadingViewport()
        post('position', { page: pageIndex(), count: pages.length, label: String(pageIndex() + 1),
            anchor: pageURL(), x: window.scrollX, y: window.scrollY, markdownPassage: savedReadingPassage() })
        // System WebKit saturates its root layout coordinates at this extent.
        // Automatic Markdown reading can reopen through the paged reader;
        // an explicit compatibility choice remains under the user's control.
        if (config.markdown && !reportedLayoutLimit && document.documentElement.scrollHeight >= 33554430) {
            reportedLayoutLimit = true
            post('layoutLimit')
        }
        if (interaction.keyboardLinks) updateInteraction()
    }
    // Swift's existing command queue owns navigation and acknowledges it only
    // after the destination's activation, before speech/selection can run.
    const go = href => ({ navigation: new URL(href, location.href).href })
    const navigatePage = index => {
        if (Number.isInteger(index) && index >= 0 && index < pages.length) return go(pages[index])
        else throw Error('Page not found')
    }
    const fragmentTarget = fragment => {
        let id = fragment.replace(/^#/, '')
        try { id = decodeURIComponent(id) } catch { /* Preserve a literal invalid escape in an authored id. */ }
        return document.getElementById(id) || document.getElementsByName(id)[0]
    }
    const readSearchTarget = href => {
        const hash = new URL(href, location.href).hash
        if (!hash.startsWith(searchPrefix)) return null
        try {
            const value = JSON.parse(decodeURIComponent(hash.slice(searchPrefix.length)))
            return typeof value?.text === 'string' && Number.isSafeInteger(value.index) && value.index >= 0 ? value : null
        } catch { return null }
    }
    const selectHit = index => {
        if (!hits.length) return
        selected = (index % hits.length + hits.length) % hits.length
        const hit = hits[selected]
        post('searchHit', { target: hit.target })
        post('status', { message: `${selected + 1} / ${hits.length}${hitsCapped ? '+' : ''} matches` })
        if (hit.page === pageIndex()) finder.gotoMatch(hit.index)
        else post('navigate', { href: hit.target })
    }
    window.__sumatra__ = { notify(method, generation, current, total, capped = false) {
        if (generation !== searchGeneration) return
        if (method === 'findResult') {
            if (current > 0) {
                readingViewport = null
                if (ready && !restoring && !printViewport) rememberReadingViewport()
            }
            const index = current - 1
            selected = hits.findIndex(hit => hit.page === pageIndex() && hit.index === index)
            // A page-local miss cannot finish a multi-file search. The global
            // findAllResult owns "No matches" after every requested page is read.
            if (ready && current > 0) {
                post('searchHit', { target: searchTarget(pageIndex(), index) })
                post('status', { message: selected >= 0 ? `${selected + 1} / ${hits.length}${hitsCapped ? '+' : ''} matches`
                    : `${current} / ${total}${capped ? '+' : ''} matches` })
            }
        } else if (method === 'findAllResult') {
            // Upstream records are page US local-index US snippet, joined with RS.
            const records = total ? total.split('\x1e') : []
            const currentTarget = finder.currentRange() && searchTarget(pageIndex(), Math.max(0, currentMatch))
            hits = records.map(record => {
                const [page, index, title] = record.split('\x1f'), p = Number(page) - 1, i = Number(index)
                return { page: p, index: i, title, target: searchTarget(p, i), depth: 0 }
            })
            hitsCapped = capped
            post('results', { items: hits.map(({ title, target, depth, page }) => ({ title, target, depth, page })), capped: hitsCapped })
            selected = hits.findIndex(hit => hit.target === currentTarget)
            if (selected >= 0) post('status', { message: `${selected + 1} / ${hits.length}${hitsCapped ? '+' : ''} matches` })
            else if (!hits.length) post('status', { message: 'No matches' })
        }
        if (method === 'findResult') currentMatch = current - 1
        publishRangeHighlights(true)
    } }
    let currentMatch = -1
    const selectRelative = (backwards, range) => {
        const index = range ? finder.indexFromRange(range, backwards) : currentMatch
        const local = hits.findIndex(hit => hit.page === pageIndex() && hit.index === index)
        if (local >= 0) { selectHit(local); return }
        const candidates = hits.map((hit, index) => ({ hit, index })).filter(({ hit }) => backwards ? hit.page < pageIndex() : hit.page > pageIndex())
        const candidate = backwards ? candidates.at(-1) : candidates[0]
        selectHit(candidate?.index ?? (backwards ? hits.length - 1 : 0))
    }
    const find = async command => {
        if (!command.text) { clearFind(); return }
        const options = { text: command.text, matchCase: !!command.matchCase, matchWholeWords: !!command.matchWholeWords }
        const key = JSON.stringify(options)
        const origin = command.fromSelection && selection()?.rangeCount ? selection().getRangeAt(0).cloneRange() : null
        if (searchKey === key) {
            const generation = searchGeneration
            // The query that started the scan owns reporting its failure.
            if (scan) { try { await scan } catch { return } }
            if (generation !== searchGeneration || searchKey !== key || !hits.length) return
            if (origin) { selectRelative(command.backwards, origin); return }
            selectHit(selected + (command.backwards ? -1 : 1)); return
        }
        searchKey = key; searchOptions = options; hits = []; hitsCapped = false; selected = -1
        const generation = ++searchGeneration
        searchAbort?.abort()
        const controller = new AbortController()
        searchAbort = controller
        post('results', { items: [] }); post('status', { message: 'Searching…' })
        const work = (async () => {
            const currentSnippets = await finder.start(options.text, options.matchCase, options.matchWholeWords, generation, -1, true)
            if (generation !== searchGeneration) return
            await finder.searchAll(pages, options.text, options.matchCase, options.matchWholeWords, generation,
                url => fetchDocument(url, controller.signal), currentSnippets)
        })()
        scan = work
        try {
            await work
            if (generation !== searchGeneration || !hits.length) return
            if (origin || selected < 0) selectRelative(command.backwards, origin)
        } catch (error) {
            if (generation !== searchGeneration) return
            clearFind()
            throw error
        } finally {
            if (scan === work) scan = null
            if (searchAbort === controller) searchAbort = null
        }
    }
    const clearFind = (publish = true) => {
        ++searchGeneration; searchKey = ''; searchOptions = null; hits = []; hitsCapped = false; selected = -1; currentMatch = -1; scan = null
        searchAbort?.abort(); searchAbort = null
        finder.clear(); publishRangeHighlights()
        if (publish) { post('results', { items: [] }); post('searchHit', { target: null }); post('status', { message: '' }) }
    }
    const style = document.createElement('style'); style.dataset.sumra = 'typography'; document.head.append(style)
    const interactionStyle = document.createElement('style'); interactionStyle.dataset.sumra = 'interaction'; document.head.append(interactionStyle)
    const publisherStyles = [...document.querySelectorAll('style:not([data-sumra]),link[rel~="stylesheet"]')]
        .map(element => ({ element, media: element.media }))
    const inlineStyles = [...document.querySelectorAll('[style]')].map(element => ({ element, css: element.getAttribute('style') }))
    const scheme = matchMedia('(prefers-color-scheme:dark)')
    const applyDocumentCSS = () => {
        for (const { element, media } of publisherStyles) element.media = useDocumentCSS ? media : 'not all'
        for (const { element, css } of inlineStyles) {
            if (useDocumentCSS) element.setAttribute('style', css)
            else element.removeAttribute('style')
        }
    }
    const applyStyle = () => {
        const [family = 'system', size = '17', line = '1.6', margin = '32', theme = 'system'] = String(typography || '').split('|')
        const font = family === 'system' ? '-apple-system,BlinkMacSystemFont,sans-serif'
            : ['serif', 'sans-serif', 'monospace'].includes(family) ? family : JSON.stringify(family)
        const dark = theme === 'dark' || theme === 'system' && scheme.matches
        const padding = margins.length === 4 ? margins.map(value => `${value * 96 / 72}px`).join(' ') : `${margin}px`
        // ChmModel::ChmThemeStyleTemp leaves the author's layout intact.
        // Swift supplies non-default theme colors through userCSS.
        const layout = config.chm && useDocumentCSS
            ? (margins.length === 4 ? `body{padding:${padding}!important}` : '')
            : `:root{color-scheme:${dark ? 'dark' : 'light'};--bg:${dark ? '#111' : '#fff'};--fg:${dark ? '#ddd' : '#24292f'};--link:${dark ? '#4493f8' : '#0969da'};--muted:${dark ? '#9198a1' : '#57606a'};--border:${dark ? '#444' : '#d0d7de'};--code-bg:${dark ? '#222' : '#f6f8fa'}}
            body{font-family:${font}!important;font-size:${Number(size)}px!important;line-height:${Number(line)}!important;padding:${padding}!important;background:var(--bg)!important;color:var(--fg)!important}a{color:var(--link)}`
        const css = `${layout}
            ::highlight(sumra-speech){background:#ffd54f;color:#000}
            ${document.contentType === 'text/plain' ? 'pre{white-space:pre-wrap;overflow-wrap:anywhere}' : ''}\n${userCSS}`
        if (style.textContent !== css) style.textContent = css
    }
    const updateStyle = command => {
        if ('zoom' in command) highlightZoom = command.zoom
        if ('text' in command) typography = command.text
        if ('userCSS' in command) userCSS = command.userCSS || ''
        if ('useDocumentCSS' in command && useDocumentCSS !== (command.useDocumentCSS !== false)) {
            useDocumentCSS = command.useDocumentCSS !== false
            applyDocumentCSS()
        }
        if ('pageMargins' in command) margins = command.pageMargins || []
        applyStyle()
    }
    const clearLinkPreview = () => {
        if (!previewLink) return
        if (previewTitle === null) previewLink.removeAttribute('title')
        else previewLink.setAttribute('title', previewTitle)
        previewLink = null; previewTitle = null
    }
    const updateInteraction = () => {
        const css = `${interaction.showLinks ? 'a[href]{outline:1px solid #e4a000;background:#ffcc0033}' : ''}
            a[data-sumra-link]::before{content:attr(data-sumra-link);font:bold 11px sans-serif;color:#000;background:#ffd24d;border:1px solid #8c6800;padding:0 2px}
            ${interaction.scrollbars === 'hidden' ? 'html{scrollbar-width:none}::-webkit-scrollbar{display:none}' : interaction.scrollbars === 'shown' ? 'html{overflow:scroll}' : ''}`
        if (interactionStyle.textContent !== css) interactionStyle.textContent = css
        if (!interaction.hoverPreview) clearLinkPreview()
        if (mainFrame && ready && !config.chm) {
            const requested = !!interaction.outlineRequested
            if (requested && !outlineDemand) loadOutline()
            outlineDemand = requested
        }
        for (const link of document.querySelectorAll('a[data-sumra-link]')) link.removeAttribute('data-sumra-link')
        if (interaction.keyboardLinks) {
            const visible = [...document.querySelectorAll('a[href]')].filter(link => {
                const rect = link.getBoundingClientRect()
                return rect.bottom >= 0 && rect.top <= innerHeight
            })
            visible.forEach((link, index) => { link.dataset.sumraLink = String(index + 1) })
        }
    }
    const caret = (x, y) => document.caretRangeFromPoint(Math.max(0, Math.min(innerWidth - 1, x)), Math.max(0, Math.min(innerHeight - 1, y)))
    const visibleRange = () => {
        const start = caret(Math.min(40, innerWidth / 2), 1), end = caret(innerWidth - 1, innerHeight - 1)
        if (!start || !end) return null
        const range = document.createRange(); range.setStart(start.startContainer, start.startOffset); range.setEnd(end.startContainer, end.startOffset)
        return range
    }
    const selectRange = range => {
        if (!range) return
        selection().removeAllRanges(); selection().addRange(range); reportSelection()
    }
    const atDocumentEnd = () => scrollY > 0 && scrollY + document.documentElement.clientHeight >= document.documentElement.scrollHeight - 1
    const passageText = (node, offset) => {
        let start = Math.max(0, offset - 16), end = Math.min(node.length, offset + 16)
        // The bridge carries Unicode strings, while DOM offsets use UTF-16.
        // Keep the nearby-text check from splitting a surrogate pair.
        if (start > 0 && /[\uDC00-\uDFFF]/.test(node.data[start])) --start
        if (end < node.length && /[\uD800-\uDBFF]/.test(node.data[end - 1])) ++end
        return node.data.slice(start, end)
    }
    const savedReadingPassage = () => {
        if (!config.markdown || !readingViewport) return null
        if (readingViewport.end) return {path: [], offset: 0, top: 0, text: '', end: true}
        const range = readingViewport.range, top = readingViewport.top
        if (!range || range.startContainer.nodeType !== Node.TEXT_NODE || !Number.isFinite(top)) return null
        const path = [], original = range.startContainer
        for (let node = original; node !== document.body; node = node.parentNode) {
            if (!node.parentNode) return null
            path.unshift(Array.prototype.indexOf.call(node.parentNode.childNodes, node))
        }
        return {path, offset: range.startOffset, top, text: passageText(original, range.startOffset), end: false}
    }
    const restoreReadingPassage = position => {
        const passage = position?.markdownPassage
        if (!config.markdown || !passage) return false
        if (passage.end === true) {
            scrollTo({left: position.x || 0, top: document.documentElement.scrollHeight, behavior: 'instant'})
            return true
        }
        if (passage.end !== false || !Array.isArray(passage.path) || !passage.path.length ||
            !Number.isInteger(passage.offset) || passage.offset < 0 || !Number.isFinite(passage.top) || typeof passage.text !== 'string') return false
        let node = document.body
        for (const index of passage.path) {
            if (!Number.isInteger(index) || index < 0 || !node?.childNodes[index]) return false
            node = node.childNodes[index]
        }
        if (node.nodeType !== Node.TEXT_NODE || passage.offset > node.length || passageText(node, passage.offset) !== passage.text) return false
        const range = document.createRange(); range.setStart(node, passage.offset); range.collapse(true)
        const top = range.getBoundingClientRect().top
        if (!Number.isFinite(top)) return false
        scrollTo({left: position.x || 0, top: scrollY + top - passage.top, behavior: 'instant'})
        return true
    }
    const rememberReadingViewport = () => {
        if (!config.markdown || readingViewport &&
            (readingViewport.width !== innerWidth || readingViewport.height !== innerHeight)) return
        const range = scrollY > 0 ? caret(Math.min(40, innerWidth / 2), 1) : null
        range?.collapse(true)
        readingViewport = {range, top: range?.getBoundingClientRect().top, x: scrollX,
            width: innerWidth, height: innerHeight,
            end: atDocumentEnd()}
    }
    const resizeReadingViewport = () => {
        const saved = readingViewport
        if (config.markdown && mainFrame && ready && !restoring && !printViewport && saved &&
            (saved.width !== innerWidth || saved.height !== innerHeight)) {
            if (saved.end) scrollTo({left: saved.x, top: document.documentElement.scrollHeight, behavior: 'instant'})
            else if (saved.range?.startContainer.isConnected && Number.isFinite(saved.top)) {
                scrollTo({left: saved.x, top: scrollY + saved.range.getBoundingClientRect().top - saved.top, behavior: 'instant'})
            }
        }
        readingViewport = null
        reportPosition(); scheduleRangeHighlights()
    }
    const reflowText = async command => {
        readingViewport = null
        const pageTop = scrollY
        const end = config.markdown && atDocumentEnd()
        const anchor = config.markdown && pageTop > 0 && !end ? caret(Math.min(40, innerWidth / 2), 1) : null
        anchor?.collapse(true)
        const anchorTop = anchor?.getBoundingClientRect().top
        updateStyle(command)
        // Shrinking the layout can clamp scrolling before fonts settle.
        // Only a later scroll should override the saved reading passage.
        const styledTop = scrollY
        await document.fonts.ready
        if (scrollY !== styledTop) return
        if (end) scrollTo({left: scrollX, top: document.documentElement.scrollHeight, behavior: 'instant'})
        else if (anchor?.startContainer.isConnected && Number.isFinite(anchorTop)) {
            scrollTo({left: scrollX, top: scrollY + anchor.getBoundingClientRect().top - anchorTop, behavior: 'instant'})
        }
    }
    const readAloud = source => {
        const current = selection(), selected = source === 'selection' || !source && !current.isCollapsed
        const cursor = source === 'cursor' || !source && interaction.keyboardSelection
        if (selected && current.isCollapsed) throw Error('Select text to read aloud')
        let range = selected || cursor && current.rangeCount ? current.getRangeAt(0).cloneRange()
            : cursor && pointer ? caret(pointer.x, pointer.y) : visibleRange()
        if (!range) throw Error('No text at the reading position')
        if (!selected) { range.collapse(true); range.setEnd(document.body, document.body.childNodes.length) }
        speechNodes = []; let spoken = ''
        for (const node of finder.textNodesInRange(range, document.body)) {
            const from = range.startContainer === node ? range.startOffset : 0
            const to = range.endContainer === node ? range.endOffset : node.length
            if (to <= from) continue
            const part = document.createRange(); part.setStart(node, from); part.setEnd(node, to)
            if (!part.getClientRects().length) continue
            speechNodes.push({ node, from, to, start: spoken.length }); spoken += node.data.slice(from, to)
        }
        if (!spoken) throw Error('No text in the selection')
        post('readAloud', { text: spoken, ...(selected ? {} : { page: pageIndex() }), startOffset: 0 })
    }
    const highlightSpeech = command => {
        CSS.highlights?.delete('sumra-speech')
        speechRange = null
        if (!command.length || !speechNodes.length) { publishRangeHighlights(true); return }
        const end = command.location + command.length
        // Spoken UTF-16 offsets are ordered and contiguous. Locate both word
        // boundaries without scanning the whole passage for every callback.
        const boundary = (offset, starts) => {
            let low = 0, high = speechNodes.length
            while (low < high) {
                const middle = low + Math.floor((high - low) / 2), item = speechNodes[middle]
                const value = item.start + (starts ? 0 : item.to - item.from)
                if (starts ? value < offset : value <= offset) low = middle + 1
                else high = middle
            }
            return low
        }
        const first = speechNodes[boundary(command.location, false)]
        const last = speechNodes[boundary(end, true) - 1]
        if (!first?.node.isConnected || !last?.node.isConnected) { publishRangeHighlights(true); return }
        const range = document.createRange()
        range.setStart(first.node, first.from + Math.max(0, command.location - first.start))
        range.setEnd(last.node, Math.min(last.to, last.from + end - last.start))
        if (window.Highlight && CSS.highlights) CSS.highlights.set('sumra-speech', new Highlight(range))
        else speechRange = range
        if (interaction.speechFollow) {
            const rect = range.getBoundingClientRect()
            if (rect.top < 0 || rect.bottom > innerHeight) scrollBy(0, rect.top - innerHeight / 3)
        }
        publishRangeHighlights(true)
    }
    const fileEntry = (url, page) => {
        let title = new URL(url).pathname.split('/').pop()
        try { title = decodeURIComponent(title) } catch { /* File names can contain literal percent signs. */ }
        return { title, target: url, depth: 0, page }
    }
    const fetchDocument = async (url, signal) => {
        // Searches and full-document text already have this page's live DOM.
        // Do not fetch/decode/parse a second complete copy of the current book.
        if (mainFrame && !config.chm && withoutHash(url) === withoutHash(pageURL())) return document
        const response = await (signal ? fetch(url, { signal }) : fetch(url))
        if (signal?.aborted) throw new DOMException('Search cancelled', 'AbortError')
        if (!response.ok) throw Error(`Cannot read document (${response.status})`)
        const type = response.headers.get('content-type') || ''
        const plain = type.startsWith('text/plain')
        const encoded = config.chm || !config.markdown
        const body = encoded ? await response.arrayBuffer() : await response.text()
        if (signal?.aborted) throw new DOMException('Search cancelled', 'AbortError')
        const text = encoded ? decodeHTML(body, type.match(/charset=([^;\s]+)/i)?.[1],
            { plain, preferUTF8: config.chm }) : body
        if (!plain) return new DOMParser().parseFromString(text, 'text/html')
        const doc = document.implementation.createHTMLDocument(''), pre = doc.createElement('pre')
        pre.textContent = text; doc.body.append(pre)
        return doc
    }
    let outlineItems = config.chm ? config.outline || [] : pages.map(fileEntry)
    const loadOutline = () => {
        if (outlineLoad) return
        const work = (async () => {
            const response = await fetch('leaf://book/outline')
            if (!response.ok) throw Error(`Cannot read document outline (${response.status})`)
            const items = await response.json()
            if (outlineLoad !== work || !ready) return
            outlineItems = items; post('toc', { items: outlineItems })
        })()
        outlineLoad = work
        work.catch(error => {
            if (outlineLoad !== work) return
            outlineLoad = null
            if (ready) post('outlineError', { message: error.message })
        })
    }
    const restoreSearch = async search => {
        searchOptions = { text: search.text, matchCase: !!search.matchCase, matchWholeWords: !!search.matchWholeWords }
        const key = JSON.stringify(searchOptions)
        if (searchKey !== key || !hits.length) {
            // Like MarkdownModel::GoToPageWithFind, retain the host's
            // existing global results and rebuild only this page's Ranges.
            hits = (config.searchResults || []).flatMap(item => {
                const target = readSearchTarget(item.target)
                if (!target || target.text !== search.text || !!target.matchCase !== !!search.matchCase
                    || !!target.matchWholeWords !== !!search.matchWholeWords) return []
                return [{ ...item, index: target.index }]
            })
            hitsCapped = hits.length > 0 && config.searchCountCapped === true
        }
        searchKey = key; scan = null
        const generation = ++searchGeneration
        searchAbort?.abort(); searchAbort = null
        await finder.start(search.text, search.matchCase, search.matchWholeWords, generation, search.index ?? -1)
        return generation === searchGeneration
    }
    const restore = async position => {
        const anchor = position?.anchor || pages[position?.page] || location.href, destination = new URL(anchor, location.href)
        if (withoutHash(destination.href) !== withoutHash(location.href) && position?.page !== pageIndex()) return go(destination.href)
        // An authored fragment creates a new history item. Set restoration on
        // the current item, including cached pages, before applying our position.
        if (mainFrame) history.scrollRestoration = 'manual'
        const revision = ++restoreRevision
        readingViewport = null
        restoring = true
        try {
            const search = readSearchTarget(destination.href)
            if (search) return await restoreSearch(search)
            else if (destination.hash === '#sumra-end') scrollTo(0, document.documentElement.scrollHeight)
            else if (destination.hash) {
                // MarkdownToc emits empty inline anchors before headings.
                // WebKit's scrollIntoView can leave those anchors unmoved or
                // align their text baseline instead of their reported origin.
                const target = fragmentTarget(destination.hash)
                // Window.scrollY loses the fractional scroll at native page zoom.
                const viewport = window.visualViewport
                if (target) scrollTo(window.scrollX,
                    viewport.pageTop - viewport.offsetTop + target.getBoundingClientRect().top)
            }
            else if (!restoreReadingPassage(position)) scrollTo(position?.x || 0, position?.y || 0)
        } finally {
            if (revision === restoreRevision) { restoring = false; reportPosition() }
        }
    }
    const activate = async command => {
        const revision = ++activationRevision
        readingViewport = null
        ready = false
        printViewport = null
        clearFind(false)
        config.searchResults = command.searchResults || []
        config.searchCountCapped = command.searchCountCapped === true
        // A cached page can still have only filename placeholders from an
        // earlier failed outline load. Preserve the host's recovered tree.
        if (mainFrame && Array.isArray(command.outline) && command.outline.length) outlineItems = command.outline
        updateStyle(command)
        interaction = command.flags || {}; updateInteraction()
        await document.fonts.ready
        if (revision !== activationRevision) return
        await Promise.all(childReaders().map(reader => reader.leafCommand({ ...command, position: null, search: null, searchResults: [] })))
        if (revision !== activationRevision) return
        const target = readSearchTarget(command.position?.anchor || pages[command.position?.page] || location.href)
        const search = command.search?.enabled
            ? command.search.text ? command.search : readSearchTarget(config.searchResults[0]?.target || location.href) : null
        let searchRestored = true
        if (!target && search?.text) searchRestored = await restoreSearch(search)
        if (revision !== activationRevision) return
        if (mainFrame && await restore(command.position) === false) searchRestored = false
        if (revision !== activationRevision) return
        if (!target && searchRestored) {
            if (currentMatch < 0) {
                const index = hits.findIndex(hit => hit.target === command.selectedSearchTarget)
                if (index >= 0) selected = index
            }
            // A query whose global scan never finished still needs that scan
            // when the user next invokes Find; page activation never starts it.
            if (!hits.length) searchKey = ''
        }
        ready = true
        updateInteraction()
        scheduleRangeHighlights()
        reportPosition()
        reportSelection()
        post('inputFocus', { focused: window.leafInputFocused() })
        if (mainFrame) post('toc', { items: outlineItems })
        // The restored ranges were built while activation suppressed reporting.
        // Publish through the same match owner once the page is ready.
        if (currentMatch >= 0) finder.report()
        // Native readiness follows this promise. Return the initial fallback
        // rectangles through that same barrier, including cached-page restores.
        if (!window.Highlight || !CSS.highlights) {
            const rangeHighlights = window.leafRangeHighlights()
            hadRangeHighlights = Object.values(rangeHighlights).some(rects => rects.length)
            return { rangeHighlights }
        }
    }
    const scroll = command => {
        const vertical = command.direction === 'up' || command.direction === 'down'
        const sign = command.direction === 'up' || command.direction === 'left' ? -1 : 1
        const amount = command.amount === 'line' ? Math.max(16, Number(String(typography).split('|')[1]) || 17)
            : (vertical ? innerHeight : innerWidth) * (command.amount === 'halfPage' ? 0.5 : 1)
        const distance = amount * sign * (command.count ?? 1)
        scrollBy(vertical ? 0 : distance, vertical ? distance : 0); reportPosition()
    }
    const turnPages = count => {
        if (!count) return
        const bottom = Math.max(0, document.documentElement.scrollHeight - innerHeight)
        if (count > 0 && scrollY >= bottom - 1 && pageIndex() + 1 < pages.length) return navigatePage(pageIndex() + 1)
        else if (count < 0 && scrollY <= 0 && pageIndex() > 0) { const url = new URL(pages[pageIndex() - 1]); url.hash = 'sumra-end'; return go(url) }
        else { scrollBy(0, innerHeight * count); reportPosition() }
    }
    window.leafCommand = async command => {
        // Let the existing native readiness/error owner finish activation.
        if (command.name === 'activate') return await activate(command)
        try {
        if (['turnPages', 'scroll', 'page', 'location', 'href', 'restore'].includes(command.name)) readingViewport = null
        const focused = ['copy', 'speechHighlight'].includes(command.name)
            || command.name === 'readAloud' && (!command.source || command.source === 'selection') ? selectionReader() : focusedReader()
        if (focused && ['copy', 'selectAll', 'selectCurrentPage', 'readAloud', 'speechHighlight'].includes(command.name)) return await focused.leafCommand(command)
        if (['style', 'interaction'].includes(command.name)) await Promise.all(childReaders().map(reader => reader.leafCommand(command)))
        switch (command.name) {
        case 'find': return await find(command)
        case 'toc': clearFind(); post('toc', { items: outlineItems }); break
        case 'turnPages': return turnPages(command.count)
        case 'scroll': scroll(command); break
        case 'page': return navigatePage(command.number)
        case 'location': {
            if (command.text === 'first') { if (pageIndex() === 0) scrollTo(0, 0); else return navigatePage(0); reportPosition(); break }
            if (command.text === 'last') { if (pageIndex() === pages.length - 1) scrollTo(0, document.documentElement.scrollHeight); else { const url = new URL(pages.at(-1)); url.hash = 'sumra-end'; return go(url) }; reportPosition(); break }
            const [page, part = 1] = command.text.split(':').map(Number)
            if (!Number.isSafeInteger(page) || page < 1 || page > pages.length || part !== 1) throw Error('Page not found')
            return navigatePage(page - 1)
        }
        case 'href': {
            const url = localURL(command.text), search = readSearchTarget(url.href)
            if (withoutHash(url.href) === withoutHash(location.href)) {
                if (search && searchKey === JSON.stringify({ text: search.text, matchCase: !!search.matchCase, matchWholeWords: !!search.matchWholeWords })) finder.gotoMatch(search.index)
                else if (search || url.hash) return restore({ page: pageIndex(), anchor: url.href })
                else scrollTo(0, 0)
            } else return go(url.href)
            reportPosition()
            break
        }
        case 'restore': {
            updateStyle(command); await document.fonts.ready
            const result = await restore(command.position); publishRangeHighlights(); return result
        }
        case 'style':
            if (config.markdown) await reflowText(command)
            else updateStyle(command)
            reportPosition(); publishRangeHighlights(); break
        case 'zoom': {
            // Swift translates Markdown zoom to typography and supplies the
            // actual WK scale for geometry; other browser documents scale as a page.
            if (config.markdown) await reflowText(command)
            else updateStyle(command)
            highlightZoom = command.number; reportPosition(); publishRangeHighlights(); break
        }
        case 'interaction': interaction = command.flags || {}; updateInteraction(); break
        case 'copy': { const text = selectedText(); if (text) post('copy', { text }); break }
        case 'selectAll': { const range = document.createRange(); range.selectNodeContents(document.body); selectRange(range); break }
        case 'selectCurrentPage': selectRange(visibleRange()); break
        case 'readAloud': readAloud(command.source); break
        case 'speechHighlight': highlightSpeech(command); break
        }
        } catch (error) { post('error', { message: error.message }) }
    }
    window.leafSelectionBounds = () => {
        const focused = selectionReader()
        if (focused) {
            const frame = [...document.querySelectorAll('frame,iframe')].find(frame => frame.contentWindow === focused)
            const rect = focused.leafSelectionBounds(), origin = frame.getBoundingClientRect()
            if (rect) return [rect[0] + origin.x, rect[1] + origin.y, rect[2], rect[3]]
        }
        if (!selection()?.rangeCount || selection().isCollapsed) return null
        const rect = selection().getRangeAt(0).getBoundingClientRect()
        return [rect.x, rect.y, rect.width, rect.height]
    }
    window.leafText = async (entireDocument = false) => {
        const selected = !entireDocument && selectionReader()
        if (selected) return await selected.leafText(false)
        if (!entireDocument) return selectedText() || finder.textFromRange(visibleRange())
        const text = []
        for (let page = 0; page < pages.length; page++) {
            const doc = page === pageIndex() ? document : await fetchDocument(pages[page])
            text.push(finder.textFromBody(doc.body, false).text)
        }
        return text.join('\n\n')
    }
    window.leafCapturePrintViewport = () => {
        readingViewport = null
        const children = childReaders().map(reader => ({ reader, document: reader.document, url: reader.location.href }))
        const viewport = window.visualViewport
        printViewport = { document, url: location.href, x: viewport.pageLeft - viewport.offsetLeft,
            y: viewport.pageTop - viewport.offsetTop, children }
        children.forEach(child => child.reader.leafCapturePrintViewport())
    }
    window.leafRestorePrintViewport = async () => {
        const saved = printViewport
        if (!saved || saved.document !== document || saved.url !== location.href) {
            printViewport = null
            return false
        }
        // WK's print operation can return while this live page is still paginated.
        // Restoring then clamps the reading offset to print geometry.
        const media = matchMedia('print')
        if (media.matches) await new Promise((resolve, reject) => {
            const cleanup = () => {
                media.removeEventListener('change', screen)
                window.removeEventListener('afterprint', screen)
                window.removeEventListener('pagehide', leave)
            }
            const screen = () => { if (!media.matches) { cleanup(); resolve() } }
            const leave = () => { cleanup(); reject(Error('The displayed topic changed before printing completed.')) }
            media.addEventListener('change', screen)
            window.addEventListener('afterprint', screen)
            window.addEventListener('pagehide', leave)
            screen()
        })
        if (printViewport !== saved || saved.document !== document || saved.url !== location.href) {
            if (printViewport === saved) printViewport = null
            return false
        }
        let failure = null
        for (const child of saved.children) {
            let current = false
            try { current = child.reader.document === child.document && child.reader.location.href === child.url }
            catch { /* A frame may have navigated away from this reader. */ }
            if (!current) continue
            try {
                if (!await child.reader.leafRestorePrintViewport()) throw Error('A frame position could not be restored after printing.')
            } catch (error) { failure ||= error }
        }
        if (printViewport !== saved || saved.document !== document || saved.url !== location.href) {
            if (printViewport === saved) printViewport = null
            return false
        }
        printViewport = null
        scrollTo(saved.x, saved.y)
        reportPosition()
        publishRangeHighlights(true)
        if (failure) throw failure
        return true
    }
    window.leafPreparePrint = async () => {
        await document.fonts.ready
        await Promise.all(Array.from(document.images, image => {
            // WK's native print operation starts after this preparation. Start
            // deferred requests now; offscreen lazy images otherwise never emit
            // the load/error event this promise is waiting for.
            if (image.complete) return Promise.resolve()
            return new Promise(resolve => {
                const complete = () => {
                    image.removeEventListener('load', complete)
                    image.removeEventListener('error', complete)
                    resolve()
                }
                image.addEventListener('load', complete, { once: true })
                image.addEventListener('error', complete, { once: true })
                if (image.loading === 'lazy') {
                    const loading = image.getAttribute('loading')
                    image.loading = 'eager'
                    // Eager starts the deferred request synchronously. Restore
                    // authored CSS before layout, without a later write that
                    // could overwrite an author's change while it loads.
                    if (loading === null) image.removeAttribute('loading')
                    else image.setAttribute('loading', loading)
                }
                if (image.complete) complete()
            })
        }))
        await Promise.all(childReaders().map(reader => reader.leafPreparePrint()))
    }
    // Capture the loaded, decoded publication, not the original source bytes.
    // WebKit supplies print-media computed styles; MuPDF owns the later reflow.
    window.leafPrintSnapshot = () => {
        const resources = [], resourcePaths = new Map(), media = [], viewports = [], fontFaces = [], fontsUsed = new Set()
        const output = document.implementation.createHTMLDocument(document.title)
        const cssProperties = ['display', 'visibility', 'color', 'background-color', 'background-image',
            'font-family', 'font-size', 'font-style', 'font-weight', 'line-height', 'letter-spacing',
            'text-align', 'text-decoration', 'text-indent', 'white-space', 'vertical-align',
            'margin-top', 'margin-right', 'margin-bottom', 'margin-left',
            'padding-top', 'padding-right', 'padding-bottom', 'padding-left',
            'border-top', 'border-right', 'border-bottom', 'border-left', 'border-collapse',
            'list-style-type', 'list-style-position', 'list-style-image', 'break-before', 'break-after',
            'break-inside', 'fill', 'fill-opacity', 'stroke', 'stroke-width', 'stroke-opacity']
        const resource = (value, base, svg = false) => {
            const url = new URL(value, base)
            const fragment = url.hash; url.hash = ''
            let path = resourcePaths.get(url.href)
            if (!path) {
                const type = url.protocol === 'data:' ? url.pathname.split(';')[0].split('/')[1] : url.pathname.split('.').at(-1)
                const extension = /^[a-z0-9]+$/i.test(type) ? type.replace('svg+xml', 'svg') : 'bin'
                path = `resources/${resources.length}.${url.protocol === 'data:' && url.pathname.startsWith('image/svg+xml') ? 'svg' : extension}`
                resourcePaths.set(url.href, path); resources.push({url: url.href, path})
            }
            return (svg ? path.slice('resources/'.length) : path) + fragment
        }
        const cssURLs = (text, base, svg = false) => text.replace(/url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*?))\s*\)/gi,
            (match, double, single, bare) => {
                const value = double ?? single ?? bare
                return value.startsWith('#') ? match : `url("${resource(value, base, svg)}")`
            })
        const printMedia = (list, win) => {
            const original = list.mediaText
            if (!original) return
            // Unknown media types are false, so `not screen` remains true for
            // print. matchMedia also evaluates the remaining platform features.
            const query = original.replace(/\b(screen|print)\b/gi,
                type => type.toLowerCase() === 'print' ? 'screen' : 'sumra-reading-screen')
            media.push({list, original}); list.mediaText = win.matchMedia(query).matches ? 'all' : 'not all'
        }
        const prepareDocument = doc => {
            const win = doc.defaultView
            viewports.push({win, x: win.scrollX, y: win.scrollY})
            const visitRules = (rules, base, enabled) => {
                for (const rule of rules) {
                    if (rule.media) printMedia(rule.media, win)
                    const active = enabled && (!rule.media || rule.media.mediaText !== 'not all')
                    if (rule.styleSheet) visitSheet(rule.styleSheet, active)
                    else if (rule.cssRules) visitRules(rule.cssRules, base, active)
                    else if (active && rule.type === win.CSSRule.FONT_FACE_RULE) fontFaces.push({rule, base})
                }
            }
            const visitSheet = (sheet, enabled = true) => {
                printMedia(sheet.media, win)
                const active = enabled && !sheet.disabled && sheet.media.mediaText !== 'not all'
                if (!active) return
                let rules
                try { rules = sheet.cssRules }
                catch (error) { throw Error('A printed stylesheet could not be read: ' + sheet.href, {cause: error}) }
                visitRules(rules, sheet.href || doc.baseURI, active)
            }
            for (const sheet of doc.styleSheets) visitSheet(sheet)
        }
        const transformText = (text, style, element) => {
            const language = element.closest('[lang]')?.lang || undefined
            switch (style.textTransform) {
            case 'uppercase': return text.toLocaleUpperCase(language)
            case 'lowercase': return text.toLocaleLowerCase(language)
            case 'capitalize': return text.replace(/(^|[^\p{L}\p{N}])(\p{L})/gu,
                (_, prefix, letter) => prefix + letter.toLocaleUpperCase(language))
            default: return text
            }
        }
        const applyComputedStyle = (target, style, base, svg) => {
            for (const family of style.fontFamily.split(',')) fontsUsed.add(family.trim().replace(/^['"]|['"]$/g, '').toLowerCase())
            for (const property of cssProperties) {
                if (style.visibility !== 'visible' && ['background-image', 'list-style-image'].includes(property)) continue
                const value = style.getPropertyValue(property)
                if (value) target.style.setProperty(property, cssURLs(value, base, svg))
            }
        }
        const updateCounters = (style, counters, scope) => {
            for (const property of ['counter-reset', 'counter-set', 'counter-increment']) {
                const value = style.getPropertyValue(property)
                if (!value || value === 'none') continue
                for (const part of value.matchAll(/([^\s]+)(?:\s+(-?\d+))?/g)) {
                    const name = part[1], amount = part[2] === undefined ? property === 'counter-increment' ? 1 : 0 : Number(part[2])
                    let stack = counters.get(name)?.slice() || []
                    if (property === 'counter-reset') {
                        if (stack.at(-1)?.scope === scope) stack.pop()
                        stack.push({value: amount, scope})
                    } else {
                        if (!stack.length) stack.push({value: 0, scope})
                        if (property === 'counter-set') stack.at(-1).value = amount
                        else stack.at(-1).value += amount
                    }
                    counters.set(name, stack)
                }
            }
        }
        const counterText = (value, format = 'decimal') => {
            if (format === 'decimal') return String(value)
            if (format === 'decimal-leading-zero') return String(value).padStart(2, '0')
            if (['lower-alpha', 'lower-latin', 'upper-alpha', 'upper-latin'].includes(format)) {
                let result = ''
                for (let number = value; number > 0; number = Math.floor((number - 1) / 26)) result = String.fromCharCode(97 + (number - 1) % 26) + result
                return format.startsWith('upper') ? result.toUpperCase() : result
            }
            if (['lower-roman', 'upper-roman'].includes(format)) {
                let number = value, result = ''
                for (const [amount, letters] of [[1000,'M'],[900,'CM'],[500,'D'],[400,'CD'],[100,'C'],[90,'XC'],[50,'L'],[40,'XL'],[10,'X'],[9,'IX'],[5,'V'],[4,'IV'],[1,'I']]) {
                    while (number >= amount) { result += letters; number -= amount }
                }
                return format === 'lower-roman' ? result.toLowerCase() : result
            }
            throw Error('Printed counter style cannot be captured: ' + format)
        }
        const generated = (element, pseudo, svg, counters, quotes) => {
            const style = element.ownerDocument.defaultView.getComputedStyle(element, pseudo)
            if (['none', 'normal'].includes(style.content) || style.display === 'none' || style.visibility !== 'visible') return null
            const span = output.createElement('span')
            applyComputedStyle(span, style, element.baseURI, svg)
            // CSSOM serializes strings with CSS escapes, and retains attr() on
            // older WebKit. Resolve those against the live originating element.
            const decode = text => text.replace(/\\([\da-f]{1,6})\s?|\\(.)/gi,
                (_, hex, character) => hex ? String.fromCodePoint(parseInt(hex, 16)) : character)
            updateCounters(style, counters, element)
            const tokenPattern = /"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|url\([^)]*\)|attr\([^)]*\)|counters?\([^)]*\)|(?:no-)?(?:open|close)-quote|\//g
            const tokens = style.content.match(tokenPattern) || []
            const unresolved = style.content.replace(tokenPattern, '').trim()
            if (unresolved) throw Error('Printed generated content cannot be captured: ' + style.content)
            for (const token of tokens) {
                if (token === '/') break // Following string is accessibility alternative text.
                if (/^url\(/i.test(token)) {
                    const image = output.createElement('img')
                    image.src = cssURLs(token, element.baseURI, svg).slice(5, -2); span.append(image)
                } else {
                    let text
                    if (token.startsWith('attr(')) text = element.getAttribute(token.slice(5, -1).trim()) || ''
                    else if (/^counters?\(/.test(token)) {
                        const parts = token.slice(token.indexOf('(') + 1, -1).match(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^,\s]+/g)
                        const stack = counters.get(parts[0]) || [{value: 0}]
                        const multiple = token.startsWith('counters(')
                        const format = parts[multiple ? 2 : 1] || 'decimal'
                        text = (multiple ? stack : stack.slice(-1)).map(counter => counterText(counter.value, format)).join(multiple ? decode(parts[1].slice(1, -1)) : '')
                    } else if (token.endsWith('-quote')) {
                        const pairs = style.quotes.match(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/g)?.map(pair => decode(pair.slice(1, -1))) || ['“', '”', '‘', '’']
                        const open = token.endsWith('open-quote')
                        if (!open) quotes.depth = Math.max(0, quotes.depth - 1)
                        text = token.startsWith('no-') || style.quotes === 'none' ? '' : pairs[Math.min(quotes.depth, pairs.length / 2 - 1) * 2 + (open ? 0 : 1)]
                        if (open) quotes.depth++
                    } else text = decode(token.slice(1, -1))
                    span.append(output.createTextNode(transformText(text, style, element)))
                }
            }
            return span
        }
        const capture = (element, svg = false, counters = new Map(), quotes = {depth: 0}) => {
            const doc = element.ownerDocument, win = doc.defaultView, style = win.getComputedStyle(element)
            const tag = element.localName
            if (['script', 'style', 'link', 'meta', 'base', 'head', 'source'].includes(tag) || style.display === 'none' || Number(style.opacity) === 0) return null
            if (style.visibility !== 'visible' && ['img', 'svg', 'canvas'].includes(tag)) return null
            if (tag === 'iframe' || tag === 'frame') {
                const child = element.contentDocument
                if (!child || !child.documentElement) throw Error('A printed frame document could not be read: ' + element.src)
                const url = new URL(child.URL)
                if (!(url.protocol === 'leaf:' && url.host === 'book') && url.protocol !== 'about:') throw Error('A printed frame is outside the publication: ' + child.URL)
                prepareDocument(child)
                const section = output.createElement('section')
                applyComputedStyle(section, style, element.baseURI, false)
                const body = capture(child.body || child.documentElement)
                if (body) section.append(body)
                return section
            }
            if (!svg && (tag === 'canvas' || tag === 'svg')) {
                const image = output.createElement('img')
                applyComputedStyle(image, style, element.baseURI, false)
                image.width = element.getBoundingClientRect().width; image.height = element.getBoundingClientRect().height
                let url
                if (tag === 'canvas') url = element.toDataURL('image/png')
                else {
                    const vector = capture(element, true)
                    vector.setAttribute('width', image.width); vector.setAttribute('height', image.height)
                    url = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(new XMLSerializer().serializeToString(vector))
                }
                image.setAttribute('src', resource(url, element.baseURI))
                return image
            }
            const form = ['input', 'textarea', 'select'].includes(tag)
            if (tag === 'input' && element.type === 'hidden') return null
            if (tag === 'input' && element.type === 'image') {
                if (style.visibility !== 'visible') return null
                const image = output.createElement('img')
                applyComputedStyle(image, style, element.baseURI, svg)
                image.setAttribute('src', resource(element.src, element.baseURI, svg))
                image.style.width = style.width; image.style.height = style.height
                return image
            }
            updateCounters(style, counters, element.parentElement)
            const target = form ? output.createElement('span') : output.importNode(element, false)
            // Authored CSS must not reapply screen media after capture.
            target.removeAttribute('style')
            for (const attribute of [...target.attributes]) if (/^on/i.test(attribute.name)) target.removeAttribute(attribute.name)
            applyComputedStyle(target, style, element.baseURI, svg)
            if (form) {
                let text = element.value
                if (tag === 'select') text = [...element.selectedOptions].map(option => option.text).join('\n')
                else if (element.type === 'checkbox' || element.type === 'radio') text = element.checked ? '☑' : '☐'
                else if (element.type === 'password') text = '•'.repeat(element.value.length)
                else if (element.type === 'file') text = [...element.files].map(file => file.name).join(', ')
                if (tag === 'textarea' || tag === 'select' && element.multiple) target.style.whiteSpace = 'pre-wrap'
                if (style.visibility === 'visible') target.textContent = transformText(text, style, element)
                return target
            }
            for (const attribute of ['href', 'xlink:href', 'src', 'poster', 'background']) {
                if (!element.hasAttribute(attribute)) continue
                const value = tag === 'img' && attribute === 'src' ? element.currentSrc || element.src : element.getAttribute(attribute)
                if (value.startsWith('#')) continue
                const asset = attribute !== 'href' && attribute !== 'xlink:href' || svg && ['image', 'use', 'feImage'].includes(tag)
                target.setAttribute(attribute, asset ? resource(value, element.baseURI, svg) : new URL(value, element.baseURI).href)
            }
            if (tag === 'img') {
                target.removeAttribute('srcset'); target.removeAttribute('sizes'); target.removeAttribute('loading')
                if (!element.hasAttribute('src') && element.currentSrc) target.setAttribute('src', resource(element.currentSrc, element.baseURI, svg))
                target.style.width = style.width; target.style.height = style.height
            }
            const childCounters = new Map(counters)
            const before = generated(element, '::before', svg, childCounters, quotes)
            if (before) target.append(before)
            for (const node of element.childNodes) {
                if (node.nodeType === Node.TEXT_NODE && style.visibility === 'visible') target.append(output.createTextNode(transformText(node.data, style, element)))
                else if (node.nodeType === Node.ELEMENT_NODE) { const child = capture(node, svg, childCounters, quotes); if (child) target.append(child) }
            }
            const after = generated(element, '::after', svg, childCounters, quotes)
            if (after) target.append(after)
            return target
        }
        try {
            prepareDocument(document)
            const body = capture(document.body || document.documentElement)
            output.body.replaceWith(body)
            output.documentElement.lang = document.documentElement.lang
            output.documentElement.dir = document.documentElement.dir
            const charset = output.createElement('meta'); charset.setAttribute('charset', 'utf-8'); output.head.prepend(charset)
            const usedFaces = fontFaces.filter(({rule}) => fontsUsed.has(rule.style.fontFamily.replace(/^['"]|['"]$/g, '').toLowerCase()))
            if (usedFaces.length) {
                const fonts = output.createElement('style'); fonts.textContent = usedFaces.map(({rule, base}) => cssURLs(rule.cssText, base)).join('\n'); output.head.append(fonts)
            }
            // CSSOM serializes legacy page-break aliases as modern break
            // properties. Append raw attributes only after all style edits;
            // MuPDF's parser consumes the legacy spelling.
            for (const target of output.querySelectorAll('[style]')) {
                const breaks = ['before', 'after', 'inside'].map(boundary => {
                    const value = target.style.getPropertyValue('break-' + boundary)
                    return value ? `page-break-${boundary}:${value === 'page' ? 'always' : value};` : ''
                }).join('')
                target.setAttribute('style', target.style.cssText + breaks)
            }
            return {html: '<!doctype html>\n' + output.documentElement.outerHTML, resources}
        } finally {
            for (const {list, original} of media.reverse()) list.mediaText = original
            // Force the restored reading layout before restoring offsets that a
            // temporarily shorter print layout may have clamped.
            for (const {win, x, y} of viewports.reverse()) { void win.document.documentElement.offsetHeight; win.scrollTo(x, y) }
        }
    }
    window.sumraRenderMermaid = async () => {
        if (!window.mermaid) return
        for (const code of document.querySelectorAll('pre > code[class~="language-mermaid" i]')) {
            const pre = code.parentElement; pre.textContent = code.textContent; pre.classList.add('mermaid')
        }
        const color = getComputedStyle(document.body).backgroundColor.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/i)
        const dark = color && (0.2126 * Number(color[1]) + 0.7152 * Number(color[2]) + 0.0722 * Number(color[3])) < 140
        mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default' })
        await mermaid.run({ querySelector: 'pre.mermaid' })
    }
    const isInput = target => target?.closest?.('input,textarea,select,[contenteditable]:not([contenteditable="false"])')
    window.leafInputFocused = () => focusedReader()?.leafInputFocused() || !!isInput(document.activeElement)
    document.addEventListener('focusin', event => post('inputFocus', { focused: !!isInput(event.target) }))
    document.addEventListener('focusout', event => post('inputFocus', { focused: !!isInput(event.relatedTarget) }))
    document.addEventListener('selectionchange', reportSelection)
    document.addEventListener('pointerdown', event => { pointer = { x: event.clientX, y: event.clientY } })
    document.addEventListener('pointerover', event => {
        const link = event.target.closest?.('a[href]')
        if (!interaction.hoverPreview || !link || link === previewLink) return
        clearLinkPreview()
        previewLink = link; previewTitle = link.getAttribute('title')
        link.title = fragmentTarget(link.hash)?.textContent.trim().slice(0, 500) || link.href
    })
    document.addEventListener('pointerout', event => {
        if (previewLink && event.relatedTarget?.closest?.('a[href]') !== previewLink) clearLinkPreview()
    })
    document.addEventListener('click', event => {
        const link = event.target.closest?.('a[href]')
        if (!link) return
        if (interaction.disableLinks) { event.preventDefault(); return }
        const url = localURL(link.getAttribute('href'))
        if (config.chm && url.protocol === 'javascript:') return
        // Native frame targets are part of the publication, not top-level
        // history entries. Let WebKit navigate those frames in place.
        if (url.protocol === 'leaf:' && ((!mainFrame && !['_top', '_blank'].includes(link.target))
            || link.target && !['_self', '_top', '_blank', '_parent'].includes(link.target))) {
            link.href = url.href; return
        }
        event.preventDefault()
        post(url.protocol === 'leaf:' ? 'navigate' : 'external', { href: url.href })
    })
    document.addEventListener('keydown', event => {
        if (event.metaKey || event.ctrlKey || isInput(event.target)) return
        if (interaction.keyboardLinks) {
            if (/^[0-9]$/.test(event.key)) { event.preventDefault(); linkDigits += event.key; post('status', { message: `Link ${linkDigits} · Return to follow` }); return }
            if (event.key === 'Enter') { event.preventDefault(); const link = [...document.querySelectorAll('a[data-sumra-link]')].find(link => link.dataset.sumraLink === linkDigits); linkDigits = ''; if (link && !interaction.disableLinks) link.click(); return }
            if (event.key === 'Escape') { event.preventDefault(); linkDigits = ''; interaction.keyboardLinks = false; updateInteraction(); post('keyboardMode', { links: false }); return }
        }
        if (interaction.keyboardSelection && ['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.key)) {
            event.preventDefault()
            if (!selection().rangeCount) { const range = visibleRange(); if (range) { range.collapse(true); selection().addRange(range) } }
            selection().modify(event.shiftKey ? 'extend' : 'move', ['ArrowLeft', 'ArrowUp'].includes(event.key) ? 'backward' : 'forward',
                ['ArrowUp', 'ArrowDown'].includes(event.key) ? 'line' : event.altKey ? 'word' : 'character')
        }
    })
    window.addEventListener('scroll', reportPosition, { passive: true })
    window.addEventListener('scroll', () => scheduleRangeHighlights(), { passive: true, capture: true })
    window.addEventListener('resize', resizeReadingViewport, { passive: true })
    window.addEventListener('hashchange', () => {
        if (ready) restore({ page: pageIndex(), anchor: location.href }).catch(error => post('error', { message: error.message }))
    })
    window.addEventListener('pagehide', () => {
        ++activationRevision; ++restoreRevision; restoring = false
        ready = false
        readingViewport = null
        outlineLoad = null; outlineDemand = false
        printViewport = null
        clearFind(false); clearLinkPreview()
        speechNodes = []; speechRange = null; CSS.highlights?.delete('sumra-speech'); scheduleRangeHighlights()
    })
    scheme.addEventListener('change', () => { if (String(typography).split('|')[4] === 'system') applyStyle() })
    if (!useDocumentCSS) applyDocumentCSS()
    applyStyle()
    // Native navigation completion owns activation and position restoration.
    // Sibling headings are read on demand by Contents or its palette mode.
    const start = async () => {
        if (config.chm) for (const element of document.querySelectorAll('[href],[src],[poster]')) {
            for (const attribute of ['href', 'src', 'poster']) {
                const value = element.getAttribute(attribute)
                if (value && (/^(?:mk:@MSITStore:|ms-its:|its:)/i.test(value) || value.includes('\\'))) element.setAttribute(attribute, localURL(value).href)
            }
        }
        if (document.readyState !== 'complete') await new Promise(resolve => window.addEventListener('load', resolve, { once: true }))
        await document.fonts.ready
        if (!mainFrame) {
            // A newly navigated child frame gets the current main-frame style
            // and interaction values without changing the main topic location.
            await window.top.leafApplyFrame?.(window)
        }
    }
    window.leafApplyFrame = reader => reader.leafCommand({ name: 'activate', text: typography, userCSS,
        useDocumentCSS, pageMargins: margins, flags: interaction })
    start().catch(error => post('error', { message: error.message }))
})()
