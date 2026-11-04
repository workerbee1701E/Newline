import Foundation

import NewlineCore

private final class AssetScenarios {
    private var root: URL!

    func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NewlineAssets-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testImportUsesRelativeEscapedNamesAndNeverOverwrites() throws {
        let doc = root.appendingPathComponent("Meine Notiz.md")
        let a = try AssetStore.importImage(data: Data([1, 2]), preferredName: "Bild eins.png", documentURL: doc)
        let b = try AssetStore.importImage(data: Data([3, 4]), preferredName: "Bild eins.png", documentURL: doc)
        try assetExpectEqual(a, "Meine%20Notiz.assets/Bild%20eins.png")
        try assetExpectEqual(b, "Meine%20Notiz.assets/Bild%20eins-2.png")
        try assetExpectEqual(try Data(contentsOf: root.appendingPathComponent(a.removingPercentEncoding!)), Data([1, 2]))
        try assetExpectEqual(try Data(contentsOf: root.appendingPathComponent(b.removingPercentEncoding!)), Data([3, 4]))
    }

    func testFilenameRenameDoesNotRenameAssetFolder() throws {
        let old = root.appendingPathComponent("One.md")
        let path = try AssetStore.importImage(data: Data([1]), preferredName: "a.png", documentURL: old)
        let original = "![image](\(path))\n"
        let moved = try AssetStore.prepareRelocation(source: original, from: old, to: root.appendingPathComponent("Two.md"))
        try assetExpectEqual(moved.source, original)
        try assetExpectTrue(moved.copiedFiles.isEmpty)
    }

    func testMoveCopiesAssetsAndPreservesUnmanagedRelativeTargets() throws {
        let old = root.appendingPathComponent("Old/Note.md")
        let next = root.appendingPathComponent("New/Note.md")
        try FileManager.default.createDirectory(at: next.deletingLastPathComponent(), withIntermediateDirectories: true)
        let image = try AssetStore.importImage(data: Data([1, 2, 3]), preferredName: "photo.png", documentURL: old)
        let original = "![photo](\(image))\n[Other](../Reference.md#part)\n[Web](https://example.com/page)\n"
        let result = try AssetStore.prepareRelocation(source: original, from: old, to: next)
        try assetExpectEqual(result.source, original)
        try assetExpectEqual(result.copiedFiles.count, 1)
        try assetExpectEqual(try Data(contentsOf: result.copiedFiles[0]), Data([1, 2, 3]))
        try assetExpectTrue(FileManager.default.fileExists(atPath: old.deletingLastPathComponent().appendingPathComponent(image).path))
        try assetExpectTrue(FileManager.default.fileExists(atPath: next.deletingLastPathComponent().appendingPathComponent(image).path))
    }

    func testMoveRebasesLinksAndReferenceDefinitionsButLeavesExamplesAlone() throws {
        let old = root.appendingPathComponent("Old/Note.md")
        let next = root.appendingPathComponent("New/Deep/Note.md")
        let source = """
        [link](other.md#anchor)
        ![pic](<two words.png> "Title")
        [ref]: other.md "Label"
        `![example](example.png)`
        ```md
        [example](example.md)
        ```
            [indented](example.md)
        plain ](not-a-link)
        """
        let result = try AssetStore.prepareRelocation(source: source, from: old, to: next)
        try assetExpectTrue(result.source.contains("[link](../../Old/other.md#anchor)"))
        try assetExpectTrue(result.source.contains("![pic](<../../Old/two%20words.png> \"Title\")"))
        try assetExpectTrue(result.source.contains("[ref]: ../../Old/other.md \"Label\""))
        try assetExpectTrue(result.source.contains("`![example](example.png)`"))
        try assetExpectTrue(result.source.contains("[example](example.md)"))
        try assetExpectTrue(result.source.contains("[indented](example.md)"))
        try assetExpectTrue(result.source.contains("plain ](not-a-link)"))
    }

    func testDestinationCollisionUsesSeparateAssetFolderAndReusesCopiedFile() throws {
        let old = root.appendingPathComponent("Old/Note.md")
        let next = root.appendingPathComponent("New/Note.md")
        let image = try AssetStore.importImage(data: Data([1]), preferredName: "a.png", documentURL: old)
        try FileManager.default.createDirectory(at: next.deletingLastPathComponent().appendingPathComponent("Note.assets"), withIntermediateDirectories: true)
        let result = try AssetStore.prepareRelocation(source: "![a](\(image)) ![b](\(image))", from: old, to: next)
        try assetExpectEqual(result.source, "![a](Note-2.assets/a.png) ![b](Note-2.assets/a.png)")
        try assetExpectEqual(result.copiedFiles.count, 1)
    }

    func testCopyFailureRetainsOriginalAsset() throws {
        let old = root.appendingPathComponent("Old/Note.md")
        let path = try AssetStore.importImage(data: Data([9]), preferredName: "a.png", documentURL: old)
        let destinationParent = root.appendingPathComponent("NotAFolder")
        try Data([7]).write(to: destinationParent)
        try assetExpectError(try AssetStore.prepareRelocation(source: "![a](\(path))", from: old,
                                                            to: destinationParent.appendingPathComponent("Note.md")))
        try assetExpectEqual(try Data(contentsOf: old.deletingLastPathComponent().appendingPathComponent(path)), Data([9]))
    }

    func testDestinationScanningPreservesFrontmatterAndEscapedLinkSyntax() throws {
        let source = "---\ntitle: '[example](no.md)'\n---\n\\[escaped](no.md)\n[real](file(a).md)\n"
        let ns = source as NSString
        try assetExpectEqual(AssetStore.destinationRanges(in: source).map { ns.substring(with: $0) }, ["file(a).md"])
    }

    func testNestedListAndFootnoteLinksRemainRelocatable() throws {
        let source = "- Parent\n    - [nested](nested.md)\n\nText.[^n]\n\n[^n]: Definition\n\n    [note](note.md)\n"
        let ns = source as NSString
        try assetExpectEqual(AssetStore.destinationRanges(in: source).map { ns.substring(with: $0) }, ["nested.md", "note.md"])
    }
}

private struct AssetCheckFailure: Error, CustomStringConvertible {
    let description: String
}
private func assetExpectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T, line: Int = #line) throws {
    let a = try actual(), e = try expected()
    guard a == e else { throw AssetCheckFailure(description: "Asset check line \(line): expected \(e), got \(a)") }
}
private func assetExpectTrue(_ condition: @autoclosure () throws -> Bool, line: Int = #line) throws {
    guard try condition() else { throw AssetCheckFailure(description: "Asset check line \(line): condition failed") }
}
private func assetExpectError<T>(_ operation: @autoclosure () throws -> T, line: Int = #line) throws {
    do { _ = try operation() } catch { return }
    throw AssetCheckFailure(description: "Asset check line \(line): expected an error")
}

@MainActor func runAssetChecks() throws -> Int {
    do { let suite = AssetScenarios(); try suite.setUpWithError(); defer { try? suite.tearDownWithError() }; try suite.testImportUsesRelativeEscapedNamesAndNeverOverwrites() }
    do { let suite = AssetScenarios(); try suite.setUpWithError(); defer { try? suite.tearDownWithError() }; try suite.testFilenameRenameDoesNotRenameAssetFolder() }
    do { let suite = AssetScenarios(); try suite.setUpWithError(); defer { try? suite.tearDownWithError() }; try suite.testMoveCopiesAssetsAndPreservesUnmanagedRelativeTargets() }
    do { let suite = AssetScenarios(); try suite.setUpWithError(); defer { try? suite.tearDownWithError() }; try suite.testMoveRebasesLinksAndReferenceDefinitionsButLeavesExamplesAlone() }
    do { let suite = AssetScenarios(); try suite.setUpWithError(); defer { try? suite.tearDownWithError() }; try suite.testDestinationCollisionUsesSeparateAssetFolderAndReusesCopiedFile() }
    do { let suite = AssetScenarios(); try suite.setUpWithError(); defer { try? suite.tearDownWithError() }; try suite.testCopyFailureRetainsOriginalAsset() }
    do { let suite = AssetScenarios(); try suite.setUpWithError(); defer { try? suite.tearDownWithError() }; try suite.testDestinationScanningPreservesFrontmatterAndEscapedLinkSyntax() }
    do { let suite = AssetScenarios(); try suite.setUpWithError(); defer { try? suite.tearDownWithError() }; try suite.testNestedListAndFootnoteLinksRemainRelocatable() }
    return 8
}
