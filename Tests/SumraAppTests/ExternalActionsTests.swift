#if os(macOS)
import XCTest
@testable import Sumra

final class ExternalActionsTests: XCTestCase {
    func testTranslationDefaultsFollowSystemUntilTargetIsRemembered() {
        for (system, code) in [("en-US", "en"), ("fr-FR", "fr"), ("zh-Hans-CN", "zh-CN"),
                               ("zh-Hant", "zh-TW"), ("zh-HK", "zh-TW"), ("zh-MO", "zh-TW"), ("nb-NO", "no")] {
            XCTAssertEqual(ReaderTranslation.resolvedTarget(nil, preferredLanguages: [system]), code)
            XCTAssertEqual(ReaderTranslation.resolvedTarget("  ", preferredLanguages: [system]), code)
            XCTAssertEqual(ReaderTranslation.resolvedTarget("ja", preferredLanguages: [system]), "ja")
        }
        XCTAssertEqual(ReaderTranslation.resolvedTarget(nil, preferredLanguages: []), "en")
        XCTAssertEqual(ReaderTranslation.engine(nil, saved: "DeepL"), "deepl")
        XCTAssertEqual(ReaderTranslation.engine("google", saved: "deepl"), "google")
        XCTAssertEqual(ReaderTranslation.engine(nil, saved: "unknown"), "google")
    }

    func testTranslationLanguageNamesAndExistingISOCodesShareTheSameURLs() throws {
        let text = "Edited selection & words /?#%2F + 中文\nSecond line"
        let google = try XCTUnwrap(ReaderTranslation.url(provider: "google", source: "Auto", target: "Chinese (Traditional)", text: text))
        let query = try XCTUnwrap(URLComponents(url: google, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(google.host, "translate.google.com")
        XCTAssertEqual(query, [.init(name: "op", value: "translate"), .init(name: "sl", value: "auto"),
                               .init(name: "tl", value: "zh-TW"), .init(name: "text", value: text)])
        XCTAssertEqual(ReaderTranslation.url(provider: "google", source: "auto", target: "zh-TW", text: text), google)
        XCTAssertEqual(ReaderTranslation.languageCode(" eo ", source: false), "eo", "Existing custom ISO settings remain usable")
        XCTAssertEqual(ReaderTranslation.resolvedTarget("pt-BR", preferredLanguages: ["en-US"]), "pt-br")
        XCTAssertEqual(ReaderTranslation.languageCode("en-GB", source: false), "en-gb")
        XCTAssertEqual(ReaderTranslation.languageCode("unknown language name", source: true), "auto")
        XCTAssertEqual(ReaderTranslation.languageCode("unknown language name", source: false), "en")

        let deepL = try XCTUnwrap(ReaderTranslation.url(provider: "deepl", source: "English", target: "zh-Hant", text: text))
        let fragment = try XCTUnwrap(URLComponents(url: deepL, resolvingAgainstBaseURL: false)?.percentEncodedFragment)
        XCTAssertEqual(deepL.host, "www.deepl.com")
        XCTAssertEqual(fragment.split(separator: "/").map { String($0).removingPercentEncoding }, ["en", "zh", text])
        XCTAssertNil(ReaderTranslation.url(provider: "google", source: "English", target: "en", text: text))
        XCTAssertNil(ReaderTranslation.url(provider: "deepl", source: "auto", target: "en", text: " \n\t"))
    }

    func testViewerCoordinatesAndWildcardFilters() throws {
        let command = try XCTUnwrap(ExternalReaderCommand.read("""
        [{"name":"Viewer","arguments":["open","%1","page=%p&zoom=%z,%x,%y","%%d"],"filter":"*.pdf;*.xps"}]
        """).first)
        let file = URL(fileURLWithPath: "/tmp/Book.PDF")
        XCTAssertTrue(command.matches(file))
        XCTAssertFalse(command.matches(file.deletingPathExtension().appendingPathExtension("txt")))
        let variables = try ExternalReaderCommand.variables(file: file, page: 2, selection: "", zoom: 125, x: 20, y: 30)
        XCTAssertEqual(ExternalReaderCommand.expand(command.arguments, replacements: variables),
                       ["open", file.path, "page=3&zoom=125.0,20.0,30.0", "%d"])
    }
    func testURLHandlerEscapesSelectionAndKeepsLiteralTemplateText() throws {
        let command = try XCTUnwrap(ExternalReaderCommand.read("""
        [{"name":"Search","url":"https://example.test/search?q=${selection}","shortcut":"cmd+shift+g"}]
        """).first)
        XCTAssertTrue(command.arguments.isEmpty)
        let selected = "A&B=?# ${userlang} 中文"
        let variables = try ExternalReaderCommand.variables(file: URL(fileURLWithPath: "/tmp/Book.pdf"), page: 0, selection: selected)
        let url = try ExternalReaderCommand.handlerURL(try XCTUnwrap(command.url), variables: variables)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [.init(name: "q", value: selected)])
        XCTAssertThrowsError(try ExternalReaderCommand.handlerURL("javascript://execute", variables: variables))
        let path = "/tmp/A&B?#.pdf"
        let pathValues = try ExternalReaderCommand.variables(file: URL(fileURLWithPath: path), page: 0, selection: selected)
        let pathURL = try ExternalReaderCommand.handlerURL("https://example.test/?file={file}&json=${selectionjson}", variables: pathValues)
        let query = try XCTUnwrap(URLComponents(url: pathURL, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first?.value, path)
        XCTAssertEqual(query.count, 2)
    }
    func testPOSTBodyUsesJSONEscapingAndBrowserFormCannotInjectFields() throws {
        let selection = "\"<&\ntext=second ${userlang}"
        let variables = try ExternalReaderCommand.variables(file: URL(fileURLWithPath: "/tmp/Book.pdf"), page: 0,
            selection: selection, language: "zh-Hans", selectionFile: "/tmp/Selection.txt", selectionPosition: CGRect(x: 10, y: 20, width: 30, height: 40))
        let url = try XCTUnwrap(URL(string: "https://example.test/post"))
        let request = ExternalReaderCommand.postRequest(url: url, body: "{\"text\":\"${selectionjson}\"}", contentType: "application/json", headers: ["X-Test": "Value"], variables: variables)
        let data = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: String], ["text": selection])
        XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.value(forHTTPHeaderField: "X-Test"), "Value")
        let html = ExternalReaderCommand.formHTML(url: url, body: "text=${selection}&lang=${userlang}", variables: variables)
        XCTAssertEqual(html.components(separatedBy: "<input ").count - 1, 2)
        XCTAssertTrue(html.contains("&quot;&lt;&amp;&#10;text=second ${userlang}"))
        XCTAssertEqual(ExternalReaderCommand.expand(["${selectionfile}", "${selectionPosition}"], replacements: variables), ["/tmp/Selection.txt", "10,20,30,40"])
    }
    func testHandlerRejectsUnusableConfiguration() {
        for json in [
            "[{\"name\":\"Both\",\"arguments\":[\"open\"],\"url\":\"https://example.test\"}]",
            "[{\"name\":\"Method\",\"url\":\"https://example.test\",\"method\":\"DELETE\"}]",
            "[{\"name\":\"Shortcut\",\"arguments\":[\"open\"],\"shortcut\":\"cmd+unknownkey\"}]",
            "[{\"name\":\"Headers\",\"url\":\"https://example.test\",\"method\":\"POST-VIA-BROWSER\",\"headers\":{\"X-Test\":\"value\"}}]"
        ] { XCTAssertThrowsError(try ExternalReaderCommand.read(json)) }
    }
    func testSubstitutionPreservesLiteralArgumentsAndDoesNotReexpandValues() throws {
        let command = try ExternalReaderCommand.read("""
        [{"name":"Editor","arguments":["/usr/bin/open","{file}","{selection}","page={page}"]}]
        """).first!
        let file = URL(fileURLWithPath: "/tmp/书 {selection}.pdf")
        let variables = try ExternalReaderCommand.variables(file: file, page: 4, selection: "{file} $(touch nope) 'x'\n")
        XCTAssertEqual(ExternalReaderCommand.expand(command.arguments, replacements: variables),
                       ["/usr/bin/open", file.path, "{file} $(touch nope) 'x'\n", "page=5"])
    }

    func testInvalidExecutableAndDuplicateNamesCannotBeSaved() {
        XCTAssertThrowsError(try ExternalReaderCommand.read("""
        [{"name":"Empty","arguments":[]}]
        """))
        XCTAssertThrowsError(try ExternalReaderCommand.read("""
        [{"name":"Same","arguments":["open"]},{"name":"Same","arguments":["other"]}]
        """))
    }
}
#endif
