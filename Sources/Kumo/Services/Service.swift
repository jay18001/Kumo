import Foundation
import RxSwift

#if canImport(KumoCoding)
import KumoCoding
#endif

public struct ServiceKey: Hashable {
    
    let stringValue: String
    
    public init(_ name: String) {
        self.stringValue = name
    }
    
}

public struct ResponseObjectError: Error {

    public let responseObject: URLResponse?
    public let wrappedError: Error

    init(error: Error, responseObject: URLResponse?) {
        self.responseObject = responseObject
        self.wrappedError = error
    }

    public var localizedDescription: String {
        return wrappedError.localizedDescription
    }

}

public class Service {
    
    /// The base URL for all requests. The URLs for requests performed by the service are made
    /// by appending path components to this URL.
    public let baseURL: URL
    
    private let delegate = URLSessionInvalidationDelegate()
    
    /// The type of error returned by the server. When a response returns an error status code,
    /// the service will attempt to decode the body of the response as this type.
    ///
    /// The default value of this is `nil`. If no type is set, the service will not attempt to
    /// decode an error body.
    public var errorType = ResponseError?.none
    
    /// THe object which encodes request bodies which conform to the `Encodable` protocol.
    ///
    /// The default instance is a `JSONEncoder`.
    public var requestEncoder: RequestEncoding = JSONEncoder()
    
    /// THe object which decodes response bodies which conform to the `Decodable` protocol.
    ///
    /// The default instance is a `JSONDecoder`.
    public var requestDecoder: RequestDecoding = JSONDecoder()
    
    /// The behavior to use for encoding dynamically-typed request bodies.
    ///
    /// The default implementation uses Foundation's `JSONSerialization`.
    public var dynamicRequestEncodingStrategy: (Any) throws -> Data
    
    /// The behavior to use for decoding dynamically-typed response bodies.
    ///
    /// The default implementation uses Foundation's `JSONSerialization`.
    public var dynamicRequestDecodingStrategy: (Data) throws -> Any
    
    /// The scheduler on which to observe tasks.
    ///
    /// By default, tasks are observed on the main thread.
    public var operationScheduler: SchedulerType = MainScheduler.instance

    /// The characters to be allowed in the query sectiom of request URLs.
    public var urlQueryAllowedCharacters = CharacterSet.urlQueryAllowed

    private(set) var session: URLSession
    
    /// Returns the headers applied to all requests.
    public var commonHTTPHeaders: [HTTP.Header: Any]? {
        return session.configuration.httpHeaders
    }
    
    public init(baseURL: URL, runsInBackground: Bool = false, configuration: ((URLSessionConfiguration) -> ())? = nil) {
        self.baseURL = baseURL
        let sessionConfiguration = runsInBackground ? URLSessionConfiguration.background(withIdentifier: baseURL.absoluteString) : .default
        configuration?(sessionConfiguration)
        session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        dynamicRequestEncodingStrategy = { object in
            return try JSONSerialization.data(withJSONObject: object, options: [])
        }
        dynamicRequestDecodingStrategy = { data in
            return try JSONSerialization.jsonObject(with: data, options: [])
        }
    }
    
    internal func copySettings(from applicationLayer: ApplicationLayer) {
        
    }
    
    public func reconfigure(applying changes: @escaping (URLSessionConfiguration) -> ()) {
        session.finishTasksAndInvalidate { [unowned self] session, _ in
            let newConfiguration: URLSessionConfiguration = session.configuration.copy()
            changes(newConfiguration)
            self.session = URLSession(configuration: newConfiguration, delegate: self.delegate, delegateQueue: nil)
        }
    }

    public func reconfiguring(applying changes: @escaping (URLSessionConfiguration) -> ()) -> Observable<Void> {
        return Observable<Void>.create { [weak self] subscriber in
            guard let self = self else {
                subscriber.onNext(())
                subscriber.onCompleted()
                return Disposables.create()
            }
            self.session.finishTasksAndInvalidate { [unowned self] session, _ in
                let newConfiguration: URLSessionConfiguration = session.configuration.copy()
                changes(newConfiguration)
                self.session = URLSession(configuration: newConfiguration, delegate: self.delegate, delegateQueue: nil)
                subscriber.onNext(())
                subscriber.onCompleted()
            }
            return Disposables.create()
        }
    }
    
    public func upload<Response: Decodable>(_ endpoint: String, file: URL, under key: String) -> Observable<Response> {
        return Observable.create { [self] observer in
            do {
                var request = try self.createRequest(method: .post, endpoint: endpoint)
                guard file.isFileURL else { throw UploadError.notAFileURL(file) }
                let form = try MultipartForm(file: file, under: key, encoding: .utf8)
                request.set(contentType: .multipartFormData(boundary: form.boundary))
                let task = self.session.uploadTask(with: request, from: form.data) {
                    observer.on(self.resultToElement(data: $0, response: $1, error: $2))
                    observer.onCompleted()
                }
                task.resume()
                return Disposables.create(with: task.cancel)
            } catch {
                observer.onError(error)
                return Disposables.create()
            }
        }
            .observeOn(operationScheduler)
    }
            
    func createRequest(method: HTTP.Method, endpoint: String, queryParameters: [String: Any] = [:], body: [String: Any]? = nil) throws -> URLRequest {
        let data: Data?
        do { data = try body.map(dynamicRequestEncodingStrategy) }
        catch { throw HTTPError.unserializableRequestBody(object: body, originalError: error) }
        return try createRequest(method: method, endpoint: endpoint, queryParameters: queryParameters, body: data)
    }
    
    func createRequest<Body: Encodable>(method: HTTP.Method, endpoint: String, queryParameters: [String: Any] = [:], body: Body? = nil) throws -> URLRequest {
        let data: Data?
        do { data = try body.map(requestEncoder.encode) }
        catch { throw HTTPError.unserializableRequestBody(object: body, originalError: error) }
        return try createRequest(method: method, endpoint: endpoint, queryParameters: queryParameters, body: data)
    }
    
    func createRequest(method: HTTP.Method, endpoint: String, queryParameters: [String: Any], body: Data?) throws -> URLRequest {
        let url = endpoint.isEmpty ? baseURL : baseURL.appendingPathComponent(endpoint)
        let finalURL: URL
        if queryParameters.isEmpty { finalURL = url }
        else {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw HTTPError.malformedURL(url, parameters: queryParameters)
            }
            components.percentEncodedQuery = queryParameters.compactMap {
                guard let key = $0.key.addingPercentEncoding(withAllowedCharacters: urlQueryAllowedCharacters) else {
                    return nil
                }

                if let value = ($0.value as? String)?.addingPercentEncoding(withAllowedCharacters: urlQueryAllowedCharacters) {
                    return "\(key)=\(value)"
                }

                return "\(key)=\($0.value)"
            }.joined(separator: "&")
            guard components.url != nil else {
                throw HTTPError.malformedURL(url, parameters: queryParameters)
            }
            finalURL = components.url!
        }
        var request = URLRequest(url: finalURL)
        request.httpHeaders = [.contentType: requestEncoder.contentType.rawValue,
                               .accept: requestDecoder.acceptType.rawValue]
        request.httpMethod = method.rawValue
        request.httpBody = body
        return request
    }
    
    /// Converts the results of a `URLSessionDataTask` into an Rx `Event` with which consumers may
    /// perform side effects.
    func resultToEvent(data: Data?, response: URLResponse?, error: Error?) -> Event<Void> {
        if let error = error { return .error(ResponseObjectError(error: error, responseObject: response)) }
        guard let httpResponse = response as? HTTPURLResponse else {
            return .error(ResponseObjectError(error: response == nil ? HTTPError.emptyResponse : HTTPError.unsupportedResponse, responseObject: response))
        }
         if httpResponse.status.isError {
               return errorType.flatMap { type in
                   data.map {
                       do { return try .error(ResponseObjectError(error: type.decode(data: $0, with: requestDecoder), responseObject: response)) }
                       catch { return .error(ResponseObjectError(error: HTTPError.corruptedError(type.type, decodingError: error), responseObject: response)) }
                   } ?? .error(ResponseObjectError(error: HTTPError.ambiguousError(httpResponse.status), responseObject: response))
               } ?? .error(ResponseObjectError(error: HTTPError.ambiguousError(httpResponse.status), responseObject: response))
           }
        return .next(())
    }

    /// Converts the results of a `URLSessionDataTask` into an Rx `Event` with which consumers may
    /// act on an element.
    func resultToElement<Response: Decodable>(data: Data?, response: URLResponse?, error: Error?) -> Event<Response> {
        if let error = error {
            return .error(ResponseObjectError(error: error, responseObject: response))
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            return .error(ResponseObjectError(error: response == nil ? HTTPError.emptyResponse : HTTPError.unsupportedResponse, responseObject: response))
        }
        if httpResponse.status.isError {
            return errorType.flatMap { type in
                data.map {
                    do { return try .error(ResponseObjectError(error: type.decode(data: $0, with: requestDecoder), responseObject: response)) }
                    catch { return .error(ResponseObjectError(error: HTTPError.corruptedError(type.type, decodingError: error), responseObject: response)) }
                } ?? .error(ResponseObjectError(error: HTTPError.ambiguousError(httpResponse.status), responseObject: response))
            } ?? .error(ResponseObjectError(error: HTTPError.ambiguousError(httpResponse.status), responseObject: response))
        }
        return data.map {
            do { return try .next(self.requestDecoder.decode(Response.self, from: $0)) }
            catch { return .error(ResponseObjectError(error: error, responseObject: response)) }
        } ?? .completed
    }

    /// Converts the results of a `URLSessionDataTask` into an Rx `Event` with which consumers may
    /// act on an element.
    func resultToElement(data: Data?, response: URLResponse?, error: Error?) -> Event<Any> {
        if let error = error {
            return .error(ResponseObjectError(error: error, responseObject: response))
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            return .error(ResponseObjectError(error: response == nil ? HTTPError.emptyResponse : HTTPError.unsupportedResponse, responseObject: response))
        }
        if httpResponse.status.isError {
            return errorType.flatMap { type in
                data.map {
                    do { return try .error(ResponseObjectError(error: type.decode(data: $0, with: requestDecoder), responseObject: response)) }
                    catch { return .error(ResponseObjectError(error: HTTPError.corruptedError(type.type, decodingError: error), responseObject: response)) }
                } ?? .error(ResponseObjectError(error: HTTPError.ambiguousError(httpResponse.status), responseObject: response))
            } ?? .error(ResponseObjectError(error: HTTPError.ambiguousError(httpResponse.status), responseObject: response))
        }
        return data.map {
            do { return try .next(self.dynamicRequestDecodingStrategy($0)) }
            catch { return .error(ResponseObjectError(error: error, responseObject: response)) }
        } ?? .completed
    }

    func response<Response: Decodable>(keyedUnder key: String? = nil, forRequest request: URLRequest, observer: AnyObserver<Response>) -> Cancelable {
        let task: URLSessionDataTask
        if let key = key {
            task = self.session.dataTask(with: request) {
                let event: Event<JSONWrapper<Response>> = self.resultToElement(data: $0, response: $1, error: $2)
                switch event {
                case .error(let error): return observer.onError(error)
                case .completed: return observer.onCompleted()
                case .next(let wrapper):
                    do { try observer.onNext(wrapper.value(forKey: key)) }
                    catch { observer.onError(error) }
                    observer.onCompleted()
                }
            }
        } else {
            task = self.session.dataTask(with: request) {
                observer.on(self.resultToElement(data: $0, response: $1, error: $2))
                observer.onCompleted()
            }
        }
        task.resume()
        return Disposables.create(with: task.cancel)
    }

    func response(forRequest request: URLRequest, observer: AnyObserver<Any>) -> Cancelable {
        let task = self.session.dataTask(with: request) {
            observer.on(self.resultToElement(data: $0, response: $1, error: $2))
            observer.onCompleted()
        }
        task.resume()
        return Disposables.create(with: task.cancel)
    }

    func response(forRequest request: URLRequest, observer: AnyObserver<Void>) -> Cancelable {
        let task = self.session.dataTask(with: request) {
            observer.on(self.resultToEvent(data: $0, response: $1, error: $2))
            observer.onCompleted()
        }
        task.resume()
        return Disposables.create(with: task.cancel)
    }

    /// Converts the results of a `URLSessionDownloadTask` into an Rx `Event` with which consumer
    /// may act on an element.
    func downloadResultToURL(url: URL?, response: URLResponse?, error: Error?) -> Event<URL> {
        if let error = error { return .error(error) }
        guard let httpResponse = response as? HTTPURLResponse else {
            return .error(response == nil ? HTTPError.emptyResponse : HTTPError.unsupportedResponse)
        }
        if httpResponse.status.isError {
            return .error(HTTPError.ambiguousError(httpResponse.status))
        }
        guard let url = url else { return .completed }
        let fileName = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let fileType = (response?.mimeType).flatMap({ try? FileType(mimeType: $0) })
        let newURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName, isDirectory: false)
            .appendingPathExtension(fileType?.fileExtension ?? "")
        do {
            try FileManager.default.moveItem(atPath: url.path, toPath: newURL.path)
            return .next(newURL)
        } catch {
            return .error(error)
        }
    }
    
}

public extension Service {

    func perform<Response: Decodable, Method: RequestMethod, Resource: RequestResource, Parameters: RequestParameters, Body: RequestBody, Key: ResponseNestedKey>(_ request: HTTP._Request<Method, Resource, Parameters, Body, Key>) -> Observable<Response> {
        return Observable.create { [self] observer in
            do {
                let urlRequest = try self.createURLRequest(from: request)
                return self.response(keyedUnder: request.nestingKey, forRequest: urlRequest, observer: observer)
            } catch {
                observer.onError(error)
                return Disposables.create()
            }
        }
            .observeOn(operationScheduler)
    }

    func perform<Method: RequestMethod, Resource: RequestResource, Parameters: RequestParameters, Body: RequestBody, Key: ResponseNestedKey>(_ request: HTTP._Request<Method, Resource, Parameters, Body, Key>) -> Observable<Void> {
        return Observable.create { [self] observer in
            do {
                let urlRequest = try self.createURLRequest(from: request)
                return self.response(forRequest: urlRequest, observer: observer)
            } catch {
                observer.onError(error)
                return Disposables.create()
            }
        }
            .observeOn(operationScheduler)
    }

    func perform<Method: RequestMethod, Resource: RequestResource, Parameters: RequestParameters, Body: RequestBody, Key: ResponseNestedKey>(_ request: HTTP._Request<Method, Resource, Parameters, Body, Key>) -> Observable<Any> {
        return Observable.create { [self] observer in
            do {
                let urlRequest = try self.createURLRequest(from: request)
                return self.response(forRequest: urlRequest, observer: observer)
            } catch {
                observer.onError(error)
                return Disposables.create()
            }
        }
            .observeOn(operationScheduler)
    }

    func perform<Resource: RequestResource, Parameters: RequestParameters>(_ request: HTTP._DownloadRequest<Resource, Parameters>) -> Observable<URL> {
        return Observable.create { [self] observer in
            do {
                var urlRequest = try self.createURLRequest(from: request.baseRepresentation)
                urlRequest.remove(header: .accept)
                let task = self.session.downloadTask(with: urlRequest) {
                    observer.on(self.downloadResultToURL(url: $0, response: $1, error: $2))
                    observer.onCompleted()
                }
                task.resume()
                return Disposables.create(with: task.cancel)
            } catch {
                observer.onError(error)
                return Disposables.create()
            }
        }
    }

}

extension Service {

    func createURLRequest<Method: RequestMethod, Resource: RequestResource, Parameters: RequestParameters, Body: RequestBody, Key: ResponseNestedKey>(from request: HTTP._Request<Method, Resource, Parameters, Body, Key>) throws -> URLRequest {
        let url: URL
        switch request.resourceLocator {
        case .relative(let endpoint):
            url = endpoint.isEmpty ? baseURL : baseURL.appendingPathComponent(endpoint)
        case .absolute(let absoluteURL):
            url = absoluteURL
        }
        let finalURL: URL
        if request.parameters.isEmpty { finalURL = url }
        else {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw HTTPError.malformedURL(url, parameters: request.parameters)
            }
            components.queryItems = request.parameters.map { URLQueryItem(name: $0.key, value: "\($0.value)") }
            guard components.url != nil else {
                throw HTTPError.malformedURL(url, parameters: request.parameters)
            }
            finalURL = components.url!
        }
        let contentType = try request.data(typedEncoder: requestEncoder, dynamicEncoder: dynamicRequestEncodingStrategy)
        var urlRequest = URLRequest(url: finalURL)
        urlRequest.setValue(contentType?.mimeType.rawValue, forHTTPHeaderField: "Content-Type")
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = contentType?.data
        return urlRequest
    }

}

extension FileManager {
    
    var documentsDirectory: URL {
        return urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    var cachesDirectory: URL {
        return try! url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

}
