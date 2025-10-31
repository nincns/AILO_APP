// AILO_APP/Core/Mail/MailProcessorAdapter.swift
// Adapter to gradually migrate from old EmailContentParser to new MailProcessor
// Provides backward compatibility while enabling new enhanced processing
//
// SYNC INTEGRATION FIX (Phase 1):
// Added sync strategy detection and MailSyncEngine integration helpers
// This fixes the "empty database" issue where incremental sync finds no messages
// because it doesn't know to perform initial sync when DB is empty.

import Foundation

/// Adapter to bridge old EmailContentParser API with new MailProcessor
public class MailProcessorAdapter {
    
    /// Legacy ParsedEmailContent structure for backward compatibility
    public struct ParsedEmailContent: Sendable {
        public let content: String
        public let isHTML: Bool
        public let encoding: String
        
        public init(content: String, isHTML: Bool, encoding: String) {
            self.content = content
            self.isHTML = isHTML
            self.encoding = encoding
        }
    }
    
    // MARK: - Backward Compatibility Methods
    
    /// Maintains EmailContentParser.parseEmailContent API for existing code
    public static func parseEmailContent(_ rawContent: String) async -> ParsedEmailContent {
        // Use new MailProcessor internally
        let processed = await MailProcessorLegacy.processRawMail(rawContent)
        
        // Convert to legacy format
        let content = processed.html ?? processed.text ?? ""
        let isHTML = processed.html != nil
        let encoding = processed.transferEncoding
        
        return ParsedEmailContent(content: content, isHTML: isHTML, encoding: encoding)
    }
    
    // MARK: - Enhanced Processing Methods (for migration)
    
    /// Enhanced processing that returns full metadata
    /// Use this for new code that can handle enhanced metadata
    public static func processEmailWithMetadata(_ rawContent: String) async -> ProcessedMail {
        return await MailProcessorLegacy.processRawMail(rawContent)
    }
    
    /// Convert ProcessedMail to MessageBodyEntity (for database storage)
    public static func toMessageBodyEntity(_ processed: ProcessedMail, accountId: UUID, folder: String, uid: String) -> MessageBodyEntity {
        return MessageBodyEntity(
            accountId: accountId,
            folder: folder,
            uid: uid,
            text: processed.text,
            html: processed.html,
            hasAttachments: !processed.attachments.isEmpty,
            contentType: processed.contentType,
            charset: processed.charset,
            transferEncoding: processed.transferEncoding,
            isMultipart: processed.isMultipart,
            rawSize: processed.rawSize,
            processedAt: processed.processedAt
        )
    }
    
    /// Convert ProcessedAttachment to AttachmentEntity (for database storage)
    public static func toAttachmentEntity(_ processed: ProcessedAttachment, accountId: UUID, folder: String, uid: String) -> AttachmentEntity {
        return AttachmentEntity(
            accountId: accountId,
            folder: folder,
            uid: uid,
            partId: processed.partId,
            filename: processed.filename,
            mimeType: processed.mimeType,
            sizeBytes: processed.sizeBytes,
            data: processed.data,
            contentId: processed.contentId,
            isInline: processed.isInline,
            filePath: nil, // To be set by AttachmentManager
            checksum: processed.checksum
        )
    }
    
    // MARK: - Migration Helper Methods
    
    /// Check if content needs re-processing (for migration)
    public static func needsReprocessing(_ messageBody: MessageBodyEntity) -> Bool {
        // Content needs reprocessing if it lacks new metadata fields
        return messageBody.contentType == nil || 
               messageBody.charset == nil ||
               messageBody.processedAt == nil
    }
    
    /// Re-process existing content with enhanced metadata
    public static func reprocessExistingContent(_ rawContent: String, messageBody: MessageBodyEntity) async -> MessageBodyEntity {
        let processed = await MailProcessorLegacy.processRawMail(rawContent)
        
        // Create updated entity with enhanced metadata
        return MessageBodyEntity(
            accountId: messageBody.accountId,
            folder: messageBody.folder,
            uid: messageBody.uid,
            text: processed.text ?? messageBody.text,
            html: processed.html ?? messageBody.html,
            hasAttachments: !processed.attachments.isEmpty,
            contentType: processed.contentType,
            charset: processed.charset,
            transferEncoding: processed.transferEncoding,
            isMultipart: processed.isMultipart,
            rawSize: processed.rawSize,
            processedAt: processed.processedAt
        )
    }
    
    /// Process raw content for optimal display (chooses best format)
    public static func processForDisplay(_ processed: ProcessedMail) -> (content: String, isHTML: Bool) {
        // Apply multipart/alternative priority logic
        if processed.isMultipart {
            // HTML preferred if available and not empty
            if let html = processed.html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (html, true)
            }
            
            // Fallback to text
            if let text = processed.text {
                return (text, false)
            }
        }
        
        // Single part content
        if let html = processed.html {
            return (html, true)
        }
        
        if let text = processed.text {
            return (text, false)
        }
        
        // No content found
        return ("", false)
    }
}

// MARK: - Migration Status Tracking

/// Helper for tracking migration progress
public struct MailMigrationStatus {
    public let totalMails: Int
    public let processedMails: Int
    public let needsMigration: Int
    public let migrationComplete: Bool
    
    public var progressPercentage: Double {
        guard totalMails > 0 else { return 100.0 }
        return (Double(processedMails) / Double(totalMails)) * 100.0
    }
    
    public init(totalMails: Int, processedMails: Int) {
        self.totalMails = totalMails
        self.processedMails = processedMails
        self.needsMigration = totalMails - processedMails
        self.migrationComplete = processedMails >= totalMails
    }
}

// MARK: - Sync Integration Helpers

extension MailProcessorAdapter {
    
    /// Helper method to integrate MailSyncEngine with MailRepository
    /// This provides the bridge between the repository pattern and the sync engine
    public static func performSyncWithEngine(
        accountId: UUID,
        folder: String,
        syncEngine: MailSyncEngine,
        imapClient: IMAPClient,
        dao: any MailWriteDAO,
        isInitialSync: Bool = false
    ) async throws -> Int {
        
        // Create mock entities for the sync engine
        // TODO: These should be loaded from actual account/folder configuration
        let account = AccountEntity(
            id: accountId,
            displayName: "Account",
            emailAddress: "user@example.com",
            hostIMAP: "imap.example.com",
            hostSMTP: "smtp.example.com",
            createdAt: Date(),
            updatedAt: Date()
        )
        
        let folderEntity = FolderEntity(
            accountId: accountId,
            name: folder,
            specialUse: folder == "INBOX" ? "inbox" : nil,
            delimiter: "/",
            attributes: []
        )
        
        print("🔄 Starting MailSyncEngine.syncHeaders for \(isInitialSync ? "initial" : "incremental") sync")
        
        // Use MailSyncEngine to perform the actual sync
        let result = try await syncEngine.syncHeaders(
            client: imapClient,
            account: account,
            folder: folderEntity
        )
        
        print("✅ MailSyncEngine completed: \(result.newCount) new, \(result.updatedCount) updated")
        
        return result.newCount
    }
    
    /// Helper to check if a sync is needed based on database state
    public static func shouldPerformInitialSync(
        accountId: UUID,
        folder: String,
        dao: any MailReadDAO
    ) -> Bool {
        do {
            let headers = try dao.headers(accountId: accountId, folder: folder, limit: 1, offset: 0)
            let isEmpty = headers.isEmpty
            print("📊 Database check for \(folder): \(isEmpty ? "empty" : "has data") (checked: \(headers.count))")
            return isEmpty
        } catch {
            print("❌ Error checking database state: \(error)")
            // If we can't check, assume we need initial sync
            return true
        }
    }
    
    /// Helper to determine sync strategy based on local state
    public static func determineSyncStrategy(
        accountId: UUID,
        folder: String,
        dao: any MailReadDAO
    ) -> SyncStrategy {
        if shouldPerformInitialSync(accountId: accountId, folder: folder, dao: dao) {
            return .initialSync
        } else {
            return .incrementalSync
        }
    }
    
    /// Sync strategies that can be performed
    public enum SyncStrategy {
        case initialSync    // Database is empty, fetch all headers
        case incrementalSync // Database has data, fetch only new messages
        case fullRefresh    // Re-sync everything (for manual refresh)
        
        var description: String {
            switch self {
            case .initialSync: return "Initial Sync (empty database)"
            case .incrementalSync: return "Incremental Sync (fetch new)"
            case .fullRefresh: return "Full Refresh (re-sync all)"
            }
        }
    }
}
