import sys
import tempfile
import threading
import unittest
from pathlib import Path
import re
from urllib.parse import unquote

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from archive_core import Cancelled, Line, digest, export_archive, mark_quotes, merge_pages, safe_name


class ArchiveTests(unittest.TestCase):
    def test_flat_archive_integrity_duplicate_and_collision(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "inputs"
            source.mkdir()
            second = source / "second"
            second.mkdir()
            files = []
            for index, name in enumerate(["照片 #1.png", "video.mp4", "conversation.md", "plan.pdf"]):
                path = source / name
                path.write_bytes(f"original-{index}".encode())
                files.append(path)
            collision = second / "plan.pdf"
            collision.write_bytes(b"another original")
            report = export_archive(root, [Line("这是回复"), Line("张三：引用内容", quoted=True)], files + [collision, files[0]])
            names = {path.name for path in report.folder.iterdir()}
            self.assertEqual(names, {"conversation.md", "照片 #1.png", "video.mp4", "conversation-2.md", "plan.pdf", "plan-2.pdf"})
            for path in files:
                name = "conversation-2.md" if path.name == "conversation.md" else path.name
                self.assertEqual(digest(path), digest(report.folder / name))
            md = (report.folder / "conversation.md").read_text(encoding="utf-8")
            self.assertIn("%20%231.png)", md)
            self.assertIn("[video.mp4](video.mp4)", md)
            self.assertIn("\n\n> 张三：引用内容", md)
            self.assertEqual((report.image_count, report.video_count, report.file_count), (1, 1, 3))
            moved = root / "移动后的记录"
            report.folder.rename(moved)
            for link in re.findall(r"\]\(([^)]+)\)", md):
                self.assertTrue((moved / unquote(link)).is_file())

    def test_missing_file_not_success(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            report = export_archive(root, [Line("missing.pdf")], [root / "missing.pdf"])
            self.assertEqual(report.file_count, 0)
            self.assertTrue(report.warnings)
            self.assertIn("未保存的附件", (report.folder / "conversation.md").read_text(encoding="utf-8"))

    def test_stop_leaves_no_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            stop = threading.Event()
            stop.set()
            with self.assertRaises(Cancelled):
                export_archive(root, [], [], stop=stop)
            self.assertEqual(list(root.iterdir()), [])

    def test_quotes_and_repeated_message_are_distinct(self):
        lines = mark_quotes([Line("昵称", .1, .1, .2, .02, muted=True),
                             Line("2026年10月18日 00:09", .7, .1, .2, .02, muted=True),
                             Line("正文", .1, .2, .2, .03),
                             Line("张三：引用内容", .1, .25, .5, .025, muted=True),
                             Line("引用续行", .1, .28, .5, .025, muted=True),
                             Line("下一条正文", .1, .4, .5, .025)])
        self.assertEqual([line.quoted for line in lines], [False, False, False, True, True, False])
        merged = merge_pages([[Line("开始"), Line("重复")], [Line("重复"), Line("重复"), Line("结束")]])
        self.assertEqual([line.text for line in merged], ["开始", "重复", "重复", "结束"])

    def test_invalid_names(self):
        self.assertNotIn("/", safe_name("../x.pdf"))
        self.assertEqual(safe_name("CON.txt"), "_CON.txt")


@unittest.skipUnless(sys.platform == "win32", "Windows runtime check requires Windows")
class WindowsRuntimeTests(unittest.TestCase):
    def test_local_ocr_and_uia(self):
        import asyncio
        from PIL import Image, ImageDraw, ImageFont
        from windows_capture import WeChatCapture
        backend = WeChatCapture(lambda _: None, threading.Event())
        try:
            backend.windows()
            image = Image.new("RGB", (600, 120), "white")
            font = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 40)
            ImageDraw.Draw(image).text((20, 20), "Hello world", fill="black", font=font)
            lines = asyncio.run(backend.recognize(image))
            self.assertTrue(any("hello" in line.text.lower() for line in lines))
        finally:
            backend.close()


if __name__ == "__main__":
    unittest.main()
