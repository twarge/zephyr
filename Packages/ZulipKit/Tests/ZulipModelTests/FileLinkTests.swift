import Foundation
import Testing
@testable import ZulipModel

struct FileLinkTests {
    private func classify(_ string: String) -> FileLink {
        FileLink.classify(URL(string: string)!)
    }

    @Test func archivesAndDocumentsDownload() {
        #expect(classify("https://example.com/build/release.zip") == .download)
        #expect(classify("https://example.com/Zephyr.dmg") == .download)
        #expect(classify("https://example.com/notes/report.docx") == .download)
        #expect(classify("https://example.com/deck.pptx") == .download)
        #expect(classify("https://example.com/data.tar.gz") == .download)
    }

    @Test func dataFilesDownloadDespiteConformingToText() {
        #expect(classify("https://data.example.com/run42.csv") == .download)
        #expect(classify("https://data.example.com/run42.tsv") == .download)
    }

    @Test func browserRenderedTypesStayPages() {
        #expect(classify("https://example.com/docs/index.html") == .page)
        #expect(classify("https://example.com/README.txt") == .page)
        #expect(classify("https://example.com/api/schema.json") == .page)
        #expect(classify("https://example.com/photo.jpg") == .page)
        #expect(classify("https://example.com/demo.mp4") == .page)
        #expect(classify("https://example.com/paper.pdf") == .page)
        #expect(classify("https://example.com/script.py") == .page)
    }

    @Test func extensionlessAndVersionPathsStayPages() {
        #expect(classify("https://example.com/download") == .page)
        #expect(classify("https://docs.example.com/release/v1.2") == .page)
        #expect(classify("https://github.com/foo/bar/releases/tag/v1.2b") == .page)
    }

    @Test func pageGeneratorSuffixesStayPages() {
        #expect(classify("https://example.com/list.aspx") == .page)
        #expect(classify("https://example.com/report.jsp") == .page)
    }

    @Test func unknownExtensionsAreAmbiguous() {
        #expect(classify("https://data.example.com/run42.dat") == .ambiguous)
        #expect(classify("https://data.example.com/model.npz") == .ambiguous)
    }

    @Test func nonWebSchemesStayPages() {
        #expect(classify("mailto:someone@example.com") == .page)
        #expect(classify("zephyr://narrow?channel=3") == .page)
    }

    @Test func queryStringsDoNotHideTheFile() {
        #expect(classify("https://example.com/report.zip?dl=1&sig=abc") == .download)
    }
}
