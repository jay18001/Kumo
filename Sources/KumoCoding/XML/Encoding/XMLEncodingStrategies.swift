import Foundation

struct XMLEncodingStrategies {

    let userInfo: [CodingUserInfoKey: Any]
    private let keyEncoding: (CodingKey) -> String
    private let nilEncoding: (inout XMLNode) -> ()
    private let inheritedNamespace: XMLNamespace?

    init(keyEncodingStrategy: XMLEncoder.KeyEncodingStrategy, nilEncoding: XMLEncoder.NilEncodingStrategy, namespace: XMLNamespace? = nil, userInfo: [CodingUserInfoKey: Any] = [:]) {
        self.keyEncoding = keyEncodingStrategy.convert(key:)
        self.nilEncoding = { node in
            switch nilEncoding {
            case .useNilAttribute:
                node.attributes["xsi:nil"] = "true"
            case .leaveEmpty:
                node.child = .text("")
            }
        }
        self.inheritedNamespace = namespace
        self.userInfo = userInfo
    }

    private init(from strategies: XMLEncodingStrategies, under key: CodingKey) {
        self.userInfo = strategies.userInfo
        self.keyEncoding = strategies.keyEncoding
        self.nilEncoding = strategies.nilEncoding
        switch (strategies.userInfo[.xmlNamespaces] as? [HashedCodingKey: XMLNamespaceUsage])?[key] {
        case .some(.useBeneath(let namespace)), .some(.defineBeneath(let namespace)):
            inheritedNamespace = namespace
        default: inheritedNamespace = strategies.inheritedNamespace
        }
    }

    func createNode(under key: CodingKey) -> XMLNode {
        let name: String
        let attributes: [String: String]
        switch (userInfo[.xmlNamespaces] as? [HashedCodingKey: XMLNamespaceUsage])?[key] {
        case .some(.use(let namespace)):
            name = "\(namespace.prefix):\(keyEncoding(key))"
            attributes = [:]
        case .some(.define(using: let namespace, including: let namespaces)):
            name = "\(namespace.prefix):\(keyEncoding(key))"
            attributes = Dictionary(uniqueKeysWithValues: ([namespace] + namespaces).map { ($0.attributeName, $0.uri ?? "") })
        case .some(.useBeneath(let namespace)):
            name = "\(namespace.prefix):\(keyEncoding(key))"
            attributes = [:]
        case .some(.defineBeneath(let namespace)):
            name = "\(namespace.prefix):\(keyEncoding(key))"
            attributes = [namespace.attributeName: namespace.uri ?? ""]
        case .none where inheritedNamespace != nil:
            name = "\(inheritedNamespace!.prefix):\(keyEncoding(key))"
            attributes = [:]
        default:
            name = keyEncoding(key)
            attributes = [:]
        }
        return XMLNode(name: name, attributes: attributes)
    }

    func createNode(listedUnder node: XMLNode) -> XMLNode {

        guard let key = CodingUserInfoKey(rawValue: node.name), let name = userInfo[key] as? String else {
            fatalError("""
                        Attempted to add an element listed under \(node) but no element name was assigned.
                        Add an element name by calling addElementNameForList(elementName:list) on the XMLEncoder.
                        Example, given the following xml:

                            ```
                            <?xml version="1.0"?>
                            <ListContainer xmlns="urn:xml.is.bad">
                                <SimpleList>
                                    <Element>xml</Element>
                                    <Element>is</Element>
                                    <Element>bad</Element>
                                </SimpleList>
                            </ListContainer>
                            ```

                        Call the following:

                            `encoder.addElementNameForList(elementName: "Element", list: "SimpleList")`
                       """)
        }
        return XMLNode(name: name, attributes: [:])
    }

    func encodeNil(in node: inout XMLNode) {
        nilEncoding(&node)
    }

    func strategies(for key: CodingKey) -> XMLEncodingStrategies {
        return XMLEncodingStrategies(from: self, under: key)
    }

}
