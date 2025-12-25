// Database/Schema/JourneySchema.swift
// Journey Feature - SQLite Schema Definition

import Foundation

public enum JourneySchema {

    /// Schema-Version für Journey-Tabellen
    /// Separat von MailSchema verwaltet
    public static let currentVersion: Int = 1

    // MARK: - Table Names

    public static let tNodes = "journey_nodes"
    public static let tAttachments = "journey_attachments"
    public static let tContactRefs = "journey_contact_refs"
    public static let tBlobs = "journey_blobs"

    // MARK: - DDL v1

    public static let ddl_v1: [String] = [
        // Journey Nodes (Haupttabelle)
        """
        CREATE TABLE IF NOT EXISTS \(tNodes) (
            id TEXT PRIMARY KEY,
            origin_id TEXT NOT NULL,
            revision INTEGER NOT NULL DEFAULT 1,
            parent_id TEXT,
            section TEXT NOT NULL,
            node_type TEXT NOT NULL,
            title TEXT NOT NULL,
            content TEXT,
            sort_order INTEGER NOT NULL DEFAULT 0,
            tags TEXT,
            created_at REAL NOT NULL,
            modified_at REAL NOT NULL,
            doing_at REAL,
            status TEXT,
            due_date REAL,
            progress INTEGER,
            calendar_event_id TEXT,
            assigned_to TEXT,
            created_by TEXT,
            completed_at REAL,
            completed_by TEXT,
            FOREIGN KEY (parent_id) REFERENCES \(tNodes)(id) ON DELETE CASCADE
        );
        """,

        // Indizes für journey_nodes
        """
        CREATE INDEX IF NOT EXISTS idx_journey_parent ON \(tNodes)(parent_id);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_journey_section ON \(tNodes)(section);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_journey_origin ON \(tNodes)(origin_id);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_journey_created ON \(tNodes)(created_at);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_journey_modified ON \(tNodes)(modified_at);
        """,

        // Journey Attachments
        """
        CREATE TABLE IF NOT EXISTS \(tAttachments) (
            id TEXT PRIMARY KEY,
            node_id TEXT NOT NULL,
            filename TEXT NOT NULL,
            mime_type TEXT NOT NULL,
            file_size INTEGER NOT NULL,
            data_hash TEXT NOT NULL,
            created_at REAL NOT NULL,
            FOREIGN KEY (node_id) REFERENCES \(tNodes)(id) ON DELETE CASCADE
        );
        """,

        // Indizes für journey_attachments
        """
        CREATE INDEX IF NOT EXISTS idx_jattach_node ON \(tAttachments)(node_id);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_jattach_hash ON \(tAttachments)(data_hash);
        """,

        // Journey Contact References
        """
        CREATE TABLE IF NOT EXISTS \(tContactRefs) (
            id TEXT PRIMARY KEY,
            node_id TEXT NOT NULL,
            contact_id TEXT,
            display_name TEXT NOT NULL,
            email TEXT,
            phone TEXT,
            role TEXT,
            note TEXT,
            created_at REAL NOT NULL,
            FOREIGN KEY (node_id) REFERENCES \(tNodes)(id) ON DELETE CASCADE
        );
        """,

        // Indizes für journey_contact_refs
        """
        CREATE INDEX IF NOT EXISTS idx_jcontact_node ON \(tContactRefs)(node_id);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_jcontact_email ON \(tContactRefs)(email);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_jcontact_cid ON \(tContactRefs)(contact_id);
        """,

        // Journey Blobs (Deduplizierter Medien-Speicher)
        """
        CREATE TABLE IF NOT EXISTS \(tBlobs) (
            hash TEXT PRIMARY KEY,
            data BLOB NOT NULL,
            ref_count INTEGER NOT NULL DEFAULT 1
        );
        """
    ]

    // MARK: - Migration API

    public static func createStatements(for version: Int = currentVersion) -> [String] {
        switch version {
        case 1: return ddl_v1
        default: return ddl_v1
        }
    }

    public static func migrationSteps(from oldVersion: Int, to newVersion: Int = currentVersion) -> [[String]] {
        guard oldVersion < newVersion else { return [] }
        var steps: [[String]] = []
        var v = oldVersion
        while v < newVersion {
            switch v {
            case 0:
                steps.append(ddl_v1)
            // Zukünftige Migrationen hier
            default:
                steps.append([])
            }
            v += 1
        }
        return steps
    }
}
