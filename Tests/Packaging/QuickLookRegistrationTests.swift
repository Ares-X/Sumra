
import UniformTypeIdentifiers

let registration = quickLookRegistration()
let declarations = registration.exported + registration.imported
let registeredIDs = Set(declarations.compactMap { $0["UTTypeIdentifier"] as? String })
precondition(Set(registration.contentTypes) == registeredIDs.union(["org.idpf.epub-container"]))
var registeredExtensions = Set<String>()
for declaration in declarations {
    let parents = declaration["UTTypeConformsTo"] as! [String]
    precondition(parents.contains("public.content"), "Quick Look documents must be content types")
    // Finder resolves file URLs with a physical data-type constraint. Semantic
    // categories such as public.archive do not supply that conformance.
    precondition(parents.contains { UTType($0)?.conforms(to: .data) == true },
                 "\(declaration["UTTypeIdentifier"]!) must represent a physical file")
    let tags = declaration["UTTypeTagSpecification"] as! [String: [String]]
    registeredExtensions.formUnion(tags["public.filename-extension"]!)
}
precondition(Set(["cbz", "cbr", "cbt", "cb7", "mobi", "prc", "azw", "azw3", "fb2"]).isSubset(of: registeredExtensions))
precondition(registeredExtensions.isDisjoint(with: ["pdf", "zip", "rar", "7z"]))
precondition(registration.contentTypes.contains("com.bandisoft.cbz"), "Existing Finder CBZ metadata can use Bandizip's identifier")
let plist = try PropertyListSerialization.data(fromPropertyList: declarations, format: .xml, options: 0)
let decoded = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [[String: Any]]
precondition(decoded?.count == declarations.count)
print("Quick Look registration checks passed (host and both extensions share \(registration.contentTypes.count) content types).")
