#if os(macOS)
import Foundation
import SumraCore

// The GUI file tools share the caller's Save Copy of the live document,
// including its edits. MuPDF's existing writers own each output policy.
enum NativePDFOutput {
    enum Operation: Sendable {
        case extract([Int], annotationsOnly: Bool)
        case delete([Int], count: Int)
        case merge([(url: URL, password: String)])
        case transform(PDFAdvancedOperation)
        case encrypt(owner: String, user: String)
        case decrypt
    }

    static func write(snapshot: URL, password: String, operation: Operation, to destination: URL,
                      originalSources: [URL], invalidateSignatures: Bool = false) throws {
        guard !originalSources.contains(where: { PDFTools.sameFile($0, destination) }) else {
            throw ReadError("Choose a different file for tool output")
        }
        try Task.checkCancellation()
        switch operation {
        case .extract(let pages, let annotationsOnly):
            try NativePDFTools.selectPages(source: snapshot, destination: destination, pages: pages,
                annotationsOnly: annotationsOnly, password: password, invalidateSignatures: invalidateSignatures)
        case .delete(let pages, let count):
            let removed = Set(pages)
            guard count > 0, !removed.isEmpty, removed.allSatisfy({ (0..<count).contains($0) }) else {
                throw ReadError("Choose pages within the document")
            }
            let kept = (0..<count).filter { !removed.contains($0) }
            guard !kept.isEmpty else { throw ReadError("At least one PDF page must remain") }
            try NativePDFTools.selectPages(source: snapshot, destination: destination, pages: kept,
                password: password, invalidateSignatures: invalidateSignatures)
        case .merge(let others):
            try NativePDFTools.merge(sources: [(snapshot, password)] + others, destination: destination,
                invalidateSignatures: invalidateSignatures)
        case .transform(let operation):
            try NativePDFTools.transform(source: snapshot, destination: destination, operation: operation,
                password: password, invalidateSignatures: invalidateSignatures)
        case .encrypt(let owner, let user):
            try NativePDFTools.encrypt(source: snapshot, destination: destination, ownerPassword: owner, userPassword: user,
                documentPassword: password, invalidateSignatures: invalidateSignatures)
        case .decrypt:
            try NativePDFTools.decrypt(source: snapshot, destination: destination, password: password,
                invalidateSignatures: invalidateSignatures)
        }
    }
}
#endif
