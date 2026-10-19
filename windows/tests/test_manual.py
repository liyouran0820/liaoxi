import sys
import tempfile
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from archive_core import Cancelled
from manual_archive import ManualAttachment, export_manual


class ManualTests(unittest.TestCase):
    def test_exact_text(self):
        with tempfile.TemporaryDirectory() as temp:
            text = 'A🙂\n\n> 引用\n```sh\n echo hello\n```\n重复\n重复'
            report = export_manual(temp, text)
            self.assertIn('## 对话内容\n\n' + text + '\n\n## 附件索引', report.markdown_path.read_text())
            self.assertEqual(report.folder.name, report.markdown_path.stem)

    def test_inline_files_dedup_and_collision(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'other').mkdir()
            files = [root / 'photo.jpg', root / 'alias.jpg', root / 'other/photo.jpg', root / 'movie.mp4']
            for file, data in zip(files, [b'same', b'same', b'different', b'video']):
                file.write_bytes(data)
            entries = [ManualAttachment(i + 1, file) for i, file in enumerate(files)]
            draft = 'A\n' + entries[0].token + '\nB\n' + '\n'.join(entry.token for entry in entries[1:])
            report = export_manual(root, draft, entries)
            md = report.markdown_path.read_text()
            self.assertIn('A\n[照片：photo.jpg](photo.jpg)\nB', md)
            self.assertIn('[照片：photo-2.jpg](photo-2.jpg)', md)
            self.assertIn('[视频：movie.mp4](movie.mp4)', md)
            self.assertNotIn('alias.jpg', md)
            self.assertNotIn('[[', md)
            self.assertEqual((report.image_count, report.video_count), (2, 1))
            self.assertEqual(len(list(report.folder.iterdir())), 4)
            self.assertTrue(all(file.exists() for file in files))
            self.assertEqual((report.folder / 'photo.jpg').read_bytes(), files[0].read_bytes())

    def test_missing_file_preserves_text(self):
        with tempfile.TemporaryDirectory() as temp:
            entry = ManualAttachment(1, Path(temp) / 'missing.pdf')
            report = export_manual(temp, 'A\n' + entry.token + '\nB', [entry])
            md = report.markdown_path.read_text()
            self.assertIn('A\n[附件未保存：missing.pdf]\nB', md)
            self.assertNotIn('](missing.pdf)', md)
            self.assertEqual(len(report.warnings), 1)

    def test_invalid_and_cancelled_create_nothing(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError):
                export_manual(temp, '  \n')
            stop = threading.Event()
            stop.set()
            with self.assertRaises(Cancelled):
                export_manual(temp, 'A', stop=stop)
            self.assertEqual(list(Path(temp).iterdir()), [])
