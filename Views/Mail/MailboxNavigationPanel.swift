// MailboxNavigationPanel.swift - Mailbox Rail und Sliding Panel für MailView in AILO_APP
import SwiftUI
import Foundation
import Combine

// MARK: - Mailbox Navigation Panel

struct MailboxNavigationPanel: View {
    // State bindings from parent
    @Binding var isMailboxPanelOpen: Bool
    @Binding var railVerticalOffset: CGFloat
    @Binding var selectedMailbox: MailboxType
    
    // Data from parent
    let availableBoxesSorted: [MailboxType]
    let mailboxSection: AnyView
    let accountsSection: AnyView
    
    // Callbacks
    let onMailboxSelected: (MailboxType) -> Void
    let mailboxIcon: (MailboxType) -> String
    
    var body: some View {
        GeometryReader { geo in
            let validWidth = max(1, geo.size.width)   // ← ensure never 0 or negative
            let validHeight = max(1, geo.size.height) // ← ensure never 0 or negative
            let panelWidth = max(280, validWidth * 0.6)
            let panelHeight = validHeight + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            let railWidth: CGFloat = 56

            // Left icon rail (compact; draggable vertically)
            VStack {
                Spacer(minLength: 0)

                // Inner rail box
                VStack(spacing: 0) {
                    // Expand button (draggable)
                    Button {
                        withAnimation(.easeInOut) { 
                            isMailboxPanelOpen = true 
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .imageScale(.large)
                            .frame(width: railWidth, height: 44)
                    }
                    .buttonStyle(.plain)
                    .gesture(railDragGesture(validHeight: validHeight))

                    Divider().padding(.horizontal, 8)

                    // Mailbox icons
                    ForEach(availableBoxesSorted, id: \.self) { box in
                        Button {
                            selectedMailbox = box
                            onMailboxSelected(box)
                        } label: {
                            Image(systemName: mailboxIcon(box))
                                .imageScale(.large)
                                .foregroundColor(box == selectedMailbox ? .accentColor : .primary)
                                .frame(width: railWidth, height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: railWidth)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 1)
                .offset(y: railVerticalOffset)

                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.leading, 8)
            .zIndex(2)

            // Sliding panel with mailbox + accounts list
            VStack(spacing: 0) {
                List {
                    mailboxSection
                    accountsSection
                }
                .listStyle(.insetGrouped)
                .safeAreaPadding(.top)
                .safeAreaPadding(.bottom)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .frame(width: panelWidth, height: panelHeight)
            .background(.regularMaterial)
            .ignoresSafeArea()
            .offset(x: isMailboxPanelOpen ? 0 : -panelWidth)
            .gesture(panelDragGesture())
            .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 0)
            .zIndex(3)
        }
    }
    
    // MARK: - Drag Gestures
    
    private func railDragGesture(validHeight: CGFloat) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                let newOffset = railVerticalOffset + value.translation.height
                let maxHeight = validHeight - 200 // Leave some margin
                let minOffset = -maxHeight * 0.4
                let maxOffset = maxHeight * 0.4
                railVerticalOffset = max(minOffset, min(maxOffset, newOffset))
            }
            .onEnded { value in
                // Save position to UserDefaults
                UserDefaults.standard.set(railVerticalOffset, forKey: "mailview.rail.offset")
                
                // Optional: Add some spring animation when drag ends
                withAnimation(.interpolatingSpring(stiffness: 300, damping: 30)) {
                    // Keep current position or add snapping logic here if desired
                }
            }
    }
    
    private func panelDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onEnded { value in
                if value.translation.width < -60 {
                    withAnimation(.easeInOut) { 
                        isMailboxPanelOpen = false 
                    }
                } else if value.translation.width > 60 {
                    withAnimation(.easeInOut) { 
                        isMailboxPanelOpen = true 
                    }
                }
            }
    }
}

// MARK: - Panel Configuration

struct MailboxPanelConfiguration {
    let railWidth: CGFloat = 56
    let minimumPanelWidth: CGFloat = 280
    let panelWidthRatio: CGFloat = 0.6
    let railMargin: CGFloat = 200
    let railOffsetRange: CGFloat = 0.4
    let minimumDragDistance: CGFloat = 10
    let closeDragThreshold: CGFloat = -60
    let openDragThreshold: CGFloat = 60
    
    // Animation configurations
    let panelAnimation: Animation = .easeInOut
    let railAnimation: Animation = .interpolatingSpring(stiffness: 300, damping: 30)
    
    // Visual configurations
    let railCornerRadius: CGFloat = 12
    let railShadowRadius: CGFloat = 6
    let railShadowOpacity: Double = 0.12
    let panelShadowOpacity: Double = 0.15
}

// MARK: - Mailbox Panel State Manager

@MainActor
class MailboxPanelStateManager: ObservableObject {
    @Published var isOpen: Bool = false
    @Published var railOffset: CGFloat
    
    private let configuration = MailboxPanelConfiguration()
    
    init() {
        self.railOffset = UserDefaults.standard.double(forKey: "mailview.rail.offset")
    }
    
    func togglePanel() {
        withAnimation(configuration.panelAnimation) {
            isOpen.toggle()
        }
    }
    
    func closePanel() {
        withAnimation(configuration.panelAnimation) {
            isOpen = false
        }
    }
    
    func openPanel() {
        withAnimation(configuration.panelAnimation) {
            isOpen = true
        }
    }
    
    func updateRailOffset(_ newOffset: CGFloat, for screenHeight: CGFloat) {
        let maxHeight = screenHeight - configuration.railMargin
        let minOffset = -maxHeight * configuration.railOffsetRange
        let maxOffset = maxHeight * configuration.railOffsetRange
        
        railOffset = max(minOffset, min(maxOffset, newOffset))
        UserDefaults.standard.set(railOffset, forKey: "mailview.rail.offset")
    }
    
    func handlePanelDrag(translation: CGSize) {
        if translation.width < configuration.closeDragThreshold {
            closePanel()
        } else if translation.width > configuration.openDragThreshold {
            openPanel()
        }
    }
}