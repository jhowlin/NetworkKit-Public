//
//  Network.swift
//  
//
//  Created by Jason Howlin on 7/15/19.
//

import Foundation
import CoreFoundation
#if os(Linux)
import FoundationNetworking
#endif

public struct NetworkRequest<T:Decodable>: @unchecked Sendable {

    public typealias Parser = (Data?) throws -> (T)
    public typealias ResponseValidator = (Int) -> (Bool)

    public let identifier:String
    public let urlRequest:URLRequest
    public var mockData:Data?
    public let uuid = UUID().uuidString
    public var retryCount = 0
    public var displayLabel:String = ""
    var failCount = 0
    var submissionTime = CFAbsoluteTimeGetCurrent()
    
    var label:String {
        return "\(uuid.prefix(5)) \(displayLabel)"
    }
    
    public var parser:Parser = { data in
        guard let data = data else { throw NetworkError.noParserProvided }
        return try JSONDecoder().decode(T.self, from: data)
        
    }
    public var validator:ResponseValidator = { code in 200...299 ~= code }
    
    public init(identifier:String, urlRequest:URLRequest) {
        self.identifier = identifier
        self.urlRequest = urlRequest
    }
}

public struct NetworkResponse<T:Decodable> {
    
    public var result: Result<T, NetworkError>
    public var response: HTTPURLResponse?

    public var failure:NetworkError? {
        switch result {
        case .failure(let error):return error
        case .success:return nil
        }
    }
    
    public var success:T? {
        switch result {
        case .failure:return nil
        case .success(let data):return data
        }
    }
    
    public var succeeded:Bool {
        return success != nil
    }
}

public enum NetworkError: Error, CustomStringConvertible {
    case unknown
    case parsingError(Error)
    case network(Error)
    case noParserProvided
    case invalidResponse(Int)
    case serverError(Int, String)
    case cancelled
    
    public var localizedDescription: String {
        switch self {
            
        case .unknown:
            return "Unknown error"
        case .parsingError(let decodeError):
            return "Parsing error: \(decodeError.localizedDescription)\n\n\(decodeError)"
        case .network(let networkError):
            return "Foundation networking error: \(networkError.localizedDescription)\n\n\(networkError)"
        case .noParserProvided:
            return "No parser provided"
        case .invalidResponse(let statusCode):
            return "Invalid response. Status code: \(statusCode)"
        case .serverError(let statusCode, let serverResponseString):
            return "Server error. Status code: \(statusCode). Server response: \(serverResponseString)"
        case .cancelled:
            return "Cancelled"
        }
    }
    
    public var description: String {
        localizedDescription
    }
}

struct LaunchArguments {
    static var logResponse:Bool {
        return hasLaunchArgument("-LOG_RESPONSE") || UserDefaults.standard.bool(forKey: "-LOG_RESPONSE")
    }
    static var logCurl:Bool {
        return hasLaunchArgument("-LOG_CURL") || UserDefaults.standard.bool(forKey: "-LOG_CURL")
    }
    static var writeResponseToDisk:Bool {
        return hasLaunchArgument("-WRITE_RESPONSE") || UserDefaults.standard.bool(forKey: "-WRITE_RESPONSE")
    }
    static func hasLaunchArgument(_ arg:String) -> Bool {
        return ProcessInfo.processInfo.arguments.contains(arg)
    }
}

public protocol NetworkKitLoggingDelegate: AnyObject {
    func log(_ message: String, isError: Bool)
}

public class Network: @unchecked Sendable {
    
    typealias AnyCompletion = (Any, DispatchQueue)
    typealias RequestTypeID = String
    typealias UniqueID = String
    
    private var session:URLSession
    let isolationQueue = DispatchQueue(label: "com.NetworkIsolationQueue")
    let decodingQueue = DispatchQueue(label: "com.NetworkDecoderQueue")
    var completions = GroupedDictionary<RequestTypeID, UniqueID, AnyCompletion>()
    var operations = [RequestTypeID:DownloadOperation]()
    let operationQueue = OperationQueue()
    weak public var loggingDelegate: NetworkKitLoggingDelegate?

    public init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
        operationQueue.maxConcurrentOperationCount = 6

    }
    
    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration)
        operationQueue.maxConcurrentOperationCount = 6
    }
    
    public func executeRequest<T>(request:NetworkRequest<T>,
                                  queue:DispatchQueue = .main,
                                  completion: @escaping (NetworkResponse<T>)-> ()) {
        
        var request = request
        request.submissionTime = CFAbsoluteTimeGetCurrent()
        log("START REQUEST: \(request.label)")
        guard hasCompletionsForRequest(request) == false else {
            addCompletion((completion, queue), request:request)
            return
        }

        addCompletion((completion, queue), request:request)

        createAndRunOperationForRequest(request: request)
    }
        
    func createAndRunOperationForRequest<T>(request:NetworkRequest<T>) {
        
        if let data = request.mockData {
            self.handleResponse(request: request, data: data, response: nil, error: nil)
            return
        }

        let urlRequest = request.urlRequest
        let op = DownloadOperation(session: session, request: urlRequest) { [weak self] data, response, error in
            self?.handleResponse(request:request, data: data, response: response, error: error)
        }

        addOperation(op: op, identifier: request.identifier)
        if LaunchArguments.logCurl {
            print(urlRequest.asCurl)
        }
        operationQueue.addOperation(op)
    }
    
    func handleResponse<T>(request:NetworkRequest<T>, data:Data?, response:URLResponse?, error:Error?) {
        
        decodingQueue.async { [weak self] in
            var request = request
            let result:Result<T, NetworkError>
            
            if let response = response as? HTTPURLResponse, request.validator(response.statusCode) == false {
                var errorString = ""
                if let data = data {
                    errorString = String(data: data, encoding: .utf8) ?? ""
                }
                result = .failure(.serverError(response.statusCode, errorString))
            }  else if let error = error {
                
                result = .failure(.network(error))
            
            } else {

                if LaunchArguments.writeResponseToDisk {
                    data?.debugWriteToDiskAsJSON(name: request.label)
                }
                if LaunchArguments.logResponse {
                    print(data?.asJSONString() ?? "No data")
                }
                do {
                    let res = try request.parser(data)
                    result = .success(res)
                } catch let error {
                    result = .failure(.parsingError(error))
                }
            }
            self?.removeOperation(identifier: request.identifier)

            if case Result.failure = result, request.failCount < request.retryCount  {
                
                if self?.hasCompletionsForRequest(request) ?? false {
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) {
                        request.failCount += 1
                        self?.createAndRunOperationForRequest(request: request)
                    }
                }
            } else {
                let networkResponse = NetworkResponse(result: result, response: response as? HTTPURLResponse)
                self?.fireCompletionsWithResult(result: networkResponse, request:request)
            }
        }
    }
    
    public func cancelRequest<T>(_ request:NetworkRequest<T>) {
        
        isolationQueue.async {
            if let completion = self.completions.removeValueForUniqueID(request.uuid) {
                guard let block = completion.0 as? (NetworkResponse<T>) -> () else { return }
                completion.1.async {
                    block(NetworkResponse(result: .failure(.cancelled), response: nil))
                }
            }
            if self.completions.hasValuesForGroupID(request.identifier) == false {
                let op = self.operations[request.identifier]
                op?.cancel()
                self.operations[request.identifier] = nil
            }
        }
    }

    public func cancelAllRequests() {
        isolationQueue.async {
            _ = self.completions.removeAllValues()
            self.operationQueue.cancelAllOperations()
            self.operations.removeAll()
        }
    }

    func addOperation(op:DownloadOperation, identifier:String) {
        isolationQueue.sync {
            self.operations[identifier] = op
        }
    }

    func removeOperation(identifier:String) {
        isolationQueue.async {
            self.operations[identifier] = nil
        }
    }

    func addCompletion<T>(_ completion:AnyCompletion, request:NetworkRequest<T>) {
        isolationQueue.sync { [weak self] in
            self?.completions.addValueForGroupID(request.identifier, uniqueID: request.uuid, value: completion)
        }
    }
    
    func fireCompletionsWithResult<T>(result:NetworkResponse<T>, request:NetworkRequest<T>) {
        let duration = (CFAbsoluteTimeGetCurrent() - request.submissionTime) * 1000
        let time = String(format: "%.0f ms", duration)
        log("END REQUEST: \(request.label) took \(time). \(result.succeeded ? "SUCCESS" : "FAILURE")", isError: !result.succeeded)
        
        
        isolationQueue.async { [weak self] in
            let allCompletions = self?.completions.removeAllValuesForGroupID(request.identifier) ?? []
            for completion in allCompletions {
                guard let block = completion.0 as? (NetworkResponse<T>) -> () else { return }
                
                // There's a bug on Linux where the queue is getting released before the block is fired
                
                #if os(iOS) || os(OSX) || os(watchOS)
                
                let queue = completion.1
                queue.async {
                    block(result)
                }
                
                #else
                
                block(result)
                
                #endif
            }
        }
    }

    func hasCompletionsForRequest<T>(_ request:NetworkRequest<T>) -> Bool {
        return isolationQueue.sync {
            completions.hasValuesForGroupID(request.identifier)
        }
    }
    
    func log(_ message: String, isError: Bool = false) {
        if let loggingDelegate = loggingDelegate {
            loggingDelegate.log(message, isError: isError)
        } else {
            print(message)
        }
    }
}

typealias DownloadCompletion = (Data?, URLResponse?, Error?) -> ()

final class DownloadOperation:BaseAsyncOperation {

    var session:URLSession
    var task : URLSessionDataTask?
    var request:URLRequest
    var completion:DownloadCompletion
    #if os(iOS) || os(OSX) || os(watchOS)
    var obsToken:NSKeyValueObservation? = nil
    #endif

    init(session:URLSession, request:URLRequest, completion:@escaping DownloadCompletion) {
        self.session = session
        self.completion = completion
        self.request = request
        super.init()
        #if os(iOS) || os(OSX) || os(watchOS)
        obsToken = self.observe(\.isCancelled, options:[.new]) { [weak self] op, change in
            if let isCancelled = change.newValue, isCancelled == true {
                self?.task?.cancel()
            }
        }
        #endif
    }

    override func execute() {

        guard isCancelled == false else { operationCancelled() ; return}

        task = session.dataTask(with: request) { [weak self] data, response, error in
            
            guard self?.isCancelled == false else { self?.operationCancelled() ; return }
            
            self?.completion(data, response, error)
            self?.finish()
        }
        task?.resume()
    }

    func operationCancelled() {
        completion(nil,nil,NetworkError.cancelled)
        finish()
    }
}
