import sys
import tempfile
import threading
import unittest
from pathlib import Path
import re
from urllib.parse import unquote

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from archive_core import AttachmentPosition, Cancelled, Line, archive_workspace, digest, export_archive, is_merged_record_title, mark_quotes, merge_pages, resolve_attachment_positions, safe_name


class ArchiveTests(unittest.TestCase):
    def test_position_metadata_does_not_replace_any_message(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            photo = root / 'photo.jpg'
            photo.write_bytes(b'photo')
            texts = ['Alice', '时间A', '照片前的消息', 'Bob', '时间B', '照片后的消息', '笑死我了', '再次回复', '笑死我了', '张三：引用内容']
            lines = [Line(t, quoted=t.startswith('张三：')) for t in texts]
            original = list(lines)
            position = AttachmentPosition(photo, tuple(texts[:3]), tuple(texts[3:9]))
            report = export_archive(root, lines, [photo], attachment_positions=[position])
            md = report.markdown_path.read_text()
            body = md.split('## 对话内容\n\n', 1)[1].split('## 附件', 1)[0]
            extracted = [t.strip().removeprefix('> ') for t in body.splitlines() if t.strip() and not t.startswith('[照片：')]
            self.assertEqual(extracted, texts)
            self.assertEqual(lines, original)
            self.assertEqual(report.line_count, len(lines))
            self.assertIn('照片前的消息  \n\n[照片：photo.jpg](photo.jpg)  \n\nBob', body)

    def test_ambiguous_position_is_not_guessed(self):
        lines = [Line(t) for t in ['Alice', '时间A', 'Alice', '时间A']]
        position = AttachmentPosition(Path('/tmp/image.jpg'), ('Alice', '时间A'))
        self.assertEqual(resolve_attachment_positions([position], lines), {})

    def test_same_file_at_distinct_positions_and_alias_dedup(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            photo, alias = root / 'photo.jpg', root / 'alias.jpg'
            photo.write_bytes(b'same photo')
            alias.write_bytes(b'same photo')
            texts = ['Alice', '时间A', '消息A', 'Bob', '时间B', '消息B']
            positions = [AttachmentPosition(file, tuple(texts[:3]), tuple(texts[3:])) for file in [photo, alias]]
            positions.append(AttachmentPosition(photo, tuple(texts)))
            report = export_archive(root, [Line(t) for t in texts], [photo, alias], attachment_positions=positions)
            md = report.markdown_path.read_text()
            body = md.split('## 对话内容\n\n', 1)[1].split('## 附件', 1)[0]
            self.assertEqual(body.count('[照片：photo.jpg]'), 2)
            self.assertNotIn('alias.jpg', md)
            self.assertEqual(report.image_count, 1)

    def test_headers_and_ocr_nickname_do_not_duplicate_messages(self):
        first = ["●", "Alice和Bob的聊天记录", "••●", "Alice01", "2026年10月18日 22:44", "请先保存全部原始附件", "Alice01", "2026年10月18日 22:45", "然后检查目录里的文件"]
        second = ["Alice和Bob的聊天记录", "•••", "Alice0l", "2026年10月18日22:44", "请先保存全部原始附件", "Alice01", "2026年10月18日 22:45", "然后检查目录里的文件", "Bob", "2026年10月18日 22:46", "这是下一条消息"]
        third = ["Alice和Bob的聊天记录", "•••", "Bob", "2026年10月18日 22:46", "这是下一条消息", "Alice01", "2026年10月18日 22:47", "请先保存全部原始附件", "👍"]
        result = merge_pages([[Line(text) for text in page] for page in [first, second, third]])
        self.assertEqual([line.text for line in result], first[3:] + second[-3:] + third[-4:])

    def test_overlap_keeps_missing_lines_and_distinct_times(self):
        first = ["Alice01", "2026年10月18日 22:44", "请先保存全部原始附件", "然后检查目录里的文件"]
        second = ["Alice0l", "2026年10月18日22:44", "请先保存全部原始附件", "中间新识别到的内容", "然后检查目录里的文件", "结束"]
        result = merge_pages([[Line(text) for text in page] for page in [first, second]])
        self.assertEqual([line.text for line in result], first[:3] + second[3:])
        later = ["Alice01", "2026年10月18日 22:45", "请先保存全部原始附件", "然后检查目录里的文件", "新消息"]
        result = merge_pages([[Line(text) for text in page] for page in [first, later]])
        self.assertEqual([line.text for line in result], first + later)

    def test_body_heading_and_emoji_are_not_window_chrome(self):
        lines = [Line("某人的聊天记录", y=.4, height=.03), Line("👍", y=.5, height=.03)]
        self.assertEqual(merge_pages([lines]), lines)
        self.assertEqual([x.text for x in merge_pages([[Line("👍")], [Line("👎")]])], ["👍", "👎"])

    def test_corrupted_sender_and_clipped_time_use_aligned_context(self):
        first = ["Alice01", "2026年10月18日 22:47", "请先保存全部原始附件", "Bob", "2026年10月18日 22:48", "然后检查目录里的文件"]
        second = ["TayToTK", "2020年10月18日 22:4/", "请先保存全部原始附件", "Bob", "2026年10月18日 22:48", "然后检查目录里的文件", "新增消息"]
        result = merge_pages([[Line(text) for text in page] for page in [first, second]])
        self.assertEqual([line.text for line in result], first + ["新增消息"])

    def test_similar_commands_are_not_ocr_nickname_duplicates(self):
        first = ["共同上下文第一行内容", "共同上下文第二行内容", "共同上下文第三行内容", "run --level=1"]
        second = ["共同上下文第一行内容", "共同上下文第二行内容", "共同上下文第三行内容", "run --level=2", "结束"]
        merged = [line.text for line in merge_pages([[Line(text) for text in page] for page in [first, second]])]
        self.assertIn("run --level=1", merged)
        self.assertIn("run --level=2", merged)

    def test_collected_and_imported_duplicates_keep_only_one(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            imported = root / "manual.jpg"
            imported.write_bytes(b"same original")
            with archive_workspace(root) as folder:
                first, repeated = folder / "saved.jpg", folder / "overlap.jpg"
                first.write_bytes(b"same original")
                repeated.write_bytes(b"same original")
                report = export_archive(root, [], [imported, first, repeated, repeated], existing_directory=folder)
                self.assertEqual(report.image_count, 1)
                self.assertFalse(report.warnings)
                self.assertEqual({p.name for p in folder.iterdir()}, {report.markdown_path.name, "saved.jpg"})
                self.assertTrue(imported.is_file())

    def test_search_window_is_not_merged_record(self):
        self.assertFalse(is_merged_record_title("搜索聊天记录"))
        self.assertFalse(is_merged_record_title("Search chat history"))
        self.assertTrue(is_merged_record_title("张三和李四的聊天记录"))

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
            self.assertEqual(names, {report.markdown_path.name, "照片 #1.png", "video.mp4", "conversation.md", "plan.pdf", "plan-2.pdf"})
            self.assertEqual(report.markdown_path.stem, report.folder.name)
            for path in files:
                name = path.name
                self.assertEqual(digest(path), digest(report.folder / name))
            md = report.markdown_path.read_text(encoding="utf-8")
            self.assertIn("%20%231.png)", md)
            self.assertIn("[视频：video.mp4](video.mp4)", md)
            self.assertNotIn("![", md)
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
            self.assertIn("未保存的附件", report.markdown_path.read_text(encoding="utf-8"))

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

    def test_direct_workspace_keeps_original_and_does_not_duplicate(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with archive_workspace(root) as folder:
                photo = folder / "direct.png"
                photo.write_bytes(b"original photo bytes")
                report = export_archive(root, [Line("正文")], [photo], existing_directory=folder)
                self.assertEqual(report.folder, folder)
                self.assertEqual(report.image_count, 1)
                self.assertEqual({f.name for f in folder.iterdir()}, {folder.name + ".md", "direct.png"})


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

    def test_photo_words_never_enter_chat_ocr(self):
        import asyncio
        from PIL import Image, ImageDraw, ImageFont
        from windows_capture import WeChatCapture
        class Rect:
            left, top, right, bottom = 0, 0, 560, 720
            def width(self): return 560
            def height(self): return 720
        class Window:
            def rectangle(self): return Rect()
            def descendants(self, **kwargs): return []
        backend = WeChatCapture(lambda _: None, threading.Event())
        try:
            image = Image.new("RGB", (560, 720), (250, 250, 250))
            drawing = ImageDraw.Draw(image)
            font = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 24)
            drawing.rectangle((72, 150, 320, 400), fill=(30, 100, 180))
            drawing.text((85, 240), "SECRET PHOTO", fill="white", font=font)
            drawing.text((72, 500), "Hello body", fill="black", font=font)
            regions = backend.media_regions(Window(), image)
            self.assertTrue(regions)
            for x, y, w, h in regions:
                drawing.rectangle((int(x*560), int(y*720), int((x+w)*560), int((y+h)*720)), fill="white")
            text = " ".join(line.text for line in asyncio.run(backend.recognize(image)))
            self.assertIn("hello", text.lower())
            self.assertNotIn("SECRET", text.upper())
        finally:
            backend.close()


if __name__ == "__main__":
    unittest.main()
