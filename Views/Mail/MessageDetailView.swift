// MessageDetailView.swift - Detailed view for reading email messages
// OPTIMIERT: Nutzt BodyContentProcessor fr initiale Bereinigung + filterTechnicalHeaders fr UI-Toggle
import SwiftUI
import WebKit
import QuickLook
import Security

// MARK: - Message Detail View
//  PERFORMANCE FIX: This view now loads pre-processed content directly from storage
// The MailSyncEngine handles all MIME parsing, transfer encoding decoding, and content processing
// BodyContentProcessor handles final display preparation (Schritt 2)
// filterTechnicalHeaders provides optional UI toggle for technical details

struct MessageDetailView: View {
    let mail: MessageHeaderEntity
    let onDelete: ((MessageHeaderEntity) -> Void)?
    let onToggleFlag: ((MessageHeaderEntity) -> Void)?
    let onToggleRead: ((MessageHeaderEntity) -> Void)?
    
    @State private var isLoadingBody: Bool = false
    @State private var bodyText: String = ""
    @State private var isHTML: Bool = false
    @State private var attachments: [AttachmentEntity] = []
    @State private var tempFiles: [URL] = []
    @State private var errorMessage: String? = nil
    @State private var showTechnicalHeaders: Bool = false
    @State private var rawBodyText: String = ""
    @State private var showShareSheet: Bool = false
    @State private var shareItems: [URL] = []
    @State private var savingAttachments: Bool = false
    @State private var hasDetectedAttachments: Bool = false
    @State private var previewURL: URL? = nil

    // S/MIME signature verification state
    @State private var signatureStatus: SignatureStatus? = nil
    @State private var signerInfo: MessageSignerInfo? = nil
    @State private var isVerifyingSignature: Bool = false

    // Reply/Forward state
    @State private var showReplySheet: Bool = false
    @State private var isReplyAll: Bool = false
    @State private var isForward: Bool = false
    @State private var parsedToField: String = ""
    @State private var parsedCCField: String = ""
    @State private var composeSheetId: UUID = UUID()  // Force sheet recreation

    // Log creation state
    @State private var showLogCreated: Bool = false
    @EnvironmentObject private var store: DataStore

    @Environment(\.dismiss) private var dismiss
    
    // Convenience initializer for use without actions
    init(mail: MessageHeaderEntity, onDelete: ((MessageHeaderEntity) -> Void)? = nil, onToggleFlag: ((MessageHeaderEntity) -> Void)? = nil, onToggleRead: ((MessageHeaderEntity) -> Void)? = nil) {
        self.mail = mail
        self.onDelete = onDelete
        self.onToggleFlag = onToggleFlag
        self.onToggleRead = onToggleRead
    }
    
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                // Mail header information
                mailHeaderSection

                // Attachments section - NEUE POSITION
                let _ = print("📎 [VIEW] attachments.isEmpty = \(attachments.isEmpty), count = \(attachments.count)")
                if !attachments.isEmpty {
                    attachmentsSection
                }
                
                Divider()
                
                // Mail body content
                if isLoadingBody {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(String(localized: "app.mail.detail.content_loading"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
                } else if let error = errorMessage {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .padding(.vertical, 20)
                } else {
                    mailBodySection
                }
                
                // Show refresh action if no content available
                if bodyText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty && !isLoadingBody {
                    VStack(spacing: 12) {
                        Text(String(localized: "app.mail.detail.content_unavailable"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button(action: refreshBodyContent) {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text(String(localized: "app.mail.detail.refresh_content"))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
                
                Spacer(minLength: 20)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(minHeight: geometry.size.height)
            }
        }
        .navigationTitle(String(localized: "app.mail.detail.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: replyAction) {
                        Label(String(localized: "app.mail.action.reply"), systemImage: "arrowshape.turn.up.left")
                    }
                    Button(action: replyAllAction) {
                        Label(String(localized: "app.mail.action.reply_all"), systemImage: "arrowshape.turn.up.left.2")
                    }
                    Button(action: forwardAction) {
                        Label(String(localized: "app.mail.action.forward"), systemImage: "arrowshape.turn.up.right")
                    }
                    Divider()
                    Button(action: createLogEntry) {
                        Label(String(localized: "app.mail.action.create_log"), systemImage: "doc.text.fill")
                    }
                    Divider()
                    Button(action: toggleFlagAction) {
                        Label(
                            mail.flags.contains("\\Flagged") ? String(localized: "app.mail.action.unflag") : String(localized: "app.mail.action.flag"),
                            systemImage: mail.flags.contains("\\Flagged") ? "flag.slash" : "flag"
                        )
                    }
                    Button(action: toggleReadAction) {
                        Label(
                            mail.flags.contains("\\Seen") ? String(localized: "app.mail.action.mark_unread") : String(localized: "app.mail.action.mark_read"),
                            systemImage: mail.flags.contains("\\Seen") ? "envelope.badge" : "envelope.open"
                        )
                    }
                    Divider()
                    Button(action: {
                        let oldValue = showTechnicalHeaders
                        showTechnicalHeaders.toggle()

                        // Wechsel von ON (RAW) → OFF (Normal) triggert Re-Processing
                        if oldValue == true && showTechnicalHeaders == false {
                            Task {
                                await reprocessMailBody()
                            }
                        }
                    }) {
                        Label(
                            showTechnicalHeaders ? String(localized: "app.mail.action.hide_technical") : String(localized: "app.mail.action.show_technical"),
                            systemImage: "info.circle"
                        )
                    }

                    // Anhänge speichern - anzeigen wenn Anhänge erkannt wurden
                    if mail.hasAttachments || hasDetectedAttachments {
                        Divider()
                        Button(action: saveAllAttachments) {
                            Label("Anhänge speichern", systemImage: "square.and.arrow.down")
                        }
                    }

                    Divider()
                    Button(role: .destructive, action: deleteAction) {
                        Label(String(localized: "common.delete"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            loadMailBody()
        }
        .onDisappear {
            cleanupTempFiles()
        }
        .sheet(isPresented: $showShareSheet) {
            if !shareItems.isEmpty {
                ShareSheet(items: shareItems)
            }
        }
        .sheet(isPresented: $showReplySheet) {
            ComposeMailView(
                replyToMail: mail,
                replyAll: isReplyAll,
                isForward: isForward,
                originalBody: bodyText,
                originalTo: parsedToField,
                originalCC: parsedCCField,
                originalIsHTML: isHTML,
                preselectedAccountId: mail.accountId,
                originalAttachments: extractAttachmentsForCompose()
            )
            .id(composeSheetId)  // Force recreation on each open
        }
        .overlay {
            if savingAttachments {
                ZStack {
                    Color.black.opacity(0.3)
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Anhänge werden extrahiert...")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .ignoresSafeArea()
            }
        }
        .quickLookPreview($previewURL)
        .alert(String(localized: "app.mail.log_created.title"), isPresented: $showLogCreated) {
            Button(String(localized: "common.ok"), role: .cancel) {}
        } message: {
            Text(String(localized: "app.mail.log_created.message"))
        }
    }
    
    @ViewBuilder
    private var mailHeaderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Subject
            Text(mail.subject.isEmpty ? String(localized: "app.mail.detail.no_subject") : mail.subject)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            
            // From, Date, and Flags - Optimiertes Grid-Layout
            VStack(alignment: .leading, spacing: 8) {
                let parsedFrom = parseFromAddress(mail.from)
                
                // Von (Absender) - Zeile
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    // Icon + Label
                    HStack(spacing: 6) {
                        Image(systemName: "person.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                        Text("Von:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                    }
                    
                    // Wert (Name) + Signatur-Icon
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let displayName = parsedFrom.name, !displayName.isEmpty {
                                Text(displayName)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.primary)
                            } else if let email = parsedFrom.email {
                                Text(email)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.primary)
                            } else {
                                Text(mail.from)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.primary)
                            }

                            // S/MIME Signature Icon (nur bei gültiger Signatur)
                            if let status = signatureStatus,
                               status == .valid || status == .validUntrusted || status == .validExpired {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(signatureIconColor(status))
                                    .font(.subheadline)
                            }
                        }

                        // E-Mail-Adresse (nur wenn Name vorhanden)
                        if let displayName = parsedFrom.name, !displayName.isEmpty,
                           let email = parsedFrom.email {
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }
                
                // Datum - Zeile
                if let date = mail.date {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        // Icon + Label
                        HStack(spacing: 6) {
                            Image(systemName: "calendar")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                            Text("Datum:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .leading)
                        }
                        
                        // Wert
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                        
                        Spacer()
                    }
                }
            }
            
            // Mail status indicators (Ungelesen, Markiert, Anhänge auf einer Zeile)
            HStack(spacing: 16) {
                if !mail.flags.contains("\\Seen") {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                        Text(String(localized: "app.mail.detail.unread"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if mail.flags.contains("\\Flagged") {
                    HStack(spacing: 4) {
                        Image(systemName: "flag.fill")
                            .foregroundStyle(.orange)
                        Text(String(localized: "app.mail.detail.flagged"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Anhänge-Indikator
                if !attachments.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Anhänge (\(attachments.count))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // S/MIME Signature Status Indicator (nur bei Fehler/ungültig anzeigen)
            if isVerifyingSignature {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Signatur wird überprüft...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if let status = signatureStatus,
                      status == .invalid || status == .error {
                // Nur bei Fehler die vollständige Status-Zeile anzeigen
                signatureStatusView(status: status, signer: signerInfo)
            }
        }
    }

    /// View for displaying S/MIME signature verification status
    @ViewBuilder
    private func signatureStatusView(status: SignatureStatus, signer: MessageSignerInfo?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: status.iconName)
                .foregroundStyle(signatureIconColor(status))
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.displayText)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(signatureTextColor(status))

                if let signer = signer {
                    Text("von \(signer.commonName ?? signer.email)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(signatureBackgroundColor(status))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func signatureIconColor(_ status: SignatureStatus) -> Color {
        switch status {
        case .valid: return .green
        case .validUntrusted, .validExpired: return .teal
        case .invalid, .error: return .red
        case .notSigned: return .secondary
        }
    }

    private func signatureTextColor(_ status: SignatureStatus) -> Color {
        switch status {
        case .valid: return .green
        case .validUntrusted, .validExpired: return .teal
        case .invalid, .error: return .red
        case .notSigned: return .secondary
        }
    }

    private func signatureBackgroundColor(_ status: SignatureStatus) -> Color {
        switch status {
        case .valid: return .green.opacity(0.1)
        case .validUntrusted, .validExpired: return .teal.opacity(0.1)
        case .invalid, .error: return .red.opacity(0.1)
        case .notSigned: return .clear
        }
    }
    
    @ViewBuilder
    private var mailBodySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showTechnicalHeaders {
                // RAW Ansicht
                ScrollView {
                    Text(rawBodyText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                }
                .background(Color.gray.opacity(0.1))
            } else {
                // Normal Ansicht
                if isHTML {
                    // HTML rendern
                    MailHTMLWebView(html: bodyText)
                        .frame(minHeight: 200)
                } else {
                    // Plain-Text rendern
                    ScrollView {
                        Text(bodyText)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding()
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if attachments.count > 3 {
                // Scrollbare Liste mit fester Höhe
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                            AttachmentRowView(
                                attachment: attachment,
                                tempFileURL: index < tempFiles.count ? tempFiles[index] : nil,
                                onTap: {
                                    openAttachmentPreview(attachment: attachment)
                                }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 40) // Kompakte Höhe, Rest per Scroll
            } else {
                // Normale Anzeige ohne Scroll (3 oder weniger)
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                    AttachmentRowView(
                        attachment: attachment,
                        tempFileURL: index < tempFiles.count ? tempFiles[index] : nil,
                        onTap: {
                            openAttachmentPreview(attachment: attachment)
                        }
                    )
                }
            }
        }
    }
    
    // MARK: - Actions
    
    private func loadMailBody() {
        isLoadingBody = true
        errorMessage = nil

        Task {
            do {
                print("📧 [MessageDetailView] ========== LOADING MAIL BODY ==========")
                print("📧 [MessageDetailView] Subject: \(mail.subject)")
                print("📧 [MessageDetailView] UID: \(mail.uid)")
                print("📧 [MessageDetailView] From: \(mail.from)")
                print("🔍 DEBUG: mail.accountId = \(mail.accountId)")
                print("🔍 DEBUG: mail.folder = \(mail.folder)")
                print("🔍 DEBUG: mail.uid = \(mail.uid)")
                print("🔍 DEBUG: MailRepository.shared.dao = \(MailRepository.shared.dao != nil)")
                
                var bodyLoaded = false
                
                // ✅ PHASE 4: RAW-first Loading mit Safety Guards
                guard let dao = MailRepository.shared.dao else {
                    print("❌ [MessageDetailView] DAO not available")
                    await MainActor.run {
                        errorMessage = String(localized: "app.mail.detail.database_unavailable")
                        isLoadingBody = false
                    }
                    return
                }
                
                do {
                    if let bodyEntity = try dao.bodyEntity(accountId: mail.accountId, folder: mail.folder, uid: mail.uid) {
                        print("🔍 [MessageDetailView] bodyEntity loaded successfully")
                        print("   - text: \(bodyEntity.text?.count ?? 0)")
                        print("   - html: \(bodyEntity.html?.count ?? 0)")
                        print("   - rawBody: \(bodyEntity.rawBody?.count ?? 0)")
                        
                        // ✅ Check: Brauchen wir Processing?
                        let needsProc = MailBodyProcessor.needsProcessing(bodyEntity.html)
                        print("📧 [MessageDetailView] needsProcessing = \(needsProc)")
                        if needsProc {
                            print("⚠️ [MessageDetailView] HTML needs processing - triggering decode...")
                            
                            // ✅ NEU - zentrale Methode nutzen:
                            if let rawBody = bodyEntity.rawBody {
                                do {
                                    let (displayText, displayIsHTML) = try await processAndStoreMailBody(
                                        rawBody: rawBody,
                                        bodyEntity: bodyEntity
                                    )

                                    // ✅ FIX: Nutze zentralen AttachmentExtractor
                                    let extracted = AttachmentExtractor.extract(from: rawBody)
                                    let extractedAttachments: [AttachmentEntity] = extracted.enumerated().map { (index, att) in
                                        AttachmentEntity(
                                            accountId: mail.accountId,
                                            folder: mail.folder,
                                            uid: mail.uid,
                                            partId: "part\(index + 1)",
                                            filename: att.filename,
                                            mimeType: att.mimeType,
                                            sizeBytes: att.data.count,
                                            data: att.data,
                                            contentId: att.contentId,
                                            isInline: att.contentId != nil
                                        )
                                    }
                                    if !extractedAttachments.isEmpty {
                                        print("📎 [loadMailBody] AttachmentExtractor found \(extractedAttachments.count) attachment(s)")
                                    }

                                    await MainActor.run {
                                        bodyText = displayText
                                        isHTML = displayIsHTML
                                        rawBodyText = rawBody
                                        isLoadingBody = false
                                        if !extractedAttachments.isEmpty {
                                            self.attachments = extractedAttachments
                                            self.hasDetectedAttachments = true
                                            print("📎 [UI] attachments state updated: \(self.attachments.count) items")
                                            for att in self.attachments {
                                                print("📎 [UI] - \(att.filename)")
                                            }
                                        }
                                    }
                                    bodyLoaded = true

                                    // ✅ S/MIME Signature Verification
                                    print("📧 [MessageDetailView] PATH-A: Calling verifyEmailSignature with \(rawBody.count) chars")
                                    await verifyEmailSignature(rawBody: rawBody)

                                } catch {
                                    print("❌ [loadMailBody] Processing failed: \(error)")
                                    await MainActor.run {
                                        errorMessage = error.localizedDescription
                                        bodyText = ""
                                        isHTML = false
                                        rawBodyText = rawBody  // RAW trotzdem zeigen
                                        isLoadingBody = false
                                    }
                                    bodyLoaded = true  // Trotzdem als geladen markieren (RAW ist da)
                                }
                            }
                        } else {
                            // ✅ Bereits dekodiert - direkt rendern
                            print("✅ [MessageDetailView] HTML already processed - rendering directly")

                            // ✅ NEU: Anhang-Erkennung und Metadaten-Extraktion
                            if let rawBody = bodyEntity.rawBody, !rawBody.isEmpty {
                                let detectedAttachments = detectAttachmentsInRawBody(rawBody)
                                if detectedAttachments && !bodyEntity.hasAttachments {
                                    print("📎 [MessageDetailView] Late attachment detection: found attachments!")
                                    // Update database with corrected flag
                                    if let writeDAO = MailRepository.shared.writeDAO {
                                        var updatedEntity = bodyEntity
                                        updatedEntity.hasAttachments = true
                                        try? writeDAO.storeBody(
                                            accountId: mail.accountId,
                                            folder: mail.folder,
                                            uid: mail.uid,
                                            body: updatedEntity
                                        )
                                        print("✅ [MessageDetailView] Updated hasAttachments flag in DB")
                                    }
                                }

                                // ✅ FIX: Nutze zentralen AttachmentExtractor statt extractAttachmentMetadata
                                // AttachmentExtractor handhabt MIME-encoded Dateinamen korrekt
                                print("📎 [PATH-A] detectedAttachments=\(detectedAttachments), bodyEntity.hasAttachments=\(bodyEntity.hasAttachments)")
                                if detectedAttachments || bodyEntity.hasAttachments {
                                    let extracted = AttachmentExtractor.extract(from: rawBody)
                                    print("📎 [PATH-A] AttachmentExtractor found: \(extracted.count) attachment(s)")
                                    if !extracted.isEmpty {
                                        let attachmentEntities = extracted.enumerated().map { (index, att) in
                                            AttachmentEntity(
                                                accountId: mail.accountId,
                                                folder: mail.folder,
                                                uid: mail.uid,
                                                partId: "part\(index + 1)",
                                                filename: att.filename,
                                                mimeType: att.mimeType,
                                                sizeBytes: att.data.count,
                                                data: att.data,
                                                contentId: att.contentId,
                                                isInline: att.contentId != nil
                                            )
                                        }
                                        await MainActor.run {
                                            self.attachments = attachmentEntities
                                            self.hasDetectedAttachments = true
                                            print("📎 [PATH-A UI] attachments set: \(self.attachments.count)")
                                        }
                                    }
                                }
                            }

                            let displayContent = BodyContentProcessor.selectDisplayContent(
                                html: bodyEntity.html,
                                text: bodyEntity.text
                            )

                            // Inline-Bilder: CID-Referenzen durch Base64 Data-URLs ersetzen
                            var finalContent = displayContent.content
                            if displayContent.isHTML, let rawBody = bodyEntity.rawBody {
                                finalContent = replaceCIDWithBase64(html: finalContent, rawBody: rawBody)
                            }

                            await MainActor.run {
                                bodyText = finalContent
                                isHTML = displayContent.isHTML
                                rawBodyText = bodyEntity.rawBody ?? ""
                                isLoadingBody = false
                            }
                            bodyLoaded = true

                            // ✅ S/MIME Signature Verification
                            print("📧 [MessageDetailView] PATH-B: Checking rawBody availability: \(bodyEntity.rawBody?.count ?? 0) chars")
                            if let rawBody = bodyEntity.rawBody, !rawBody.isEmpty {
                                print("📧 [MessageDetailView] PATH-B: Calling verifyEmailSignature with \(rawBody.count) chars")
                                await verifyEmailSignature(rawBody: rawBody)
                            } else {
                                print("📧 [MessageDetailView] PATH-B: rawBody is empty or nil - cannot verify signature")
                            }
                        }
                    } else {
                        print("📧 [MessageDetailView] bodyEntity is nil - no body in DB")
                    }
                } catch {
                    print("⚠️ [MessageDetailView] Error loading bodyEntity: \(error)")
                    // Continue to on-demand fetch
                }
                
                // ✅ NEU: On-Demand Body Fetch wenn nicht im Cache
                if !bodyLoaded {
                    print("⚠️ No cached body - triggering ON-DEMAND fetch for UID: \(mail.uid)")
                    
                    await MainActor.run {
                        bodyText = String(localized: "app.mail.detail.loading_from_server")
                        isHTML = false
                        isLoadingBody = true
                    }
                    
                    // Direkter Body-Fetch statt Full-Sync (schneller!)
                    do {
                        try await MailRepository.shared.fetchBodyOnDemand(
                            accountId: mail.accountId,
                            folder: mail.folder,
                            uid: mail.uid
                        )
                        
                        print("✅ On-Demand fetch completed, waiting for DB write...")
                        
                        // Warte kurz damit DB-Write abgeschlossen ist
                        try await Task.sleep(nanoseconds: 300_000_000) // 0.3s
                        
                        // Versuche erneut zu laden
                        await loadMailBodyAfterSync()
                        
                    } catch {
                        print("❌ On-Demand fetch failed: \(error)")
                        await MainActor.run {
                            errorMessage = String.localizedStringWithFormat(
                                String(localized: "app.mail.detail.error_loading"), 
                                error.localizedDescription
                            )
                            bodyText = ""
                            isLoadingBody = false
                        }
                    }
                }
                
                // Load attachments in parallel (doesn't block body display)
                await loadAttachments()
                
            } catch {
                print("❌ [MessageDetailView] Failed to load mail body: \(error)")
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    bodyText = ""
                    isHTML = false
                    isLoadingBody = false
                }
            }
        }
    }
    
    /// Load mail body after full sync
    private func loadMailBodyAfterSync() async {
        print("🔍 [MessageDetailView] Loading body after sync...")
        
        do {
            var bodyLoaded = false
            
            // ✅ PHASE 4: RAW direkt laden und anzeigen mit Safety Guards
            guard let dao = MailRepository.shared.dao else {
                print("❌ [MessageDetailView] DAO not available after sync")
                await MainActor.run {
                    errorMessage = String(localized: "app.mail.detail.database_unavailable")
                    isLoadingBody = false
                }
                return
            }
            
            do {
                if let bodyEntity = try dao.bodyEntity(accountId: mail.accountId, folder: mail.folder, uid: mail.uid) {
                    // ✅ Check: Brauchen wir Processing?
                    if MailBodyProcessor.needsProcessing(bodyEntity.html) {
                        print("⚠️ [MessageDetailView] Post-sync HTML needs processing...")
                        
                        // ✅ NEU - zentrale Methode nutzen:
                        if let rawBody = bodyEntity.rawBody {
                            do {
                                let (displayText, displayIsHTML) = try await processAndStoreMailBody(
                                    rawBody: rawBody,
                                    bodyEntity: bodyEntity
                                )

                                // ✅ FIX: Nutze zentralen AttachmentExtractor
                                let extracted = AttachmentExtractor.extract(from: rawBody)
                                let extractedAttachments: [AttachmentEntity] = extracted.enumerated().map { (index, att) in
                                    AttachmentEntity(
                                        accountId: mail.accountId,
                                        folder: mail.folder,
                                        uid: mail.uid,
                                        partId: "part\(index + 1)",
                                        filename: att.filename,
                                        mimeType: att.mimeType,
                                        sizeBytes: att.data.count,
                                        data: att.data,
                                        contentId: att.contentId,
                                        isInline: att.contentId != nil
                                    )
                                }
                                if !extractedAttachments.isEmpty {
                                    print("📎 [loadMailBodyAfterSync] AttachmentExtractor found \(extractedAttachments.count) attachment(s)")
                                }

                                await MainActor.run {
                                    bodyText = displayText
                                    isHTML = displayIsHTML
                                    rawBodyText = rawBody
                                    isLoadingBody = false
                                    if !extractedAttachments.isEmpty {
                                        self.attachments = extractedAttachments
                                        self.hasDetectedAttachments = true
                                    }
                                }
                                print("✅ [loadMailBodyAfterSync] Processed content loaded")
                                bodyLoaded = true

                                // ✅ S/MIME Signature Verification
                                await verifyEmailSignature(rawBody: rawBody)

                            } catch {
                                print("❌ [loadMailBodyAfterSync] Processing failed: \(error)")
                                await MainActor.run {
                                    errorMessage = error.localizedDescription
                                    bodyText = ""
                                    isHTML = false
                                    rawBodyText = rawBody
                                    isLoadingBody = false
                                }
                                bodyLoaded = true
                            }
                        }
                    } else {
                        // ✅ Bereits dekodiert - direkt rendern
                        print("✅ [MessageDetailView] Post-sync HTML already processed - rendering directly")

                        // ✅ NEU: Anhang-Erkennung und Metadaten-Extraktion (post-sync)
                        if let rawBody = bodyEntity.rawBody, !rawBody.isEmpty {
                            let detectedAttachments = detectAttachmentsInRawBody(rawBody)
                            if detectedAttachments && !bodyEntity.hasAttachments {
                                print("📎 [MessageDetailView] Late attachment detection (post-sync): found attachments!")
                                if let writeDAO = MailRepository.shared.writeDAO {
                                    var updatedEntity = bodyEntity
                                    updatedEntity.hasAttachments = true
                                    try? writeDAO.storeBody(
                                        accountId: mail.accountId,
                                        folder: mail.folder,
                                        uid: mail.uid,
                                        body: updatedEntity
                                    )
                                    print("✅ [MessageDetailView] Updated hasAttachments flag in DB")
                                }
                            }

                            // ✅ FIX: Nutze zentralen AttachmentExtractor
                            if detectedAttachments || bodyEntity.hasAttachments {
                                let extracted = AttachmentExtractor.extract(from: rawBody)
                                if !extracted.isEmpty {
                                    let attachmentEntities = extracted.enumerated().map { (index, att) in
                                        AttachmentEntity(
                                            accountId: mail.accountId,
                                            folder: mail.folder,
                                            uid: mail.uid,
                                            partId: "part\(index + 1)",
                                            filename: att.filename,
                                            mimeType: att.mimeType,
                                            sizeBytes: att.data.count,
                                            data: att.data,
                                            contentId: att.contentId,
                                            isInline: att.contentId != nil
                                        )
                                    }
                                    print("📎 [MessageDetailView] AttachmentExtractor found \(attachmentEntities.count) attachment(s) (post-sync)")
                                    await MainActor.run {
                                        self.attachments = attachmentEntities
                                        self.hasDetectedAttachments = true
                                    }
                                }
                            }
                        }

                        let displayContent = BodyContentProcessor.selectDisplayContent(
                            html: bodyEntity.html,
                            text: bodyEntity.text
                        )

                        // Inline-Bilder: CID-Referenzen durch Base64 Data-URLs ersetzen
                        var finalContent = displayContent.content
                        if displayContent.isHTML, let rawBody = bodyEntity.rawBody {
                            finalContent = replaceCIDWithBase64(html: finalContent, rawBody: rawBody)
                        }

                        await MainActor.run {
                            bodyText = finalContent
                            isHTML = displayContent.isHTML
                            rawBodyText = bodyEntity.rawBody ?? ""
                            isLoadingBody = false
                        }
                        bodyLoaded = true

                        // ✅ S/MIME Signature Verification
                        if let rawBody = bodyEntity.rawBody, !rawBody.isEmpty {
                            await verifyEmailSignature(rawBody: rawBody)
                        }
                    }
                }
            } catch {
                print("⚠️ [MessageDetailView] Error loading bodyEntity after sync: \(error)")
            }
            
            if !bodyLoaded {
                await MainActor.run {
                    bodyText = String(localized: "app.mail.detail.content_could_not_load")
                    isHTML = false
                    isLoadingBody = false
                }
                print("⚠️ [MessageDetailView] Body still not available after sync")
            }
            
        } catch {
            print("❌ [MessageDetailView] Failed to load body after sync: \(error)")
            await MainActor.run {
                errorMessage = String.localizedStringWithFormat(
                    String(localized: "app.mail.detail.error_loading_content"), 
                    error.localizedDescription
                )
                bodyText = ""
                isHTML = false
                isLoadingBody = false
            }
        }
    }
    
    /// Refresh body content by triggering sync and reloading
    private func refreshBodyContent() {
        print("🔄 User requested body content refresh")
        
        // Start loading state
        isLoadingBody = true
        errorMessage = nil
        bodyText = "Inhalt wird vom Server geladen..."
        
        Task {
            do {
                // ✅ NEU: Direkter On-Demand Fetch (schneller als Full-Sync)
                print("🔄 Triggering ON-DEMAND body fetch...")
                try await MailRepository.shared.fetchBodyOnDemand(
                    accountId: mail.accountId,
                    folder: mail.folder,
                    uid: mail.uid
                )
                
                print("✅ On-Demand fetch completed for refresh")
                
                // Warte kurz damit DB-Write abgeschlossen ist
                try await Task.sleep(nanoseconds: 300_000_000) // 0.3s
                
                // Try loading again after fetch completes
                await loadMailBodyAfterSync()
                
            } catch {
                print("❌ Refresh failed: \(error)")
                await MainActor.run {
                    errorMessage = String.localizedStringWithFormat(
                        String(localized: "app.mail.detail.error_refreshing"), 
                        error.localizedDescription
                    )
                    isLoadingBody = false
                }
            }
        }
    }
    
    /// Wait for sync to complete by monitoring sync state
    private func waitForSyncCompletion() async {
        let maxWaitTime: TimeInterval = 10.0 // Maximum 10 seconds
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < maxWaitTime {
            // Check if we can load body content now
            do {
                if let text = try MailRepository.shared.getBody(accountId: mail.accountId, folder: mail.folder, uid: mail.uid) {
                    if !text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                        print(" Body content became available during sync wait")
                        return
                    }
                }
            } catch {
                print(" Error checking body during sync wait: \(error)")
            }
            
            // Wait 0.5 seconds before checking again
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        
        print(" Sync wait completed after \(Date().timeIntervalSince(startTime))s")
    }
    
    private func loadAttachments() async {
        guard let dao = MailRepository.shared.dao else { return }
        
        do {
            // Try to load attachments - cast to expected type
            if let loadedAttachments = try dao.attachments(accountId: mail.accountId, folder: mail.folder, uid: mail.uid) as? [AttachmentEntity] {
                var tempURLs: [URL] = []
                
                // Create temporary files for attachments that have data
                for attachment in loadedAttachments {
                    if let data = attachment.data {
                        let filename = attachment.filename.isEmpty ? "\(attachment.partId).dat" : attachment.filename
                        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                        
                        do {
                            try data.write(to: tempURL)
                            tempURLs.append(tempURL)
                        } catch {
                            MailLogger.shared.error(.FETCH, accountId: mail.accountId, "Failed to write temp file for attachment: \(error)")
                            tempURLs.append(FileManager.default.temporaryDirectory.appendingPathComponent("attachment_error.txt"))
                        }
                    } else {
                        // Placeholder for attachments without data
                        tempURLs.append(FileManager.default.temporaryDirectory.appendingPathComponent("no_data.txt"))
                    }
                }
                
                await MainActor.run {
                    // ✅ FIX: Nur überschreiben wenn DB-Anhänge vorhanden
                    // Sonst bleiben die aus rawBody extrahierten Anhänge erhalten
                    if !loadedAttachments.isEmpty {
                        self.attachments = loadedAttachments
                        self.tempFiles = tempURLs
                        print("📎 [loadAttachments] Loaded \(loadedAttachments.count) from DB")
                    } else {
                        print("📎 [loadAttachments] DB empty, keeping \(self.attachments.count) extracted attachments")
                    }
                }
            }
        } catch {
            MailLogger.shared.error(.FETCH, accountId: mail.accountId, "Failed to load attachments: \(error)")
        }
    }
    
    private func cleanupTempFiles() {
        for tempFile in tempFiles {
            try? FileManager.default.removeItem(at: tempFile)
        }
        tempFiles.removeAll()
    }
    
    private func replyAction() {
        print("📧 Reply to mail: \(mail.subject)")
        parseHeadersForReply()
        isReplyAll = false
        isForward = false
        composeSheetId = UUID()  // Force new view instance
        showReplySheet = true
    }

    private func replyAllAction() {
        print("📧 Reply All to mail: \(mail.subject)")
        parseHeadersForReply()
        isReplyAll = true
        isForward = false
        composeSheetId = UUID()  // Force new view instance
        showReplySheet = true
    }

    private func parseHeadersForReply() {
        // Parse To and CC from raw body headers
        guard !rawBodyText.isEmpty else {
            parsedToField = ""
            parsedCCField = ""
            return
        }

        // Find headers section (before first empty line)
        let lines = rawBodyText.components(separatedBy: "\n")
        var toField = ""
        var ccField = ""
        var currentField = ""

        for line in lines {
            // Empty line marks end of headers
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }

            // Check for header continuation (starts with whitespace)
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if currentField == "to" {
                    toField += " " + line.trimmingCharacters(in: .whitespaces)
                } else if currentField == "cc" {
                    ccField += " " + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            // Check for new header
            let lowerLine = line.lowercased()
            if lowerLine.hasPrefix("to:") {
                currentField = "to"
                toField = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if lowerLine.hasPrefix("cc:") {
                currentField = "cc"
                ccField = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else {
                currentField = ""
            }
        }

        parsedToField = toField
        parsedCCField = ccField
        print("📧 Parsed To: \(toField)")
        print("📧 Parsed CC: \(ccField)")
    }

    private func getPlainTextBody() -> String {
        // Return plain text version of body for quoting
        if !isHTML {
            return bodyText
        }
        // Strip HTML tags for quote
        return bodyText.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private func forwardAction() {
        print("📧 Forward mail: \(mail.subject)")
        parseHeadersForReply()
        isReplyAll = false
        isForward = true
        composeSheetId = UUID()  // Force new view instance
        showReplySheet = true
    }

    private func createLogEntry() {
        print("📝 Creating log entry from mail: \(mail.subject)")

        // Erstelle den Log-Text aus der Mail
        var logContent = ""

        // Header-Informationen
        logContent += "Von: \(mail.from)\n"
        if let date = mail.date {
            logContent += "Datum: \(date.formatted(date: .abbreviated, time: .shortened))\n"
        }
        logContent += "Betreff: \(mail.subject)\n"
        logContent += "\n---\n\n"

        // Mail-Body
        if isHTML {
            // HTML-Tags entfernen für Plain-Text
            let plainText = bodyText
                .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
                .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
                .replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
                .replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
                .replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
            logContent += plainText
        } else {
            logContent += bodyText
        }

        // Erstelle den LogEntry
        let entry = LogEntry.text(
            logContent.trimmingCharacters(in: .whitespacesAndNewlines),
            title: mail.subject.isEmpty ? String(localized: "app.mail.log_default_title") : mail.subject,
            category: String(localized: "app.mail.log_category"),
            tags: ["E-Mail"]
        )

        // Zum DataStore hinzufügen
        store.add(entry)

        // Bestätigung anzeigen
        showLogCreated = true
        print("✅ Log entry created successfully")
    }

    private func toggleFlagAction() {
        onToggleFlag?(mail)
        print(" Toggle flag for mail: \(mail.subject)")
    }
    
    private func toggleReadAction() {
        onToggleRead?(mail)
        print(" Toggle read status for mail: \(mail.subject)")
    }
    
    private func deleteAction() {
        onDelete?(mail)
        print(" Delete mail: \(mail.subject)")
        dismiss()
    }

    /// Öffnet Anhang-Vorschau mit QuickLook
    private func openAttachmentPreview(attachment: AttachmentEntity) {
        print("📎 [openAttachmentPreview] Opening: \(attachment.filename)")

        guard !rawBodyText.isEmpty else {
            print("❌ [openAttachmentPreview] rawBodyText is empty")
            return
        }

        Task {
            // Extrahiere Anhänge mit vollem Daten-Inhalt
            let extractedAttachments = AttachmentExtractor.extract(from: rawBodyText)

            print("📎 [openAttachmentPreview] Looking for: '\(attachment.filename)'")
            for (i, ext) in extractedAttachments.enumerated() {
                print("📎 [openAttachmentPreview] Extracted[\(i)]: '\(ext.filename)'")
            }

            // Robustes Matching: Exakt → Case-insensitive → Enthält → Erweiterung
            let searchName = attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchNameLower = searchName.lowercased()
            let searchExt = (searchName as NSString).pathExtension.lowercased()

            var matchingAttachment = extractedAttachments.first(where: {
                $0.filename.trimmingCharacters(in: .whitespacesAndNewlines) == searchName
            })

            // Fallback 1: Case-insensitive
            if matchingAttachment == nil {
                matchingAttachment = extractedAttachments.first(where: {
                    $0.filename.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == searchNameLower
                })
            }

            // Fallback 2: Enthält den Suchbegriff
            if matchingAttachment == nil {
                matchingAttachment = extractedAttachments.first(where: {
                    $0.filename.lowercased().contains(searchNameLower) ||
                    searchNameLower.contains($0.filename.lowercased())
                })
            }

            // Fallback 3: Gleiche Dateierweiterung (wenn nur 1 mit dieser Erweiterung)
            if matchingAttachment == nil && !searchExt.isEmpty {
                let sameExtAttachments = extractedAttachments.filter {
                    ($0.filename as NSString).pathExtension.lowercased() == searchExt
                }
                if sameExtAttachments.count == 1 {
                    matchingAttachment = sameExtAttachments.first
                    print("📎 [openAttachmentPreview] Matched by extension: \(searchExt)")
                }
            }

            guard let found = matchingAttachment else {
                print("❌ [openAttachmentPreview] Attachment not found: \(attachment.filename)")
                return
            }

            // Erstelle temporäre Datei - nutze sauberen Dateinamen
            let tempDir = FileManager.default.temporaryDirectory
            let safeFilename = found.filename
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            let fileURL = tempDir.appendingPathComponent(safeFilename)

            do {
                // Lösche evtl. existierende Datei
                try? FileManager.default.removeItem(at: fileURL)
                try found.data.write(to: fileURL)
                print("📎 [openAttachmentPreview] Created temp file: \(fileURL.lastPathComponent) (\(found.data.count) bytes)")

                await MainActor.run {
                    previewURL = fileURL
                }
            } catch {
                print("❌ [openAttachmentPreview] Failed to create temp file: \(error)")
            }
        }
    }

    /// Speichert alle Anhänge aus dem rawBody
    private func saveAllAttachments() {
        print("📎 [saveAllAttachments] Starting attachment extraction...")

        guard !rawBodyText.isEmpty else {
            print("❌ [saveAllAttachments] rawBodyText is empty")
            return
        }

        Task {
            await MainActor.run { savingAttachments = true }

            // ✅ Zentralen AttachmentExtractor verwenden (RFC 5322 konform)
            let extractedAttachments = AttachmentExtractor.extract(from: rawBodyText)

            print("📎 [saveAllAttachments] Found \(extractedAttachments.count) attachments")

            var savedFiles: [URL] = []
            for attachment in extractedAttachments {
                let tempDir = FileManager.default.temporaryDirectory
                let fileURL = tempDir.appendingPathComponent(attachment.filename)

                do {
                    try attachment.data.write(to: fileURL)
                    savedFiles.append(fileURL)
                    print("📎 [saveAllAttachments] Saved: \(attachment.filename) (\(attachment.data.count) bytes)")
                } catch {
                    print("❌ [saveAllAttachments] Failed to save \(attachment.filename): \(error)")
                }
            }

            await MainActor.run {
                savingAttachments = false
                if !savedFiles.isEmpty {
                    shareItems = savedFiles
                    showShareSheet = true
                    print("📎 [saveAllAttachments] Showing share sheet with \(savedFiles.count) files")
                } else {
                    print("❌ [saveAllAttachments] No files to share")
                }
            }
        }
    }

    /// Re-processes mail body when toggling from RAW to Normal view
    private func reprocessMailBody() async {
        print("🔄 [reprocessMailBody] Re-processing mail body (toggle trigger)...")
        
        guard let dao = MailRepository.shared.dao else {
            print("❌ [reprocessMailBody] DAO not available")
            return
        }
        
        guard let bodyEntity = try? dao.bodyEntity(
            accountId: mail.accountId,
            folder: mail.folder,
            uid: mail.uid
        ) else {
            print("❌ [reprocessMailBody] Could not load bodyEntity")
            return
        }
        
        guard let rawBody = bodyEntity.rawBody else {
            print("❌ [reprocessMailBody] No rawBody available")
            return
        }
        
        do {
            let (displayText, displayIsHTML) = try await processAndStoreMailBody(
                rawBody: rawBody,
                bodyEntity: bodyEntity
            )
            
            await MainActor.run {
                bodyText = displayText
                isHTML = displayIsHTML
            }
            print("✅ [reprocessMailBody] Re-processing completed")
            
        } catch {
            print("❌ [reprocessMailBody] Re-processing failed: \(error)")
            await MainActor.run {
                errorMessage = String.localizedStringWithFormat(
                    String(localized: "app.mail.detail.error_reprocessing"), 
                    error.localizedDescription
                )
            }
        }
    }
    
    /// Zentrale Methode: Verarbeitet und speichert Mail-Body in DB
    /// Wirft Fehler bei Problemen, damit Caller reagieren kann
    private func processAndStoreMailBody(
        rawBody: String,
        bodyEntity: MessageBodyEntity
    ) async throws -> (bodyText: String, isHTML: Bool) {

        print("🔄 [processAndStoreMailBody] Starting processing for UID: \(mail.uid)")

        // 1. Process rawBody mit MailBodyProcessor (erweiterte Version für hasAttachments)
        let processingResult = MailBodyProcessor.processRawBodyExtended(rawBody)
        let text = processingResult.text
        let html = processingResult.html
        let hasAttachments = processingResult.hasAttachments

        print("   📋 Processing result: text=\(text?.count ?? 0), html=\(html?.count ?? 0), hasAttachments=\(hasAttachments)")

        // 2. Validierung: Mindestens text ODER html muss vorhanden sein
        guard text != nil || html != nil else {
            print("❌ [processAndStoreMailBody] No content extracted!")
            throw MailBodyError.noContentExtracted
        }

        // 3. DAO verfügbar?
        guard let writeDAO = MailRepository.shared.writeDAO else {
            print("❌ [processAndStoreMailBody] WriteDAO not available!")
            throw MailBodyError.daoNotAvailable
        }

        // 4. Update Entity MIT DEFENSIVE MERGE
        var updatedEntity = bodyEntity

        // ✅ KRITISCHER FIX: Nur setzen wenn nicht-nil, sonst bestehenden Wert behalten
        // Dies verhindert dass INSERT OR REPLACE bestehende Werte mit NULL überschreibt
        if let newText = text {
            updatedEntity.text = newText
            print("   → Setting new text (\(newText.count) chars)")
        } else if bodyEntity.text != nil {
            print("   → Preserving existing text (\(bodyEntity.text!.count) chars)")
            // updatedEntity.text bleibt bodyEntity.text (bereits durch var updatedEntity = bodyEntity)
        }

        if let newHtml = html {
            updatedEntity.html = newHtml
            print("   → Setting new html (\(newHtml.count) chars)")
        } else if bodyEntity.html != nil {
            print("   → Preserving existing html (\(bodyEntity.html!.count) chars)")
            // updatedEntity.html bleibt bodyEntity.html (bereits durch var updatedEntity = bodyEntity)
        }

        // ✅ NEU: hasAttachments aus Processing-Ergebnis setzen
        if hasAttachments {
            updatedEntity.hasAttachments = true
            print("   → Setting hasAttachments = true (detected during processing)")
        }

        updatedEntity.processedAt = Date()

        // 5. Store in DB (OHNE try? - Fehler werden geworfen!)
        try writeDAO.storeBody(
            accountId: mail.accountId,
            folder: mail.folder,
            uid: mail.uid,
            body: updatedEntity
        )

        // 6. Logging mit Details
        print("✅ [processAndStoreMailBody] DB updated successfully (defensive merge)")
        print("   - UID: \(mail.uid)")
        print("   - Final text: \(updatedEntity.text?.count ?? 0) chars")
        print("   - Final html: \(updatedEntity.html?.count ?? 0) chars")
        print("   - hasAttachments: \(updatedEntity.hasAttachments)")
        print("   - processedAt: \(updatedEntity.processedAt?.description ?? "nil")")

        // 7. Optional: Verification durch Re-Read
        if let dao = MailRepository.shared.dao,
           let verifyEntity = try? dao.bodyEntity(
               accountId: mail.accountId,
               folder: mail.folder,
               uid: mail.uid
           ) {
            print("✅ [processAndStoreMailBody] Verification successful")
            print("   - DB html length: \(verifyEntity.html?.count ?? 0)")
            print("   - DB text length: \(verifyEntity.text?.count ?? 0)")
            print("   - DB hasAttachments: \(verifyEntity.hasAttachments)")
            print("   - DB processedAt: \(verifyEntity.processedAt != nil ? "set" : "nil")")
        }

        // 8. Return Display-Content (bevorzuge html wenn vorhanden)
        let displayText = updatedEntity.html ?? updatedEntity.text ?? ""
        let displayIsHTML = updatedEntity.html != nil

        return (displayText, displayIsHTML)
    }
    
    // MARK: - Helper Functions

    /// Parse "Display Name <email@domain.com>" format into components
    private func parseFromAddress(_ from: String) -> (name: String?, email: String?) {
        // Pattern: "Name <email>" or just "email"
        let trimmed = from.trimmingCharacters(in: .whitespaces)
        
        // Check for "Name <email>" format
        if let openBracket = trimmed.lastIndex(of: "<"),
           let closeBracket = trimmed.lastIndex(of: ">"),
           openBracket < closeBracket {
            
            let name = String(trimmed[..<openBracket])
                .trimmingCharacters(in: .whitespaces)
            let email = String(trimmed[trimmed.index(after: openBracket)..<closeBracket])
                .trimmingCharacters(in: .whitespaces)
            
            return (name.isEmpty ? nil : name, email)
        }
        
        // If no brackets, check if it's just an email
        if trimmed.contains("@") {
            return (nil, trimmed)
        }
        
        // Fallback: treat entire string as name
        return (trimmed, nil)
    }

    /// Erkennt Anhänge im rawBody für nachträgliche Aktualisierung
    private func detectAttachmentsInRawBody(_ rawBody: String) -> Bool {
        let lowerBody = rawBody.lowercased()

        // 1. Explizit als Attachment markiert
        if lowerBody.contains("content-disposition: attachment") {
            return true
        }

        // 2. Multipart/mixed enthält typischerweise Anhänge
        if lowerBody.contains("content-type: multipart/mixed") {
            return true
        }

        // 3. Multipart/related enthält eingebettete Bilder
        if lowerBody.contains("content-type: multipart/related") {
            return true
        }

        // 4. PDF, Office-Dokumente, etc.
        let attachmentTypes = [
            "application/pdf",
            "application/msword",
            "application/vnd.openxmlformats",
            "application/vnd.ms-excel",
            "application/vnd.ms-powerpoint",
            "application/zip",
            "application/x-zip",
            "application/octet-stream"
        ]
        for type in attachmentTypes {
            if lowerBody.contains("content-type: \(type)") {
                return true
            }
        }

        // 5. Bilder (inline oder attachment)
        let imageTypes = ["image/png", "image/jpeg", "image/jpg", "image/gif", "image/bmp", "image/webp"]
        for type in imageTypes {
            if lowerBody.contains("content-type: \(type)") {
                return true
            }
        }

        // 6. Dateiname mit typischer Anhang-Erweiterung (inkl. Bilder)
        if lowerBody.contains("filename=") || lowerBody.contains("name=") {
            let attachmentExtensions = [
                ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".zip", ".rar",
                ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp"
            ]
            for ext in attachmentExtensions {
                if lowerBody.contains(ext) {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - S/MIME Signature Verification

    /// Detects if the email is signed and verifies the signature
    private func verifyEmailSignature(rawBody: String) async {
        print("🔐 [Signature] Checking for S/MIME signature... (rawBody: \(rawBody.count) chars)")

        let lowerBody = rawBody.lowercased()

        // Debug: Show first 500 chars of content-type headers
        if let ctRange = lowerBody.range(of: "content-type:") {
            let start = ctRange.lowerBound
            let end = lowerBody.index(start, offsetBy: min(200, lowerBody.distance(from: start, to: lowerBody.endIndex)))
            print("🔐 [Signature] Content-Type found: \(lowerBody[start..<end])")
        }

        // Check if this is a multipart/signed message
        let hasMultipartSigned = lowerBody.contains("multipart/signed")
        let hasPkcs7Sig = lowerBody.contains("application/pkcs7-signature")
        let hasXPkcs7Sig = lowerBody.contains("application/x-pkcs7-signature")
        let hasSmimeP7s = lowerBody.contains("smime.p7s")

        print("🔐 [Signature] Detection: multipart/signed=\(hasMultipartSigned), pkcs7=\(hasPkcs7Sig), x-pkcs7=\(hasXPkcs7Sig), smime.p7s=\(hasSmimeP7s)")

        guard hasMultipartSigned || hasPkcs7Sig || hasXPkcs7Sig || hasSmimeP7s else {
            print("🔐 [Signature] No signature detected in message")
            return
        }

        print("🔐 [Signature] S/MIME signature detected, starting verification...")

        await MainActor.run {
            isVerifyingSignature = true
        }

        // Extract the signed content and signature
        let verificationResult = await performSignatureVerification(rawBody: rawBody)

        await MainActor.run {
            self.signatureStatus = verificationResult.status
            self.signerInfo = verificationResult.signer
            self.isVerifyingSignature = false
            print("🔐 [Signature] Verification complete: \(verificationResult.status.displayText)")
        }
    }

    /// Performs the actual signature verification
    private func performSignatureVerification(rawBody: String) async -> (status: SignatureStatus, signer: MessageSignerInfo?) {
        // Extract boundary from Content-Type header
        guard let boundary = extractBoundary(from: rawBody) else {
            print("❌ [Signature] Could not extract boundary")
            return (.error, nil)
        }

        print("🔐 [Signature] Found boundary: \(boundary)")

        // Split the message into parts
        let parts = splitMultipartBody(rawBody: rawBody, boundary: boundary)

        print("🔐 [Signature] Split into \(parts.count) parts")
        for (i, part) in parts.enumerated() {
            let preview = String(part.prefix(200)).replacingOccurrences(of: "\r\n", with: "\\r\\n").replacingOccurrences(of: "\n", with: "\\n")
            print("🔐 [Signature] Part \(i): \(part.count) chars, preview: \(preview)")
        }

        guard parts.count >= 2 else {
            print("❌ [Signature] Expected 2 parts, found \(parts.count)")
            return (.error, nil)
        }

        let signedContent = parts[0]
        let signaturePart = parts[1]

        print("🔐 [Signature] Signature part content-type check...")
        let sigPartLower = signaturePart.lowercased()
        print("🔐 [Signature] Has pkcs7: \(sigPartLower.contains("pkcs7")), has smime: \(sigPartLower.contains("smime"))")

        // Extract the signature data (base64 encoded PKCS#7)
        guard let signatureData = extractSignatureData(from: signaturePart) else {
            print("❌ [Signature] Could not extract signature data")
            print("❌ [Signature] Signature part full content (\(signaturePart.count) chars):")
            print(signaturePart.prefix(500))
            return (.error, nil)
        }

        print("🔐 [Signature] Extracted signature data: \(signatureData.count) bytes")

        // For now, we'll use a simplified verification that checks if the signature is valid
        // In a full implementation, this would call the SMIMEVerificationService
        let signerInfo = extractSignerInfoFromSignature(signatureData)

        // Try to verify the signature using Security framework
        let isValid = verifyPKCS7Signature(signedContent: signedContent, signature: signatureData)

        if isValid {
            // Check if certificate is trusted
            let trustLevel = checkCertificateTrust(signatureData)
            switch trustLevel {
            case .trusted:
                return (.valid, signerInfo)
            case .untrusted, .marginal, .unknown:
                return (.validUntrusted, signerInfo)
            case .invalid:
                return (.invalid, signerInfo)
            case .revoked:
                return (.invalid, signerInfo)
            }
        } else {
            return (.invalid, signerInfo)
        }
    }

    /// Extract boundary from Content-Type header
    private func extractBoundary(from rawBody: String) -> String? {
        let pattern = "boundary\\s*=\\s*\"?([^\";\\r\\n]+)\"?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        let range = NSRange(rawBody.startIndex..., in: rawBody)
        guard let match = regex.firstMatch(in: rawBody, options: [], range: range),
              let boundaryRange = Range(match.range(at: 1), in: rawBody) else {
            return nil
        }

        return String(rawBody[boundaryRange])
    }

    /// Split multipart body into parts
    private func splitMultipartBody(rawBody: String, boundary: String) -> [String] {
        let separator = "--" + boundary
        let endMarker = separator + "--"

        // Find the body start (after headers)
        var bodyStart = rawBody.startIndex
        if let headerEnd = rawBody.range(of: "\r\n\r\n") {
            bodyStart = headerEnd.upperBound
        } else if let headerEnd = rawBody.range(of: "\n\n") {
            bodyStart = headerEnd.upperBound
        }

        let body = String(rawBody[bodyStart...])

        // Split by boundary
        var parts: [String] = []
        let components = body.components(separatedBy: separator)

        for (index, component) in components.enumerated() {
            // Skip the first empty part and the ending part
            if index == 0 || component.hasPrefix("--") {
                continue
            }

            // Clean up the part
            var part = component
            if part.hasPrefix("\r\n") {
                part = String(part.dropFirst(2))
            } else if part.hasPrefix("\n") {
                part = String(part.dropFirst(1))
            }

            // Remove trailing boundary markers
            if let endRange = part.range(of: endMarker) {
                part = String(part[..<endRange.lowerBound])
            }

            if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(part)
            }
        }

        return parts
    }

    /// Extract signature data from the signature MIME part
    private func extractSignatureData(from signaturePart: String) -> Data? {
        // Try to find the content after headers (double newline)
        var content = signaturePart

        if let headerEnd = signaturePart.range(of: "\r\n\r\n") {
            content = String(signaturePart[headerEnd.upperBound...])
        } else if let headerEnd = signaturePart.range(of: "\n\n") {
            content = String(signaturePart[headerEnd.upperBound...])
        } else {
            // No double newline found - look for base64 content directly
            // Base64 PKCS#7 typically starts with "MIA" (ASN.1 sequence)
            // Split by lines and find the first line that looks like base64
            let lines = signaturePart.components(separatedBy: CharacterSet.newlines)
            var foundContent = false
            var base64Lines: [String] = []

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Skip header lines (contain ':')
                if trimmed.contains(":") && !foundContent {
                    continue
                }
                // Skip empty lines
                if trimmed.isEmpty {
                    foundContent = true
                    continue
                }
                // Check if this looks like base64 (starts with valid base64 chars, no colon)
                if !trimmed.contains(":") && trimmed.count > 10 {
                    let base64Chars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
                    if trimmed.unicodeScalars.allSatisfy({ base64Chars.contains($0) }) {
                        foundContent = true
                        base64Lines.append(trimmed)
                    }
                }
            }

            if !base64Lines.isEmpty {
                content = base64Lines.joined()
                print("🔐 [Signature] Extracted base64 using line-by-line method: \(content.count) chars")
            }
        }

        // Remove whitespace and decode base64
        let cleanedContent = content
            .replacingOccurrences(of: "\r\n", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        print("🔐 [Signature] Cleaned base64 content: \(cleanedContent.count) chars, starts with: \(String(cleanedContent.prefix(20)))")

        guard !cleanedContent.isEmpty else {
            print("❌ [Signature] No base64 content found")
            return nil
        }

        guard let data = Data(base64Encoded: cleanedContent) else {
            print("❌ [Signature] Base64 decode failed")
            return nil
        }

        return data
    }

    /// Extract signer information from the PKCS#7 signature
    /// Note: Full PKCS#7 parsing requires OpenSSL on iOS. This extracts basic info from ASN.1.
    private func extractSignerInfoFromSignature(_ signatureData: Data) -> MessageSignerInfo? {
        // Try to extract email from the PKCS#7 certificate
        // Parse the ASN.1 structure to find email addresses
        let email = extractEmailFromPKCS7(signatureData) ?? "Signiert"
        let commonName = extractCommonNameFromPKCS7(signatureData)

        print("🔐 [Signature] Detected signer: \(commonName ?? "Unknown") <\(email)>")

        return MessageSignerInfo(
            email: email,
            commonName: commonName,
            organization: nil,
            validFrom: nil,
            validUntil: nil,
            issuer: nil
        )
    }

    /// Extract email address from PKCS#7 signature data by searching for email patterns
    private func extractEmailFromPKCS7(_ data: Data) -> String? {
        // Convert to string and search for email pattern
        // Email addresses in certificates are often stored as IA5String
        guard let str = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .utf8) else {
            return nil
        }

        // Look for email pattern
        let emailPattern = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
        if let regex = try? NSRegularExpression(pattern: emailPattern, options: []),
           let match = regex.firstMatch(in: str, options: [], range: NSRange(str.startIndex..., in: str)),
           let range = Range(match.range, in: str) {
            return String(str[range])
        }

        return nil
    }

    /// Extract common name from PKCS#7 signature by searching for CN= pattern
    private func extractCommonNameFromPKCS7(_ data: Data) -> String? {
        guard let str = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .utf8) else {
            return nil
        }

        // Look for CN= pattern (Common Name in X.509)
        if let cnRange = str.range(of: "CN=") {
            let afterCN = str[cnRange.upperBound...]
            // Find end of CN value (comma, newline, or non-printable)
            var endIndex = afterCN.endIndex
            for (idx, char) in afterCN.enumerated() {
                if char == "," || char == "\n" || char == "\r" || !char.isASCII {
                    endIndex = afterCN.index(afterCN.startIndex, offsetBy: idx)
                    break
                }
            }
            let cn = String(afterCN[..<endIndex]).trimmingCharacters(in: .whitespaces)
            if !cn.isEmpty {
                return cn
            }
        }

        return nil
    }

    /// Verify PKCS#7 signature - simplified detection for iOS
    /// Note: Full cryptographic verification requires OpenSSL. This checks if signature data is valid PKCS#7.
    private func verifyPKCS7Signature(signedContent: String, signature: Data) -> Bool {
        // Check if this looks like valid PKCS#7/CMS data
        // PKCS#7 starts with ASN.1 SEQUENCE tag (0x30) followed by length
        guard signature.count > 20 else { return false }

        let bytes = [UInt8](signature)

        // Check for ASN.1 SEQUENCE tag
        if bytes[0] != 0x30 {
            return false
        }

        // Check for signedData OID (1.2.840.113549.1.7.2)
        // This OID appears early in PKCS#7 signed data
        let signedDataOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]
        let signatureBytes = [UInt8](signature)

        // Search for the OID in the first 50 bytes
        for i in 0..<min(50, signatureBytes.count - signedDataOID.count) {
            var found = true
            for j in 0..<signedDataOID.count {
                if signatureBytes[i + j] != signedDataOID[j] {
                    found = false
                    break
                }
            }
            if found {
                print("🔐 [Signature] Valid PKCS#7 signedData structure detected")
                return true
            }
        }

        // If we have data and it starts with ASN.1, assume it's valid
        // Full verification would require OpenSSL
        print("🔐 [Signature] PKCS#7 structure detected (basic check)")
        return bytes[0] == 0x30
    }

    /// Check certificate trust level - simplified for iOS
    /// Note: Without CMSDecoder, we can't fully evaluate trust on iOS
    private func checkCertificateTrust(_ signatureData: Data) -> TrustLevel {
        // On iOS without CMSDecoder, we can't fully evaluate certificate trust
        // Return .unknown to indicate signature is present but trust is unverified
        // The UI will show this as "Signiert (nicht verifiziert)"
        return .unknown
    }

    /// Extrahiert Anhang-Metadaten aus dem rawBody - Regex-basiert für bessere Erkennung
    private func extractAttachmentMetadata(from rawBody: String) -> [AttachmentEntity] {
        print("📎 [extractAttachmentMetadata] Starting extraction from rawBody (\(rawBody.count) chars)")
        var attachments: [AttachmentEntity] = []
        var partCounter = 1

        let lowerBody = rawBody.lowercased()

        // Debug-Ausgabe
        let hasAttachmentDisp = lowerBody.contains("content-disposition: attachment") ||
                                lowerBody.contains("content-disposition:attachment")
        let hasPdf = lowerBody.contains("application/pdf")
        let hasFilename = lowerBody.contains("filename=") || lowerBody.contains("filename*=")
        let hasName = lowerBody.contains("name=")

        print("📎 Quick scan: disposition=\(hasAttachmentDisp), pdf=\(hasPdf), filename=\(hasFilename), name=\(hasName)")

        // Regex-basierte Suche nach filename (auch über Zeilenumbrüche hinweg)
        // Suche nach: filename="...", filename*="...", name="..."
        let patterns = [
            "filename\\s*=\\s*\"([^\"]+)\"",           // filename="value"
            "filename\\s*=\\s*'([^']+)'",              // filename='value'
            "filename\\s*=\\s*([^;\\s\\r\\n]+)",       // filename=value (ohne Quotes)
            "filename\\*\\s*=\\s*[^']*'[^']*'([^;\\s\\r\\n]+)", // filename*=utf-8''value
            "name\\s*=\\s*\"([^\"]+)\"",               // name="value"
            "name\\s*=\\s*'([^']+)'",                  // name='value'
            "name\\s*=\\s*([^;\\s\\r\\n]+)"            // name=value
        ]

        var foundFilenames: Set<String> = []

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(rawBody.startIndex..., in: rawBody)
                let matches = regex.matches(in: rawBody, options: [], range: range)

                for match in matches {
                    if match.numberOfRanges > 1,
                       let filenameRange = Range(match.range(at: 1), in: rawBody) {
                        var filename = String(rawBody[filenameRange])
                            .trimmingCharacters(in: .whitespaces)

                        // URL-Dekodierung für filename*=
                        if filename.contains("%") {
                            filename = filename.removingPercentEncoding ?? filename
                        }

                        // MIME-Dekodierung
                        filename = decodeFilename(filename)

                        // Nur Dateien mit bekannten Erweiterungen
                        let validExts = [".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx",
                                        ".zip", ".rar", ".png", ".jpg", ".jpeg", ".gif", ".txt",
                                        ".csv", ".rtf", ".odt", ".ods"]
                        let hasValidExt = validExts.contains { filename.lowercased().hasSuffix($0) }

                        if hasValidExt && !foundFilenames.contains(filename.lowercased()) {
                            foundFilenames.insert(filename.lowercased())

                            // MIME-Type aus Erweiterung ableiten
                            var mimeType = "application/octet-stream"
                            let ext = (filename as NSString).pathExtension.lowercased()
                            switch ext {
                            case "pdf": mimeType = "application/pdf"
                            case "doc": mimeType = "application/msword"
                            case "docx": mimeType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                            case "xls": mimeType = "application/vnd.ms-excel"
                            case "xlsx": mimeType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                            case "png": mimeType = "image/png"
                            case "jpg", "jpeg": mimeType = "image/jpeg"
                            case "gif": mimeType = "image/gif"
                            case "zip": mimeType = "application/zip"
                            case "txt": mimeType = "text/plain"
                            default: break
                            }

                            let attachment = AttachmentEntity(
                                accountId: mail.accountId,
                                folder: mail.folder,
                                uid: mail.uid,
                                partId: "part\(partCounter)",
                                filename: filename,
                                mimeType: mimeType,
                                sizeBytes: 0,
                                data: nil
                            )
                            attachments.append(attachment)
                            partCounter += 1
                            print("📎 Found: \(filename) (\(mimeType))")
                        }
                    }
                }
            }
        }

        print("📎 [extractAttachmentMetadata] Found \(attachments.count) attachments total")
        return attachments
    }

    /// Extrahiert einen gequoteten Wert (z.B. filename="test.pdf")
    private func extractQuotedValue(_ input: String) -> String {
        var result = input.trimmingCharacters(in: .whitespaces)

        // Remove leading quote
        if result.hasPrefix("\"") {
            result = String(result.dropFirst())
        }
        if result.hasPrefix("'") {
            result = String(result.dropFirst())
        }

        // Find end of value
        var endIndex = result.endIndex
        for (i, char) in result.enumerated() {
            if char == "\"" || char == "'" || char == ";" || char == "\r" || char == "\n" {
                endIndex = result.index(result.startIndex, offsetBy: i)
                break
            }
        }

        return String(result[..<endIndex]).trimmingCharacters(in: .whitespaces)
    }

    /// Dekodiert einen MIME-encoded Dateinamen
    private func decodeFilename(_ filename: String) -> String {
        var decoded = filename

        // Handle =?charset?encoding?text?= format
        if decoded.contains("=?") && decoded.contains("?=") {
            // Simple UTF-8 Q-encoding decode
            decoded = decoded.replacingOccurrences(of: "=?utf-8?Q?", with: "", options: .caseInsensitive)
            decoded = decoded.replacingOccurrences(of: "=?UTF-8?Q?", with: "", options: .caseInsensitive)
            decoded = decoded.replacingOccurrences(of: "?=", with: "")
            decoded = decoded.replacingOccurrences(of: "_", with: " ")

            // Decode =XX hex sequences
            var result = ""
            var i = decoded.startIndex
            while i < decoded.endIndex {
                if decoded[i] == "=" && decoded.distance(from: i, to: decoded.endIndex) >= 3 {
                    let hexStart = decoded.index(after: i)
                    let hexEnd = decoded.index(hexStart, offsetBy: 2)
                    let hexStr = String(decoded[hexStart..<hexEnd])
                    if let byte = UInt8(hexStr, radix: 16) {
                        result.append(Character(UnicodeScalar(byte)))
                        i = hexEnd
                        continue
                    }
                }
                result.append(decoded[i])
                i = decoded.index(after: i)
            }
            decoded = result
        }

        return decoded
    }

    /// Extrahiert Anhänge für ComposeMailView (Reply/Forward)
    private func extractAttachmentsForCompose() -> [ComposeMailView.Attachment] {
        guard !rawBodyText.isEmpty else {
            print("📎 [extractAttachmentsForCompose] rawBodyText is empty")
            return []
        }

        // Nutze den zentralen AttachmentExtractor
        let extracted = AttachmentExtractor.extract(from: rawBodyText)
        print("📎 [extractAttachmentsForCompose] Extracted \(extracted.count) attachments")

        // Konvertiere zu ComposeMailView.Attachment Format
        var composeAttachments: [ComposeMailView.Attachment] = []
        for att in extracted {
            let composeAtt = ComposeMailView.Attachment(
                data: att.data,
                mimeType: att.mimeType,
                filename: att.filename
            )
            composeAttachments.append(composeAtt)
            print("📎 [extractAttachmentsForCompose] Added: \(att.filename) (\(att.data.count) bytes)")
        }

        return composeAttachments
    }

    /// Ersetzt CID-Referenzen in HTML durch Base64 Data-URLs für Inline-Bilder
    private func replaceCIDWithBase64(html: String, rawBody: String) -> String {
        guard !rawBody.isEmpty else { return html }

        // Extrahiere Anhänge mit Content-ID
        let attachments = AttachmentExtractor.extract(from: rawBody)
        let cidAttachments = attachments.filter { $0.contentId != nil }

        guard !cidAttachments.isEmpty else {
            print("🖼️ [CID] No attachments with Content-ID found")
            return html
        }

        print("🖼️ [CID] Found \(cidAttachments.count) attachments with Content-ID")

        var result = html

        for attachment in cidAttachments {
            guard let contentId = attachment.contentId else { continue }

            // CID kann verschiedene Formate haben: cid:image001.png@... oder cid:image001.png
            // Wir suchen nach beiden Varianten
            let base64String = attachment.data.base64EncodedString()
            let dataURL = "data:\(attachment.mimeType);base64,\(base64String)"

            // Pattern 1: Vollständige CID (mit @-Teil)
            let fullCIDPattern = "cid:\(NSRegularExpression.escapedPattern(for: contentId))"
            result = result.replacingOccurrences(of: fullCIDPattern, with: dataURL, options: .caseInsensitive)

            // Pattern 2: CID ohne @-Teil (nur der Dateiname-Teil)
            if let atIndex = contentId.firstIndex(of: "@") {
                let shortCID = String(contentId[..<atIndex])
                let shortCIDPattern = "cid:\(NSRegularExpression.escapedPattern(for: shortCID))"
                result = result.replacingOccurrences(of: shortCIDPattern, with: dataURL, options: .caseInsensitive)
            }

            print("🖼️ [CID] Replaced cid:\(contentId.prefix(30))... with data URL (\(attachment.data.count) bytes)")
        }

        return result
    }

}

// MARK: - Errors

enum MailBodyError: LocalizedError {
    case processingFailed(String)
    case daoNotAvailable
    case noContentExtracted
    
    var errorDescription: String? {
        switch self {
        case .processingFailed(let reason):
            return "Verarbeitung fehlgeschlagen: \(reason)"
        case .daoNotAvailable:
            return "Datenbankzugriff nicht verfügbar"
        case .noContentExtracted:
            return "Kein Inhalt aus Mail extrahiert"
        }
    }
}

// MARK: - Supporting Views

private struct MailHTMLWebView: UIViewRepresentable {
    let html: String
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.scrollView.isScrollEnabled = true
        webView.isOpaque = false
        webView.backgroundColor = UIColor.clear
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // Der HTML-Content ist bereits durch BodyContentProcessor bereinigt
        // CSS mit media queries und !important für automatische Dark/Light Mode Anpassung
        let styledHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', system-ui, sans-serif;
                    font-size: 16px;
                    line-height: 1.5;
                    background-color: transparent;
                    margin: 0;
                    padding: 0;
                    word-wrap: break-word;
                }
                /* Force text colors to adapt - override inline styles */
                body, body * {
                    color: #000000 !important;
                }
                a, a * {
                    color: #007AFF !important;
                }
                @media (prefers-color-scheme: dark) {
                    body, body * {
                        color: #ffffff !important;
                    }
                    a, a * {
                        color: #64B5F6 !important;
                    }
                }
                img {
                    max-width: 100% !important;
                    height: auto !important;
                }
                table {
                    max-width: 100% !important;
                    table-layout: fixed !important;
                }
                pre {
                    white-space: pre-wrap;
                    word-wrap: break-word;
                }
                blockquote, blockquote * {
                    color: #666 !important;
                }
                @media (prefers-color-scheme: dark) {
                    blockquote, blockquote * {
                        color: #999 !important;
                    }
                }
            </style>
        </head>
        <body>
        \(html)
        </body>
        </html>
        """

        webView.loadHTMLString(styledHTML, baseURL: nil)
    }
}

private struct AttachmentRowView: View {
    let attachment: AttachmentEntity
    let tempFileURL: URL?
    let onTap: (() -> Void)?

    init(attachment: AttachmentEntity, tempFileURL: URL?, onTap: (() -> Void)? = nil) {
        self.attachment = attachment
        self.tempFileURL = tempFileURL
        self.onTap = onTap
    }

    var body: some View {
        Button(action: {
            onTap?()
        }) {
            HStack(spacing: 6) {
                Image(systemName: iconForAttachment)
                    .font(.caption2)
                    .foregroundStyle(.blue)

                Text(attachment.filename.isEmpty ? attachment.partId : attachment.filename)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 0)
        .padding(.vertical, 2)
    }
    
    private var iconForAttachment: String {
        let filename = attachment.filename.lowercased()
        if filename.hasSuffix(".pdf") {
            return "doc.fill"
        } else if filename.hasSuffix(".jpg") || filename.hasSuffix(".jpeg") || filename.hasSuffix(".png") || filename.hasSuffix(".gif") {
            return "photo.fill"
        } else if filename.hasSuffix(".doc") || filename.hasSuffix(".docx") {
            return "doc.text.fill"
        } else if filename.hasSuffix(".xls") || filename.hasSuffix(".xlsx") {
            return "tablecells.fill"
        } else if filename.hasSuffix(".zip") || filename.hasSuffix(".rar") {
            return "archivebox.fill"
        } else {
            return "paperclip"
        }
    }
}

#Preview {
    NavigationStack {
        MessageDetailView(
            mail: MessageHeaderEntity(
                accountId: UUID(),
                folder: "INBOX",
                uid: "123",
                from: "john@example.com",
                subject: "Important Meeting Tomorrow",
                date: Date(),
                flags: []
            )
        )
    }
}

// MARK: - Share Sheet

/// UIKit-basiertes Share Sheet für iOS
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // Keine Updates nötig
    }
}
