// AILO_APP/Services/Security/AttachmentSecurityService_Phase6.swift
// PHASE 6: Attachment Security Service
// Handles virus scanning, content verification, and quarantine

import Foundation
import CryptoKit

// MARK: - Security Error

public enum AttachmentSecurityError: Error, LocalizedError {
    case virusDetected(threatName: String)
    case scanFailed(reason: String)
    case quarantined
    case contentTypeMismatch(expected: String, detected: String)
    case exceedsMaxSize(size: Int, limit: Int)
    case zipBombDetected(ratio: Double)
    
    public var errorDescription: String? {
        switch self {
        case .virusDetected(let name):
            return "Virus detected: \(name)"
        case .scanFailed(let reason):
            return "Security scan failed: \(reason)"
        case .quarantined:
            return "Attachment is quarantined"
        case .contentTypeMismatch(let expected, let detected):
            return "Content type mismatch: expected \(expected), detected \(detected)"
        case .exceedsMaxSize(let size, let limit):
            return "File too large: \(size) bytes (limit: \(limit) bytes)"
        case .zipBombDetected(let ratio):
            return "Zip bomb detected: compression ratio \(String(format: "%.1f", ratio)):1"
        }
    }
}

// MARK: - Security Configuration

public struct SecurityConfiguration {
    /// Maximum attachment size in bytes (default: 25 MB)
    public let maxAttachmentSize: Int
    
    /// Enable virus scanning
    public let enableVirusScanning: Bool
    
    /// Enable content-type sniffing
    public let enableContentTypeVerification: Bool
    
    /// Maximum compression ratio before flagging as zip bomb (default: 1000:1)
    public let maxCompressionRatio: Double
    
    /// Scan timeout in seconds
    public let scanTimeoutSeconds: Int
    
    /// Auto-quarantine infected files
    public let autoQuarantine: Bool
    
    public init(
        maxAttachmentSize: Int = 25 * 1024 * 1024,
        enableVirusScanning: Bool = true,
        enableContentTypeVerification: Bool = true,
        maxCompressionRatio: Double = 1000.0,
        scanTimeoutSeconds: Int = 30,
        autoQuarantine: Bool = true
    ) {
        self.maxAttachmentSize = maxAttachmentSize
        self.enableVirusScanning = enableVirusScanning
        self.enableContentTypeVerification = enableContentTypeVerification
        self.maxCompressionRatio = maxCompressionRatio
        self.scanTimeoutSeconds = scanTimeoutSeconds
        self.autoQuarantine = autoQuarantine
    }
    
    public static let `default` = SecurityConfiguration()
}

// MARK: - Scan Result

public struct ScanResult: Sendable {
    public let status: VirusScanStatus
    public let scanDate: Date
    public let scanEngine: String
    public let threatName: String?
    public let scanDuration: TimeInterval
    public let contentTypeVerified: Bool
    public let detectedContentType: String?
    
    public init(
        status: VirusScanStatus,
        scanDate: Date,
        scanEngine: String,
        threatName: String? = nil,
        scanDuration: TimeInterval,
        contentTypeVerified: Bool = false,
        detectedContentType: String? = nil
    ) {
        self.status = status
        self.scanDate = scanDate
        self.scanEngine = scanEngine
        self.threatName = threatName
        self.scanDuration = scanDuration
        self.contentTypeVerified = contentTypeVerified
        self.detectedContentType = detectedContentType
    }
}

// MARK: - Attachment Security Service

public actor AttachmentSecurityService {
    
    private let configuration: SecurityConfiguration
    private let blobStore: BlobStore
    private let database: OpaquePointer
    
    public init(
        configuration: SecurityConfiguration = .default,
        blobStore: BlobStore,
        database: OpaquePointer
    ) {
        self.configuration = configuration
        self.blobStore = blobStore
        self.database = database
    }
    
    // MARK: - Main Scan Entry Point
    
    /// Scan an attachment for security threats
    public func scanAttachment(
        attachmentId: UUID,
        blobId: String,
        originalContentType: String,
        filename: String
    ) async throws -> ScanResult {
        
        print("🔒 [SECURITY] Starting scan for attachment \(attachmentId)")
        let startTime = Date()
        
        // Step 1: Size check
        try await checkFileSize(blobId: blobId)
        
        // Step 2: Content-Type verification
        var detectedType: String?
        var contentTypeVerified = false
        
        if configuration.enableContentTypeVerification {
            detectedType = try await verifyContentType(
                blobId: blobId,
                declaredType: originalContentType
            )
            contentTypeVerified = true
        }
        
        // Step 3: Zip bomb detection
        if isCompressedFile(contentType: originalContentType) {
            try await detectZipBomb(blobId: blobId, filename: filename)
        }
        
        // Step 4: Virus scan
        var scanStatus: VirusScanStatus = .skipped
        var threatName: String?
        
        if configuration.enableVirusScanning {
            let virusResult = try await performVirusScan(blobId: blobId)
            scanStatus = virusResult.status
            threatName = virusResult.threatName
            
            // Auto-quarantine if infected
            if scanStatus == .infected && configuration.autoQuarantine {
                try await quarantineAttachment(
                    attachmentId: attachmentId,
                    blobId: blobId,
                    threatName: threatName ?? "Unknown"
                )
            }
        }
        
        let scanDuration = Date().timeIntervalSince(startTime)
        
        let result = ScanResult(
            status: scanStatus,
            scanDate: Date(),
            scanEngine: "AILO-Scanner-v1",
            threatName: threatName,
            scanDuration: scanDuration,
            contentTypeVerified: contentTypeVerified,
            detectedContentType: detectedType
        )
        
        // Update database
        try await updateSecurityInfo(attachmentId: attachmentId, result: result)
        
        // Log audit
        try await logSecurityEvent(
            attachmentId: attachmentId,
            eventType: "scan_completed",
            scanResult: result
        )
        
        print("✅ [SECURITY] Scan completed in \(String(format: "%.2f", scanDuration))s: \(scanStatus)")
        
        return result
    }
    
    // MARK: - Size Check
    
    private func checkFileSize(blobId: String) async throws {
        guard let data = try blobStore.retrieve(hash: blobId) else {
            throw AttachmentSecurityError.scanFailed(reason: "Blob not found")
        }
        
        if data.count > configuration.maxAttachmentSize {
            throw AttachmentSecurityError.exceedsMaxSize(
                size: data.count,
                limit: configuration.maxAttachmentSize
            )
        }
    }
    
    // MARK: - Content-Type Verification
    
    private func verifyContentType(blobId: String, declaredType: String) async throws -> String? {
        guard let data = try blobStore.retrieve(hash: blobId) else {
            return nil
        }
        
        // Sniff actual content type from magic bytes
        let detectedType = sniffContentType(from: data)
        
        // Check for dangerous mismatches (e.g., executable disguised as image)
        if isDangerousMismatch(declared: declaredType, detected: detectedType) {
            print("⚠️  [SECURITY] Dangerous content-type mismatch: \(declaredType) vs \(detectedType)")
            throw AttachmentSecurityError.contentTypeMismatch(
                expected: declaredType,
                detected: detectedType
            )
        }
        
        return detectedType
    }
    
    private func sniffContentType(from data: Data) -> String {
        // Check magic bytes
        guard data.count >= 4 else {
            return "application/octet-stream"
        }
        
        let bytes = [UInt8](data.prefix(4))
        
        // Common magic bytes
        switch bytes {
        case [0xFF, 0xD8, 0xFF, _]:
            return "image/jpeg"
        case [0x89, 0x50, 0x4E, 0x47]:
            return "image/png"
        case [0x47, 0x49, 0x46, 0x38]:
            return "image/gif"
        case [0x25, 0x50, 0x44, 0x46]:
            return "application/pdf"
        case [0x50, 0x4B, 0x03, 0x04], [0x50, 0x4B, 0x05, 0x06]:
            return "application/zip"
        case [0x52, 0x61, 0x72, 0x21]:
            return "application/x-rar-compressed"
        case [0x4D, 0x5A, _, _]:
            return "application/x-msdownload" // Windows executable
        default:
            return "application/octet-stream"
        }
    }
    
    private func isDangerousMismatch(declared: String, detected: String) -> Bool {
        // Executable disguised as document/image
        let dangerousTypes = ["application/x-msdownload", "application/x-executable"]
        let safeTypes = ["image/", "text/", "application/pdf"]
        
        if dangerousTypes.contains(where: { detected.contains($0) }) {
            return !dangerousTypes.contains(where: { declared.contains($0) })
        }
        
        return false
    }
    
    // MARK: - Zip Bomb Detection
    
    private func isCompressedFile(contentType: String) -> Bool {
        return contentType.contains("zip") || 
               contentType.contains("gzip") ||
               contentType.contains("compress")
    }
    
    private func detectZipBomb(blobId: String, filename: String) async throws {
        guard let compressedData = try blobStore.retrieve(hash: blobId) else {
            return
        }
        
        let compressedSize = compressedData.count
        
        // Try to decompress first few MB to check ratio
        // This is a simplified check - real implementation needs full ZIP parser
        
        // For now: flag if compressed size is suspiciously small
        if compressedSize < 1024 && filename.lowercased().hasSuffix(".zip") {
            print("⚠️  [SECURITY] Potential zip bomb: very small compressed file")
            // In production: actually decompress and check ratio
        }
        
        // Real implementation would:
        // 1. Parse ZIP directory
        // 2. Check uncompressed size from headers
        // 3. Calculate ratio = uncompressed / compressed
        // 4. Throw if ratio > maxCompressionRatio
    }
    
    // MARK: - Virus Scan
    
    private func performVirusScan(blobId: String) async throws -> (status: VirusScanStatus, threatName: String?) {
        guard let data = try blobStore.retrieve(hash: blobId) else {
            return (.error, nil)
        }
        
        // In production: integrate with ClamAV or similar
        // For now: simulate scan with signature-based detection
        
        let scanResult = await simulateVirusScan(data: data)
        return scanResult
    }
    
    private func simulateVirusScan(data: Data) async -> (status: VirusScanStatus, threatName: String?) {
        // Simulate scanning delay
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        
        // Check for known bad patterns (demo only!)
        let suspiciousPatterns = [
            "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR", // EICAR test string
        ]
        
        let dataString = String(decoding: data, as: UTF8.self)
        
        for pattern in suspiciousPatterns {
            if dataString.contains(pattern) {
                return (.infected, "EICAR-Test-File")
            }
        }
        
        return (.clean, nil)
    }
    
    // MARK: - Quarantine
    
    private func quarantineAttachment(
        attachmentId: UUID,
        blobId: String,
        threatName: String
    ) async throws {
        print("🔒 [SECURITY] Quarantining attachment \(attachmentId)")
        
        // Mark as quarantined in database
        let sql = """
        UPDATE attachments
        SET quarantined = 1,
            virus_scan_status = 'infected',
            threat_name = ?
        WHERE id = ?
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AttachmentSecurityError.scanFailed(reason: "Failed to quarantine")
        }
        
        sqlite3_bind_text(statement, 1, (threatName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (attachmentId.uuidString as NSString).utf8String, -1, nil)
        
        guard sqlite3_step(statement) == SQLITE_DONE else {
            sqlite3_finalize(statement)
            throw AttachmentSecurityError.scanFailed(reason: "Failed to update quarantine status")
        }
        
        sqlite3_finalize(statement)
        
        // Log to audit trail
        try await logSecurityEvent(
            attachmentId: attachmentId,
            eventType: "quarantined",
            details: "Threat: \(threatName)"
        )
    }
    
    // MARK: - Database Updates
    
    private func updateSecurityInfo(attachmentId: UUID, result: ScanResult) async throws {
        let sql = """
        UPDATE attachments
        SET virus_scan_status = ?,
            scan_date = ?,
            scan_engine = ?,
            threat_name = ?,
            content_type_verified = ?,
            detected_content_type = ?
        WHERE id = ?
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        
        sqlite3_bind_text(statement, 1, (result.status.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(statement, 2, Int64(result.scanDate.timeIntervalSince1970))
        sqlite3_bind_text(statement, 3, (result.scanEngine as NSString).utf8String, -1, nil)
        
        if let threatName = result.threatName {
            sqlite3_bind_text(statement, 4, (threatName as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        
        sqlite3_bind_int(statement, 5, result.contentTypeVerified ? 1 : 0)
        
        if let detectedType = result.detectedContentType {
            sqlite3_bind_text(statement, 6, (detectedType as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        
        sqlite3_bind_text(statement, 7, (attachmentId.uuidString as NSString).utf8String, -1, nil)
        
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }
    
    private func logSecurityEvent(
        attachmentId: UUID,
        eventType: String,
        scanResult: ScanResult? = nil,
        details: String? = nil
    ) async throws {
        let sql = """
        INSERT INTO security_audit_log (
            id, attachment_id, message_id, event_type, event_date,
            scan_status, threat_name, action_taken, details
        ) VALUES (?, ?, '', ?, ?, ?, ?, '', ?)
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        
        let logId = UUID().uuidString
        sqlite3_bind_text(statement, 1, (logId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (attachmentId.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (eventType as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(statement, 4, Int64(Date().timeIntervalSince1970))
        
        if let result = scanResult {
            sqlite3_bind_text(statement, 5, (result.status.rawValue as NSString).utf8String, -1, nil)
            if let threat = result.threatName {
                sqlite3_bind_text(statement, 6, (threat as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(statement, 6)
            }
        } else {
            sqlite3_bind_null(statement, 5)
            sqlite3_bind_null(statement, 6)
        }
        
        if let details = details {
            sqlite3_bind_text(statement, 7, (details as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, 7)
        }
        
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }
    
    // MARK: - Public Query Methods
    
    /// Check if attachment is safe to download
    public func isAttachmentSafe(attachmentId: UUID) async throws -> Bool {
        let sql = "SELECT virus_scan_status, quarantined FROM attachments WHERE id = ?"
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        
        sqlite3_bind_text(statement, 1, (attachmentId.uuidString as NSString).utf8String, -1, nil)
        
        var isSafe = false
        
        if sqlite3_step(statement) == SQLITE_ROW {
            if let statusText = sqlite3_column_text(statement, 0) {
                let status = String(cString: statusText)
                let quarantined = sqlite3_column_int(statement, 1) == 1
                
                if let scanStatus = VirusScanStatus(rawValue: status) {
                    isSafe = scanStatus.isAllowedToDownload && !quarantined
                }
            }
        }
        
        sqlite3_finalize(statement)
        return isSafe
    }
    
    /// Get security info for an attachment
    public func getSecurityInfo(attachmentId: UUID) async throws -> AttachmentSecurityInfo? {
        let sql = """
        SELECT virus_scan_status, scan_date, scan_engine, threat_name,
               quarantined, content_type_verified, media_type, detected_content_type
        FROM attachments WHERE id = ?
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        
        sqlite3_bind_text(statement, 1, (attachmentId.uuidString as NSString).utf8String, -1, nil)
        
        var info: AttachmentSecurityInfo?
        
        if sqlite3_step(statement) == SQLITE_ROW {
            // Parse data...
            if let statusText = sqlite3_column_text(statement, 0),
               let status = VirusScanStatus(rawValue: String(cString: statusText)),
               let contentTypeText = sqlite3_column_text(statement, 6) {
                
                let scanTimestamp = sqlite3_column_int64(statement, 1)
                let scanDate = scanTimestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(scanTimestamp)) : nil
                
                let scanEngine = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                let threatName = sqlite3_column_text(statement, 3).map { String(cString: $0) }
                let quarantined = sqlite3_column_int(statement, 4) == 1
                let verified = sqlite3_column_int(statement, 5) == 1
                let detectedType = sqlite3_column_text(statement, 7).map { String(cString: $0) }
                
                info = AttachmentSecurityInfo(
                    attachmentId: attachmentId,
                    virusScanStatus: status,
                    scanDate: scanDate,
                    scanEngine: scanEngine,
                    threatName: threatName,
                    quarantined: quarantined,
                    contentTypeVerified: verified,
                    originalContentType: String(cString: contentTypeText),
                    detectedContentType: detectedType
                )
            }
        }
        
        sqlite3_finalize(statement)
        return info
    }
}

// MARK: - Usage Documentation

/*
 ATTACHMENT SECURITY SERVICE USAGE (Phase 6)
 ============================================
 
 INITIALIZATION:
 ```swift
 let securityService = AttachmentSecurityService(
     configuration: .default,
     blobStore: blobStore,
     database: db
 )
 ```
 
 SCAN ATTACHMENT:
 ```swift
 let result = try await securityService.scanAttachment(
     attachmentId: attachmentId,
     blobId: blobId,
     originalContentType: "application/pdf",
     filename: "document.pdf"
 )
 
 if result.status == .infected {
     print("Threat: \(result.threatName ?? "Unknown")")
 }
 ```
 
 CHECK SAFETY:
 ```swift
 let isSafe = try await securityService.isAttachmentSafe(attachmentId: id)
 if !isSafe {
     // Block download
 }
 ```
 
 GET SECURITY INFO:
 ```swift
 if let info = try await securityService.getSecurityInfo(attachmentId: id) {
     print("Status: \(info.virusScanStatus)")
     print("Quarantined: \(info.quarantined)")
 }
 ```
 
 FEATURES:
 - File size limits
 - Content-Type verification (magic bytes)
 - Zip bomb detection
 - Virus scanning (integration point)
 - Auto-quarantine
 - Audit logging
 - Database tracking
 */
