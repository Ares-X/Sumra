#if os(macOS)
import AppKit
import SumraCore
import WebKit
import XCTest
@testable import Sumra

final class BrowserReadingModesTests: XCTestCase {
    @MainActor
    private func reader(markdown: Bool = false, html: String? = nil, styles: [String: String] = [:]) async throws -> (WKWebView, BrowserReader.Coordinator, NSWindow) {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let paragraphs = (0..<120).map { index in
            "Passage \(index). " + String(repeating: "Original source glyphs 中文 Ω remain selectable. ", count: 8)
        }
        let file = directory.url.appendingPathComponent(markdown ? "topic.md" : "topic.html")
        let content = html ?? (markdown ? paragraphs.joined(separator: "\n\n")
            : "<!doctype html><meta charset=utf-8><input id=field value=original>" +
                paragraphs.map { "<p>\($0)</p>" }.joined())
        for (name, css) in styles {
            try css.write(to: directory.url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try content.write(to: file, atomically: true, encoding: .utf8)
        let state = ReaderState(recordsHistory: false)
        state.document = try ReadingDocument.open(file, markdownRenderer: .compatible)
        state.flow = "continuous"; state.spread = false; state.rtl = false
        state.font = "system"; state.fontSize = 17; state.lineHeight = 1.6; state.margin = 32
        state.theme = "light"; state.zoom = 1; state.userCSS = ""; state.useDocumentCSS = true
        guard case .browser(let source) = state.document?.content else { throw ReadError("Expected browser fixture") }
        let coordinator = BrowserReader.Coordinator(state: state, source: source)
        let view = coordinator.makeView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        addTeardownBlock { @MainActor in
            BrowserReader.dismantleNSView(view, coordinator: coordinator)
            state.windowClosed(); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        coordinator.load(view)
        let deadline = Date().addingTimeInterval(10)
        while !coordinator.ready, coordinator.readerError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if let error = coordinator.readerError { throw error }
        XCTAssertTrue(coordinator.ready)
        return (view, coordinator, window)
    }

    @MainActor
    private func evaluate(_ script: String, view: WKWebView, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let result = try await view.callAsyncJavaScript(script, arguments: arguments, in: nil,
            contentWorld: .world(name: "SumraMarkup"))
        return try XCTUnwrap(result as? [String: Any])
    }

    @MainActor
    func testProgressSeeksCurrentFileAcrossContinuousPagedAndRTL() async throws {
        let (view, coordinator, _) = try await reader()
        for (flow, rtl) in [("continuous", false), ("paged", false), ("paged", true)] {
            let result = try await evaluate("""
                await window.leafCommand({name:'style',flow,rtl,spread:false});
                const samples=[];
                for(const value of [0,0.5,1]) {
                    await window.leafCommand({name:'progress',value});
                    const extent=flow==='paged'?document.documentElement.scrollWidth-innerWidth:document.documentElement.scrollHeight-innerHeight;
                    const offset=flow==='paged'?scrollX*(rtl?-1:1):scrollY;
                    samples.push(offset/extent);
                }
                return {samples};
                """, view: view, arguments: ["flow": flow, "rtl": rtl])
            let values = try XCTUnwrap(result["samples"] as? [Double])
            XCTAssertEqual(values[0], 0, accuracy: 0.001)
            XCTAssertEqual(values[1], 0.5, accuracy: 0.04)
            XCTAssertEqual(values[2], 1, accuracy: 0.001)
        }
        // Position posts preserve file counts while reporting local scroll.
        let deadline = Date().addingTimeInterval(2)
        while coordinator.state.browserProgress != 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(coordinator.state.browserProgress ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(coordinator.state.count, 1)
    }

    @MainActor
    func testMarkdownAndHTMLSwitchBetweenVerticalContinuousSingleAndSpreadWithoutReplacingDOM() async throws {
        for markdown in [false, true] {
            let (view, _, _) = try await reader(markdown: markdown)
            let result = try await evaluate("""
                const first = document.querySelector('p'), text = first.firstChild;
                const range = document.createRange(); range.setStart(text, 0); range.setEnd(text, 9);
                getSelection().removeAllRanges(); getSelection().addRange(range);
                const selected = getSelection().toString();
                const field = document.getElementById('field'); if (field) field.value = 'Edited live value';
                await window.leafCommand({name:'turnPages',count:1});
                const continuousY = scrollY;
                await window.leafCommand({name:'style',flow:'paged',spread:false,rtl:false});
                await window.leafCommand({name:'location',text:'first'});
                await window.leafCommand({name:'turnPages',count:1});
                const single = {x:scrollX,y:scrollY,columns:getComputedStyle(document.body).columnCount};
                await window.leafCommand({name:'style',flow:'paged',spread:true});
                await window.leafCommand({name:'location',text:'first'});
                await window.leafCommand({name:'turnPages',count:1});
                const double = {x:scrollX,y:scrollY,columns:getComputedStyle(document.body).columnCount};
                await window.leafCommand({name:'style',flow:'continuous',spread:false});
                await window.leafCommand({name:'location',text:'first'});
                await window.leafCommand({name:'turnPages',count:1});
                return {continuousY,single,double,finalY:scrollY,finalX:scrollX,width:innerWidth,
                    sameNode:first===document.querySelector('p'),selected:getSelection().toString()===selected,
                    form:!field||field.value==='Edited live value'};
                """, view: view)
            XCTAssertGreaterThan(try XCTUnwrap(result["continuousY"] as? Double), 0)
            XCTAssertGreaterThan(try XCTUnwrap(result["finalY"] as? Double), 0)
            XCTAssertEqual(try XCTUnwrap(result["finalX"] as? Double), 0, accuracy: 1)
            for (key, columns) in [("single", "1"), ("double", "2")] {
                let mode = try XCTUnwrap(result[key] as? [String: Any])
                XCTAssertEqual(mode["columns"] as? String, columns)
                XCTAssertEqual(try XCTUnwrap(mode["x"] as? Double), try XCTUnwrap(result["width"] as? Double), accuracy: 1)
                XCTAssertEqual(try XCTUnwrap(mode["y"] as? Double), 0, accuracy: 1)
            }
            XCTAssertEqual(result["sameNode"] as? Bool, true)
            XCTAssertEqual(result["selected"] as? Bool, true)
            XCTAssertEqual(result["form"] as? Bool, true)
        }
    }

    @MainActor
    func testContinuousWholeDOMRestoresParagraphFlowWithoutViewportSeams() async throws {
        for (markdown, chmTopicStyle) in [(false, false), (true, false), (false, true)] {
            let (view, _, _) = try await reader(markdown: markdown)
            let result = try await evaluate("""
                // Exercise CHM's shared topic style path on the same HTML DOM;
                // archive decoding and topic navigation have separate fixtures.
                window.sumraDocument.chm=chmTopicStyle;
                await window.leafCommand({name:'style',flow:'continuous',spread:false,rtl:false});
                await window.leafCommand({name:'location',text:'first'});
                const paragraphs=[...document.querySelectorAll('p')],original=document.body.innerHTML;
                const boxes=()=>paragraphs.map(p=>{const r=p.getBoundingClientRect();
                    return {top:r.top+scrollY,height:r.height,left:r.left,rects:p.getClientRects().length};});
                const before=boxes();
                await window.leafCommand({name:'style',flow:'paged',spread:true,rtl:true});
                await window.leafCommand({name:'turnPages',count:2});
                await window.leafCommand({name:'style',flow:'continuous',spread:false,rtl:false});
                await window.leafCommand({name:'location',text:'first'});
                const after=boxes(),style=getComputedStyle(document.body);
                const sameFlow=before.every((box,i)=>Math.abs(box.top-after[i].top)<1&&
                    Math.abs(box.height-after[i].height)<1&&Math.abs(box.left-after[i].left)<1&&after[i].rects===1);
                const crossing=paragraphs.find(p=>p.getBoundingClientRect().bottom>=innerHeight);
                scrollTo(0,innerHeight-12);
                const firstY=scrollY,firstTop=crossing.getBoundingClientRect().top;
                scrollTo(0,innerHeight+12);
                const secondY=scrollY,secondTop=crossing.getBoundingClientRect().top;
                return {sameFlow,columns:style.columnCount,columnWidth:style.columnWidth,
                    wholeBody:document.body.getBoundingClientRect().height>innerHeight*5,
                    sameDOM:document.body.innerHTML===original&&paragraphs.every(p=>p.isConnected),
                    deltaY:secondY-firstY,deltaTop:firstTop-secondTop,x:scrollX};
                """, view: view, arguments: ["chmTopicStyle": chmTopicStyle])
            let context = "markdown=\(markdown), CHM topic style=\(chmTopicStyle)"
            XCTAssertEqual(result["sameFlow"] as? Bool, true, context)
            XCTAssertEqual(result["columns"] as? String, "auto", context)
            XCTAssertEqual(result["columnWidth"] as? String, "auto", context)
            XCTAssertEqual(result["wholeBody"] as? Bool, true, context)
            XCTAssertEqual(result["sameDOM"] as? Bool, true, context)
            XCTAssertEqual(try XCTUnwrap(result["deltaY"] as? Double), 24, accuracy: 1, context)
            XCTAssertEqual(try XCTUnwrap(result["deltaTop"] as? Double), 24, accuracy: 1, context)
            XCTAssertEqual(result["x"] as? Double, 0, context)
        }
    }

    @MainActor
    func testRTLTurnsAndDirectionalCommandsUseTheSameColumnsAndSearchKeepsSelection() async throws {
        let (view, _, _) = try await reader()
        let result = try await evaluate("""
            await window.leafCommand({name:'style',flow:'paged',spread:true,rtl:true});
            await window.leafCommand({name:'location',text:'first'});
            await window.leafCommand({name:'turnPages',count:1});
            const forward = scrollX;
            await window.leafCommand({name:'scroll',direction:'right',amount:'page',count:1});
            const backward = scrollX;
            await window.leafCommand({name:'scroll',direction:'left',amount:'page',count:1});
            const left = scrollX;
            const node = document.querySelector('p').firstChild;
            const range = document.createRange(); range.setStart(node,0); range.setEnd(node,9);
            getSelection().removeAllRanges(); getSelection().addRange(range);
            const selected = getSelection().toString();
            await window.__sumatraFind.start('Passage 85.',true,false,1);
            const current = window.__sumatraFind.currentRange(), rect = current.getBoundingClientRect();
            return {forward,backward,left,width:innerWidth,selected:getSelection().toString()===selected,
                found:current.toString(),visible:rect.right>0&&rect.left<innerWidth};
            """, view: view)
        let width = try XCTUnwrap(result["width"] as? Double)
        XCTAssertEqual(try XCTUnwrap(result["forward"] as? Double), -width, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(result["backward"] as? Double), 0, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(result["left"] as? Double), -width, accuracy: 1)
        XCTAssertEqual(result["selected"] as? Bool, true)
        XCTAssertEqual(result["found"] as? String, "Passage 85.")
        XCTAssertEqual(result["visible"] as? Bool, true)
    }

    @MainActor
    func testBareArrowKeysTurnSingleAndSpreadPagesInBothReadingDirections() async throws {
        for markdown in [false, true] {
            let (view, _, _) = try await reader(markdown: markdown)
            let result = try await evaluate("""
                const modes=[];
                const arrow=key=>{const event=new KeyboardEvent('keydown',{key,bubbles:true,cancelable:true});
                    document.body.dispatchEvent(event);return event.defaultPrevented;};
                for(const spread of [false,true])for(const rtl of [false,true]){
                    await window.leafCommand({name:'style',flow:'paged',spread,rtl});
                    await window.leafCommand({name:'location',text:'first'});
                    const forwardHandled=arrow(rtl?'ArrowLeft':'ArrowRight'),forward=scrollX;
                    const backwardHandled=arrow(rtl?'ArrowRight':'ArrowLeft'),backward=scrollX;
                    modes.push({spread,rtl,forward,backward,forwardHandled,backwardHandled,width:innerWidth});
                }
                await window.leafCommand({name:'style',flow:'continuous',spread:false,rtl:false});
                await window.leafCommand({name:'location',text:'first'});
                const continuousHandled=arrow('ArrowRight');
                return {modes,continuousHandled,continuousX:scrollX,continuousY:scrollY};
                """, view: view)
            let modes = try XCTUnwrap(result["modes"] as? [[String: Any]])
            XCTAssertEqual(modes.count, 4)
            for mode in modes {
                let direction = mode["rtl"] as? Bool == true ? -1.0 : 1.0
                XCTAssertEqual(try XCTUnwrap(mode["forward"] as? Double), direction * (try XCTUnwrap(mode["width"] as? Double)), accuracy: 1)
                XCTAssertEqual(try XCTUnwrap(mode["backward"] as? Double), 0, accuracy: 1)
                XCTAssertEqual(mode["forwardHandled"] as? Bool, true)
                XCTAssertEqual(mode["backwardHandled"] as? Bool, true)
            }
            XCTAssertEqual(result["continuousHandled"] as? Bool, false)
            XCTAssertEqual(result["continuousX"] as? Double, 0)
            XCTAssertEqual(result["continuousY"] as? Double, 0)
        }
    }

    @MainActor
    func testArrowPageTurnsPreserveFormEditingSelectionModifiersAndNestedScrolling() async throws {
        let (view, _, _) = try await reader()
        let result = try await evaluate("""
            await window.leafCommand({name:'style',flow:'paged',spread:false,rtl:false});
            await window.leafCommand({name:'location',text:'first'});
            const arrow=(target,flags={})=>{const event=new KeyboardEvent('keydown',
                {key:'ArrowRight',bubbles:true,cancelable:true,...flags});target.dispatchEvent(event);
                return event.defaultPrevented;};
            const field=document.getElementById('field');field.value='Edited form';field.setSelectionRange(0,3);
            const formHandled=arrow(field),formX=scrollX;
            const editable=document.createElement('p');editable.contentEditable='true';editable.textContent='Editable text';
            document.body.append(editable);const editableHandled=arrow(editable),editableX=scrollX;
            const nested=document.createElement('div');nested.style.cssText='width:100px;height:40px;overflow:auto';
            nested.innerHTML='<div style="width:500px;height:150px">Nested content</div>';document.body.append(nested);
            const nestedHandled=arrow(nested.firstElementChild),nestedX=scrollX;
            const modifiers=[{shiftKey:true},{altKey:true},{ctrlKey:true},{metaKey:true}].map(flags=>arrow(document.body,flags));
            const modifiersX=scrollX;
            const text=document.querySelector('p').firstChild,range=document.createRange();
            range.setStart(text,0);range.setEnd(text,9);getSelection().removeAllRanges();getSelection().addRange(range);
            await window.leafCommand({name:'interaction',flags:{keyboardSelection:true}});
            const selectionHandled=arrow(document.body,{shiftKey:true});
            return {formHandled,formX,formValue:field.value,editableHandled,editableX,
                editableText:editable.textContent,nestedHandled,nestedX,modifiers,modifiersX,
                selectionHandled,selection:getSelection().toString(),selectionX:scrollX};
            """, view: view)
        for key in ["formHandled", "editableHandled", "nestedHandled"] {
            XCTAssertEqual(result[key] as? Bool, false, key)
        }
        for key in ["formX", "editableX", "nestedX", "modifiersX", "selectionX"] {
            XCTAssertEqual(try XCTUnwrap(result[key] as? Double), 0, accuracy: 1, key)
        }
        XCTAssertEqual(result["modifiers"] as? [Bool], [false, false, false, false])
        XCTAssertEqual(result["formValue"] as? String, "Edited form")
        XCTAssertEqual(result["editableText"] as? String, "Editable text")
        XCTAssertEqual(result["selectionHandled"] as? Bool, true)
        XCTAssertEqual(result["selection"] as? String, "Passage 0.")
    }

    @MainActor
    func testStyleBridgeAndModeReflowKeepTheVisibleSourceGlyph() async throws {
        for markdown in [false, true] {
            let (view, coordinator, window) = try await reader(markdown: markdown)
            coordinator.state.flow = "paged"; coordinator.state.spread = true; coordinator.state.rtl = true
            let arguments = coordinator.styleArguments()
            XCTAssertEqual(arguments["flow"] as? String, "paged")
            XCTAssertEqual(arguments["spread"] as? Bool, true)
            XCTAssertEqual(arguments["rtl"] as? Bool, true)
            let result = try await evaluate("""
                scrollTo(0,1400);
                const source = document.caretRangeFromPoint(40,1); source.collapse(true);
                window.modeSourceGlyph = source;
                const node = source.startContainer, offset = source.startOffset;
                const before = source.getBoundingClientRect().toJSON();
                await window.leafCommand({name:'style',flow:'paged',spread:true,rtl:true});
                const rect = source.getBoundingClientRect();
                const pagedVisible = rect.left>=-1&&rect.right<=innerWidth+1&&rect.bottom>=0&&rect.top<innerHeight;
                await window.leafCommand({name:'style',flow:'continuous',spread:false,rtl:false,text:'serif|22|1.8|32|light'});
                const continuous = source.getBoundingClientRect();
                return {pagedVisible,continuousVisible:continuous.bottom>=0&&continuous.top<innerHeight,
                    sameGlyph:node.isConnected&&source.startContainer===node&&source.startOffset===offset,
                    before,paged:rect.toJSON(),continuous:continuous.toJSON()};
                """, view: view)
            XCTAssertEqual(result["pagedVisible"] as? Bool, true, "markdown=\(markdown): \(result)")
            XCTAssertEqual(result["continuousVisible"] as? Bool, true, "markdown=\(markdown): \(result)")
            XCTAssertEqual(result["sameGlyph"] as? Bool, true)
            window.setContentSize(NSSize(width: 510, height: 380))
            let deadline = Date().addingTimeInterval(5)
            var resized: [String: Any] = [:]
            repeat {
                resized = try await evaluate("""
                    const range = window.modeSourceGlyph, rect = range.getBoundingClientRect();
                    return {width:innerWidth,visible:rect.bottom>=0&&rect.top<innerHeight,
                        connected:range.startContainer.isConnected,rect:rect.toJSON()};
                    """, view: view)
                if resized["width"] as? Double == 510, resized["visible"] as? Bool == true { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            } while Date() < deadline
            XCTAssertEqual(resized["width"] as? Double, 510)
            XCTAssertEqual(resized["visible"] as? Bool, true, "markdown=\(markdown): \(resized)")
            XCTAssertEqual(resized["connected"] as? Bool, true)
        }
    }

    @MainActor
    func testPagedEndStillNavigatesToTheNextChapter() async throws {
        for rtl in [false, true] {
            let (view, _, _) = try await reader()
            let result = try await evaluate("""
                await window.leafCommand({name:'style',flow:'paged',spread:true,rtl,
                    pageMargins:[10,20,30,40]});
                const next = new URL('chapter2.html',location.href).href;
                window.sumraDocument.pages.push(next);
                // Asymmetric margins produce a partial final spread. Restoring
                // its end must survive position reporting and reach the next topic.
                await window.leafCommand({name:'restore',position:{page:0,anchor:location.href+'#sumra-end'}});
                const extent = document.documentElement.scrollWidth - innerWidth;
                const end = Math.abs(scrollX);
                const navigation = await window.leafCommand({name:'turnPages',count:1});
                return {next,navigation:navigation?.navigation ?? null,y:scrollY,end,extent};
                """, view: view, arguments: ["rtl": rtl])
            XCTAssertEqual(try XCTUnwrap(result["end"] as? Double), try XCTUnwrap(result["extent"] as? Double), accuracy: 1, "rtl=\(rtl)")
            XCTAssertEqual(result["navigation"] as? String, result["next"] as? String, "rtl=\(rtl): \(result)")
            XCTAssertEqual(try XCTUnwrap(result["y"] as? Double), 0, accuracy: 1)
        }
    }

    @MainActor
    func testThemeOverridesImportantPublisherColorsWhileKeepingImagesAndExplicitUserCSS() async throws {
        let image = "url(data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7)"
        let (view, coordinator, _) = try await reader(html: """
            <!doctype html><meta charset=utf-8><link rel=stylesheet href=publisher.css>
            <body style="background:#000 \(image) repeat!important;color:white!important">
            <p id=classBlock class=black>Class block</p>
            <p id=inlineBlock style="background:#000 \(image) left top/2px 2px repeat!important;color:white!important;padding:17px!important">Inline block</p>
            </body>
            """, styles: ["publisher.css": "@import url(imported.css);",
                           "imported.css": "@media screen {#classBlock.black{background:#000 \(image) repeat!important;color:white!important;padding:13px!important}}"])
        let script = """
            await window.leafCommand(command);
            const values = id => {const style=getComputedStyle(document.getElementById(id));
                return {color:style.color,background:style.backgroundColor,image:style.backgroundImage,padding:style.paddingTop};};
            return {classBlock:values('classBlock'),inlineBlock:values('inlineBlock'),
                paper:getComputedStyle(document.body).backgroundColor,bodyImage:getComputedStyle(document.body).backgroundImage};
            """
        for theme in ["light", "solarized-dark"] {
            coordinator.state.theme = theme
            var arguments = coordinator.styleArguments(); arguments["name"] = "style"
            let result = try await evaluate(script, view: view, arguments: ["command": arguments])
            let palette = coordinator.state.palette
            let color = "rgb(\((palette.text >> 16) & 255), \((palette.text >> 8) & 255), \(palette.text & 255))"
            let paper = "rgb(\((palette.background >> 16) & 255), \((palette.background >> 8) & 255), \(palette.background & 255))"
            XCTAssertEqual(result["paper"] as? String, paper)
            XCTAssertNotEqual(result["bodyImage"] as? String, "none")
            for (key, padding) in [("classBlock", "13px"), ("inlineBlock", "17px")] {
                let block = try XCTUnwrap(result[key] as? [String: Any])
                XCTAssertEqual(block["color"] as? String, color)
                XCTAssertEqual(block["background"] as? String, "rgba(0, 0, 0, 0)")
                XCTAssertNotEqual(block["image"] as? String, "none")
                XCTAssertEqual(block["padding"] as? String, padding)
            }
        }
        coordinator.state.userCSS = "#inlineBlock{color:#102030!important;background-color:#abcdef!important}"
        var arguments = coordinator.styleArguments(); arguments["name"] = "style"
        let result = try await evaluate(script, view: view, arguments: ["command": arguments])
        let custom = try XCTUnwrap(result["inlineBlock"] as? [String: Any])
        XCTAssertEqual(custom["color"] as? String, "rgb(16, 32, 48)")
        XCTAssertEqual(custom["background"] as? String, "rgb(171, 205, 239)")
        XCTAssertNotEqual(custom["image"] as? String, "none")
    }
}
#endif
