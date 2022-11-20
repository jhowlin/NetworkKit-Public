//
//  Utilities.swift
//  
//
//  Created by Jason Howlin on 7/16/19.
//

import Foundation
#if os(Linux)
import FoundationNetworking
#endif

extension URLRequest {
    
    var asCurl:String {
        var curl = "curl -k -i "
        if let data = httpBody, httpMethod == "POST", let params = String(data: data, encoding: .utf8) {
            curl.append("-d \"\(params)\" ")
        }
        allHTTPHeaderFields?.forEach { (key, value) in
            let header = "-H \"\(key)\":\"\(value)\" "
            curl.append(header)
        }
        curl.append("\"\(self.url?.absoluteString ?? "")\"")
        return curl
    }
}

extension Data {
    
    func debugWriteToDiskAsJSON(name:String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).last else { return }
        let name = name + ".json"
        let url = docs.appendingPathComponent(name)
        let textResponse = self.asJSONString()
        
        do {
            try textResponse.write(to: url, atomically: true, encoding: .utf8)
            print("Wrote \(name) to \(url.absoluteString)")
        } catch {}
    }
    
    func asJSONString() -> String {
        var text = ""
        
        do {
            let json = try JSONSerialization.jsonObject(with: self, options: [])
            var options:JSONSerialization.WritingOptions = [.prettyPrinted]
            #if os(iOS) || os(OSX) || os(watchOS)
            if #available(iOS 13.0, *), #available(watchOS 6.0, *) {
                options = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            }
            if #available(iOS 11.0, *), #available(watchOS 4.0, *) {
                options = [.prettyPrinted, .sortedKeys]
            }
            #endif
            let encoded = try JSONSerialization.data(withJSONObject: json, options: options)
            if let textResponse = String(data: encoded, encoding: .utf8) {
                text = textResponse
            }
        } catch {}
        return text
    }
}

extension Bundle {
    
    static func loadJSONDictionaryWithFilename(filename:String) -> Data {
        if let path = Bundle.main.path(forResource: filename, ofType: "json") {
            let url = URL(fileURLWithPath: path, isDirectory: false)
            do {
                let data = try Data(contentsOf: url)
                return data
            } catch { }
        }
        fatalError()
    }
}

/**
Nested dictionary used in the network class to manage completion blocks.
 
 Example:
 
 [Download for NYT Logo GroupID:
    [Stream Article 1 UniqueID: Article 1 Completion Value]
    [Stream Article 2 UniqueID: Article 2 Completion Value]
 [Download for Thumbnail:
    [Stream Article 1 UniqueID: Article 1 Completion Value]
 
 Allows for fast internal lookups of an individual UniqueID via `reverseLookup`
 */

/**
 The `GroupID` key represents the network operation
 `UniqueID` key represents each submitter of the same network operation.
 `Value` is the completion block of each individual submitter
 */
class GroupedDictionary<GroupID:Hashable, UniqueID:Hashable, Value>: CustomStringConvertible {
    var description: String {
        var output = "\(storage.count) groups\n"
        for (_, value) in storage {
            output += "\(value.count) values\n"
        }
        return output
    }
    
    
    var storage = [GroupID:[UniqueID:Value]]()
    
    /// Allows us to find what network request an individual observation token is associated with
    var reverseLookup = [UniqueID:GroupID]()
    
    /// Does a particluar network request have any observers?
    func hasValuesForGroupID(_ groupID:GroupID) -> Bool {
        return (storage[groupID]?.count ?? 0) > 0
    }
    
    /// Is there a completion block for a particluar observation token?
    func hasValueForUniqueID( _ uniqueID:UniqueID) -> Bool {
        return reverseLookup[uniqueID] != nil
    }
    
    /// Add a completion block for an observer for a network operation
    func addValueForGroupID(_ groupID:GroupID, uniqueID:UniqueID, value:Value) {
        reverseLookup[uniqueID] = groupID
        if storage[groupID] == nil {
            storage[groupID] = [uniqueID:value]
        } else {
            storage[groupID]?[uniqueID] = value
        }
    }
    
    func valueForUniqueID(_ uniqueID: UniqueID) -> Value? {
        guard let requestTypeID = reverseLookup[uniqueID] else { return nil }
        return storage[requestTypeID]?[uniqueID]
    }

    /// Remove and return all observers for a network operation
    func removeAllValuesForGroupID(_ groupID: GroupID) -> [Value] {
        let valuesForGroup = storage[groupID] ?? [:]
        for uniqueID in valuesForGroup.keys {
            reverseLookup[uniqueID] = nil
        }
        storage[groupID] = nil
        return Array(valuesForGroup.values)
    }

    /// Remove and return a completion block for a particular observer
    @discardableResult func removeValueForUniqueID(_ uniqueID: UniqueID) -> Value? {
        guard let requestTypeID = reverseLookup[uniqueID] else { return nil }
        reverseLookup[uniqueID] = nil
        let value = storage[requestTypeID]?[uniqueID]
        storage[requestTypeID]?[uniqueID] = nil
        if hasValuesForGroupID(requestTypeID) == false {
            storage[requestTypeID] = nil
        }
        return value
    }

    /// Clear out everything
    func removeAllValues() -> [Value] {
        let values = storage.values.map { dict in
            return dict.values
        }.flatMap { $0 }
        storage.removeAll()
        reverseLookup.removeAll()
        return values
    }
    
    func hasAdditionalValuesAssociatedWithUniqueID(_ uniqueID: UniqueID) -> Bool {
        guard let requestTypeID = reverseLookup[uniqueID] else { return false }
        let hasMultiple = (storage[requestTypeID]?.count ?? 0) > 1
        return hasMultiple
    }
}

class BaseAsyncOperation:Operation {

    enum State {
        case executing, finished, notTrackedYet
    }

    func execute() {
        fatalError("Subclasses must override this")
    }

    override var isAsynchronous: Bool {
        return true
    }

    let queue = DispatchQueue(label: "com.howlin.opIsolationQueue", attributes:.concurrent)

    var state:State {
        get {
            return queue.sync {
                unsafeInternalState
            }
        }
        set {
            switch newValue {
            case .executing:
                willChangeValue(forKey: "isExecuting")
            case .finished:
                willChangeValue(forKey: "isFinished")
            case .notTrackedYet:
                break
            }

            queue.sync(flags:.barrier) {
                self.unsafeInternalState = newValue
            }

            switch newValue {
            case .executing:
                didChangeValue(forKey: "isExecuting")
            case .finished:
                didChangeValue(forKey: "isFinished")
            case .notTrackedYet:
                break
            }
        }
    }

    var unsafeInternalState:State = .notTrackedYet

    override var isExecuting: Bool {
        return state == .executing
    }

    override var isFinished: Bool {
        return state == .finished
    }

    override func start() {
        state = .executing
        execute()
    }

    func finish() {
        state = .finished
    }
}
