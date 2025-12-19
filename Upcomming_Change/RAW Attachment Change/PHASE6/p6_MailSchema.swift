// AILO_APP/Models/Database/MailSchema_Phase6_Security.swift
// PHASE 6: Security & Compliance Schema Extensions
// Adds virus scanning, quarantine, and security tracking for attachments

import Foundation
import SQLite3

// MARK: - Virus Scan Status

/// Status of virus scan for an attachment
public enum VirusScanStatus: String, Codable, Sendable {
    case pending    // Not yet scanned
    case clean      // Scanned, no threats
    case infected   // Threat detected
    case error      // Scan failed
    case skipped    // Too large or scan disabled
    
    public var description: String {
        switch self {
        case .pending: return "Pending scan"
        case .clean: return "Clean"
        case .infected: return "Infected"
        case .error: return "Scan error"
        case .skipped: return "Not scanned"
        }
    }
    
    public var isAllowedToDownload: Bool {
        return self == .clean || self == .skipped
    }
}

// MARK: - Content Security Info

/// Security metadata for an attachment
public struct AttachmentSecurityInfo: Codable, Sendable {
    public let attachmentId: UUID
    public let virusScanStatus: VirusScanStatus
    public let scanDate: Date?
    public let scanEngine: String?
    public let threatName: String?
    public let quarantined: Bool
    public let contentTypeVerified: Bool
    public let originalContentType: String
    public let detectedContentType: String?
    
    public init(
        attachmentId: UUID,
        virusScanStatus: VirusScanStatus,
        scanDate: Date? = nil,
        scanEngine: String? = nil,
        threatName: String? = nil,
        quarantined: Bool = false,
        contentTypeVerified: Bool = false,
        originalContentType: String,
        detectedContentType: String? = nil
    ) {
        self.attachmentId = attachmentId
        self.virusScanStatus = virusScanStatus
        self.scanDate = scanDate
        self.scanEngine = scanEngine
        self.threatName = threatName
        self.quarantined = quarantined
        self.contentTypeVerified = contentTypeVerified
        self.originalContentType = originalContentType
        self.detectedContentType = detectedContentType
    }
}

// MARK: - Schema Migration Phase 6

public class MailSchemaPhase6Security {
    
    // MARK: - Migration
    
    /// Migrate database to Phase 6 (Security)
    public static func migrate(db: OpaquePointer) throws {
        print("🔒 [SCHEMA-6] Starting Phase 6 security migration...")
        
        // Add security columns to attachments table
        try addSecurityColumnsToAttachments(db: db)
        
        // Create security audit log table
        try createSecurityAuditTable(db: db)
        
        // Create quarantine table
        try createQuarantineTable(db: db)
        
        print("✅ [SCHEMA-6] Phase 6 security migration completed")
    }
    
    // MARK: - Attachments Security Columns
    
    private static func addSecurityColumnsToAttachments(db: OpaquePointer) throws {
        print("🔒 [SCHEMA-6] Adding security columns to attachments...")
        
        let columns = [
            // Virus scan status
            "ALTER TABLE attachments ADD COLUMN virus_scan_status TEXT DEFAULT 'pending'",
            "ALTER TABLE attachments ADD COLUMN scan_date INTEGER",
            "ALTER TABLE attachments ADD COLUMN scan_engine TEXT",
            "ALTER TABLE attachments ADD COLUMN threat_name TEXT",
            
            // Quarantine flag
            "ALTER TABLE attachments ADD COLUMN quarantined INTEGER DEFAULT 0",
            
            // Content-Type verification
            "ALTER TABLE attachments ADD COLUMN content_type_verified INTEGER DEFAULT 0",
            "ALTER TABLE attachments ADD COLUMN detected_content_type TEXT",
            
            // Size limits check
            "ALTER TABLE attachments ADD COLUMN exceeds_size_limit INTEGER DEFAULT 0",
            "ALTER TABLE attachments ADD COLUMN size_limit_bytes INTEGER"
        ]
        
        for sql in columns {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_DONE {
                    print("  ✓ Added column")
                } else {
                    // Column might already exist (ALTER TABLE fails silently in SQLite)
                    print("  ⚠️  Column might already exist")
                }
            }
            sqlite3_finalize(statement)
        }
        
        // Create index on virus_scan_status
        let indexSQL = """
        CREATE INDEX IF NOT EXISTS idx_attachments_virus_scan
        ON attachments(virus_scan_status, quarantined)
        """
        
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, indexSQL, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_DONE {
                print("  ✓ Created virus scan index")
            }
        }
        sqlite3_finalize(statement)
    }
    
    // MARK: - Security Audit Log
    
    private static func createSecurityAuditTable(db: OpaquePointer) throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS security_audit_log (
            id TEXT PRIMARY KEY,
            attachment_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            event_type TEXT NOT NULL,
            event_date INTEGER NOT NULL,
            scan_status TEXT,
            threat_name TEXT,
            action_taken TEXT,
            user_action TEXT,
            details TEXT,
            
            FOREIGN KEY (attachment_id) REFERENCES attachments(id),
            FOREIGN KEY (message_id) REFERENCES messages(id)
        )
        """
        
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_DONE {
                print("  ✓ Created security_audit_log table")
            }
        } else {
            let error = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "MailSchema", code: 6001, 
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create security_audit_log: \(error)"])
        }
        sqlite3_finalize(statement)
        
        // Create indexes
        let indexes = [
            "CREATE INDEX IF NOT EXISTS idx_security_audit_attachment ON security_audit_log(attachment_id)",
            "CREATE INDEX IF NOT EXISTS idx_security_audit_date ON security_audit_log(event_date)",
            "CREATE INDEX IF NOT EXISTS idx_security_audit_event ON security_audit_log(event_type)"
        ]
        
        for indexSQL in indexes {
            var indexStatement: OpaquePointer?
            if sqlite3_prepare_v2(db, indexSQL, -1, &indexStatement, nil) == SQLITE_OK {
                sqlite3_step(indexStatement)
            }
            sqlite3_finalize(indexStatement)
        }
    }
    
    // MARK: - Quarantine Table
    
    private static func createQuarantineTable(db: OpaquePointer) throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS quarantined_attachments (
            id TEXT PRIMARY KEY,
            attachment_id TEXT NOT NULL UNIQUE,
            message_id TEXT NOT NULL,
            original_filename TEXT NOT NULL,
            quarantine_date INTEGER NOT NULL,
            threat_name TEXT,
            threat_severity TEXT,
            original_blob_id TEXT,
            quarantine_blob_id TEXT,
            can_restore INTEGER DEFAULT 0,
            deleted INTEGER DEFAULT 0,
            
            FOREIGN KEY (attachment_id) REFERENCES attachments(id),
            FOREIGN KEY (message_id) REFERENCES messages(id)
        )
        """
        
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_DONE {
                print("  ✓ Created quarantined_attachments table")
            }
        } else {
            let error = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "MailSchema", code: 6002,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create quarantined_attachments: \(error)"])
        }
        sqlite3_finalize(statement)
        
        // Create index
        let indexSQL = "CREATE INDEX IF NOT EXISTS idx_quarantine_date ON quarantined_attachments(quarantine_date)"
        var indexStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, indexSQL, -1, &indexStatement, nil) == SQLITE_OK {
            sqlite3_step(indexStatement)
        }
        sqlite3_finalize(indexStatement)
    }
    
    // MARK: - Rollback
    
    /// Rollback Phase 6 migration (for testing/development)
    public static func rollback(db: OpaquePointer) throws {
        print("⚠️  [SCHEMA-6] Rolling back Phase 6 security migration...")
        
        // Drop tables
        let dropStatements = [
            "DROP TABLE IF EXISTS quarantined_attachments",
            "DROP TABLE IF EXISTS security_audit_log"
        ]
        
        for sql in dropStatements {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
        
        // Note: Cannot drop columns in SQLite, they will remain but be unused
        print("  ⚠️  Security columns remain in attachments table (SQLite limitation)")
        print("✅ [SCHEMA-6] Rollback completed")
    }
}

// MARK: - Usage Documentation

/*
 PHASE 6 SECURITY SCHEMA USAGE
 ==============================
 
 MIGRATION:
 ```swift
 try MailSchemaPhase6Security.migrate(db: db)
 ```
 
 VIRUS SCAN STATUS:
 ```swift
 let status = VirusScanStatus.clean
 print(status.isAllowedToDownload) // true
 ```
 
 SECURITY INFO:
 ```swift
 let securityInfo = AttachmentSecurityInfo(
     attachmentId: attachmentId,
     virusScanStatus: .clean,
     scanDate: Date(),
     scanEngine: "ClamAV",
     originalContentType: "application/pdf"
 )
 ```
 
 NEW COLUMNS IN attachments:
 - virus_scan_status (TEXT): pending/clean/infected/error/skipped
 - scan_date (INTEGER): Unix timestamp
 - scan_engine (TEXT): Scanner name
 - threat_name (TEXT): Detected threat
 - quarantined (INTEGER): 0/1 flag
 - content_type_verified (INTEGER): 0/1 flag
 - detected_content_type (TEXT): Sniffed MIME type
 - exceeds_size_limit (INTEGER): 0/1 flag
 - size_limit_bytes (INTEGER): Max allowed size
 
 NEW TABLES:
 - security_audit_log: All security events
 - quarantined_attachments: Isolated threats
 */
