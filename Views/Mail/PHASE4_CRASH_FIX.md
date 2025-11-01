# Phase 4 Crash Fix - RAW-First Architecture

## Identified Potential Crash Causes:

### 1. MessageBodyEntity Initialization Mismatch
The complex initializer in MailTransportStubs might be causing issues with parameter ordering or null values.

### 2. Database Thread Safety Issues
DAO access might not be thread-safe when called from async contexts.

### 3. Force Unwrapping Hidden Issues
Some properties might be force-unwrapped indirectly through the entity system.

## Applied Fixes:

### ✅ Fixed: MailTransportStubs.swift - fetchMessageUID()
- **REMOVED:** Complex MIME parsing logic
- **ADDED:** Simple RAW-first storage
- **SIMPLIFIED:** MessageBodyEntity initialization with minimal parameters

### ✅ Applied Changes:
```swift
// OLD (Complex processing):
let mime = MIMEParser().parse(...)
let finalText = mime.text
let finalHTML = mime.html
// Multiple complex fields...

// NEW (RAW-first):
let entity = MessageBodyEntity(
    accountId: account.id,
    folder: folder,
    uid: uid,
    text: nil,              // ← Empty (later processing)
    html: nil,              // ← Empty (later processing)  
    hasAttachments: false,  // ← Later from rawBody
    rawBody: raw,           // ← ONLY RAW storage
    contentType: nil,       // ← Later extraction
    charset: nil,           // ← Later extraction
    transferEncoding: nil,
    isMultipart: false,     // ← Later from rawBody
    rawSize: raw.count,
    processedAt: nil        // ← NIL = not processed
)
```

## Testing Checklist:

1. **✅ Build Test**: Project compiles without errors
2. **🔄 Runtime Test**: App starts without crashing
3. **📧 Sync Test**: Sync process completes
4. **📱 UI Test**: MessageDetailView opens without crash
5. **🔍 RAW Display**: RAW content displays correctly

## Next Steps if Crash Persists:

### A. Check Database Schema
```swift
// Verify MailSchema.swift MessageBodyEntity matches database schema
// Ensure all optional fields are handled correctly
```

### B. Add Safety Guards
```swift
// Add nil checks for critical properties
guard let dao = MailRepository.shared.dao else {
    print("❌ DAO not available")
    return
}

// Add try-catch for entity creation
do {
    let entity = MessageBodyEntity(...)
    try writeDAO.storeBody(...)
} catch {
    print("❌ Entity creation failed: \(error)")
}
```

### C. Check Threading Issues
```swift
// Ensure UI updates are on main thread
Task { @MainActor in
    // UI updates here
}
```

## Debug Commands:

```swift
// Add to loadMailBody() in MessageDetailView:
print("🔍 DEBUG: mail.accountId = \(mail.accountId)")
print("🔍 DEBUG: mail.folder = \(mail.folder)")
print("🔍 DEBUG: mail.uid = \(mail.uid)")
print("🔍 DEBUG: MailRepository.shared.dao = \(MailRepository.shared.dao != nil)")
```

## Rollback Plan if Needed:

1. Revert MailTransportStubs.swift changes
2. Keep MailRepository.swift RAW-first storage
3. Test with simplified processing chain

---

**Status:** ✅ Phase 4 crash fixes applied
**Next:** Test and verify no crashes occur