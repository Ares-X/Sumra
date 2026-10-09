// CHM record/path and HHC traversal behavior follows SumatraPDF ChmFile.cpp
// and EngineEbook.cpp at 012d997f (GPLv3). WebKit supplies the HTML parser.
const base = 'leaf://book'
const entryURL = name => `${base}/entry/${name.replace(/^\/+/, '').replace(/\\/g, '/').split('/').map(encodeURIComponent).join('/')}`
const localHref = href => String(href ?? '').replace(/^(?:mk:@MSITStore:|ms-its:|its:).*?::\/?/i, '/').replace(/\\/g, '/')
const resourceURL = (href, relativeTo) => {
    // Like Sumatra's url::DecodeTemp, a malformed escape means a literal '%'.
    const value = localHref(href).replace(/%(?![\da-f]{2})/gi, '%25')
    return value.startsWith('/') ? new URL(value.replace(/^\/+/, ''), `${base}/entry/`).href : new URL(value, relativeTo).href
}
const parse = text => new DOMParser().parseFromString(text, 'text/html')
const flatten = (items = [], depth = 0) => items.flatMap(item => [
    { title: item.label || 'Untitled', target: item.href ?? '', depth },
    ...flatten(item.subitems, depth + 1),
])

const decodeHTML = (bytes, charset, { plain = false, preferUTF8 = true } = {}) => {
    // A BOM and explicit markup charset precede the CHM's system codepage.
    const array = new Uint8Array(bytes)
    if (array[0] === 0xff && array[1] === 0xfe) return new TextDecoder('utf-16le').decode(bytes)
    if (array[0] === 0xfe && array[1] === 0xff) return new TextDecoder('utf-16be').decode(bytes)
    if (array[0] === 0xef && array[1] === 0xbb && array[2] === 0xbf) return new TextDecoder().decode(bytes)
    let declared
    if (!plain) {
        const head = parse(new TextDecoder('windows-1252').decode(array.subarray(0, 1024)))
        declared = head.querySelector('meta[charset]')?.getAttribute('charset')
            ?? [...head.querySelectorAll('meta[http-equiv]')]
                .find(el => el.getAttribute('http-equiv').toLowerCase() === 'content-type')
                ?.getAttribute('content')?.match(/charset\s*=\s*["']?([^\s;"']+)/i)?.[1]
            ?? new TextDecoder('windows-1252').decode(array.subarray(0, 256))
                .match(/^\s*<\?xml\s[^>]*encoding\s*=\s*["']([^"']+)/i)?.[1]
    }
    if (!declared && preferUTF8) {
        try { return new TextDecoder('utf-8', { fatal: true }).decode(bytes) } catch { /* legacy CHM */ }
    }
    try {
        let decoder = new TextDecoder(declared || charset || 'windows-1252')
        // HTML declarations of UTF-16 mean UTF-8 unless a BOM already won.
        if (declared && ['utf-16le', 'utf-16be'].includes(decoder.encoding)) decoder = new TextDecoder()
        return decoder.decode(bytes)
    }
    catch { return new TextDecoder(charset || 'windows-1252').decode(bytes) }
}

const hhcContents = (doc, relativeTo) => {
    const result = []
    const itemFrom = object => {
        const params = Object.fromEntries([...object.children]
            .filter(el => el.localName === 'param')
            .map(el => [el.getAttribute('name')?.toLowerCase(), el.getAttribute('value')]))
        if (!params.name) return null
        let href
        try { if (params.local) href = resourceURL(params.local, relativeTo) } catch { /* title-only group */ }
        return { label: params.name, href, subitems: [] }
    }
    // Sumatra's WalkChmUl also accepts sibling ULs belonging to the preceding LI.
    const roots = [...doc.querySelectorAll('ul')].filter(el => !el.parentElement.closest('ul'))
    const stack = roots.reverse().map(ul => ({ elements: [...ul.children], index: 0, items: result, last: null }))
    while (stack.length) {
        const frame = stack[stack.length - 1]
        if (frame.index >= frame.elements.length) { stack.pop(); continue }
        const el = frame.elements[frame.index++]
        if (el.localName === 'ul') {
            const items = frame.last ? frame.last.subitems : frame.items
            stack.push({ elements: [...el.children], index: 0, items, last: null })
        } else if (el.localName === 'li') {
            const object = [...el.children].find(child => child.localName === 'object')
            const item = object && itemFrom(object)
            if (item) { frame.items.push(item); frame.last = item }
            const lists = [...el.children].filter(child => child.localName === 'ul')
            for (const ul of lists.reverse()) stack.push({ elements: [...ul.children], index: 0,
                items: item ? item.subitems : frame.items, last: null })
        }
    }
    if (!result.length) for (const object of doc.querySelectorAll('object[type="text/sitemap"]')) {
        const item = itemFrom(object)
        if (item) result.push(item)
    }
    return result
}

// ChmHtmlCollector: default topic, then HHC-linked entries, then unlisted HTML.
// The browser displays original topic bytes; no DOM-to-blob publication copy.
const indexCHM = async meta => {
    const entries = meta.entries.map(item => item.filename)
    const canonical = new Map(entries.map(path => [path.toLowerCase(), path]))
    const pathFor = href => {
        const url = new URL(href)
        return url.host === 'book' && url.pathname.startsWith('/entry/')
            ? canonical.get(decodeURIComponent(url.pathname.slice(7)).toLowerCase()) : null
    }
    const tocBytes = Uint8Array.from(atob(meta.tocData || ''), char => char.charCodeAt(0))
    let toc = meta.toc && tocBytes.length ? hhcContents(parse(decodeHTML(tocBytes, meta.charset)), entryURL(meta.toc)) : []
    const paths = [], seen = new Set()
    const add = href => {
        let path
        try { path = pathFor(resourceURL(href, `${base}/entry/`)) } catch { return }
        if (path && !seen.has(path)) { seen.add(path); paths.push(path) }
    }
    if (meta.home) add(meta.home)
    const available = entries.filter(path => /\.(?:html?|xhtml|xht|txt)$/i.test(path))
    if (!paths.length && available.length) add(entryURL(available.find(path => /(^|\/)(index|default|welcome)\.html?$/i.test(path)) || available[0]))
    for (const item of flatten(toc)) if (item.target) add(item.target)
    for (const path of available) add(entryURL(path))
    if (!paths.length) throw Error('This CHM contains no readable topics')
    const pages = paths.map(entryURL)
    if (!toc.length) toc = paths.map(path => ({ label: path, href: entryURL(path) }))
    const items = flatten(toc).map(item => {
        const path = item.target && pathFor(item.target)
        if (!path) return item
        const url = new URL(entryURL(path)); url.hash = new URL(item.target).hash
        return { ...item, target: url.href, page: paths.indexOf(path) }
    })
    return { pages, toc: items }
}
