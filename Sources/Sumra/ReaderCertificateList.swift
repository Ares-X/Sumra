import Foundation
import CryptoKit
import SumraCore

// Direct macOS translation of pinned EutlTrust.cpp: an explicitly downloaded
// certificate-fingerprint list. Membership never changes SecTrust results.
enum ReaderCertificateList {
    struct Snapshot: Codable, Sendable {
        let fingerprints: Set<String>
        let updated: Date
        let nationalLists: Int

        func contains(_ certificate: Data) -> Bool {
            fingerprints.contains(ReaderCertificateList.fingerprint(certificate))
        }
    }
    struct Update: Sendable {
        let snapshot: Snapshot
        let failures: [String]
    }
    static let lotlURL = URL(string: "https://ec.europa.eu/tools/lotl/eu-lotl.xml")!
    static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sumra", isDirectory: true).appendingPathComponent("eutl.json")
    }

    static func read(from url: URL = cacheURL) throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
    }

    static func update(at url: URL = cacheURL,
                       fetch: @Sendable (URL) async throws -> Data = { try await download($0) }) async throws -> Update {
        let lotl = try parse(await fetch(lotlURL))
        var fingerprints = lotl.fingerprints, fetched = 0, failures = [String]()
        for target in lotl.locations {
            guard let address = URL(string: target), ["http", "https"].contains(address.scheme?.lowercased() ?? ""),
                  address.path.lowercased().hasSuffix("xml") || address.path.lowercased().hasSuffix("xtsl") else { continue }
            try Task.checkCancellation()
            do {
                let list = try parse(await fetch(address))
                fingerprints.formUnion(list.fingerprints); fetched += 1
            } catch is CancellationError { throw CancellationError() }
            catch { failures.append("\(address.absoluteString): \(error.localizedDescription)") }
        }
        guard !fingerprints.isEmpty else { throw ReadError("The EU Trusted List contained no certificates") }
        try Task.checkCancellation()
        let snapshot = Snapshot(fingerprints: fingerprints, updated: Date(), nationalLists: fetched)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Fatal LOTL/empty-list/write failures preserve the prior cache;
        // unavailable national lists are reported as partial, like upstream.
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        return Update(snapshot: snapshot, failures: failures)
    }

    private static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw ReadError("Cannot download the EU Trusted List (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        return data
    }

    static func parse(_ data: Data) throws -> (fingerprints: Set<String>, locations: [String]) {
        let parser = XMLParser(data: data), contents = Contents()
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = contents
        guard parser.parse() else { throw parser.parserError ?? ReadError("Cannot read EU Trusted List XML") }
        return (contents.fingerprints, contents.locations)
    }

    private static func fingerprint(_ certificate: Data) -> String {
        SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
    }

    private final class Contents: NSObject, XMLParserDelegate {
        var fingerprints = Set<String>(), locations = [String]()
        private var element: String?, text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if elementName == "X509Certificate" || elementName == "TSLLocation" { element = elementName; text = "" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if element != nil { text += string }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard element == elementName else { return }
            if elementName == "X509Certificate", let der = Data(base64Encoded: text.filter { !$0.isWhitespace }), !der.isEmpty {
                fingerprints.insert(ReaderCertificateList.fingerprint(der))
            } else if elementName == "TSLLocation" {
                let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !address.isEmpty { locations.append(address) }
            }
            element = nil; text = ""
        }
    }
}
