//
//  ChatViewPresentationModifier.swift
//  Mallow
//
//  Created by Codex on 2026.06.13.
//

import SwiftUI

#if os(iOS) || os(macOS) || os(visionOS)
import PhotosUI
import UniformTypeIdentifiers
import QuickLook
#endif

struct ChatViewPresentationModifier: ViewModifier {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var showFullScreenComposer: Bool
    @Binding var showSystemCameraCapture: Bool
    @Binding var textSelectionSheetItem: TextSelectionSheetItem?
    @Binding var showPhotoPicker: Bool
    @Binding var pickedPhotoItems: [PhotosPickerItem]
    @Binding var showFileImporter: Bool
    @Binding var pendingPreviewFileURL: URL?
    @Binding var activeAlert: ChatAlert?

    let remainingPendingImageAttachmentSlots: Int
    let onFullScreenComposerDismiss: () -> Void
    let onCapturedPhoto: (Data, String?) -> Void
    let onCameraFailure: () -> Void
    let onSelectedImageFiles: (Result<[URL], any Error>) -> Void
    let onPickedPhotoItemsChanged: ([PhotosPickerItem]) -> Void
    let onContinueVoiceInterrupt: () -> Void
    let onContinueUnsupportedImageSend: () -> Bool
    let onContinueUnsupportedImageBranchRestart: (ChatBranchRestartConfirmation) -> Void
    let onEditUnsupportedImageBranchRestart: (UUID) -> Void
    let onEditUnsupportedQueuedDraft: (UUID) -> Void
    let onContinueUnsupportedQueuedDraftTextOnly: (UUID) -> Bool
    let onDeleteUnsupportedQueuedDraft: (UUID) -> Void
    let onNothingToSendAfterDroppingImages: () -> Void

    func body(content: Content) -> some View {
        platformPresentations(for: content)
            .alert(item: $activeAlert, content: makeAlert(for:))
            .alert(
                "CHAT_MODEL_IMAGE_INPUT_UNSUPPORTED",
                isPresented: Binding(
                    get: { viewModel.pendingUnsupportedImageQueuedDraftID != nil },
                    set: { isPresented in
                        if !isPresented {
                            viewModel.dismissUnsupportedImageConfirmationForQueuedDraft()
                        }
                    }
                )
            ) {
                unsupportedQueuedDraftAlertButtons
            } message: {
                unsupportedQueuedDraftAlertMessage
            }
    }

    @ViewBuilder
    private func platformPresentations(for content: Content) -> some View {
        #if os(iOS) || os(tvOS)
        let composerPresented = content.fullScreenCover(isPresented: $showFullScreenComposer) {
            FullScreenComposer(
                text: Binding(
                    get: { viewModel.userMessage },
                    set: { viewModel.userMessage = $0 }
                ),
                onDone: onFullScreenComposerDismiss
            )
        }
        #else
        let composerPresented = content
        #endif

        #if os(iOS)
        let cameraPresented = composerPresented.fullScreenCover(isPresented: $showSystemCameraCapture) {
            SystemCameraCapturePicker(
                isPresented: $showSystemCameraCapture,
                onCapture: onCapturedPhoto,
                onFailure: onCameraFailure
            )
            .ignoresSafeArea()
        }
        let textSelectionPresented = cameraPresented.fullScreenCover(item: $textSelectionSheetItem) { item in
            TextSelectionSheet(text: item.text)
        }
        imageImportPresentations(for: textSelectionPresented)
        #elseif os(macOS)
        let cameraPresented = composerPresented.sheet(isPresented: $showSystemCameraCapture) {
            MacCameraCaptureSheet(
                onCapture: { data, mimeType in
                    onCapturedPhoto(data, mimeType)
                    showSystemCameraCapture = false
                },
                onFailure: onCameraFailure,
                onDismiss: {
                    showSystemCameraCapture = false
                }
            )
        }
        let textSelectionPresented = cameraPresented.sheet(item: $textSelectionSheetItem) { item in
            TextSelectionSheet(text: item.text)
        }
        imageImportPresentations(for: textSelectionPresented)
        #else
        let textSelectionPresented = composerPresented.sheet(item: $textSelectionSheetItem) { item in
            TextSelectionSheet(text: item.text)
        }
        imageImportPresentations(for: textSelectionPresented)
        #endif
    }

    @ViewBuilder
    private func imageImportPresentations<PresentedContent: View>(for content: PresentedContent) -> some View {
        #if os(iOS) || os(macOS) || os(visionOS)
        content
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $pickedPhotoItems,
                maxSelectionCount: max(1, remainingPendingImageAttachmentSlots),
                matching: .images
            )
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: true,
                onCompletion: onSelectedImageFiles
            )
            .onChange(of: pickedPhotoItems) { _, newItems in
                onPickedPhotoItemsChanged(newItems)
            }
            .quickLookPreview($pendingPreviewFileURL)
            .onChange(of: pendingPreviewFileURL) { oldValue, newValue in
                guard oldValue != newValue else { return }
                ChatImageQuickLookSupport.cleanupTemporaryPreviewURL(oldValue)
            }
        #else
        content
        #endif
    }

    @ViewBuilder
    private var unsupportedQueuedDraftAlertButtons: some View {
        Button("COMMON_ACTION_CANCEL", role: .cancel) {
            viewModel.dismissUnsupportedImageConfirmationForQueuedDraft()
        }

        Button("MESSAGE_ACTION_EDIT") {
            guard let draftID = viewModel.pendingUnsupportedImageQueuedDraftID else { return }
            viewModel.dismissUnsupportedImageConfirmationForQueuedDraft()
            onEditUnsupportedQueuedDraft(draftID)
        }

        if let draftID = viewModel.pendingUnsupportedImageQueuedDraftID,
           viewModel.queuedDraftCanSendAsTextOnly(id: draftID) {
            Button("COMMON_ACTION_CONTINUE", role: .destructive) {
                guard let queuedDraftID = viewModel.pendingUnsupportedImageQueuedDraftID else { return }
                viewModel.dismissUnsupportedImageConfirmationForQueuedDraft()
                if !onContinueUnsupportedQueuedDraftTextOnly(queuedDraftID) {
                    onNothingToSendAfterDroppingImages()
                }
            }
        } else {
            Button("COMMON_ACTION_DELETE", role: .destructive) {
                guard let draftID = viewModel.pendingUnsupportedImageQueuedDraftID else { return }
                viewModel.dismissUnsupportedImageConfirmationForQueuedDraft()
                onDeleteUnsupportedQueuedDraft(draftID)
            }
        }
    }

    private var unsupportedQueuedDraftAlertMessage: some View {
        Group {
            if let draftID = viewModel.pendingUnsupportedImageQueuedDraftID,
               viewModel.queuedDraftCanSendAsTextOnly(id: draftID) {
                Text("CHAT_CONTINUE_TEXT_ONLY")
            } else {
                Text("CHAT_IMAGE_ONLY_EDIT_WARNING")
            }
        }
    }

    private func makeAlert(for alert: ChatAlert) -> Alert {
        switch alert {
        case .startVoiceModeInterrupt:
            return Alert(
                title: Text("VOICE_OTHER_TASKS_RUNNING"),
                message: Text("VOICE_INTERRUPT_TASKS_DESCRIPTION"),
                primaryButton: .destructive(Text("COMMON_ACTION_CONTINUE"), action: onContinueVoiceInterrupt),
                secondaryButton: .cancel()
            )
        case .unsupportedImageSend:
            return Alert(
                title: Text("CHAT_MODEL_IMAGE_INPUT_UNSUPPORTED"),
                message: Text("CHAT_CONTINUE_TEXT_ONLY"),
                primaryButton: .destructive(Text("COMMON_ACTION_CONTINUE")) {
                    if !onContinueUnsupportedImageSend() {
                        onNothingToSendAfterDroppingImages()
                    }
                },
                secondaryButton: .cancel()
            )
        case .unsupportedImageBranchRestart(let confirmation):
            if confirmation.canContinueTextOnly {
                return Alert(
                    title: Text("CHAT_MODEL_IMAGE_INPUT_UNSUPPORTED"),
                    message: Text("CHAT_CONTINUE_TEXT_ONLY"),
                    primaryButton: .destructive(Text("COMMON_ACTION_CONTINUE")) {
                        onContinueUnsupportedImageBranchRestart(confirmation)
                    },
                    secondaryButton: .cancel()
                )
            }
            return Alert(
                title: Text("CHAT_MODEL_IMAGE_INPUT_UNSUPPORTED"),
                message: Text("CHAT_IMAGE_ONLY_RETRY_WARNING"),
                primaryButton: .default(Text("MESSAGE_ACTION_EDIT")) {
                    onEditUnsupportedImageBranchRestart(confirmation.userMessageID)
                },
                secondaryButton: .cancel()
            )
        case .deleteQueuedDraft(let draftID):
            return Alert(
                title: Text("MESSAGE_DELETE_CONFIRMATION"),
                message: Text("MESSAGE_DELETE_DESCRIPTION"),
                primaryButton: .destructive(Text("COMMON_ACTION_DELETE")) {
                    viewModel.removeQueuedDraft(id: draftID)
                },
                secondaryButton: .cancel()
            )
        }
    }
}
