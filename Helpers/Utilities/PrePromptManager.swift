import SwiftUI
import Foundation

/// Pre-Prompt Manager - Wrapper für PrePromptCatalogView
/// Für Abwärtskompatibilität mit bestehenden NavigationLinks
struct PrePromptManager: View {
    var body: some View {
        PrePromptCatalogView()
    }
}
