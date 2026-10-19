"""聊析：手动粘贴聊天内容并整理附件。启动不读取微信、不截图、不做 OCR。"""
from __future__ import annotations

import ctypes
import os
from pathlib import Path
import queue
import sys
import threading

from archive_core import Cancelled
from manual_archive import ManualAttachment, export_manual


class App:
    def __init__(self, root):
        self.root = root
        root.title("聊析")
        root.geometry("860x780")
        root.minsize(720, 650)
        root.configure(background="#f5f8f5")
        self.events = queue.Queue()
        self.stop = threading.Event()
        self.attachments = []
        self.result = None
        self.busy = False
        self.output = ""
        self.status = tk.StringVar()
        self.file_label = tk.StringVar(value="0 个附件")
        self.output_label = tk.StringVar(value="尚未选择导出位置")
        style = ttk.Style()
        style.theme_use("clam")
        style.configure("TFrame", background="#f5f8f5")
        style.configure("TLabel", background="#f5f8f5", font=("Microsoft YaHei UI", 11))
        style.configure("TButton", font=("Microsoft YaHei UI", 11), padding=(15, 9))
        style.configure("Primary.TButton", background="#143b29", foreground="white")
        frame = ttk.Frame(root, padding=30)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="聊析", font=("Microsoft YaHei UI", 32, "bold")).pack(anchor="w")
        ttk.Label(frame, text="手动粘贴 · Markdown", foreground="#69736c").pack(anchor="w", pady=(0, 16))
        row = ttk.Frame(frame)
        row.pack(fill="x", pady=(0, 10))
        ttk.Label(row, text="01  聊天内容", font=("Microsoft YaHei UI", 11, "bold")).pack(side="left")
        self.add_button = ttk.Button(row, text="补充附件", command=self.add_files)
        self.add_button.pack(side="right")
        self.paste_button = ttk.Button(row, text="粘贴", command=self.paste)
        self.paste_button.pack(side="right", padx=10)
        self.editor = ScrolledText(frame, wrap="word", undo=True, font=("Microsoft YaHei UI", 12), padx=12, pady=12, height=12)
        self.editor.pack(fill="both", expand=True)
        row = ttk.Frame(frame)
        row.pack(fill="x", pady=8)
        ttk.Label(row, textvariable=self.file_label).pack(side="left")
        self.clear_button = ttk.Button(row, text="清空附件", command=self.clear_files)
        self.clear_button.pack(side="right")
        row = ttk.Frame(frame)
        row.pack(fill="x", pady=12)
        self.output_button = ttk.Button(row, text="选择位置", command=self.choose_output)
        self.output_button.pack(side="right")
        ttk.Label(row, textvariable=self.output_label, wraplength=560).pack(side="left")
        row = ttk.Frame(frame)
        row.pack(fill="x", pady=8)
        self.start_button = ttk.Button(row, text="导出 Markdown", style="Primary.TButton", command=self.start)
        self.start_button.pack(side="left")
        self.stop_button = ttk.Button(row, text="停止", command=self.stop.set, state="disabled")
        self.stop_button.pack(side="left", padx=10)
        self.reveal_button = ttk.Button(row, text="查看结果", command=self.reveal, state="disabled")
        self.reveal_button.pack(side="left")
        ttk.Label(frame, textvariable=self.status, wraplength=760).pack(anchor="w", pady=(8, 0))
        root.protocol("WM_DELETE_WINDOW", self.close)
        root.after(100, self.poll)

    def choose_output(self):
        value = filedialog.askdirectory(title="选择导出位置")
        if value:
            self.output = value
            self.output_label.set(value)

    def paste(self):
        try:
            text = self.root.clipboard_get()
        except tk.TclError:
            self.status.set("剪贴板中没有文字。图片和文件请用“补充附件”。")
            return
        if self.editor.tag_ranges(tk.SEL):
            self.editor.delete(tk.SEL_FIRST, tk.SEL_LAST)
        self.editor.insert(tk.INSERT, text)
        self.editor.focus_set()

    def add_files(self):
        insertion = self.editor.index(tk.INSERT)
        paths = filedialog.askopenfilenames(title="补充照片、视频和文档")
        entries = []
        for raw in paths:
            file = Path(raw)
            entry = next((a for a in self.attachments if a.source.resolve() == file.resolve()), None)
            if entry is None:
                entry = ManualAttachment(max((a.id for a in self.attachments), default=0) + 1, file)
                self.attachments.append(entry)
            entries.append(entry)
        if not entries:
            return
        before = self.editor.get("1.0", insertion)
        after = self.editor.get(insertion, "end-1c")
        block = "\n\n".join(entry.token for entry in entries)
        if before and not before.endswith("\n"):
            block = "\n\n" + block
        block += "\n\n" if after and not after.startswith("\n") else "\n"
        self.editor.insert(insertion, block)
        self.file_label.set(f"{len(self.attachments)} 个附件")
        self.editor.focus_set()

    def clear_files(self):
        text = self.editor.get("1.0", "end-1c")
        for entry in self.attachments:
            text = text.replace(entry.token, "")
        self.editor.delete("1.0", "end")
        self.editor.insert("1.0", text)
        self.attachments.clear()
        self.file_label.set("0 个附件")

    def start(self):
        if self.busy:
            return
        draft = self.editor.get("1.0", "end-1c")
        if not self.output:
            self.status.set("请先选择导出位置。")
            return
        if not draft.strip() and not self.attachments:
            self.status.set("请先粘贴聊天文字或添加附件。")
            return
        self.stop.clear()
        self.set_busy(True)
        self.status.set("正在保存 Markdown 与附件…")
        parent, attachments = self.output, list(self.attachments)

        def worker():
            try:
                self.events.put(("result", export_manual(parent, draft, attachments, self.stop)))
            except Exception as error:
                self.events.put(("error", str(error)))
            finally:
                self.events.put(("done", None))
        threading.Thread(target=worker, daemon=True).start()

    def set_busy(self, busy):
        self.busy = busy
        for widget in [self.start_button, self.paste_button, self.output_button, self.add_button, self.clear_button]:
            widget.configure(state="disabled" if busy else "normal")
        self.editor.configure(state="disabled" if busy else "normal")
        self.stop_button.configure(state="normal" if busy else "disabled")
        self.reveal_button.configure(state="disabled" if busy or self.result is None else "normal")

    def poll(self):
        try:
            while True:
                kind, value = self.events.get_nowait()
                if kind == "error":
                    self.status.set(value)
                elif kind == "result":
                    self.result = value.folder
                    self.status.set(f"已保存 {value.line_count} 行文字、{value.image_count} 张照片、{value.video_count} 个视频、{value.file_count} 个文件。"
                                    + (" 请查看文末附件提示。" if value.warnings else ""))
                elif kind == "done":
                    self.set_busy(False)
        except queue.Empty:
            pass
        self.root.after(100, self.poll)

    def reveal(self):
        if self.result:
            os.startfile(self.result)

    def close(self):
        if self.busy:
            self.stop.set()
            self.status.set("正在停止，请稍候…")
            self.root.after(250, self.close)
        else:
            self.root.destroy()


def self_test():
    import json
    import tempfile
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        file = root / "sample.txt"
        file.write_bytes(b"manual attachment")
        entry = ManualAttachment(1, file)
        report = export_manual(root, f"A：手动测试\n\n{entry.token}\n\nB：收到。", [entry])
        md = report.markdown_path.read_text(encoding="utf-8")
        assert "A：手动测试" in md and "B：收到。" in md and "(sample.txt)" in md
        assert (report.folder / file.name).read_bytes() == file.read_bytes()
    if "--self-test-report" in sys.argv:
        path = Path(sys.argv[sys.argv.index("--self-test-report") + 1])
        path.write_text(json.dumps({"status": "passed", "mode": "manual", "ocr": False, "screen_capture": False, "attachments": True}), encoding="utf-8")


def main():
    if "--self-test" in sys.argv:
        self_test()
        return
    if sys.platform != "win32":
        raise SystemExit("这是 Windows 版本；Mac 请打开聊析.app。")
    global tk, ttk, filedialog, ScrolledText
    import tkinter as tk
    from tkinter import ttk, filedialog
    from tkinter.scrolledtext import ScrolledText
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)
    except OSError:
        ctypes.windll.user32.SetProcessDPIAware()
    root = tk.Tk()
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
