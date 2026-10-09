import Foundation

/// Resolved locations for official Claude Code CLI and the ACP adapter.
public struct ClaudeRuntimeLocations: Sendable, Equatable {
    public let claudeCLIURL: URL
    public let acpAdapterURL: URL
    public let nodeURL: URL?
    public let workingDirectory: URL?
    
    public init(
        claudeCLIURL: URL,
        acpAdapterURL: URL,
        nodeURL: URL? = nil,
        workingDirectory: URL? = nil
    ) {
        self.claudeCLIURL = claudeCLIURL
        self.acpAdapterURL = acpAdapterURL
        self.nodeURL = nodeURL
        self.workingDirectory = workingDirectory
    }
}

/// Errors occurring while locating Claude Code runtime dependencies.
public enum ClaudeRuntimeError: Error, LocalizedError, Sendable, Equatable {
    case claudeCLINotFound(String)
    case acpAdapterNotFound(String)
    
    public var errorDescription: String? {
        switch self {
        case .claudeCLINotFound(let details):
            return "Claude Code CLI executable not found: \(details)"
        case .acpAdapterNotFound(let details):
            return "Claude ACP adapter executable not found: \(details)"
        }
    }
}

/// Protocol for locating official Claude Code CLI and ACP adapter binaries.
public protocol ClaudeRuntimeLocating: Sendable {
    func locateRuntime() throws -> ClaudeRuntimeLocations
    func locateClaudeCLI() -> URL?
    func locateACPAdapter() -> URL?
    func locateNode() -> URL?
}

/// Discovers the official, unmodified Claude Code CLI and ACP adapter.
/// Checks (in priority order):
/// 1. App Bundle: `Contents/Resources/runtime/...`
/// 2. Application Support: `~/Library/Application Support/Pinebot/runtime/...`
/// 3. Project runtime: `<currentDir>/work/pinebot/runtime/...` or `<currentDir>/runtime/...`
/// 4. System / user PATH candidates (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`)
public final class ClaudeCodeRuntimeLocator: ClaudeRuntimeLocating, @unchecked Sendable {
    private let customClaudeURL: URL?
    private let customACPAdapterURL: URL?
    private let customNodeURL: URL?
    private let fileManager: FileManager
    
    public init(
        claudeURL: URL? = nil,
        acpAdapterURL: URL? = nil,
        nodeURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.customClaudeURL = claudeURL
        self.customACPAdapterURL = acpAdapterURL
        self.customNodeURL = nodeURL
        self.fileManager = fileManager
    }
    
    public func locateRuntime() throws -> ClaudeRuntimeLocations {
        guard let claudeURL = locateClaudeCLI() else {
            throw ClaudeRuntimeError.claudeCLINotFound(
                "Could not locate official Claude Code CLI (claude). Checked app bundle runtime, Application Support, project runtime, and system PATH."
            )
        }
        
        guard let acpURL = locateACPAdapter() else {
            throw ClaudeRuntimeError.acpAdapterNotFound(
                "Could not locate official Claude ACP adapter (claude-agent-acp). Checked app bundle runtime, Application Support, project runtime, and system PATH."
            )
        }
        
        let nodeURL = locateNode()
        let workingDir = claudeURL.deletingLastPathComponent()
        
        return ClaudeRuntimeLocations(
            claudeCLIURL: claudeURL,
            acpAdapterURL: acpURL,
            nodeURL: nodeURL,
            workingDirectory: workingDir
        )
    }
    
    public func locateClaudeCLI() -> URL? {
        if let custom = customClaudeURL, fileManager.isExecutableFile(atPath: custom.path) {
            return custom
        }
        
        var candidates: [String] = []
        
        // 1. App Bundle
        if let resourcePath = Bundle.main.resourcePath {
            candidates.append((resourcePath as NSString).appendingPathComponent("runtime/node_modules/@anthropic-ai/claude-code/bin/claude.exe"))
            candidates.append((resourcePath as NSString).appendingPathComponent("runtime/node_modules/.bin/claude"))
            candidates.append((resourcePath as NSString).appendingPathComponent("runtime/claude"))
            candidates.append((resourcePath as NSString).appendingPathComponent("claude"))
        }
        
        // 2. Application Support
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let supportExe = appSupport.appendingPathComponent("Pinebot/runtime/node_modules/@anthropic-ai/claude-code/bin/claude.exe").path
            candidates.append(supportExe)
            let supportRuntime = appSupport.appendingPathComponent("Pinebot/runtime/node_modules/.bin/claude").path
            candidates.append(supportRuntime)
        }
        
        // 3. Project runtime candidates
        let currentDir = fileManager.currentDirectoryPath
        candidates.append((currentDir as NSString).appendingPathComponent("work/pinebot/runtime/node_modules/@anthropic-ai/claude-code/bin/claude.exe"))
        candidates.append((currentDir as NSString).appendingPathComponent("runtime/node_modules/@anthropic-ai/claude-code/bin/claude.exe"))
        candidates.append((currentDir as NSString).appendingPathComponent("work/pinebot/runtime/node_modules/.bin/claude"))
        candidates.append((currentDir as NSString).appendingPathComponent("runtime/node_modules/.bin/claude"))
        candidates.append((currentDir as NSString).appendingPathComponent("work/pinebot/runtime/node_modules/@anthropic-ai/claude-code/bin/claude.js"))
        
        // 4. System / user PATH candidates
        let home = NSHomeDirectory()
        candidates.append((home as NSString).appendingPathComponent(".npm-global/bin/claude"))
        candidates.append((home as NSString).appendingPathComponent(".local/bin/claude"))
        candidates.append("/opt/homebrew/bin/claude")
        candidates.append("/usr/local/bin/claude")
        candidates.append("/usr/bin/claude")
        
        for candidate in candidates {
            if fileManager.isExecutableFile(atPath: candidate) || fileManager.fileExists(atPath: candidate) {
                return URL(fileURLWithPath: candidate).resolvingSymlinksInPath()
            }
        }
        
        return nil
    }
    
    public func locateACPAdapter() -> URL? {
        if let custom = customACPAdapterURL, fileManager.isExecutableFile(atPath: custom.path) || fileManager.fileExists(atPath: custom.path) {
            return custom.resolvingSymlinksInPath()
        }
        
        var candidates: [String] = []
        
        // 1. App Bundle
        if let resourcePath = Bundle.main.resourcePath {
            candidates.append((resourcePath as NSString).appendingPathComponent("runtime/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js"))
            candidates.append((resourcePath as NSString).appendingPathComponent("runtime/node_modules/.bin/claude-agent-acp"))
        }
        
        // 2. Application Support
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let supportDist = appSupport.appendingPathComponent("Pinebot/runtime/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js").path
            candidates.append(supportDist)
            let supportRuntime = appSupport.appendingPathComponent("Pinebot/runtime/node_modules/.bin/claude-agent-acp").path
            candidates.append(supportRuntime)
        }
        
        // 3. Project runtime candidates
        let currentDir = fileManager.currentDirectoryPath
        candidates.append((currentDir as NSString).appendingPathComponent("work/pinebot/runtime/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js"))
        candidates.append((currentDir as NSString).appendingPathComponent("runtime/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js"))
        candidates.append((currentDir as NSString).appendingPathComponent("work/pinebot/runtime/node_modules/.bin/claude-agent-acp"))
        candidates.append((currentDir as NSString).appendingPathComponent("runtime/node_modules/.bin/claude-agent-acp"))
        
        // 4. System / user PATH candidates
        let home = NSHomeDirectory()
        candidates.append((home as NSString).appendingPathComponent(".npm-global/bin/claude-agent-acp"))
        candidates.append("/opt/homebrew/bin/claude-agent-acp")
        candidates.append("/usr/local/bin/claude-agent-acp")
        
        for candidate in candidates {
            if fileManager.isExecutableFile(atPath: candidate) || fileManager.fileExists(atPath: candidate) {
                return URL(fileURLWithPath: candidate).resolvingSymlinksInPath()
            }
        }
        
        return nil
    }
    
    public func locateNode() -> URL? {
        if let custom = customNodeURL, fileManager.isExecutableFile(atPath: custom.path) {
            return custom.resolvingSymlinksInPath()
        }
        
        var nodeCandidates: [String] = []
        
        // 1. App Bundle private Node runtime
        if let resourcePath = Bundle.main.resourcePath {
            nodeCandidates.append((resourcePath as NSString).appendingPathComponent("runtime/node/bin/node"))
        }
        
        // 2. Application Support private Node runtime
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let supportNode = appSupport.appendingPathComponent("Pinebot/runtime/node/bin/node").path
            nodeCandidates.append(supportNode)
        }
        
        // 3. Project runtime candidates
        let currentDir = fileManager.currentDirectoryPath
        nodeCandidates.append((currentDir as NSString).appendingPathComponent("work/pinebot/runtime/node/bin/node"))
        nodeCandidates.append((currentDir as NSString).appendingPathComponent("runtime/node/bin/node"))
        
        // 4. System / user fallback candidates
        nodeCandidates.append("/usr/local/bin/node")
        nodeCandidates.append("/opt/homebrew/bin/node")
        nodeCandidates.append("/usr/bin/node")
        
        for cand in nodeCandidates {
            if fileManager.isExecutableFile(atPath: cand) {
                return URL(fileURLWithPath: cand).resolvingSymlinksInPath()
            }
        }
        
        return nil
    }
}
