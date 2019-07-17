import Foundation

class FileSystem: StorageLocation {

    weak var delegate: StoragePruningDelegate?

    private let backingManager: FileManager
    private let parentDirectory: URL

    init(backingManager: FileManager = .default, parentDirectory: URL? = nil) {
        self.backingManager = backingManager
        let bundle = Bundle(for: type(of: self))
        self.parentDirectory = parentDirectory ?? backingManager.cachesDirectory
            .appendingPathComponent("\(bundle.bundleIdentifier ?? "cache").\(Bundle.main.bundleIdentifier ?? "path")")
    }

    func fetch<D: _DataRepresentable>(for url: URL, arguments: D._RepresentationArguments) throws -> D? {
        let path = parentDirectory.appendingPathComponent(String(format: "%02x", url.hashValue))
        guard let data = backingManager.contents(atPath: path.path) else { return nil }
        let referenceDate: Date = try backingManager.valueForExtendedAttribute(.expirationDate, ofItemAtPath: path.path)
        let expirationDate: Date = try backingManager.valueForExtendedAttribute(.expirationReferenceDate, ofItemAtPath: path.path)
        let parameters = CachedObjectParameters(referenceDate: referenceDate, expirationDate: expirationDate)
        if let newExpirationDate = delegate?.newExpirationDate(given: parameters) {
            try backingManager.setExtendedAttributes([
                .expirationReferenceDate: parameters.referenceDate,
                .expirationDate: newExpirationDate
            ], ofItemAtPath: path.path)
        }
        return try D.init(data: data, using: arguments)
    }

    func write<D: _DataConvertible>(_ object: D, from url: URL, arguments: D._ConversionArguments) throws {
        let path = parentDirectory.appendingPathComponent(String(format: "%02x", url.hashValue))
        guard let data = try object.data(using: arguments) else {
            throw CacheSerializationError.dataConversionFailed(D.self, object: object, arguments: arguments)
        }
        let parameters = CachedObjectParameters()
        let initialExpirationDate = delegate?.newExpirationDate(given: parameters) ?? Date()
        backingManager.createFile(atPath: path.path, contents: data)
        try backingManager.setExtendedAttributes([
            .expirationReferenceDate: parameters.referenceDate,
            .expirationDate: initialExpirationDate
        ], ofItemAtPath: path.path)
    }

    func acquire<D: _DataRepresentable>(fromPath path: URL, origin url: URL, arguments: D._RepresentationArguments) throws -> D? {
        guard let data = backingManager.contents(atPath: path.path) else { return nil }
        let newPath = parentDirectory.appendingPathComponent(String(format: "%02x", url.hashValue))
        try backingManager.moveItem(at: path, to: newPath)
        let parameters = CachedObjectParameters()
        let initialExpirationDate = delegate?.newExpirationDate(given: parameters) ?? Date()
        try backingManager.setExtendedAttributes([
            .expirationReferenceDate: parameters.referenceDate,
            .expirationDate: initialExpirationDate
        ], ofItemAtPath: newPath.path)
        return try D.init(data: data, using: arguments)
    }

    func removeAll() {
        (backingManager.subpaths(atPath: parentDirectory.path) ?? []).forEach {
            try? backingManager.removeItem(atPath: $0)
        }
    }

    func pruneExpired() {
        (backingManager.subpaths(atPath: parentDirectory.path) ?? []).filter {
            // If a file exists in our path that doesn't match our implementation details, nuke it.
            guard let expirationDate: Date = try? backingManager.valueForExtendedAttribute(.expirationDate, ofItemAtPath: $0) else {
                return true
            }
            return expirationDate < Date().addingTimeInterval(.ulpOfOne)
        }
            .forEach { try? backingManager.removeItem(atPath: $0) }
    }

}

fileprivate extension ExtendedAttributeKey {

    private class BundleKey { }

    /// The date with which the expiration window of a cached file is calculated.
    static var expirationReferenceDate: ExtendedAttributeKey {
        return bundleKey()
    }

    /// The last time a file was accessed via a caching mechanism.
    static var lastAccessDate: ExtendedAttributeKey {
        return bundleKey()
    }

    /// The date at which a file will expire.
    static var expirationDate: ExtendedAttributeKey {
        return bundleKey()
    }

    private static func bundleKey(_ function: String = #function) -> ExtendedAttributeKey {
        return ExtendedAttributeKey(rawValue: "\(Bundle(for: BundleKey.self).bundleIdentifier ?? "").\(function)")
    }

}

extension Date: DirectThrowingDataRepresentable {

    public init(data: Data) throws {
        self.init(timeIntervalSince1970: TimeInterval((data as NSData).bytes.assumingMemoryBound(to: Int.self).pointee))

    }

}

extension Date: DirectThrowingDataConvertible {

    public func data() throws -> Data {
        return Int(ceil(timeIntervalSince1970)).bytes
    }

}

fileprivate extension Int {

    var bytes: Data {
        var copy = self
        return Data(bytes: withUnsafePointer(to: &copy) {
            Array(UnsafeBufferPointer(start: $0, count: MemoryLayout<Int>.size)).map(UInt8.init)
        })
    }

}
