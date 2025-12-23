// ViewportSyncManager.swift - Scope-based mail synchronization
// Only syncs mails that are currently visible in the viewport + buffer
// Reduces bandwidth, memory, and startup time significantly

import Foundation
import Combine

/// Manages viewport-based mail synchronization
/// - Tracks which UIDs are currently visible in the UI
/// - Debounces sync requests to avoid spam during scrolling
/// - Prefetches ±10 UIDs around viewport for smooth scrolling
@MainActor
public final class ViewportSyncManager: ObservableObject {

    // MARK: - Published State

    /// Currently visible UIDs in the viewport
    @Published private(set) var visibleUIDs: Set<String> = []

    /// UIDs that are currently being synced
    @Published private(set) var syncingUIDs: Set<String> = []

    /// True if a sync operation is in progress
    @Published private(set) var isSyncing: Bool = false

    // MARK: - Configuration

    /// Number of UIDs to prefetch around the viewport (±buffer)
    private let prefetchBuffer: Int = 10

    /// Debounce delay in seconds before triggering sync
    private let debounceDelay: TimeInterval = 0.3

    /// Maximum UIDs to sync in a single batch
    private let maxBatchSize: Int = 30

    // MARK: - Internal State

    /// Debounce task for sync scheduling
    private var debounceTask: Task<Void, Never>?

    /// Reference to MailRepository for sync operations
    private weak var repository: MailRepository?

    /// Current account ID for sync context
    private var currentAccountId: UUID?

    /// Current folder for sync context
    private var currentFolder: String?

    /// Set of UIDs that have already been synced (avoid redundant fetches)
    private var syncedUIDs: Set<String> = []

    /// All known UIDs in order (for calculating prefetch range)
    private var allKnownUIDs: [String] = []

    /// Cancellables for Combine subscriptions
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    public init(repository: MailRepository = .shared) {
        self.repository = repository
        print("📍 ViewportSyncManager initialized")
    }

    // MARK: - Context Setup

    /// Set the current sync context (account and folder)
    /// Call this when switching mailbox or account
    public func setContext(accountId: UUID, folder: String) {
        print("📍 ViewportSyncManager context set - Account: \(accountId.uuidString.prefix(8)), Folder: \(folder)")

        // Only reset if context actually changed
        if currentAccountId != accountId || currentFolder != folder {
            currentAccountId = accountId
            currentFolder = folder

            // Reset state for new context
            visibleUIDs.removeAll()
            syncedUIDs.removeAll()
            allKnownUIDs.removeAll()
            debounceTask?.cancel()
        }
    }

    /// Update the list of all known UIDs (from database)
    /// This is used to calculate prefetch ranges
    public func updateKnownUIDs(_ uids: [String]) {
        allKnownUIDs = uids
        print("📍 Updated known UIDs: \(uids.count) total")
    }

    // MARK: - Viewport Tracking

    /// Called when a mail row appears in the viewport (onAppear)
    public func rowAppeared(uid: String) {
        visibleUIDs.insert(uid)
        scheduleSync()
    }

    /// Called when a mail row disappears from viewport (onDisappear)
    public func rowDisappeared(uid: String) {
        visibleUIDs.remove(uid)
        // No need to schedule sync on disappear
    }

    /// Batch update for multiple rows appearing at once (initial load)
    public func rowsAppeared(uids: [String]) {
        visibleUIDs.formUnion(uids)
        scheduleSync()
    }

    /// Clear all visible UIDs (e.g., when leaving the view)
    public func clearViewport() {
        visibleUIDs.removeAll()
        debounceTask?.cancel()
    }

    // MARK: - Debounced Sync

    /// Schedule a sync operation with debounce
    private func scheduleSync() {
        // Cancel previous debounce task
        debounceTask?.cancel()

        debounceTask = Task { [weak self] in
            guard let self = self else { return }

            // Wait for debounce delay
            try? await Task.sleep(nanoseconds: UInt64(debounceDelay * 1_000_000_000))

            // Check if task was cancelled during sleep
            guard !Task.isCancelled else { return }

            // Perform the viewport sync
            await performViewportSync()
        }
    }

    /// Force an immediate sync without debounce (e.g., on pull-to-refresh)
    public func forceSync() async {
        debounceTask?.cancel()
        await performViewportSync()
    }

    // MARK: - Sync Execution

    /// Main sync logic - fetches headers for visible UIDs + prefetch buffer
    private func performViewportSync() async {
        guard let repository = repository,
              let accountId = currentAccountId,
              let folder = currentFolder else {
            print("⚠️ ViewportSyncManager: Missing context for sync")
            return
        }

        // Calculate UIDs to sync (visible + prefetch buffer)
        let uidsToSync = calculateSyncUIDs()

        // Filter out already synced UIDs
        let newUIDs = uidsToSync.filter { !syncedUIDs.contains($0) }

        guard !newUIDs.isEmpty else {
            print("📍 ViewportSync: All UIDs already synced")
            return
        }

        // Limit batch size
        let batchUIDs = Array(newUIDs.prefix(maxBatchSize))

        print("📍 ViewportSync: Syncing \(batchUIDs.count) new UIDs (visible: \(visibleUIDs.count), prefetch buffer: \(prefetchBuffer))")

        // Update state
        isSyncing = true
        syncingUIDs.formUnion(batchUIDs)

        defer {
            isSyncing = false
            syncingUIDs.subtract(batchUIDs)
        }

        // Perform the actual sync via repository
        await repository.fetchHeadersForViewport(
            accountId: accountId,
            folder: folder,
            uids: batchUIDs
        )

        // Mark as synced
        syncedUIDs.formUnion(batchUIDs)

        print("✅ ViewportSync: Completed sync for \(batchUIDs.count) UIDs")
    }

    /// Calculate which UIDs should be synced (visible + prefetch buffer)
    private func calculateSyncUIDs() -> [String] {
        guard !visibleUIDs.isEmpty, !allKnownUIDs.isEmpty else {
            return Array(visibleUIDs)
        }

        // Find the range of visible UIDs in the sorted list
        let visibleIndices = visibleUIDs.compactMap { uid in
            allKnownUIDs.firstIndex(of: uid)
        }

        guard !visibleIndices.isEmpty else {
            return Array(visibleUIDs)
        }

        let minIndex = visibleIndices.min()!
        let maxIndex = visibleIndices.max()!

        // Expand range with prefetch buffer
        let startIndex = max(0, minIndex - prefetchBuffer)
        let endIndex = min(allKnownUIDs.count - 1, maxIndex + prefetchBuffer)

        // Get UIDs in the expanded range
        let rangeUIDs = Array(allKnownUIDs[startIndex...endIndex])

        print("📍 ViewportSync range: \(startIndex)...\(endIndex) (\(rangeUIDs.count) UIDs)")

        return rangeUIDs
    }

    // MARK: - State Management

    /// Mark specific UIDs as synced (called after successful fetch)
    public func markAsSynced(uids: [String]) {
        syncedUIDs.formUnion(uids)
    }

    /// Check if a UID needs syncing
    public func needsSync(uid: String) -> Bool {
        return !syncedUIDs.contains(uid)
    }

    /// Reset synced state (e.g., on pull-to-refresh)
    public func resetSyncedState() {
        syncedUIDs.removeAll()
        print("📍 ViewportSyncManager: Synced state reset")
    }

    /// Get sync statistics for debugging
    public var syncStats: (visible: Int, synced: Int, known: Int) {
        return (visibleUIDs.count, syncedUIDs.count, allKnownUIDs.count)
    }
}

// MARK: - MailRepository Extension for Viewport Sync

extension MailRepository {

    /// Fetch headers only for specific UIDs (viewport-based sync)
    /// This is optimized to only fetch what's needed for the current view
    public func fetchHeadersForViewport(
        accountId: UUID,
        folder: String,
        uids: [String]
    ) async {
        guard !uids.isEmpty else { return }

        print("🔍 ViewportSync: Checking \(uids.count) UIDs for folder: \(folder)")

        // 1. Check which UIDs are already in cache
        let cachedUIDs: Set<String>
        do {
            let headers = try dao?.headers(accountId: accountId, folder: folder, limit: 5000, offset: 0) ?? []
            cachedUIDs = Set(headers.map { $0.id })
        } catch {
            print("❌ Failed to check cached UIDs: \(error)")
            cachedUIDs = []
        }

        let missingUIDs = uids.filter { !cachedUIDs.contains($0) }

        guard !missingUIDs.isEmpty else {
            print("✅ ViewportSync: All \(uids.count) UIDs already cached")
            return
        }

        print("🔍 ViewportSync: Need to fetch \(missingUIDs.count) missing UIDs")

        // 2. Load account config
        let account: MailAccountConfig
        do {
            account = try loadAccountConfigPublic(accountId: accountId)
        } catch {
            print("❌ ViewportSync: Failed to load account config: \(error)")
            return
        }

        // 3. Fetch headers for missing UIDs via IMAP
        // Note: This uses the existing transport layer which fetches by limit
        // A true UID-based fetch would require extending MailSendReceive
        let transport = MailSendReceive()

        // For now, fetch a small batch that should include the missing UIDs
        let fetchLimit = min(missingUIDs.count + 10, 50)

        let result = await transport.fetchHeaders(
            limit: fetchLimit,
            folder: folder,
            using: account,
            preferCache: false,
            force: true
        )

        switch result {
        case .success(let headers):
            print("✅ ViewportSync: Fetched \(headers.count) headers")

            // Convert and save to database
            let domainHeaders = headers.map { transportHeader in
                MailHeader(
                    id: transportHeader.id,
                    from: transportHeader.from,
                    subject: transportHeader.subject,
                    date: transportHeader.date,
                    flags: transportHeader.unread ? [] : ["\\Seen"]
                )
            }

            if let writeDAO = self.writeDAO {
                try? writeDAO.upsertHeaders(accountId: accountId, folder: folder, headers: domainHeaders)
                print("✅ ViewportSync: Saved \(domainHeaders.count) headers to database")
            }

        case .failure(let error):
            print("❌ ViewportSync: Failed to fetch headers: \(error)")
        }
    }

    /// Public wrapper for loadAccountConfig
    fileprivate func loadAccountConfigPublic(accountId: UUID) throws -> MailAccountConfig {
        let key = "mail.accounts"
        guard let data = UserDefaults.standard.data(forKey: key),
              let accounts = try? JSONDecoder().decode([MailAccountConfig].self, from: data) else {
            throw RepositoryError.accountNotFound
        }

        guard let account = accounts.first(where: { $0.id == accountId }) else {
            throw RepositoryError.accountNotFound
        }

        return account
    }
}
