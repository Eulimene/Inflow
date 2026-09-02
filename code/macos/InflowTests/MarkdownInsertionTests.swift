import AppKit
import XCTest
@testable import Inflow

final class MarkdownInsertionTests: XCTestCase {
    @MainActor
    func testRelativeResourceDirectoryPolicyAndFrozenPermissionCopy() {
        XCTAssertFalse(RelativeResourceDirectoryPolicy.hasRelativeResources(in: "# Title"))
        XCTAssertFalse(RelativeResourceDirectoryPolicy.hasRelativeResources(
            in: "![remote](https://example.com/image.png) [heading](#part)"
        ))
        XCTAssertTrue(RelativeResourceDirectoryPolicy.hasRelativeResources(
            in: "![local](assets/image.png) [guide](guide/readme.md)"
        ))
        XCTAssertEqual(
            ImageAssetPicker.resourceDirectoryPromptMessage,
            "访问该目录后，Inflow 才能显示相对图片、打开链接或创建冲突副本。"
        )
    }

    @MainActor
    func testDirectoryAuthorizationPersistsRestoresAndRejectsMovedBookmark() throws {
        let exact = URL(fileURLWithPath: "/tmp/inflow-resources/document")
        let moved = URL(fileURLWithPath: "/tmp/inflow-resources/moved")
        let persistence = TestResourceDirectoryAuthorizationPersistence()
        var started: [URL] = []
        var stopped: [URL] = []

        var manager: ImageAssetDirectoryAccess? = ImageAssetDirectoryAccess(
            persistence: persistence,
            bookmarkData: { url in Data(url.path.utf8) },
            resolveBookmark: { _ in (exact, false) },
            beginAccess: { url in
                started.append(url)
                return true
            },
            endAccess: { stopped.append($0) }
        )
        try manager?.authorizePersistently(
            exact,
            now: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertTrue(manager?.isAuthorized(exact) == true)
        XCTAssertEqual(persistence.records.map(\.exactPath), [exact.path])
        XCTAssertEqual(started, [exact])
        manager = nil
        XCTAssertEqual(stopped, [exact])

        let restored = ImageAssetDirectoryAccess(
            persistence: persistence,
            bookmarkData: { _ in Data([9]) },
            resolveBookmark: { _ in (exact, true) },
            beginAccess: { _ in true },
            endAccess: { _ in }
        )
        XCTAssertTrue(restored.restoreAuthorization(for: exact))
        XCTAssertTrue(restored.isAuthorized(exact))
        XCTAssertEqual(persistence.records.first?.bookmark, Data([9]))

        let rejected = ImageAssetDirectoryAccess(
            persistence: persistence,
            bookmarkData: { _ in Data([7]) },
            resolveBookmark: { _ in (moved, false) },
            beginAccess: { _ in true },
            endAccess: { _ in }
        )
        XCTAssertFalse(rejected.restoreAuthorization(for: exact))
        XCTAssertFalse(rejected.isAuthorized(exact))
        XCTAssertTrue(persistence.records.isEmpty)
    }

    func testUnsavedImageActionWaitsForOneSuccessfulFirstSave() {
        let payload = ClipboardImagePayload(data: Data([1, 2, 3]), kind: .png)
        var queue = DeferredImageInsertionQueue()

        XCTAssertTrue(queue.enqueue(.paste(payload)))
        XCTAssertTrue(queue.hasPending)
        XCTAssertFalse(queue.enqueue(.chooseExistingImage))
        XCTAssertEqual(queue.consumeAfterSuccessfulSave(), .paste(payload))
        XCTAssertFalse(queue.hasPending)
        XCTAssertNil(queue.consumeAfterSuccessfulSave())

        XCTAssertTrue(queue.enqueue(.drop(URL(fileURLWithPath: "/tmp/photo.png"))))
        queue.cancel()
        XCTAssertFalse(queue.hasPending)
        XCTAssertEqual(DeferredImageInsertion.savePanelTitle, "先保存这份 Markdown")
        XCTAssertEqual(DeferredImageInsertion.savePanelActionTitle, "保存并继续")
        XCTAssertTrue(DeferredImageInsertion.savePanelMessage.contains("取消不会创建资源"))
    }

    func testLinkPlanWrapsUnicodeSelectionAndUpdatesExistingLink() throws {
        let source = "Read 文档👩‍💻 now"
        let selected = (source as NSString).range(of: "文档👩‍💻")
        let added = try MarkdownFormatter.linkPlan(
            source: source,
            selectedUTF16Range: selected,
            destination: "https://example.com/guide"
        )
        XCTAssertEqual(
            added.resultingSource,
            "Read [文档👩‍💻](<https://example.com/guide>) now"
        )
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: added.resultingSource).contains(
            "href=\"https://example.com/guide\""
        ))

        let updated = try MarkdownFormatter.linkPlan(
            source: added.resultingSource,
            selectedUTF16Range: (added.resultingSource as NSString).range(of: "文档👩‍💻"),
            destination: "guide/local.md"
        )
        XCTAssertEqual(
            updated.resultingSource,
            "Read [文档👩‍💻](<guide/local.md>) now"
        )
    }

    func testEmptyLinkPlanSelectsEditableLabelAndRejectsUnsafeDestination() throws {
        let plan = try MarkdownFormatter.linkPlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0),
            destination: "#section"
        )
        XCTAssertEqual(plan.resultingSource, "[链接文字](<#section>)")
        let target = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: plan.selectionUTF8Range,
                in: plan.resultingSource
            )
        )
        XCTAssertEqual((plan.resultingSource as NSString).substring(with: target.revealRange), "链接文字")

        XCTAssertThrowsError(
            try MarkdownFormatter.linkPlan(
                source: "text",
                selectedUTF16Range: NSRange(location: 0, length: 4),
                destination: "https://example.com/<unsafe>"
            )
        ) { error in
            guard case MarkdownFormatError.invalidDestination = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testImagePlanCreatesStandardMarkdownAndEditableAlternative() throws {
        let source = "Before 图片👩‍💻 after"
        let selection = (source as NSString).range(of: "图片👩‍💻")
        let selected = try MarkdownFormatter.imagePlan(
            source: source,
            selectedUTF16Range: selection,
            destination: "assets/cover%20image.png",
            defaultAlternative: "cover image"
        )
        XCTAssertEqual(
            selected.resultingSource,
            "Before ![图片👩‍💻](<assets/cover%20image.png>) after"
        )
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: selected.resultingSource).contains(
            "class=\"inflow-image-slot\""
        ))

        let empty = try MarkdownFormatter.imagePlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0),
            destination: "assets/photo.jpg",
            defaultAlternative: "photo"
        )
        XCTAssertEqual(empty.resultingSource, "![photo](<assets/photo.jpg>)")
        let target = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: empty.selectionUTF8Range,
                in: empty.resultingSource
            )
        )
        XCTAssertEqual((empty.resultingSource as NSString).substring(with: target.revealRange), "photo")
    }

    func testImagePlanRejectsPartialExistingImageAndUnsafeDestination() {
        let existing = "![old](<assets/old.png>)"
        let update = try? MarkdownFormatter.imagePlan(
            source: existing,
            selectedUTF16Range: NSRange(location: 0, length: (existing as NSString).length),
            destination: "assets/new.png",
            defaultAlternative: "unused"
        )
        XCTAssertEqual(update?.resultingSource, "![old](<assets/new.png>)")
        XCTAssertThrowsError(
            try MarkdownFormatter.imagePlan(
                source: existing,
                selectedUTF16Range: (existing as NSString).range(of: "old"),
                destination: "assets/new.png",
                defaultAlternative: "new"
            )
        )
        XCTAssertThrowsError(
            try MarkdownFormatter.imagePlan(
                source: "",
                selectedUTF16Range: NSRange(location: 0, length: 0),
                destination: "assets/<unsafe>.png",
                defaultAlternative: "image"
            )
        )
    }

    func testImageWorkerCopiesValidatedAssetAndIncrementsCollision() async throws {
        let root = try temporaryImageDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("cover image.png")
        let documentDirectory = root.appendingPathComponent("document", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        try testPNGData().write(to: sourceURL)

        let worker = ImageAssetWorker()
        let image = try await worker.loadSource(at: sourceURL)

        let changingSourceURL = root.appendingPathComponent("changing.png")
        try testPNGData().write(to: changingSourceURL)
        XCTAssertThrowsError(
            try LocalImageValidator.load(
                at: changingSourceURL,
                afterRead: {
                    let handle = try FileHandle(forWritingTo: changingSourceURL)
                    try handle.truncate(atOffset: 0)
                    try handle.write(contentsOf: Data("changed after descriptor read".utf8))
                    try handle.close()
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalImageValidationError,
                .notRegularOrUnreadable
            )
        }

        let missingDestination = try await worker.destinationSnapshot(
            documentDirectory: documentDirectory,
            originalFilename: sourceURL.lastPathComponent
        )
        let first = try await worker.importAsset(
            image: image,
            originalFilename: sourceURL.lastPathComponent,
            documentDirectory: documentDirectory,
            collisionResolution: .failIfExists,
            expectedDestination: missingDestination
        )
        XCTAssertEqual(first.relativeMarkdownPath, "assets/cover%20image.png")
        XCTAssertEqual(try Data(contentsOf: first.destinationURL), image.data)

        await XCTAssertThrowsErrorAsync {
            let existingDestination = try await worker.destinationSnapshot(
                documentDirectory: documentDirectory,
                originalFilename: sourceURL.lastPathComponent
            )
            _ = try await worker.importAsset(
                image: image,
                originalFilename: sourceURL.lastPathComponent,
                documentDirectory: documentDirectory,
                collisionResolution: .failIfExists,
                expectedDestination: existingDestination
            )
        }

        let second = try await worker.importAsset(
            image: image,
            originalFilename: sourceURL.lastPathComponent,
            documentDirectory: documentDirectory,
            collisionResolution: .incrementName,
            expectedDestination: try await worker.destinationSnapshot(
                documentDirectory: documentDirectory,
                originalFilename: sourceURL.lastPathComponent
            )
        )
        XCTAssertEqual(second.relativeMarkdownPath, "assets/cover%20image-2.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.destinationURL.path))
        try second.rollback()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.destinationURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.destinationURL.path))

        let previous = Data("previous asset".utf8)
        try previous.write(to: first.destinationURL, options: .atomic)
        let replaceDestination = try await worker.destinationSnapshot(
            documentDirectory: documentDirectory,
            originalFilename: sourceURL.lastPathComponent
        )
        let replaced = try await worker.importAsset(
            image: image,
            originalFilename: sourceURL.lastPathComponent,
            documentDirectory: documentDirectory,
            collisionResolution: .replace,
            expectedDestination: replaceDestination
        )
        XCTAssertEqual(replaced.previousData, previous)
        XCTAssertEqual(try Data(contentsOf: replaced.destinationURL), image.data)
        try replaced.rollback()
        XCTAssertEqual(try Data(contentsOf: replaced.destinationURL), previous)
    }

    func testImageWorkerRefusesReplaceWhenDestinationChangesAfterConfirmation() async throws {
        let root = try temporaryImageDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("photo.png")
        let documentDirectory = root.appendingPathComponent("document", isDirectory: true)
        let assetsDirectory = documentDirectory.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        try testPNGData().write(to: sourceURL)
        let destinationURL = assetsDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        try Data("confirmed bytes".utf8).write(to: destinationURL)

        let worker = ImageAssetWorker()
        let image = try await worker.loadSource(at: sourceURL)
        let confirmedDestination = try await worker.destinationSnapshot(
            documentDirectory: documentDirectory,
            originalFilename: sourceURL.lastPathComponent
        )
        let externalChange = Data("external change after confirmation".utf8)
        try externalChange.write(to: destinationURL, options: .atomic)

        await XCTAssertThrowsErrorAsync {
            _ = try await worker.importAsset(
                image: image,
                originalFilename: sourceURL.lastPathComponent,
                documentDirectory: documentDirectory,
                collisionResolution: .replace,
                expectedDestination: confirmedDestination
            )
        }
        XCTAssertEqual(try Data(contentsOf: destinationURL), externalChange)
    }

    func testImageWorkerRefusesSymbolicAssetsDirectory() async throws {
        let root = try temporaryImageDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("photo.png")
        let documentDirectory = root.appendingPathComponent("document", isDirectory: true)
        let outsideDirectory = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: documentDirectory.appendingPathComponent("assets", isDirectory: true),
            withDestinationURL: outsideDirectory
        )
        try testPNGData().write(to: sourceURL)

        let worker = ImageAssetWorker()
        let image = try await worker.loadSource(at: sourceURL)
        await XCTAssertThrowsErrorAsync {
            let snapshot = try await worker.destinationSnapshot(
                documentDirectory: documentDirectory,
                originalFilename: sourceURL.lastPathComponent
            )
            _ = try await worker.importAsset(
                image: image,
                originalFilename: sourceURL.lastPathComponent,
                documentDirectory: documentDirectory,
                collisionResolution: .failIfExists,
                expectedDestination: snapshot
            )
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outsideDirectory.path).isEmpty)

        let project = root.appendingPathComponent("project", isDirectory: true)
        let projectAssets = project.appendingPathComponent("assets", isDirectory: true)
        let external = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectAssets,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: true
        )
        let requestedImage = projectAssets.appendingPathComponent("preview.png")
        let externalImage = external.appendingPathComponent("preview.png")
        try testPNGData().write(to: requestedImage)
        try Data("outside bytes must never be read".utf8).write(to: externalImage)

        let capturedAssets = project.appendingPathComponent(
            "captured-assets",
            isDirectory: true
        )
        var readAfterPrevalidationDirectorySwap = false
        XCTAssertThrowsError(
            try ProjectBoundLocalImageLoader.load(
                at: requestedImage,
                projectRoot: project,
                afterIdentityCapture: {
                    try FileManager.default.moveItem(at: projectAssets, to: capturedAssets)
                    try FileManager.default.createSymbolicLink(
                        at: projectAssets,
                        withDestinationURL: external
                    )
                },
                onWillRead: {
                    readAfterPrevalidationDirectorySwap = true
                }
            )
        ) { error in
            XCTAssertEqual(error as? ProjectBoundLocalImageError, .outsideProject)
        }
        XCTAssertFalse(readAfterPrevalidationDirectorySwap)
        try FileManager.default.removeItem(at: projectAssets)
        try FileManager.default.moveItem(at: capturedAssets, to: projectAssets)

        var readAfterPreopenDirectorySwap = false
        XCTAssertThrowsError(
            try ProjectBoundLocalImageLoader.load(
                at: requestedImage,
                projectRoot: project,
                beforeOpen: {
                    try FileManager.default.moveItem(at: projectAssets, to: capturedAssets)
                    try FileManager.default.createSymbolicLink(
                        at: projectAssets,
                        withDestinationURL: external
                    )
                },
                onWillRead: {
                    readAfterPreopenDirectorySwap = true
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalImageValidationError,
                .notRegularOrUnreadable
            )
        }
        XCTAssertFalse(readAfterPreopenDirectorySwap)
        try FileManager.default.removeItem(at: projectAssets)
        try FileManager.default.moveItem(at: capturedAssets, to: projectAssets)

        var readAfterTargetSwap = false
        XCTAssertThrowsError(
            try ProjectBoundLocalImageLoader.load(
                at: requestedImage,
                projectRoot: project,
                beforeOpen: {
                    try FileManager.default.removeItem(at: requestedImage)
                    try FileManager.default.createSymbolicLink(
                        at: requestedImage,
                        withDestinationURL: externalImage
                    )
                },
                onWillRead: {
                    readAfterTargetSwap = true
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalImageValidationError,
                .notRegularOrUnreadable
            )
        }
        XCTAssertFalse(readAfterTargetSwap)
    }

    func testImageWorkerCopiesIntoSelectedRelativeDirectoryWithEncodedReference() async throws {
        let root = try temporaryImageDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("photo #1.png")
        let documentDirectory = root.appendingPathComponent("document", isDirectory: true)
        let selectedDirectory = documentDirectory
            .appendingPathComponent("资源 图片", isDirectory: true)
            .appendingPathComponent("covers", isDirectory: true)
        try FileManager.default.createDirectory(
            at: selectedDirectory,
            withIntermediateDirectories: true
        )
        try testPNGData().write(to: sourceURL)

        let plan = try ImageAssetDirectoryPlan.selected(
            selectedDirectory,
            relativeTo: documentDirectory
        )
        XCTAssertEqual(plan.markdownDirectoryPath, "%E8%B5%84%E6%BA%90%20%E5%9B%BE%E7%89%87/covers")
        XCTAssertFalse(plan.allowsCreation)

        let worker = ImageAssetWorker()
        let image = try await worker.loadSource(at: sourceURL)
        let snapshot = try await worker.destinationSnapshot(
            directoryPlan: plan,
            originalFilename: sourceURL.lastPathComponent
        )
        let asset = try await worker.importAsset(
            image: image,
            originalFilename: sourceURL.lastPathComponent,
            directoryPlan: plan,
            collisionResolution: .failIfExists,
            expectedDestination: snapshot
        )

        XCTAssertEqual(
            asset.relativeMarkdownPath,
            "%E8%B5%84%E6%BA%90%20%E5%9B%BE%E7%89%87/covers/photo%20%231.png"
        )
        XCTAssertEqual(asset.destinationURL, selectedDirectory.appendingPathComponent("photo #1.png"))
        XCTAssertEqual(try Data(contentsOf: asset.destinationURL), image.data)
    }

    func testSelectedRelativeDirectoryRejectsOutsideAndSymbolicLinkTargets() throws {
        let root = try temporaryImageDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let documentDirectory = root.appendingPathComponent("document", isDirectory: true)
        let childDirectory = documentDirectory.appendingPathComponent("media", isDirectory: true)
        let outsideDirectory = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: childDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(
            try ImageAssetDirectoryPlan.selected(
                outsideDirectory,
                relativeTo: documentDirectory
            )
        ) { error in
            XCTAssertEqual(error as? ImageAssetImportError, .unauthorizedDirectory)
        }

        let linkedDirectory = documentDirectory.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: outsideDirectory
        )
        XCTAssertThrowsError(
            try ImageAssetDirectoryPlan.selected(
                linkedDirectory,
                relativeTo: documentDirectory
            )
        ) { error in
            XCTAssertEqual(error as? ImageAssetImportError, .unauthorizedDirectory)
        }

        let rootPlan = try ImageAssetDirectoryPlan.selected(
            documentDirectory,
            relativeTo: documentDirectory
        )
        XCTAssertEqual(rootPlan.markdownDirectoryPath, "")
    }

    func testSelectedRelativeDirectoryAuthorizationExpiresWhenDirectoryIsReplaced() throws {
        let root = try temporaryImageDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let documentDirectory = root.appendingPathComponent("document", isDirectory: true)
        let selectedDirectory = documentDirectory.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: selectedDirectory,
            withIntermediateDirectories: true
        )
        let plan = try ImageAssetDirectoryPlan.selected(
            selectedDirectory,
            relativeTo: documentDirectory
        )

        try FileManager.default.removeItem(at: selectedDirectory)
        try FileManager.default.createDirectory(
            at: selectedDirectory,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(try plan.validatedDirectory(createIfNeeded: false)) { error in
            XCTAssertEqual(error as? ImageAssetImportError, .destinationChanged)
        }
    }

    func testRetainedImagePrefersEncodedRelativeReferenceAndFallsBackToFileURL() throws {
        let documentURL = URL(fileURLWithPath: "/Users/writer/Documents/note.md")
        let sourceURL = URL(fileURLWithPath: "/Users/writer/Media/图片 #1.png")
        let relative = try RetainedImageReferencePlanner.plan(
            sourceURL: sourceURL,
            documentURL: documentURL,
            sameVolume: true
        )
        XCTAssertEqual(relative.markdownDestination, "../Media/%E5%9B%BE%E7%89%87%20%231.png")
        XCTAssertTrue(relative.isRelative)

        let absolute = try RetainedImageReferencePlanner.plan(
            sourceURL: sourceURL,
            documentURL: documentURL,
            sameVolume: false
        )
        XCTAssertFalse(absolute.isRelative)
        XCTAssertTrue(absolute.markdownDestination.hasPrefix("file:///"))
        XCTAssertFalse(absolute.markdownDestination.contains(" "))
        XCTAssertTrue(absolute.markdownDestination.contains("%23"))

        let plan = try MarkdownFormatter.imagePlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0),
            destination: absolute.markdownDestination,
            defaultAlternative: "图片 #1"
        )
        XCTAssertEqual(
            plan.resultingSource,
            "![图片 #1](<\(absolute.markdownDestination)>)"
        )
    }

    @MainActor
    func testExistingImageCollisionOffersEverySafeExit() {
        XCTAssertEqual(
            ImageAssetPicker.placementDecision(for: .alertFirstButtonReturn),
            .copyToAssets
        )
        XCTAssertEqual(
            ImageAssetPicker.placementDecision(for: .alertSecondButtonReturn),
            .copyToRelativeDirectory
        )
        XCTAssertEqual(
            ImageAssetPicker.placementDecision(for: .alertThirdButtonReturn),
            .keepOriginal
        )
        XCTAssertNil(ImageAssetPicker.placementDecision(for: .cancel))
        XCTAssertEqual(
            ImageAssetPicker.existingImageCollisionDecision(for: .alertFirstButtonReturn),
            .incrementName
        )
        XCTAssertEqual(
            ImageAssetPicker.existingImageCollisionDecision(for: .alertSecondButtonReturn),
            .replace
        )
        XCTAssertEqual(
            ImageAssetPicker.existingImageCollisionDecision(for: .alertThirdButtonReturn),
            .keepOriginal
        )
        XCTAssertNil(ImageAssetPicker.existingImageCollisionDecision(for: .cancel))
    }

    func testRetainedImageRemainsUnmodifiedAndRendersFromRelativeReference() async throws {
        let root = try temporaryImageDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("outside photo.png")
        let documentDirectory = root.appendingPathComponent("document", isDirectory: true)
        let documentURL = documentDirectory.appendingPathComponent("note.md")
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        let originalData = try testPNGData()
        try originalData.write(to: sourceURL)

        let worker = ImageAssetWorker()
        _ = try await worker.loadSource(at: sourceURL)
        let reference = try await worker.retainedReference(
            sourceURL: sourceURL,
            documentURL: documentURL
        )
        XCTAssertEqual(reference.markdownDestination, "../outside%20photo.png")
        XCTAssertTrue(reference.isRelative)
        let plan = try MarkdownFormatter.imagePlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0),
            destination: reference.markdownDestination,
            defaultAlternative: "outside photo"
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: documentDirectory.appendingPathComponent("assets").path
        ))
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalData)
        let html = MarkdownRenderer.htmlDocument(
            for: plan.resultingSource,
            documentDirectory: documentDirectory
        )
        XCTAssertTrue(html.contains("class=\"inflow-local-image\""))
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,"))
    }

    @MainActor
    func testSourceEditorConsumesOnlyEditableImagePasteboardPayloads() throws {
        let imagePasteboard = NSPasteboard(
            name: NSPasteboard.Name("inflow.tests.image.\(UUID().uuidString)")
        )
        imagePasteboard.clearContents()
        imagePasteboard.declareTypes([ClipboardImageKind.png.pasteboardType], owner: nil)
        XCTAssertTrue(imagePasteboard.setData(
            try testPNGData(),
            forType: ClipboardImageKind.png.pasteboardType
        ))

        let textView = WindowAwareTextView()
        textView.isEditable = true
        var received: ClipboardImagePayload?
        textView.pasteImageHandler = { received = $0 }
        XCTAssertTrue(textView.consumeImagePaste(from: imagePasteboard))
        XCTAssertEqual(received?.kind, .png)
        XCTAssertEqual(received?.data, try testPNGData())

        let textPasteboard = NSPasteboard(
            name: NSPasteboard.Name("inflow.tests.text.\(UUID().uuidString)")
        )
        textPasteboard.clearContents()
        textPasteboard.setString("plain text", forType: .string)
        XCTAssertFalse(textView.consumeImagePaste(from: textPasteboard))

        textView.isEditable = false
        XCTAssertFalse(textView.consumeImagePaste(from: imagePasteboard))
    }

    @MainActor
    func testSourceEditorAcceptsOneSupportedImageDropAtRequestedCaret() {
        let imageURL = URL(fileURLWithPath: "/tmp/inflow-drop-photo.png")
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("inflow.tests.drop.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([imageURL as NSURL]))

        let textView = WindowAwareTextView()
        textView.isEditable = true
        textView.string = "before after"
        var receivedURL: URL?
        textView.dropImageHandler = { receivedURL = $0 }
        XCTAssertTrue(textView.consumeImageDrop(
            from: pasteboard,
            insertionRange: NSRange(location: 7, length: 0)
        ))
        XCTAssertEqual(receivedURL, imageURL)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 7, length: 0))

        let unsupported = NSPasteboard(
            name: NSPasteboard.Name("inflow.tests.drop.unsupported.\(UUID().uuidString)")
        )
        unsupported.clearContents()
        unsupported.writeObjects([URL(fileURLWithPath: "/tmp/vector.svg") as NSURL])
        XCTAssertFalse(textView.consumeImageDrop(
            from: unsupported,
            insertionRange: NSRange(location: 0, length: 0)
        ))

        let multiple = NSPasteboard(
            name: NSPasteboard.Name("inflow.tests.drop.multiple.\(UUID().uuidString)")
        )
        multiple.clearContents()
        multiple.writeObjects([
            imageURL as NSURL,
            URL(fileURLWithPath: "/tmp/second.jpg") as NSURL,
        ])
        XCTAssertFalse(textView.consumeImageDrop(
            from: multiple,
            insertionRange: NSRange(location: 0, length: 0)
        ))
    }

    func testClipboardImagesAcceptPNGAndJPEGButRejectTIFF() async throws {
        let worker = ImageAssetWorker()
        let png = try testPNGData()
        let validatedPNG = try await worker.prepareClipboardImage(
            ClipboardImagePayload(data: png, kind: .png)
        )
        XCTAssertEqual(validatedPNG.mimeType, "image/png")
        XCTAssertEqual(validatedPNG.data, png)

        let jpeg = try testJPEGData()
        let validatedJPEG = try await worker.prepareClipboardImage(
            ClipboardImagePayload(data: jpeg, kind: .jpeg)
        )
        XCTAssertEqual(validatedJPEG.mimeType, "image/jpeg")
        XCTAssertEqual(validatedJPEG.data, jpeg)

        let image = try XCTUnwrap(NSImage(data: png))
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        await XCTAssertThrowsErrorAsync {
            _ = try await worker.prepareClipboardImage(
                ClipboardImagePayload(data: tiff, kind: .tiff)
            )
        }
        XCTAssertThrowsError(
            try LocalImageValidator.validate(data: tiff, fileExtension: "tiff")
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await worker.prepareClipboardImage(
                ClipboardImagePayload(data: Data("not an image".utf8), kind: .png)
            )
        }
    }

    func testClipboardImagesUseNumberedNamesWithoutOverwriting() async throws {
        let root = try temporaryImageDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let documentDirectory = root.appendingPathComponent("document", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        let worker = ImageAssetWorker()
        let image = try await worker.prepareClipboardImage(
            ClipboardImagePayload(data: try testPNGData(), kind: .png)
        )

        let first = try await worker.importClipboardImage(
            image,
            documentDirectory: documentDirectory
        )
        let second = try await worker.importClipboardImage(
            image,
            documentDirectory: documentDirectory
        )
        XCTAssertEqual(first.relativeMarkdownPath, "assets/image-001.png")
        XCTAssertEqual(second.relativeMarkdownPath, "assets/image-002.png")
        XCTAssertEqual(try Data(contentsOf: first.destinationURL), image.data)
        XCTAssertEqual(try Data(contentsOf: second.destinationURL), image.data)

        try second.rollback()
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.destinationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.destinationURL.path))
    }

    @MainActor
    func testImageInsertionUndoAndRedoOnlyChangeMarkdownReference() async throws {
        let root = try temporaryImageDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("photo.png")
        let documentDirectory = root.appendingPathComponent("document", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        try testPNGData().write(to: sourceURL)

        let worker = ImageAssetWorker()
        let image = try await worker.loadSource(at: sourceURL)
        let asset = try await worker.importAsset(
            image: image,
            originalFilename: sourceURL.lastPathComponent,
            documentDirectory: documentDirectory,
            collisionResolution: .failIfExists,
            expectedDestination: try await worker.destinationSnapshot(
                documentDirectory: documentDirectory,
                originalFilename: sourceURL.lastPathComponent
            )
        )
        let session = MarkdownSourceEditorSession()
        session.textView.isEditable = true
        session.textView.string = "Before "
        session.textView.setSelectedRange(NSRange(location: 7, length: 0))
        let plan = try MarkdownFormatter.imagePlan(
            source: session.textView.string,
            selectedUTF16Range: session.textView.selectedRange(),
            destination: asset.relativeMarkdownPath,
            defaultAlternative: "photo"
        )
        var resourceError: String?
        XCTAssertTrue(session.applyMarkdownImage(
            plan,
            asset: asset,
            actionName: "插入图片",
            onResourceError: { resourceError = $0 }
        ))
        XCTAssertEqual(session.textView.string, "Before ![photo](<assets/photo.png>)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.destinationURL.path))

        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, "Before ")
        XCTAssertEqual(try Data(contentsOf: asset.destinationURL), image.data)
        XCTAssertNil(resourceError)

        session.textView.undoManager?.redo()
        XCTAssertEqual(session.textView.string, "Before ![photo](<assets/photo.png>)")
        XCTAssertEqual(try Data(contentsOf: asset.destinationURL), image.data)
        XCTAssertNil(resourceError)
    }

    @MainActor
    func testImageUndoLeavesExternallyChangedResourceUntouched() async throws {
        let root = try temporaryImageDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("photo.png")
        let documentDirectory = root.appendingPathComponent("document", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        try testPNGData().write(to: sourceURL)

        let worker = ImageAssetWorker()
        let image = try await worker.loadSource(at: sourceURL)
        let asset = try await worker.importAsset(
            image: image,
            originalFilename: sourceURL.lastPathComponent,
            documentDirectory: documentDirectory,
            collisionResolution: .failIfExists,
            expectedDestination: try await worker.destinationSnapshot(
                documentDirectory: documentDirectory,
                originalFilename: sourceURL.lastPathComponent
            )
        )
        let session = MarkdownSourceEditorSession()
        session.textView.isEditable = true
        let plan = try MarkdownFormatter.imagePlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0),
            destination: asset.relativeMarkdownPath,
            defaultAlternative: "photo"
        )
        var resourceError: String?
        XCTAssertTrue(session.applyMarkdownImage(
            plan,
            asset: asset,
            actionName: "插入图片",
            onResourceError: { resourceError = $0 }
        ))

        let externalChange = Data("external change".utf8)
        try externalChange.write(to: asset.destinationURL, options: .atomic)
        session.textView.undoManager?.undo()
        XCTAssertEqual(try Data(contentsOf: asset.destinationURL), externalChange)
        XCTAssertNil(resourceError)
    }

    func testTablePlanCreatesThreeByThreeTemplateAndEscapesSelection() throws {
        let empty = try MarkdownFormatter.tablePlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(
            empty.resultingSource,
            "| 标题 1 | 标题 2 | 标题 3 |\n| --- | --- | --- |\n| 内容 1 | 内容 2 | 内容 3 |\n| 内容 4 | 内容 5 | 内容 6 |"
        )
        let header = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: empty.selectionUTF8Range,
                in: empty.resultingSource
            )
        )
        XCTAssertEqual((empty.resultingSource as NSString).substring(with: header.revealRange), "标题 1")

        let source = "before A|B\nC after"
        let selected = (source as NSString).range(of: "A|B\nC")
        let escaped = try MarkdownFormatter.tablePlan(
            source: source,
            selectedUTF16Range: selected
        )
        XCTAssertTrue(escaped.resultingSource.contains("| A\\|B<br>C | 标题 2 |"))
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: escaped.resultingSource).contains(
            "<table>"
        ))
    }

    func testTablePlanRejectsInsertionInsideExistingTable() {
        let source = "| One | Two |\n| --- | --- |\n| A | B |\n"
        XCTAssertThrowsError(
            try MarkdownFormatter.tablePlan(
                source: source,
                selectedUTF16Range: NSRange(
                    location: (source as NSString).range(of: "A").location,
                    length: 0
                )
            )
        ) { error in
            guard case MarkdownFormatError.ambiguousSelection = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testHorizontalRulePlanPreservesSelectionAndCreatesRealRule() throws {
        let empty = try MarkdownFormatter.horizontalRulePlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(empty.resultingSource, "---\n\n")
        XCTAssertEqual(empty.selectionUTF8Range, 5..<5)
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: empty.resultingSource).contains(
            "<hr />"
        ))

        let source = "before 文字👩‍💻 after"
        let selection = (source as NSString).range(of: "文字👩‍💻")
        let plan = try MarkdownFormatter.horizontalRulePlan(
            source: source,
            selectedUTF16Range: selection
        )
        XCTAssertEqual(plan.resultingSource, "before 文字👩‍💻\n\n---\n\n after")
        XCTAssertTrue(plan.resultingSource.hasPrefix("before 文字👩‍💻"))
    }

    func testFootnotePlanCreatesUniqueReferenceAndEditableDefinition() throws {
        let empty = try MarkdownFormatter.footnotePlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(empty.resultingSource, "[^note-1]\n\n[^note-1]: 脚注内容\n")
        let placeholder = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: empty.selectionUTF8Range,
                in: empty.resultingSource
            )
        )
        XCTAssertEqual(
            (empty.resultingSource as NSString).substring(with: placeholder.revealRange),
            "脚注内容"
        )
        let html = try MarkdownRenderer.htmlFragment(for: empty.resultingSource)
        XCTAssertTrue(html.contains("footnote-reference"))
        XCTAssertTrue(html.contains("footnote-definition"))

        let source = "Anchor[^note-1]\n\n[^note-1]: Existing\n"
        let selection = (source as NSString).range(of: "Anchor")
        let unique = try MarkdownFormatter.footnotePlan(
            source: source,
            selectedUTF16Range: selection
        )
        XCTAssertTrue(unique.resultingSource.hasPrefix("Anchor[^note-2][^note-1]"))
        XCTAssertTrue(unique.resultingSource.hasSuffix("[^note-2]: 脚注内容\n"))
    }

    func testMathPlanCreatesInlineAndDisplayMathML() throws {
        let source = "Euler e^{i\\pi}+1=0 end"
        let inline = try MarkdownFormatter.mathPlan(
            source: source,
            selectedUTF16Range: (source as NSString).range(of: "e^{i\\pi}+1=0")
        )
        XCTAssertEqual(inline.resultingSource, "Euler $e^{i\\pi}+1=0$ end")
        let inlineHTML = try MarkdownRenderer.htmlFragment(for: inline.resultingSource)
        XCTAssertTrue(inlineHTML.contains("<math"))
        XCTAssertTrue(inlineHTML.contains("display=\"inline\""))
        XCTAssertTrue(inlineHTML.contains("<msup>"))

        let display = try MarkdownFormatter.mathPlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(display.resultingSource, "$$\n公式内容\n$$")
        let target = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: display.selectionUTF8Range,
                in: display.resultingSource
            )
        )
        XCTAssertEqual((display.resultingSource as NSString).substring(with: target.revealRange), "公式内容")
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: display.resultingSource).contains(
            "display=\"block\""
        ))
    }

    func testMermaidPlanCreatesEditableOfflineDiagram() throws {
        let template = try MarkdownFormatter.mermaidPlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(
            template.resultingSource,
            "```mermaid\nflowchart TD\n    A[开始] --> B[结束]\n```"
        )
        let target = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: template.selectionUTF8Range,
                in: template.resultingSource
            )
        )
        XCTAssertEqual(
            (template.resultingSource as NSString).substring(with: target.revealRange),
            "flowchart TD\n    A[开始] --> B[结束]"
        )
        let html = try MarkdownRenderer.htmlFragment(for: template.resultingSource)
        XCTAssertTrue(html.contains("class=\"mermaid-diagram\""))
        XCTAssertTrue(html.contains("<svg"))
        XCTAssertFalse(html.contains("<script"))
    }

    @MainActor
    func testInsertionPlansApplyAsOneUndoUnit() throws {
        let source = "Read docs"
        let session = MarkdownSourceEditorSession()
        session.textView.isEditable = true
        session.textView.string = source
        session.textView.setSelectedRange((source as NSString).range(of: "docs"))
        let plan = try MarkdownFormatter.linkPlan(
            source: source,
            selectedUTF16Range: session.textView.selectedRange(),
            destination: "https://example.com"
        )
        XCTAssertTrue(session.applyMarkdownFormat(plan, actionName: "插入链接"))
        XCTAssertEqual(session.textView.string, "Read [docs](<https://example.com>)")
        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, source)
        session.textView.undoManager?.redo()
        XCTAssertEqual(session.textView.string, "Read [docs](<https://example.com>)")

        session.textView.string = "Header"
        session.textView.setSelectedRange(NSRange(location: 0, length: 6))
        let table = try MarkdownFormatter.tablePlan(
            source: session.textView.string,
            selectedUTF16Range: session.textView.selectedRange()
        )
        XCTAssertTrue(session.applyMarkdownFormat(table, actionName: "插入表格"))
        XCTAssertTrue(session.textView.string.hasPrefix("| Header | 标题 2 |"))
        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, "Header")
        session.textView.undoManager?.redo()
        XCTAssertTrue(session.textView.string.hasPrefix("| Header | 标题 2 |"))

        session.textView.string = "Before"
        session.textView.setSelectedRange(NSRange(location: 6, length: 0))
        let horizontalRule = try MarkdownFormatter.horizontalRulePlan(
            source: session.textView.string,
            selectedUTF16Range: session.textView.selectedRange()
        )
        XCTAssertTrue(session.applyMarkdownFormat(horizontalRule, actionName: "插入分隔线"))
        XCTAssertEqual(session.textView.string, "Before\n\n---\n\n")
        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, "Before")
        session.textView.undoManager?.redo()
        XCTAssertEqual(session.textView.string, "Before\n\n---\n\n")

        session.textView.string = "Anchor"
        session.textView.setSelectedRange(NSRange(location: 0, length: 6))
        let footnote = try MarkdownFormatter.footnotePlan(
            source: session.textView.string,
            selectedUTF16Range: session.textView.selectedRange()
        )
        XCTAssertTrue(session.applyMarkdownFormat(footnote, actionName: "插入脚注"))
        XCTAssertEqual(session.textView.string, "Anchor[^note-1]\n\n[^note-1]: 脚注内容\n")
        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, "Anchor")
        session.textView.undoManager?.redo()
        XCTAssertEqual(session.textView.string, "Anchor[^note-1]\n\n[^note-1]: 脚注内容\n")

        session.textView.string = "x^2"
        session.textView.setSelectedRange(NSRange(location: 0, length: 3))
        let formula = try MarkdownFormatter.mathPlan(
            source: session.textView.string,
            selectedUTF16Range: session.textView.selectedRange()
        )
        XCTAssertTrue(session.applyMarkdownFormat(formula, actionName: "插入公式"))
        XCTAssertEqual(session.textView.string, "$x^2$")
        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, "x^2")
        session.textView.undoManager?.redo()
        XCTAssertEqual(session.textView.string, "$x^2$")

        session.textView.string = ""
        session.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let diagram = try MarkdownFormatter.mermaidPlan(
            source: session.textView.string,
            selectedUTF16Range: session.textView.selectedRange()
        )
        XCTAssertTrue(session.applyMarkdownFormat(diagram, actionName: "插入图表"))
        XCTAssertTrue(session.textView.string.hasPrefix("```mermaid\nflowchart TD"))
        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, "")
        session.textView.undoManager?.redo()
        XCTAssertTrue(session.textView.string.hasPrefix("```mermaid\nflowchart TD"))
    }

    @MainActor
    func testInsertMenuExposesPersonalCommandsAndHidesDeferredCommands() throws {
        var firstCount = 0
        var firstImageCount = 0
        var secondCount = 0
        var firstTableCount = 0
        var firstRuleCount = 0
        var firstFootnoteCount = 0
        var firstFormulaCount = 0
        var firstDiagramCount = 0
        let first = MarkdownInsertCommandActions(
            canInsert: true,
            insertLink: { firstCount += 1 },
            insertImage: { firstImageCount += 1 },
            insertTable: { firstTableCount += 1 },
            insertHorizontalRule: { firstRuleCount += 1 },
            insertFootnote: { firstFootnoteCount += 1 },
            insertFormula: { firstFormulaCount += 1 },
            insertDiagram: { firstDiagramCount += 1 }
        )
        let second = MarkdownInsertCommandActions(
            canInsert: false,
            insertLink: { secondCount += 1 },
            insertImage: { secondCount += 1 },
            insertTable: { secondCount += 1 },
            insertHorizontalRule: { secondCount += 1 },
            insertFootnote: { secondCount += 1 },
            insertFormula: { secondCount += 1 },
            insertDiagram: { secondCount += 1 }
        )
        first.insertLink()
        first.insertImage()
        first.insertTable()
        first.insertHorizontalRule()
        first.insertFootnote()
        first.insertFormula()
        first.insertDiagram()
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(firstImageCount, 1)
        XCTAssertEqual(firstTableCount, 1)
        XCTAssertEqual(firstRuleCount, 1)
        XCTAssertEqual(firstFootnoteCount, 1)
        XCTAssertEqual(firstFormulaCount, 1)
        XCTAssertEqual(firstDiagramCount, 1)
        XCTAssertEqual(secondCount, 0)
        XCTAssertFalse(second.canInsert)

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let matches = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu)).filter {
            $0.title == "链接…"
        }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.keyEquivalent, "k")
        XCTAssertEqual(
            matches.first?.keyEquivalentModifierMask.intersection([.command, .option, .shift]),
            .command
        )

        let imageItems = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu)).filter {
            $0.title == "图片…"
        }
        XCTAssertEqual(imageItems.count, 1)
        XCTAssertEqual(imageItems.first?.keyEquivalent, "")

        let tableItems = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu)).filter {
            $0.title == "表格"
        }
        XCTAssertEqual(tableItems.count, 1)
        XCTAssertEqual(tableItems.first?.keyEquivalent, "")

        let horizontalRuleItems = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu)).filter {
            $0.title == "分隔线"
        }
        XCTAssertTrue(horizontalRuleItems.isEmpty)

        let footnoteItems = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu)).filter {
            $0.title == "脚注"
        }
        XCTAssertTrue(footnoteItems.isEmpty)

        let formulaItems = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu)).filter {
            $0.title == "公式"
        }
        XCTAssertTrue(formulaItems.isEmpty)

        let diagramItems = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu)).filter {
            $0.title == "图表"
        }
        XCTAssertTrue(diagramItems.isEmpty)
    }

    @MainActor
    func testLinkDestinationEditorKeepsInputLiteral() {
        let editor = NSTextView()
        editor.smartInsertDeleteEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = true
        editor.isAutomaticDashSubstitutionEnabled = true
        editor.isAutomaticTextReplacementEnabled = true
        editor.isAutomaticSpellingCorrectionEnabled = true
        editor.isAutomaticLinkDetectionEnabled = true
        editor.isAutomaticDataDetectionEnabled = true
        editor.isContinuousSpellCheckingEnabled = true
        editor.isGrammarCheckingEnabled = true

        LiteralLinkDestinationField.configureLiteralInput(editor)

        XCTAssertFalse(editor.smartInsertDeleteEnabled)
        XCTAssertFalse(editor.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(editor.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(editor.isAutomaticLinkDetectionEnabled)
        XCTAssertFalse(editor.isAutomaticDataDetectionEnabled)
        XCTAssertFalse(editor.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(editor.isGrammarCheckingEnabled)
    }

    @MainActor
    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allMenuItems) ?? [])
        }
    }

    private func temporaryImageDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "inflow-image-import-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func testPNGData() throws -> Data {
        let representation = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1,
                pixelsHigh: 1,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 4,
                bitsPerPixel: 32
            )
        )
        let pixels = try XCTUnwrap(representation.bitmapData)
        pixels[0] = 32
        pixels[1] = 96
        pixels[2] = 220
        pixels[3] = 255
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    private func testJPEGData() throws -> Data {
        let image = try XCTUnwrap(NSImage(data: testPNGData()))
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(
            representation.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.9]
            )
        )
    }

    private func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected expression to throw", file: file, line: line)
        } catch {
            // Expected.
        }
    }
}

@MainActor
private final class TestResourceDirectoryAuthorizationPersistence:
    ResourceDirectoryAuthorizationPersistence
{
    var records: [ResourceDirectoryAuthorizationRecord] = []

    func load() -> [ResourceDirectoryAuthorizationRecord] { records }
    func save(_ records: [ResourceDirectoryAuthorizationRecord]) {
        self.records = records
    }
}
