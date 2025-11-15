// MessageProcessingOrchestrator.swift
// Hauptkoordinator für die gesamte Email-Verarbeitungspipeline
// Phase 8: Complete orchestration with error recovery and monitoring

import Foundation

// MARK: - Message Processing Orchestrator

@MainActor
class MessageProcessingOrchestrator {
    
    // MARK: - Dependencies
    
    private let messageService: MessageProcessingService
    private let attachmentController: AttachmentDownloadController
    private let errorRecovery: ErrorRecoveryService
    private let performanceMonitor: PerformanceMonitor
    private let limitsService: MessageLimitsService
    private let securityService: AttachmentSecurityService
    private let blobStore: BlobStoreProtocol
    
    // Processing queue
    private let processingQueue = OperationQueue()
    
    // Active processing tasks
    private var activeTasks: [UUID: ProcessingTask] = [:]
    
    // Statistics
    private var statistics = ProcessingStatistics()
    
    // MARK: - Initialization
    
    init(messageService: MessageProcessingService,
         attachmentController: AttachmentDownloadController,
         errorRecovery: ErrorRecoveryService,
         performanceMonitor: PerformanceMonitor,
         limitsService: MessageLimitsService,
         securityService: AttachmentSecurityService,
         blobStore: BlobStoreProtocol) {
        
        self.messageService = messageService
        self.attachmentController = attachmentController
        self.errorRecovery = errorRecovery
        self.performanceMonitor = performanceMonitor
        self.limitsService = limitsService
        self.securityService = securityService
        self.blobStore = blobStore
        
        // Configure processing queue
        processingQueue.maxConcurrentOperationCount = 3
        processingQueue.qualityOfService = .userInitiated
    }
    
    // MARK: - Main Orchestration
    
    func orchestrateProcessing(for message: MessageRequest) async throws -> ProcessingResult {
        let taskId = UUID()
        let startTime = Date()
        
        // Create processing task
        let task = ProcessingTask(
            id: taskId,
            messageId: message.messageId,
            startTime: startTime,
            status: .preparing
        )
        
        activeTasks[taskId] = task
        defer { activeTasks[taskId] = nil }
        
        print("🎼 [Orchestrator] Starting processing for message: \(message.messageId)")
        
        do {
            // Phase 1: Validation
            updateTaskStatus(taskId, .validating)
            try await validateMessage(message)
            
            // Phase 2: Fetch message data
            updateTaskStatus(taskId, .fetching)
            let fetchedData = try await fetchMessageData(message)
            
            // Phase 3: Process message
            updateTaskStatus(taskId, .processing)
            let processedMessage = try await processMessage(fetchedData)
            
            // Phase 4: Handle attachments
            updateTaskStatus(taskId, .downloadingAttachments)
            let attachmentResults = await processAttachments(processedMessage)
            
            // Phase 5: Finalize and store
            updateTaskStatus(taskId, .finalizing)
            let finalResult = try await finalizeProcessing(
                processedMessage,
                attachmentResults: attachmentResults
            )
            
            // Phase 6: Post-processing
            updateTaskStatus(taskId, .postProcessing)
            await performPostProcessing(finalResult)
            
            // Update statistics
            updateStatistics(success: true, duration: Date().timeIntervalSince(startTime))
            
            updateTaskStatus(taskId, .completed)
            
            print("✅ [Orchestrator] Completed processing for message: \(message.messageId)")
            
            return finalResult
            
        } catch {
            print("❌ [Orchestrator] Processing failed: \(error)")
            
            updateTaskStatus(taskId, .failed)
            updateStatistics(success: false, duration: Date().timeIntervalSince(startTime))
            
            // Attempt recovery
            if await errorRecovery.canRecover(from: error) {
                print("🔄 [Orchestrator] Attempting recovery...")
                return try await retryWithRecovery(message: message, error: error)
            }
            
            throw error
        }
    }
    
    // MARK: - Phase 1: Validation
    
    private func validateMessage(_ message: MessageRequest) async throws {
        print("🔍 [Orchestrator] Validating message...")
        
        // Check rate limits
        try limitsService.checkMessageRate(accountId: message.accountId)
        
        // Validate message size if known
        if let size = message.estimatedSize {
            try limitsService.validateMessage(
                size: size,
                headerSize: message.headerSize ?? 0,
                bodySize: size - (message.headerSize ?? 0)
            )
        }
        
        // Check account status
        // ... additional validation
    }
    
    // MARK: - Phase 2: Fetch Message Data
    
    private func fetchMessageData(_ message: MessageRequest) async throws -> FetchedMessageData {
        return try await performanceMonitor.measure("fetch_message") {
            print("📥 [Orchestrator] Fetching message data...")
            
            // Fetch from IMAP or cache
            let rawMessage = message.rawData
            let bodyStructure = message.bodyStructure
            
            // If not provided, fetch from server
            if rawMessage == nil && bodyStructure == nil {
                // Use transport to fetch
                // ... implementation
            }
            
            return FetchedMessageData(
                messageId: message.messageId,
                accountId: message.accountId,
                folder: message.folder,
                uid: message.uid,
                rawMessage: rawMessage,
                bodyStructure: bodyStructure
            )
        }
    }
    
    // MARK: - Phase 3: Process Message
    
    private func processMessage(_ data: FetchedMessageData) async throws -> ProcessedMessage {
        return try await performanceMonitor.measure("process_message") {
            print("⚙️ [Orchestrator] Processing message...")
            
            // Check processing time limit
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                throw ProcessingError.timeout
            }
            
            let processingTask = Task {
                try await messageService.processMessage(
                    messageId: data.messageId,
                    accountId: data.accountId,
                    folder: data.folder,
                    uid: data.uid,
                    rawMessage: data.rawMessage,
                    bodyStructure: data.bodyStructure
                )
            }
            
            // Race between processing and timeout
            let result = await withTaskGroup(of: ProcessingOutcome.self) { group in
                group.addTask {
                    do {
                        try await processingTask.value
                        return .success
                    } catch {
                        return .failure(error)
                    }
                }
                
                group.addTask {
                    do {
                        try await timeoutTask.value
                        return .timeout
                    } catch {
                        return .cancelled
                    }
                }
                
                let firstResult = await group.next()!
                group.cancelAll()
                return firstResult
            }
            
            switch result {
            case .success:
                return ProcessedMessage(
                    messageId: data.messageId,
                    mimeParts: [],  // Retrieved from service
                    hasAttachments: false,
                    renderCacheId: nil
                )
            case .timeout:
                throw ProcessingError.timeout
            case .failure(let error):
                throw error
            case .cancelled:
                return ProcessedMessage(
                    messageId: data.messageId,
                    mimeParts: [],
                    hasAttachments: false,
                    renderCacheId: nil
                )
            }
        }
    }
    
    // MARK: - Phase 4: Process Attachments
    
    private func processAttachments(_ message: ProcessedMessage) async -> [AttachmentResult] {
        print("📎 [Orchestrator] Processing attachments...")
        
        guard message.hasAttachments else {
            return []
        }
        
        var results: [AttachmentResult] = []
        
        // Process attachments concurrently with limit
        await withTaskGroup(of: AttachmentResult.self) { group in
            for part in message.mimeParts {
                if !part.isBodyCandidate && part.sizeOctets > 0 {
                    group.addTask {
                        await self.processAttachment(
                            messageId: message.messageId,
                            part: part
                        )
                    }
                }
                
                // Limit concurrent downloads
                if group.count >= 5 {
                    if let result = await group.next() {
                        results.append(result)
                    }
                }
            }
            
            // Collect remaining results
            for await result in group {
                results.append(result)
            }
        }
        
        return results
    }
    
    private func processAttachment(messageId: UUID, part: MimePartEntity) async -> AttachmentResult {
        do {
            // Check if already in blob store
            if let blobId = part.blobId,
               blobStore.exists(blobId: blobId) {
                return AttachmentResult(
                    partId: part.partId,
                    status: .cached,
                    blobId: blobId
                )
            }
            
            // Download if needed
            let data = try await attachmentController.downloadAttachment(
                messageId: messageId,
                partId: part.partId,
                section: "BODY[\(part.partId)]",
                expectedSize: part.sizeOctets
            )
            
            // Store in blob store
            let blobId = try blobStore.store(data, messageId: messageId, partId: part.partId)
            
            return AttachmentResult(
                partId: part.partId,
                status: .downloaded,
                blobId: blobId
            )
            
        } catch {
            print("⚠️ [Orchestrator] Failed to process attachment \(part.partId): \(error)")
            
            return AttachmentResult(
                partId: part.partId,
                status: .failed,
                error: error
            )
        }
    }
    
    // MARK: - Phase 5: Finalize Processing
    
    private func finalizeProcessing(_ message: ProcessedMessage,
                                   attachmentResults: [AttachmentResult]) async throws -> ProcessingResult {
        print("🏁 [Orchestrator] Finalizing processing...")
        
        // Update attachment statuses
        for result in attachmentResults {
            if result.status == .failed {
                // Mark attachment as unavailable
                // ... update database
            }
        }
        
        // Calculate final statistics
        let successfulAttachments = attachmentResults.filter { $0.status != .failed }.count
        let failedAttachments = attachmentResults.filter { $0.status == .failed }.count
        
        return ProcessingResult(
            messageId: message.messageId,
            status: .success,
            renderCacheId: message.renderCacheId,
            attachmentsProcessed: successfulAttachments,
            attachmentsFailed: failedAttachments,
            processingTime: Date().timeIntervalSince(activeTasks[message.messageId]?.startTime ?? Date())
        )
    }
    
    // MARK: - Phase 6: Post-Processing
    
    private func performPostProcessing(_ result: ProcessingResult) async {
        print("🔧 [Orchestrator] Performing post-processing...")
        
        // Cleanup temporary files
        // ... cleanup logic
        
        // Update search index
        // ... indexing logic
        
        // Send notifications if needed
        await notifyProcessingComplete(result)
        
        // Schedule background tasks
        if result.attachmentsFailed > 0 {
            // Schedule retry for failed attachments
            Task {
                try await Task.sleep(nanoseconds: 60_000_000_000) // 1 minute
                await retryFailedAttachments(messageId: result.messageId)
            }
        }
    }
    
    // MARK: - Error Recovery
    
    private func retryWithRecovery(message: MessageRequest, error: Error) async throws -> ProcessingResult {
        // Implement recovery strategy based on error type
        
        if error is ProcessingError {
            // Wait and retry
            try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            return try await orchestrateProcessing(for: message)
        }
        
        throw error
    }
    
    private func retryFailedAttachments(messageId: UUID) async {
        print("🔄 [Orchestrator] Retrying failed attachments for message: \(messageId)")
        // ... retry logic
    }
    
    // MARK: - Task Management
    
    private func updateTaskStatus(_ taskId: UUID, _ status: TaskStatus) {
        activeTasks[taskId]?.status = status
        
        // Notify observers
        Task {
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .processingStatusChanged,
                    object: nil,
                    userInfo: ["taskId": taskId, "status": status]
                )
            }
        }
    }
    
    // MARK: - Statistics
    
    private func updateStatistics(success: Bool, duration: TimeInterval) {
        if success {
            statistics.successCount += 1
        } else {
            statistics.failureCount += 1
        }
        
        statistics.totalProcessingTime += duration
        statistics.averageProcessingTime = statistics.totalProcessingTime /
                                          Double(statistics.successCount + statistics.failureCount)
    }
    
    func getStatistics() -> ProcessingStatistics {
        return statistics
    }
    
    // MARK: - Notifications
    
    private func notifyProcessingComplete(_ result: ProcessingResult) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .messageProcessingComplete,
                object: nil,
                userInfo: ["result": result]
            )
        }
    }
}

// MARK: - Queue Management

extension MessageProcessingOrchestrator {
    
    func queueMessage(_ message: MessageRequest) {
        let operation = ProcessingOperation(message: message) { message in
            Task {
                try await self.orchestrateProcessing(for: message)
            }
        }
        
        processingQueue.addOperation(operation)
    }
    
    func cancelProcessing(for messageId: UUID) {
        // Cancel active task
        if let task = activeTasks.values.first(where: { $0.messageId == messageId }) {
            // ... cancellation logic
        }
        
        // Cancel queued operations
        for operation in processingQueue.operations {
            if let processingOp = operation as? ProcessingOperation,
               processingOp.message.messageId == messageId {
                operation.cancel()
            }
        }
    }
    
    func pauseProcessing() {
        processingQueue.isSuspended = true
    }
    
    func resumeProcessing() {
        processingQueue.isSuspended = false
    }
}

// MARK: - Supporting Types

struct MessageRequest {
    let messageId: UUID
    let accountId: UUID
    let folder: String
    let uid: String
    let rawData: Data?
    let bodyStructure: IMAPBodyStructure?
    let estimatedSize: Int?
    let headerSize: Int?
}

struct FetchedMessageData {
    let messageId: UUID
    let accountId: UUID
    let folder: String
    let uid: String
    let rawMessage: Data?
    let bodyStructure: IMAPBodyStructure?
}

struct ProcessedMessage {
    let messageId: UUID
    let mimeParts: [MimePartEntity]
    let hasAttachments: Bool
    let renderCacheId: String?
}

struct AttachmentResult {
    let partId: String
    let status: AttachmentStatus
    let blobId: String?
    let error: Error?
    
    init(partId: String, status: AttachmentStatus, blobId: String? = nil, error: Error? = nil) {
        self.partId = partId
        self.status = status
        self.blobId = blobId
        self.error = error
    }
}

struct ProcessingResult {
    let messageId: UUID
    let status: ProcessingStatus
    let renderCacheId: String?
    let attachmentsProcessed: Int
    let attachmentsFailed: Int
    let processingTime: TimeInterval
}

struct ProcessingTask {
    let id: UUID
    let messageId: UUID
    let startTime: Date
    var status: TaskStatus
}

struct ProcessingStatistics {
    var successCount: Int = 0
    var failureCount: Int = 0
    var totalProcessingTime: TimeInterval = 0
    var averageProcessingTime: TimeInterval = 0
}

enum TaskStatus {
    case preparing
    case validating
    case fetching
    case processing
    case downloadingAttachments
    case finalizing
    case postProcessing
    case completed
    case failed
}

enum AttachmentStatus {
    case cached
    case downloaded
    case failed
}

enum ProcessingStatus {
    case success
    case partialSuccess
    case failed
}

enum ProcessingError: Error {
    case timeout
    case validationFailed
    case fetchFailed
    case processingFailed
}

enum ProcessingOutcome {
    case success
    case failure(Error)
    case timeout
    case cancelled
}

// MARK: - Processing Operation

class ProcessingOperation: Operation {
    let message: MessageRequest
    let processor: (MessageRequest) -> Void
    
    init(message: MessageRequest, processor: @escaping (MessageRequest) -> Void) {
        self.message = message
        self.processor = processor
    }
    
    override func main() {
        guard !isCancelled else { return }
        processor(message)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let processingStatusChanged = Notification.Name("processingStatusChanged")
    static let messageProcessingComplete = Notification.Name("messageProcessingComplete")
}
