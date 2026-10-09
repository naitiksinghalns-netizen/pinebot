import Foundation

/// Errors occurring in the AgentCoordinator during job lifecycle and lease acquisition.
public enum CoordinatorError: Error, LocalizedError, Sendable, Equatable {
    case maxDepthExceeded(String)
    case maxConcurrentJobsExceeded(String)
    case jobNotFound(UUID)
    case leaseBusy(holderId: UUID)
    
    public var errorDescription: String? {
        switch self {
        case .maxDepthExceeded(let msg): return msg
        case .maxConcurrentJobsExceeded(let msg): return msg
        case .jobNotFound(let id): return "Job \(id) not found in coordinator."
        case .leaseBusy(let id): return "Desktop action lease is currently held by job \(id)."
        }
    }
}

/// Coordinates child agent jobs with strict depth limits, concurrency bounding,
/// and exclusive desktop interaction lease management.
public actor AgentCoordinator {
    public static let shared = AgentCoordinator()
    
    public struct ChildJob: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let parentJobId: UUID?
        public let depth: Int
        public let description: String
        public let createdAt: Date
        public var status: JobStatus
    }
    
    public enum JobStatus: Sendable, Equatable {
        case active
        case completed
        case cancelled
        case failed(String)
    }
    
    public struct DesktopActionLease: Sendable {
        public let id: UUID
        public let jobId: UUID
        public let grantedAt: Date
    }
    
    public let maxDepth: Int = 1
    public let maxConcurrentJobs: Int = 2
    
    private var activeJobs: [UUID: ChildJob] = [:]
    private var activeLease: DesktopActionLease?
    
    public init() {}
    
    /// Spawns a new task/agent job, validating maximum depth and concurrent jobs limits.
    @discardableResult
    public func spawnJob(description: String, parentJobId: UUID? = nil) throws -> UUID {
        var depth = 0
        if let parentId = parentJobId {
            guard let parent = activeJobs[parentId] else {
                throw CoordinatorError.jobNotFound(parentId)
            }
            if parent.depth >= maxDepth {
                throw CoordinatorError.maxDepthExceeded("Child agent depth limit reached (max \(maxDepth)). Child agent cannot spawn further child agents.")
            }
            depth = parent.depth + 1
        }
        
        let activeCount = activeJobs.values.filter { $0.status == .active }.count
        if activeCount >= maxConcurrentJobs {
            throw CoordinatorError.maxConcurrentJobsExceeded("Max active concurrent jobs reached (limit: \(maxConcurrentJobs)).")
        }
        
        let jobId = UUID()
        let job = ChildJob(
            id: jobId,
            parentJobId: parentJobId,
            depth: depth,
            description: description,
            createdAt: Date(),
            status: .active
        )
        activeJobs[jobId] = job
        return jobId
    }
    
    /// Acquires the exclusive desktop action lease for sending CGEvent mouse/keyboard inputs.
    public func acquireDesktopLease(jobId: UUID, timeoutSeconds: Double = 5.0) async throws -> DesktopActionLease {
        if let existing = activeLease {
            if existing.jobId == jobId {
                return existing
            }
            let start = Date()
            while activeLease != nil {
                if Date().timeIntervalSince(start) > timeoutSeconds {
                    throw CoordinatorError.leaseBusy(holderId: activeLease!.jobId)
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        
        let lease = DesktopActionLease(id: UUID(), jobId: jobId, grantedAt: Date())
        self.activeLease = lease
        return lease
    }
    
    /// Releases the desktop action lease held by the given job.
    public func releaseDesktopLease(jobId: UUID) {
        if activeLease?.jobId == jobId {
            activeLease = nil
        }
    }
    
    /// Completes or terminates a job, releasing its lease and updating its status.
    public func finishJob(jobId: UUID, status: JobStatus) {
        releaseDesktopLease(jobId: jobId)
        if var job = activeJobs[jobId] {
            job.status = status
            activeJobs[jobId] = job
        }
    }
    
    public func getJob(id: UUID) -> ChildJob? {
        activeJobs[id]
    }
    
    public func activeJobCount() -> Int {
        activeJobs.values.filter { $0.status == .active }.count
    }
    
    public func reset() {
        activeJobs.removeAll()
        activeLease = nil
    }
}
