//Features/Shared/MailComposer.swift
import SwiftUI
import MessageUI

struct MailComposer: UIViewControllerRepresentable {
    var subject: String
    var body: String
    var recipients: [String] = []
    
    struct Attachment {
        let data: Data
        let mimeType: String
        let fileName: String
    }
    var attachments: [Attachment] = []

    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        // Track last applied values to avoid redundant updates
        var lastSubject: String = ""
        var lastBody: String = ""
        var lastRecipients: [String] = []

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            controller.dismiss(animated: true, completion: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.setSubject(subject)
        vc.setToRecipients(recipients)
        vc.setMessageBody(body, isHTML: false)
        for att in attachments {
            vc.addAttachmentData(att.data, mimeType: att.mimeType, fileName: att.fileName)
        }
        vc.mailComposeDelegate = context.coordinator
        context.coordinator.lastSubject = subject
        context.coordinator.lastBody = body
        context.coordinator.lastRecipients = recipients
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {
        // Update subject if needed
        if context.coordinator.lastSubject != subject {
            uiViewController.setSubject(subject)
            context.coordinator.lastSubject = subject
        }
        // Update recipients if needed
        if context.coordinator.lastRecipients != recipients {
            uiViewController.setToRecipients(recipients)
            context.coordinator.lastRecipients = recipients
        }
        // Update body if needed
        if context.coordinator.lastBody != body {
            uiViewController.setMessageBody(body, isHTML: false)
            context.coordinator.lastBody = body
        }
        // Note: Attachments cannot be modified without re-creating the controller; we set them only once in makeUIViewController.
    }
}
