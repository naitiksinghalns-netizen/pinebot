import Foundation

/// Type-safe, Sendable, Codable JSON representation for strictly conforming RPC boundaries.
@frozen
public enum JSONValue: Sendable, Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown JSON value")
            )
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let b):
            try container.encode(b)
        case .int(let i):
            try container.encode(i)
        case .double(let d):
            try container.encode(d)
        case .string(let s):
            try container.encode(s)
        case .array(let arr):
            try container.encode(arr)
        case .object(let obj):
            try container.encode(obj)
        }
    }
    
    // MARK: - Accessors
    
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    
    public var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }
    
    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    
    public var objectValue: [String: JSONValue]? {
        if case .object(let obj) = self { return obj }
        return nil
    }
    
    public var arrayValue: [JSONValue]? {
        if case .array(let arr) = self { return arr }
        return nil
    }
    
    public subscript(key: String) -> JSONValue? {
        get {
            guard case .object(let obj) = self else { return nil }
            return obj[key]
        }
        set {
            guard case .object(var obj) = self else { return }
            obj[key] = newValue
            self = .object(obj)
        }
    }
    
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let arr) = self, index >= 0, index < arr.count else { return nil }
        return arr[index]
    }
}

// MARK: - ExpressibleBy Literals

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var obj: [String: JSONValue] = [:]
        for (k, v) in elements {
            obj[k] = v
        }
        self = .object(obj)
    }
}

// MARK: - JSON-RPC Wire Protocol Types

@frozen
public enum JSONRPCId: Sendable, Codable, Equatable, Hashable, CustomStringConvertible {
    case int(Int)
    case string(String)
    
    public var description: String {
        switch self {
        case .int(let i): return "\(i)"
        case .string(let s): return s
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid JSON-RPC id")
            )
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let i):
            try container.encode(i)
        case .string(let s):
            try container.encode(s)
        }
    }
}

public struct JSONRPCRequest: Sendable, Codable {
    public let jsonrpc: String
    public let id: JSONRPCId
    public let method: String
    public let params: JSONValue?
    
    public init(id: JSONRPCId, method: String, params: JSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCNotification: Sendable, Codable {
    public let jsonrpc: String
    public let method: String
    public let params: JSONValue?
    
    public init(method: String, params: JSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

public struct JSONRPCError: Sendable, Codable, Equatable {
    public let code: Int
    public let message: String
    public let data: JSONValue?
    
    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct JSONRPCResponse: Sendable, Codable {
    public let jsonrpc: String
    public let id: JSONRPCId?
    public let result: JSONValue?
    public let error: JSONRPCError?
    
    public init(id: JSONRPCId?, result: JSONValue? = nil, error: JSONRPCError? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }
}
