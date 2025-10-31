// PlatformImage.swift
// Cross-platform Image extension for iOS and macOS compatibility

import SwiftUI
import UIKit

extension Image {
    /// Create an Image from platform-specific image data
    init(platformImage data: Data) {
        #if os(iOS)
        if let uiImage = UIImage(data: data) {
            self.init(uiImage: uiImage)
        } else {
            self.init(systemName: "photo.fill")
        }
        #elseif os(macOS)
        if let nsImage = NSImage(data: data) {
            self.init(nsImage: nsImage)
        } else {
            self.init(systemName: "photo.fill")
        }
        #endif
    }
    
    /// Get platform-specific image size from data
    static func platformImageSize(from data: Data) -> CGSize? {
        #if os(iOS)
        return UIImage(data: data)?.size
        #elseif os(macOS)
        return NSImage(data: data)?.size
        #endif
    }
}

// MARK: - Platform Colors Extension
extension Color {
    /// Cross-platform control background color
    static var controlBackground: Color {
        #if os(iOS)
        return Color(UIColor.systemGroupedBackground)
        #elseif os(macOS)
        return Color(NSColor.controlBackgroundColor)
        #endif
    }
    
    /// Cross-platform text background color
    static var textBackground: Color {
        #if os(iOS)
        return Color(UIColor.systemBackground)
        #elseif os(macOS)
        return Color(NSColor.textBackgroundColor)
        #endif
    }
}