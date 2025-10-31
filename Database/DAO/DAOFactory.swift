// AILO_APP/Core/Storage/DAOFactory.swift
// Central factory for creating and managing DAO instances
// Phase 4: Integration layer

import Foundation

// MARK: - DAO Factory

public class DAOFactory {
    
    // MARK: - Properties
    
    private let dbPath: String
    private let attachmentsDirectory: URL
    private let maxInlineSize: Int
    private let deduplicationEnabled: Bool
    private let maxRetryAttempts: Int
    
    // Lazy initialization of DAOs
    private lazy var _mailReadDAO: MailReadDAOImpl = MailReadDAOImpl(dbPath: dbPath)
    private lazy var _mailWriteDAO: MailWriteDAOImpl = MailWriteDAOImpl(dbPath: dbPath)
    private lazy var _attachmentDAO: AttachmentDAOImpl = AttachmentDAOImpl(
        dbPath: dbPath,
        attachmentsDirectory: attachmentsDirectory,
        maxInlineSize: maxInlineSize,
        deduplicationEnabled: deduplicationEnabled
    )
    private lazy var _outboxDAO: MailOutboxDAOImpl = MailOutboxDAOImpl(
        dbPath: dbPath,
        maxRetryAttempts: maxRetryAttempts
    )
    private lazy var _folderDAO: FolderDAOImpl = FolderDAOImpl(dbPath: dbPath)
    private lazy var _accountDAO: AccountDAOImpl = AccountDAOImpl(dbPath: dbPath)
    
    // MARK: - Initialization
    
    public init(dbPath: String, 
                attachmentsDirectory: URL? = nil,
                maxInlineSize: Int = 1024 * 1024,
                deduplicationEnabled: Bool = true,
                maxRetryAttempts: Int = 3) {
        self.dbPath = dbPath
        self.maxInlineSize = maxInlineSize
        self.deduplicationEnabled = deduplicationEnabled
        self.maxRetryAttempts = maxRetryAttempts
        
        // Default attachments directory if not provided
        if let attachmentsDir = attachmentsDirectory {
            self.attachmentsDirectory = attachmentsDir
        } else {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, 
                                                       in: .userDomainMask).first!
            self.attachmentsDirectory = documentsPath.appendingPathComponent("Attachments")
        }
    }
    
    // MARK: - DAO Access
    
    public var mailReadDAO: MailReadDAO { _mailReadDAO }
    public var mailWriteDAO: MailWriteDAO { _mailWriteDAO }
    public var attachmentDAO: AttachmentDAO { _attachmentDAO }
    public var outboxDAO: MailOutboxDAO { _outboxDAO }
    public var folderDAO: FolderDAO { _folderDAO }
    public var accountDAO: AccountDAO { _accountDAO }
    
    // Combined DAO for components that need both read and write
    public var mailFullAccessDAO: MailFullAccessDAO { MailFullAccessDAOImpl(factory: self) }
    
    // MARK: - Database Management
    
    public func initializeDatabase() throws {
        print("🔧 Opening primary database connection...")
        try _accountDAO.openDatabase()
        
        guard let sharedDB = _accountDAO.db else {
            throw DAOError.databaseError("Failed to establish primary database connection")
        }
        
        // Share the database connection across all DAOs using the new method
        print("🔧 Sharing database connection across all DAOs...")
        _mailReadDAO.setSharedConnection(sharedDB)
        _mailWriteDAO.setSharedConnection(sharedDB)
        _attachmentDAO.setSharedConnection(sharedDB)
        _outboxDAO.setSharedConnection(sharedDB)
        _folderDAO.setSharedConnection(sharedDB)
        
        print("🔧 Creating database schema...")
        try MailSchemaManager.createTables(using: _accountDAO)
        try MailSchemaManager.migrateIfNeeded(using: _accountDAO)
    }
    
    public func closeAllConnections() {
        // Only close the primary database connection
        // Other DAOs are sharing the same connection
        print("🔧 Closing shared database connection...")
        _accountDAO.closeDatabase()
        
        // Clear connection references in other DAOs
        _mailReadDAO.setSharedConnection(nil)
        _mailWriteDAO.setSharedConnection(nil)
        _attachmentDAO.setSharedConnection(nil)
        _outboxDAO.setSharedConnection(nil)
        _folderDAO.setSharedConnection(nil)
    }
    
    // MARK: - Performance Monitoring
    
    public func getPerformanceMetrics() -> [String: (average: TimeInterval, calls: Int)] {
        return DAOPerformanceMonitor.getMetrics()
    }
    
    public func resetPerformanceMetrics() {
        DAOPerformanceMonitor.resetMetrics()
    }
    
    // MARK: - Schema Validation Helper
    
    public func validateSchema() throws -> (userVersion: Int, foldersTableExists: Bool) {
        try _accountDAO.ensureOpen()
        let validator = DAOSchemaValidator(_accountDAO)
        let userVersion = try validator.getUserVersion()
        
        // Test table existence using the shared connection
        let foldersTableExists = try validator.validateTable(MailSchema.tFolders)
        
        // Additional table checks using SAME connection
        let accountsExist = try validator.validateTable(MailSchema.tAccounts)
        let headersExist = try validator.validateTable(MailSchema.tMsgHeader)
        
        print("🔧 Schema validation results (using shared connection):")
        print("   - Connection: \(_accountDAO.db != nil ? "Active" : "Null")")
        print("   - User Version: \(userVersion)")
        print("   - Accounts Table: \(accountsExist)")
        print("   - Folders Table: \(foldersTableExists)")  
        print("   - Headers Table: \(headersExist)")
        
        // Test if other DAOs can see the tables
        if let folderDAO = _folderDAO as? FolderDAOImpl {
            let folderDAOCanSee = try? folderDAO.ensureOpen() == () && 
                                      DAOSchemaValidator(folderDAO).validateTable(MailSchema.tFolders) == true
            print("   - FolderDAO can see folders table: \(folderDAOCanSee ?? false)")
        }
        
        return (userVersion: userVersion, foldersTableExists: foldersTableExists)
    }
    
    public func performMaintenance() throws {
        try _attachmentDAO.cleanupOrphanedFiles()
        
        // Remove old sent items (older than 30 days)
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        try _outboxDAO.removeSentItems(olderThan: thirtyDaysAgo)
        
        // Remove old failed items (older than 7 days)
        try _outboxDAO.removeFailedItems(maxAge: 7 * 24 * 60 * 60)
        
        // Perform database optimization
        try _accountDAO.exec("VACUUM")
        try _accountDAO.exec("ANALYZE")
    }
}

// MARK: - Combined DAO Implementation

private class MailFullAccessDAOImpl: MailFullAccessDAO {
    
    private let factory: DAOFactory
    
    init(factory: DAOFactory) {
        self.factory = factory
    }
    
    // MARK: - MailReadDAO Conformance
    
    func headers(accountId: UUID, folder: String, limit: Int, offset: Int) throws -> [MailHeader] {
        return try factory.mailReadDAO.headers(accountId: accountId, folder: folder, 
                                             limit: limit, offset: offset)
    }
    
    func body(accountId: UUID, folder: String, uid: String) throws -> String? {
        return try factory.mailReadDAO.body(accountId: accountId, folder: folder, uid: uid)
    }
    
    func bodyEntity(accountId: UUID, folder: String, uid: String) throws -> MessageBodyEntity? {
        return try factory.mailReadDAO.bodyEntity(accountId: accountId, folder: folder, uid: uid)
    }
    
    func attachments(accountId: UUID, folder: String, uid: String) throws -> [AttachmentEntity] {
        return try factory.mailReadDAO.attachments(accountId: accountId, folder: folder, uid: uid)
    }
    
    func specialFolders(accountId: UUID) throws -> [String: String]? {
        return try factory.mailReadDAO.specialFolders(accountId: accountId)
    }
    
    func saveSpecialFolders(accountId: UUID, map: [String: String]) throws {
        try factory.mailReadDAO.saveSpecialFolders(accountId: accountId, map: map)
    }
    
    func getLastSyncUID(accountId: UUID, folder: String) throws -> String? {
        return try factory.mailReadDAO.getLastSyncUID(accountId: accountId, folder: folder)
    }
    
    // MARK: - MailWriteDAO Conformance
    
    func insertHeaders(accountId: UUID, folder: String, headers: [MailHeader]) throws {
        try factory.mailWriteDAO.insertHeaders(accountId: accountId, folder: folder, headers: headers)
    }
    
    func upsertHeaders(accountId: UUID, folder: String, headers: [MailHeader]) throws {
        try factory.mailWriteDAO.upsertHeaders(accountId: accountId, folder: folder, headers: headers)
    }
    
    func storeBody(accountId: UUID, folder: String, uid: String, body: MessageBodyEntity) throws {
        try factory.mailWriteDAO.storeBody(accountId: accountId, folder: folder, uid: uid, body: body)
    }
    
    func storeAttachment(accountId: UUID, folder: String, uid: String, attachment: AttachmentEntity) throws {
        try factory.mailWriteDAO.storeAttachment(accountId: accountId, folder: folder, 
                                                uid: uid, attachment: attachment)
    }
    
    func updateLastSyncUID(accountId: UUID, folder: String, uid: String) throws {
        try factory.mailWriteDAO.updateLastSyncUID(accountId: accountId, folder: folder, uid: uid)
    }
    
    func deleteMessage(accountId: UUID, folder: String, uid: String) throws {
        try factory.mailWriteDAO.deleteMessage(accountId: accountId, folder: folder, uid: uid)
    }
    
    func purgeFolder(accountId: UUID, folder: String) throws {
        try factory.mailWriteDAO.purgeFolder(accountId: accountId, folder: folder)
    }
}

// MARK: - Schema Management

public class MailSchemaManager {
    
    public static func createTables(using dao: BaseDAO) throws {
        print("🔧 Creating database tables...")
        for (index, sql) in MailSchema.ddl_v1.enumerated() {
            do {
                print("🔧 Executing DDL \(index + 1): \(sql.prefix(50))...")
                try dao.exec(sql)
                print("✅ DDL \(index + 1) executed successfully")
            } catch {
                print("❌ DDL \(index + 1) failed: \(error)")
                throw error
            }
        }
        print("✅ All database tables created successfully")
    }
    
    public static func migrateIfNeeded(using dao: BaseDAO) throws {
        let validator = DAOSchemaValidator(dao)
        let currentVersion = try validator.getUserVersion()
        
        print("🔧 Current database version: \(currentVersion), target version: \(MailSchema.currentVersion)")
        
        if currentVersion < MailSchema.currentVersion {
            print("🔧 Migration needed: \(currentVersion) → \(MailSchema.currentVersion)")
            try performMigration(from: currentVersion, to: MailSchema.currentVersion, using: dao)
            try validator.setUserVersion(MailSchema.currentVersion)
            print("✅ Database migration completed to version \(MailSchema.currentVersion)")
        } else {
            print("✅ Database is up to date at version \(currentVersion)")
        }
        
        // Verify critical tables exist after migration
        let foldersExist = try validator.validateTable(MailSchema.tFolders)
        print("🔧 Post-migration check - Folders table exists: \(foldersExist)")
        
        if !foldersExist {
            print("⚠️ Folders table missing after migration - attempting repair")
            let folderDDL = """
                CREATE TABLE IF NOT EXISTS \(MailSchema.tFolders) (
                    account_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    special_use TEXT,
                    delimiter TEXT,
                    attributes TEXT,
                    PRIMARY KEY (account_id, name)
                );
            """
            try dao.exec(folderDDL)
            print("✅ Folders table created during repair")
        }
    }
    
    private static func performMigration(from oldVersion: Int, to newVersion: Int, 
                                       using dao: BaseDAO) throws {
        // Add migration logic as needed
        // For now, this is a placeholder for future schema changes
        if oldVersion == 1 && newVersion >= 2 {
            try migrateV1ToV2(using: dao)
        }
    }
    
    private static func migrateV1ToV2(using dao: BaseDAO) throws {
        // Add new columns for enhanced features
        let migrations = [
            "ALTER TABLE \(MailSchema.tMsgBody) ADD COLUMN content_type TEXT",
            "ALTER TABLE \(MailSchema.tMsgBody) ADD COLUMN charset TEXT",
            "ALTER TABLE \(MailSchema.tMsgBody) ADD COLUMN transfer_encoding TEXT",
            "ALTER TABLE \(MailSchema.tMsgBody) ADD COLUMN is_multipart INTEGER DEFAULT 0",
            "ALTER TABLE \(MailSchema.tMsgBody) ADD COLUMN raw_size INTEGER",
            "ALTER TABLE \(MailSchema.tMsgBody) ADD COLUMN processed_at REAL",
            
            "ALTER TABLE \(MailSchema.tAttachment) ADD COLUMN content_id TEXT",
            "ALTER TABLE \(MailSchema.tAttachment) ADD COLUMN is_inline INTEGER DEFAULT 0",
            "ALTER TABLE \(MailSchema.tAttachment) ADD COLUMN file_path TEXT",
            "ALTER TABLE \(MailSchema.tAttachment) ADD COLUMN checksum TEXT"
        ]
        
        for migration in migrations {
            try? dao.exec(migration) // Ignore errors for columns that might already exist
        }
    }
}
