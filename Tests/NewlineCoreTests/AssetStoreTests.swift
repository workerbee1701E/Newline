import Foundation
import XCTest
@testable import NewlineCore

final class AssetStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NewlineAssets-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testImportUsesRelativeEscapedNamesAndNeverOverwrites() throws {
        let doc = root.appendingPathComponent("Meine Notiz.md")
        let a = try AssetStore.importImage(data: Data([1, 2]), preferredName: "Bild eins.png", documentURL: doc)
        let b = try AssetStore.importImage(data: Data([3, 4]), preferredName: "Bild eins.png", documentURL: doc)
        XCTAssertEqual(a, "Meine%20Notiz.assets/Bild%20eins.png")
        XCTAssertEqual(b, "Meine%20Notiz.assets/Bild%20eins-2.png")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(a.removingPercentEncoding!)), Data([1, 2]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(b.removingPercentEncoding!)), Data([3, 4]))
    }

    func testFilenameRenameDoesNotRenameAssetFolder() throws {
        let old = root.appendingPathComponent("One.md")
        let path = try AssetStore.importImage(data: Data([1]), preferredName: "a.png", documentURL: old)
        let original = "![image](\(path))\n"
        let moved = try AssetStore.prepareRelocation(source: original, from: old, to: root.appendingPathComponent("Two.md"))
        XCTAssertEqual(moved.source, original)
        XCTAssertTrue(moved.copiedFiles.isEmpty)
    }

    func testMoveCopiesAssetsAndPreservesUnmanagedRelativeTargets() throws {
        let old = root.appendingPathComponent("Old/Note.md")
        let next = root.appendingPathComponent("New/Note.md")
        try FileManager.default.createDirectory(at: next.deletingLastPathComponent(), withIntermediateDirectories: true)
        let image = try AssetStore.importImage(data: Data([1, 2, 3]), preferredName: "photo.png", documentURL: old)
        let original = "![photo](\(image))\n[Other](../Reference.md#part)\n[Web](https://example.com/page)\n"
        let result = try AssetStore.prepareRelocation(source: original, from: old, to: next)
        XCTAssertEqual(result.source, original)
        XCTAssertEqual(result.copiedFiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: result.copiedFiles[0]), Data([1, 2, 3]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.deletingLastPathComponent().appendingPathComponent(image).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: next.deletingLastPathComponent().appendingPathComponent(image).path))
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
        XCTAssertTrue(result.source.contains("[link](../../Old/other.md#anchor)"))
        XCTAssertTrue(result.source.contains("![pic](<../../Old/two%20words.png> \"Title\")"))
        XCTAssertTrue(result.source.contains("[ref]: ../../Old/other.md \"Label\""))
        XCTAssertTrue(result.source.contains("`![example](example.png)`"))
        XCTAssertTrue(result.source.contains("[example](example.md)"))
        XCTAssertTrue(result.source.contains("[indented](example.md)"))
        XCTAssertTrue(result.source.contains("plain ](not-a-link)"))
    }

    func testDestinationCollisionUsesSeparateAssetFolderAndReusesCopiedFile() throws {
        let old = root.appendingPathComponent("Old/Note.md")
        let next = root.appendingPathComponent("New/Note.md")
        let image = try AssetStore.importImage(data: Data([1]), preferredName: "a.png", documentURL: old)
        try FileManager.default.createDirectory(at: next.deletingLastPathComponent().appendingPathComponent("Note.assets"), withIntermediateDirectories: true)
        let result = try AssetStore.prepareRelocation(source: "![a](\(image)) ![b](\(image))", from: old, to: next)
        XCTAssertEqual(result.source, "![a](Note-2.assets/a.png) ![b](Note-2.assets/a.png)")
        XCTAssertEqual(result.copiedFiles.count, 1)
    }

    func testCopyFailureRetainsOriginalAsset() throws {
        let old = root.appendingPathComponent("Old/Note.md")
        let path = try AssetStore.importImage(data: Data([9]), preferredName: "a.png", documentURL: old)
        let destinationParent = root.appendingPathComponent("NotAFolder")
        try Data([7]).write(to: destinationParent)
        XCTAssertThrowsError(try AssetStore.prepareRelocation(source: "![a](\(path))", from: old,
                                                            to: destinationParent.appendingPathComponent("Note.md")))
        XCTAssertEqual(try Data(contentsOf: old.deletingLastPathComponent().appendingPathComponent(path)), Data([9]))
    }

    func testDestinationScanningPreservesFrontmatterAndEscapedLinkSyntax() {
        let source = "---\ntitle: '[example](no.md)'\n---\n\\[escaped](no.md)\n[real](file(a).md)\n"
        let ns = source as NSString
        XCTAssertEqual(AssetStore.destinationRanges(in: source).map { ns.substring(with: $0) }, ["file(a).md"])
    }
}
