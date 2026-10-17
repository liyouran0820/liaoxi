"""聊析 Windows desktop application. Requires Python 3.12 x64 on Windows."""
from __future__ import annotations

import asyncio
import ctypes
import os
from pathlib import Path
import queue
import sys
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from archive_core import Cancelled


class App:
    def __init__(self, root):
        self.root = root
        self.root.title("聊析")
        self.root.geometry("820x680")
        self.root.minsize(720, 600)
        self.root.configure(background="#f5f8f5")
        self.events = queue.Queue()
        self.stop = threading.Event()
        self.sources = []
        self.targets = []
        self.result = None
        self.busy = False
        self.output = ""
        self.status = tk.StringVar(value="")
        self.file_label = tk.StringVar(value="已选择 0 个原文件")
        self.output_label = tk.StringVar(value="尚未选择导出位置")
        style = ttk.Style()
        style.theme_use("clam")
        style.configure("TFrame", background="#f5f8f5")
        style.configure("TLabel", background="#f5f8f5", font=("Microsoft YaHei UI", 11))
        style.configure("TButton", font=("Microsoft YaHei UI", 11), padding=(15, 10))
        style.configure("Primary.TButton", background="#143b29", foreground="white")
        style.map("Primary.TButton", background=[("active", "#24513a")])
        frame = ttk.Frame(root, padding=36)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="聊析", font=("Microsoft YaHei UI", 36, "bold")).pack(anchor="w")
        ttk.Label(frame, text="微信合并记录 · Markdown", foreground="#69736c").pack(anchor="w", pady=(0, 24))
        ttk.Label(frame, text="01  微信聊天记录", font=("Microsoft YaHei UI", 11, "bold")).pack(anchor="w")
        row = ttk.Frame(frame)
        row.pack(fill="x", pady=(10, 22))
        self.target = ttk.Combobox(row, state="readonly")
        self.target.pack(side="left", fill="x", expand=True, padx=(0, 12))
        self.refresh_button = ttk.Button(row, text="刷新窗口", command=self.refresh)
        self.refresh_button.pack(side="left")
        ttk.Label(frame, text="02  保存位置与附件", font=("Microsoft YaHei UI", 11, "bold")).pack(anchor="w")
        row = ttk.Frame(frame)
        row.pack(fill="x", pady=10)
        self.output_button = ttk.Button(row, text="选择位置", command=self.choose_output)
        self.output_button.pack(side="left", padx=(0, 15))
        ttk.Label(row, textvariable=self.output_label, wraplength=480).pack(side="left", fill="x", expand=True)
        row = ttk.Frame(frame)
        row.pack(fill="x", pady=(0, 22))
        self.add_button = ttk.Button(row, text="补充附件", command=self.add_files)
        self.add_button.pack(side="left", padx=(0, 15))
        ttk.Label(row, textvariable=self.file_label).pack(side="left")
        self.clear_button = ttk.Button(row, text="清空", command=self.clear_files)
        self.clear_button.pack(side="right")
        ttk.Label(frame, text="03  提取", font=("Microsoft YaHei UI", 11, "bold")).pack(anchor="w")
        ttk.Label(frame, text="打开合并聊天记录，保持窗口可见。", font=("Microsoft YaHei UI", 15, "bold")).pack(anchor="w", pady=12)
        row = ttk.Frame(frame)
        row.pack(fill="x")
        self.start_button = ttk.Button(row, text="开始提取", style="Primary.TButton", command=self.start)
        self.start_button.pack(side="left", padx=(0, 12))
        self.stop_button = ttk.Button(row, text="停止", command=self.stop.set, state="disabled")
        self.stop_button.pack(side="left", padx=(0, 12))
        self.reveal_button = ttk.Button(row, text="查看结果", command=self.reveal, state="disabled")
        self.reveal_button.pack(side="left")
        ttk.Label(frame, textvariable=self.status, wraplength=710).pack(anchor="w", pady=20)
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        self.root.after(100, self.poll)
        self.refresh()

    def choose_output(self):
        value = filedialog.askdirectory(title="选择导出位置")
        if value:
            self.output = value
            self.output_label.set(value)

    def add_files(self):
        values = filedialog.askopenfilenames(title="补充从微信保存的照片、视频和文档")
        self.sources = list(dict.fromkeys(self.sources + [Path(value) for value in values]))
        self.file_label.set(f"已选择 {len(self.sources)} 个原文件")

    def clear_files(self):
        self.sources.clear()
        self.file_label.set("已选择 0 个原文件")

    def refresh(self):
        if self.busy:
            return
        self.refresh_button.configure(state="disabled")
        self.status.set("正在查找打开的微信聊天记录窗口…")
        def worker():
            backend = None
            try:
                from windows_capture import WeChatCapture
                backend = WeChatCapture(lambda _: None, threading.Event())
                self.events.put(("targets", backend.windows()))
            except Exception as error:
                self.events.put(("error", str(error)))
            finally:
                if backend:
                    backend.close()
                self.events.put(("refreshed", None))
        threading.Thread(target=worker, daemon=True).start()

    def start(self):
        if self.busy:
            return
        index = self.target.current()
        if not self.output or not (0 <= index < len(self.targets)):
            self.status.set("请先选择微信聊天记录窗口和导出位置。")
            return
        self.stop.clear()
        self.set_busy(True)
        handle = self.targets[index][0]
        sources = list(self.sources)
        parent = self.output
        def worker():
            backend = None
            try:
                from windows_capture import WeChatCapture
                backend = WeChatCapture(lambda value: self.events.put(("status", value)), self.stop)
                report = asyncio.run(backend.run(handle, parent, sources))
                self.events.put(("result", report))
            except Cancelled as error:
                self.events.put(("error", str(error)))
            except Exception as error:
                self.events.put(("error", f"提取未完成：{error}"))
            finally:
                if backend:
                    backend.close()
                self.events.put(("done", None))
        threading.Thread(target=worker, daemon=True).start()

    def set_busy(self, busy):
        self.busy = busy
        for widget in [self.start_button, self.refresh_button, self.output_button, self.add_button, self.clear_button]:
            widget.configure(state="disabled" if busy else "normal")
        self.target.configure(state="disabled" if busy else "readonly")
        self.stop_button.configure(state="normal" if busy else "disabled")
        self.reveal_button.configure(state="disabled" if busy or self.result is None else "normal")

    def poll(self):
        try:
            while True:
                kind, value = self.events.get_nowait()
                if kind == "targets":
                    self.targets = value
                    self.target["values"] = [title for _, title in value]
                    if value:
                        self.target.current(0)
                    self.status.set("" if value else "未找到合并聊天记录。请在微信打开记录卡片后刷新。")
                elif kind in {"status", "error"}:
                    self.status.set(value)
                elif kind == "result":
                    self.result = value.folder
                    text = f"已保存 {value.line_count} 行文字、{value.image_count} 张照片、{value.video_count} 个视频、{value.file_count} 个文件。"
                    if value.warnings:
                        text += " 请查看 Markdown 文末附件提示。"
                    self.status.set(text)
                elif kind == "done":
                    self.set_busy(False)
                elif kind == "refreshed":
                    self.refresh_button.configure(state="normal")
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


def main():
    if sys.platform != "win32":
        raise SystemExit("这是 Windows 版本，请在 Windows 10/11 上运行。Mac 请打开聊析.app。")
    if "--self-test" in sys.argv:
        # Exercise native imports inside the packaged EXE, without touching user chats.
        import json
        from PIL import Image, ImageDraw, ImageFont
        from windows_capture import WeChatCapture
        backend = WeChatCapture(lambda _: None, threading.Event())
        try:
            backend.windows()
            image = Image.new("RGB", (640, 120), "white")
            ImageDraw.Draw(image).text((20, 20), "Hello world", fill="black",
                                      font=ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 40))
            lines = asyncio.run(backend.recognize(image))
            if not any("hello" in line.text.lower() for line in lines):
                raise RuntimeError("Packaged OCR did not recognize the test image")
            if "--self-test-report" in sys.argv:
                path = Path(sys.argv[sys.argv.index("--self-test-report") + 1])
                path.write_text(json.dumps({"status": "passed", "ocr": True, "uia": True}), encoding="utf-8")
        finally:
            backend.close()
        return
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)
    except OSError:
        ctypes.windll.user32.SetProcessDPIAware()
    root = tk.Tk()
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
