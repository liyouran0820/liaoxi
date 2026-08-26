import XCTest
@testable import ChatArchive

final class ContentProcessorTests: XCTestCase {
    func testMergesOverlappingOCRPages() {
        let processor = ContentProcessor()
        let pageOne = [
            RecognizedLine(text: "张三", bounds: .zero, confidence: 1),
            RecognizedLine(text: "先安装 Homebrew", bounds: .zero, confidence: 1),
            RecognizedLine(text: "然后打开终端", bounds: .zero, confidence: 1)
        ]
        let pageTwo = [
            RecognizedLine(text: "然后打开终端", bounds: .zero, confidence: 1),
            RecognizedLine(text: "brew install node", bounds: .zero, confidence: 1)
        ]

        XCTAssertEqual(
            processor.mergePages([pageOne, pageTwo]),
            ["张三", "先安装 Homebrew", "然后打开终端", "brew install node"]
        )
    }

    func testPrefersAccessibilityWhenItContainsEnoughText() {
        let result = ContentProcessor().chooseText(
            accessibility: ["这是一段来自辅助功能树的完整聊天正文，能够避免 OCR 对代码和英文命令造成识别错误。"],
            ocr: ["这是一段 OCR 文字", "可能有误"]
        )
        XCTAssertTrue(result.usedAccessibility)
    }

    func testFindsFileCards() {
        let names = ContentProcessor().likelyFileNames(in: ["请查看 项目说明.pdf", "配置 config.yaml"])
        XCTAssertEqual(names, ["项目说明.pdf", "config.yaml"])
    }

    func testFiltersAccessibilityTextThatIsNotVisibleInCapture() {
        let processor = ContentProcessor()
        let ocr = [
            RecognizedLine(text: "然后打开终端", bounds: .zero, confidence: 1),
            RecognizedLine(text: "brew install node", bounds: .zero, confidence: 1)
        ]
        XCTAssertEqual(
            processor.visibleAccessibilityText(["文件传输助手", "然后打开终端", "通讯录"], matching: ocr),
            ["然后打开终端"]
        )
    }
}
