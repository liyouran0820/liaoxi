"""Windows-only UIA, native OCR and visible WeChat attachment collection."""
from __future__ import annotations

import io
from pathlib import Path
import re
import sys
import uuid

from archive_core import AttachmentPosition, Line, archive_workspace, check_cancel, digest, export_archive, file_names, is_merged_record_title, key, mark_quotes, merge_pages, unique_path


class WeChatCapture:
    def __init__(self, progress, stop):
        # Import on the worker thread and initialize COM there, not on Tk's thread.
        sys.coinit_flags = 0
        import pythoncom
        pythoncom.CoInitializeEx(0)
        from winrt.runtime import init_apartment, ApartmentType
        init_apartment(ApartmentType.MULTI_THREADED)
        from pywinauto import Desktop, keyboard, mouse
        from PIL import ImageGrab
        self.desktop = Desktop(backend="uia")
        self.keyboard, self.mouse, self.grab = keyboard, mouse, ImageGrab
        self.progress, self.stop = progress, stop

    def close(self):
        import pythoncom
        from winrt.runtime import uninit_apartment
        uninit_apartment()
        pythoncom.CoUninitialize()

    def windows(self):
        import psutil
        result = []
        for window in self.desktop.windows(visible_only=True):
            try:
                process = psutil.Process(window.process_id()).name().lower()
                title = window.window_text()
                if process in {"wechat.exe", "weixin.exe"} and is_merged_record_title(title):
                    rect = window.rectangle()
                    if rect.width() >= 300 and rect.height() >= 300:
                        result.append((window.handle, title))
            except (OSError, psutil.Error, RuntimeError):
                continue
        return result

    def window(self, handle):
        if handle not in {h for h, _ in self.windows()}:
            raise RuntimeError("选中的微信聊天记录已关闭。请重新打开合并记录并刷新窗口列表。")
        return self.desktop.window(handle=handle).wrapper_object()

    def activate(self, window):
        check_cancel(self.stop)
        if window.is_minimized():
            window.restore()
        window.set_focus()
        self.pause(.2)

    def pause(self, seconds):
        if self.stop.wait(seconds):
            check_cancel(self.stop)

    def capture(self, window):
        import win32gui
        self.activate(window)
        if win32gui.GetForegroundWindow() != window.handle:
            raise RuntimeError("无法将选中的微信记录置于前台。请关闭遮挡窗口后重试。")
        rect = window.rectangle()
        return self.grab.grab(bbox=(rect.left, rect.top, rect.right, rect.bottom), all_screens=True).convert("RGB")

    def scroll(self, window, wheel_dist):
        self.activate(window)
        rect = window.rectangle()
        self.mouse.scroll(coords=(rect.left + rect.width() // 2, rect.top + rect.height() // 2), wheel_dist=wheel_dist)
        self.pause(.5)

    async def recognize(self, image):
        from winrt.windows.globalization import Language
        from winrt.windows.media.ocr import OcrEngine
        from winrt.windows.graphics.imaging import BitmapDecoder, BitmapPixelFormat, BitmapAlphaMode
        from winrt.windows.storage.streams import DataWriter, InMemoryRandomAccessStream
        engine = OcrEngine.try_create_from_language(Language("zh-Hans")) or OcrEngine.try_create_from_user_profile_languages()
        if engine is None:
            raise RuntimeError("Windows 尚未安装 OCR 语言。请在“设置 → 时间和语言 → 语言”添加中文或英语语言功能。")
        scale = min(1, OcrEngine.max_image_dimension / max(image.size))
        if scale < 1:
            image = image.resize((int(image.width * scale), int(image.height * scale)))
        data = io.BytesIO()
        image.save(data, format="PNG")
        stream = InMemoryRandomAccessStream()
        writer = DataWriter(stream)
        bitmap = None
        try:
            writer.write_bytes(data.getvalue())
            await writer.store_async()
            writer.detach_stream()
            stream.seek(0)
            decoder = await BitmapDecoder.create_async(stream)
            bitmap = await decoder.get_software_bitmap_converted_async(BitmapPixelFormat.BGRA8, BitmapAlphaMode.PREMULTIPLIED)
            result = await engine.recognize_async(bitmap)
            lines = []
            for line in result.lines:
                words = list(line.words)
                if not words:
                    continue
                x = min(w.bounding_rect.x for w in words)
                y = min(w.bounding_rect.y for w in words)
                right = max(w.bounding_rect.x + w.bounding_rect.width for w in words)
                bottom = max(w.bounding_rect.y + w.bounding_rect.height for w in words)
                pixels = sorted(v for v in image.crop((int(x), int(y), int(right), int(bottom))).convert("L").getdata() if v < 225)
                muted = bool(pixels) and pixels[len(pixels) // 3] >= 112
                lines.append(Line(line.text.strip(), x / image.width, y / image.height,
                                  (right - x) / image.width, (bottom - y) / image.height, muted))
            return mark_quotes(sorted(lines, key=lambda l: (round(l.y / .012), l.x)))
        finally:
            if bitmap is not None:
                bitmap.close()
            writer.close()
            stream.close()

    def accessible_text(self, window, lines):
        from dataclasses import replace
        rect = window.rectangle()
        candidates = []
        for item in window.descendants(control_type="Text")[:4000]:
            try:
                box = item.rectangle()
                text = item.window_text().strip()
                if item.is_visible() and text and rect_contains(rect, box):
                    candidates.append((box, text))
            except Exception:
                continue
        # Keep OCR's geometry and quote attributes; replace only text proven to match.
        output = []
        used = False
        for line in lines:
            match = next((text for box, text in candidates if key(text) == key(line.text)
                          and abs((box.top - rect.top) / rect.height() - line.y) < .04), None)
            output.append(replace(line, text=match) if match else line)
            used |= match is not None
        return output, used

    def media_regions(self, window, image):
        import cv2
        import numpy as np
        regions = []
        rect = window.rectangle()
        for control in window.descendants(control_type="Image")[:100]:
            box = control.rectangle()
            if box.width() > rect.width() * .16 and box.height() > 50 and rect_contains(rect, box):
                regions.append(((box.left - rect.left) / rect.width(), (box.top - rect.top) / rect.height(),
                                box.width() / rect.width(), box.height() / rect.height()))
        # Pixel components handle rounded thumbnails, tall photos and video cards without reading their text.
        small = image.resize((360, max(4, int(image.height * 360 / image.width))))
        array = np.asarray(small, dtype=np.int16)
        height, width = array.shape[:2]
        background = np.median(array[height // 6:height * 9 // 10, width * 95 // 100, :], axis=0)
        ink = (np.max(np.abs(array - background), axis=2) > 35).astype(np.uint8)
        joined = cv2.dilate(ink, np.ones((3, 3), np.uint8))
        count, _, stats, _ = cv2.connectedComponentsWithStats(joined)
        for index in range(1, count):
            x, y, w, h, _ = stats[index]
            density = np.count_nonzero(ink[y:y+h, x:x+w]) / (w * h)
            area = w * h / (width * height)
            if w / width >= .12 and h / height >= .045 and x / width >= .07 and (x+w) / width < .95 and y / height > .09 and .007 <= area < .65 and density > .16:
                left, top = max(0, x-2), max(0, y-2)
                right, bottom = min(width, x+w+2), min(height, y+h+2)
                if not any(abs(left / width - a) < .03 and abs(top / height - b) < .03 for a, b, _, _ in regions):
                    regions.append((left / width, top / height, (right-left) / width, (bottom-top) / height))
        return regions[:20]

    async def save_candidate(self, window, x, y, temporary: Path):
        """Only invoke Save As. Never double click/launch file contents."""
        self.activate(window)
        rect = window.rectangle()
        self.mouse.click(button="right", coords=(rect.left + int(x * rect.width()), rect.top + int(y * rect.height())))
        self.pause(.25)
        menu_items = []
        for top in self.desktop.windows(process=window.process_id()):
            menu_items.extend(top.descendants(control_type="MenuItem"))
        allowed = {"另存为", "保存为", "保存图片", "保存视频", "Save As", "Save as", "Save Image As", "Save Video As"}
        normalize_title = lambda text: re.sub(r"[.…&]|\([A-Za-z]\)|（[A-Za-z]）", "", text).strip()
        save = next((item for item in menu_items if normalize_title(item.window_text()) in allowed
                     and item.is_enabled() and item.is_visible()), None)
        save_point = None
        copy_point = None
        if save is None and not any(normalize_title(item.window_text()) in {"复制", "Copy", "复制图片", "Copy Image"}
                                    and item.is_enabled() and item.is_visible() for item in menu_items):
            px, py = rect.left + int(x * rect.width()), rect.top + int(y * rect.height())
            bounds = (max(rect.left, px-220), max(rect.top, py-20), min(rect.right, px+300), min(rect.bottom, py+420))
            menu_image = self.grab.grab(bbox=bounds, all_screens=True).convert("RGB")
            menu_lines = await self.recognize(menu_image)
            recognized = [line for line in menu_lines if re.sub(r"[.…&]|\([A-Za-z]\)", "", line.text).strip() in allowed | {"复制", "Copy", "转发", "收藏", "删除", "多选", "Forward", "Delete"}]
            if len(recognized) >= 2:
                for line in recognized:
                    title = re.sub(r"[.…&]|\([A-Za-z]\)", "", line.text).strip()
                    point = (bounds[0] + int((line.x + line.width / 2) * menu_image.width), bounds[1] + int((line.y + line.height / 2) * menu_image.height))
                    if title in allowed and save_point is None:
                        save_point = point
                    elif title in {"复制", "Copy"} and copy_point is None:
                        copy_point = point
        if save is None and save_point is None:
            copy = next((item for item in menu_items if normalize_title(item.window_text()) in {"复制", "Copy", "复制图片", "Copy Image"}
                         and item.is_enabled() and item.is_visible()), None)
            if copy is not None or copy_point is not None:
                return self.copy_candidate(copy, temporary, copy_point)
            self.mouse.click(coords=(rect.left + rect.width() // 2, rect.top + 55))
            return []
        if save_point:
            self.mouse.click(coords=save_point)
        else:
            save.click_input()
        dialog = None
        for _ in range(30):
            check_cancel(self.stop)
            for top in self.desktop.windows(process=window.process_id()):
                title = top.window_text().casefold()
                if top.handle != window.handle and ("另存" in title or "保存" in title or "save" in title):
                    dialog = top
                    break
            if dialog:
                break
            self.pause(.1)
        if dialog is None:
            # Do not press Enter blindly when WeChat did not present a save dialog.
            return []
        check_cancel(self.stop)
        edits = dialog.descendants(control_type="Edit")
        filename = next((edit for edit in edits if edit.element_info.automation_id in {"1001", "1148"}), None)
        if filename is None:
            filename = next((edit for edit in edits if "文件名" in edit.element_info.name or "file name" in edit.element_info.name.lower()), None)
        if filename is None:
            self.cancel_save_dialog(dialog)
            return []
        old = filename.get_value().strip('"')
        if not old:
            self.cancel_save_dialog(dialog)
            return []
        before = {p.name for p in temporary.iterdir()}
        destination = unique_path(temporary, f"media-{uuid.uuid4().hex[:8]}-" + Path(old).name)
        filename.set_edit_text(str(destination))
        buttons = dialog.descendants(control_type="Button")
        button = next((b for b in buttons if b.element_info.automation_id == "1" or b.window_text().replace("&", "") in {"保存", "保存(S)", "Save", "Save(S)"}), None)
        if button is None:
            self.cancel_save_dialog(dialog)
            return []
        button.click_input()
        last_size = -1
        last_name = ""
        stable = 0
        for _ in range(600):
            self.pause(.2)
            file = next((p for p in temporary.iterdir() if p.name not in before and p.is_file()
                         and p.suffix.lower() not in {".tmp", ".part", ".download"}), None)
            if file:
                size = file.stat().st_size
                stable = stable + 1 if size > 0 and size == last_size and file.name == last_name else 0
                last_size = size
                last_name = file.name
                if stable >= 15:
                    return [file]
        self.cancel_save_dialog(dialog)
        return []

    def cancel_save_dialog(self, dialog):
        try:
            cancel = next((b for b in dialog.descendants(control_type="Button")
                           if b.element_info.automation_id == "2" or b.window_text().replace("&", "") in {"取消", "Cancel"}), None)
            if cancel:
                cancel.click_input()
        except Exception:
            pass

    def copy_candidate(self, item, temporary, point=None):
        import win32clipboard as clipboard
        import shutil
        from PIL import Image
        # Only use Copy when we can preserve the prior clipboard's ordinary formats.
        snapshot = []
        clipboard.OpenClipboard()
        try:
            fmt = 0
            while True:
                fmt = clipboard.EnumClipboardFormats(fmt)
                if not fmt:
                    break
                data = clipboard.GetClipboardData(fmt)
                if not isinstance(data, (str, bytes)):
                    self.keyboard.send_keys("{ESC}")
                    return []
                snapshot.append((fmt, data))
        except Exception:
            self.keyboard.send_keys("{ESC}")
            return []
        finally:
            clipboard.CloseClipboard()
        before = win32clipboard_sequence()
        own_sequence = before
        result = []
        try:
            if point:
                self.mouse.click(coords=point)
            else:
                item.click_input()
            for _ in range(15):
                self.stop.wait(.1)
                own_sequence = win32clipboard_sequence()
                check_cancel(self.stop)
                if own_sequence != before:
                    break
            if own_sequence == before:
                return []
            content = self.grab.grabclipboard()
            if isinstance(content, list):
                for name in content:
                    path = Path(name)
                    if path.is_file() and not path.is_symlink():
                        dest = unique_path(temporary, path.name)
                        shutil.copyfile(path, dest)
                        result.append(dest)
            elif isinstance(content, Image.Image):
                dest = unique_path(temporary, "wechat-image.png")
                content.save(dest, format="PNG")
                result.append(dest)
            return result
        finally:
            # Do not overwrite a clipboard changed again by the user.
            if own_sequence != before and win32clipboard_sequence() == own_sequence:
                clipboard.OpenClipboard()
                try:
                    clipboard.EmptyClipboard()
                    for fmt, data in snapshot:
                        clipboard.SetClipboardData(fmt, data)
                finally:
                    clipboard.CloseClipboard()

    async def run(self, handle, parent, sources):
        window = self.window(handle)
        attempted = set()
        files = list(sources)
        pages = []
        warnings = []
        any_ax = False
        downloaded_hashes = {}
        positions = []
        with archive_workspace(Path(parent)) as temporary:
            temporary = Path(temporary)
            top_signature = None
            for _ in range(60):
                self.progress("正在回到聊天记录顶部…")
                self.scroll(window, 20)
                signature = self.capture(window).tobytes()
                if signature == top_signature:
                    break
                top_signature = signature
            previous = None
            reached_bottom = False
            for index in range(100):
                check_cancel(self.stop)
                self.progress(f"正在提取第 {index + 1} 屏及其附件…")
                image = self.capture(window)
                signature = image.tobytes()
                if signature == previous:
                    reached_bottom = True
                    break
                previous = signature
                regions = self.media_regions(window, image)
                from PIL import ImageDraw
                text_image = image.copy()
                drawing = ImageDraw.Draw(text_image)
                for x, y, w, h in regions:
                    drawing.rectangle((int(x*image.width), int(y*image.height), int((x+w)*image.width), int((y+h)*image.height)), fill="white")
                lines = await self.recognize(text_image)
                lines, used_ax = self.accessible_text(window, lines)
                any_ax |= used_ax
                pages.append(lines)
                candidates = [(line.x + line.width / 2, line.y + line.height / 2, line.text) for line in lines if file_names([line])]
                for x, y, w, h in regions:
                    context = "|".join(line.text for line in lines if 0 < y - line.y < .1)
                    candidates.append((x + w / 2, y + h / 2, f"media|{context}|{w:.2f}|{h:.2f}"))
                for x, y, identity in candidates:
                    if identity in attempted or not (.05 < y < .92):
                        continue
                    attempted.add(identity)
                    try:
                        for file in await self.save_candidate(window, x, y, temporary):
                            sha = digest(file)
                            first = downloaded_hashes.get(sha)
                            if first is not None and first != file and digest(first) == sha:
                                file.unlink()  # Fresh collector-created duplicate; verified first copy remains.
                                file = first
                            else:
                                downloaded_hashes[sha] = file
                                files.append(file)
                            before = tuple(line.text for line in lines if line.y + line.height / 2 < y)[-6:]
                            after = tuple(line.text for line in lines if line.y + line.height / 2 > y)[:6]
                            positions.append(AttachmentPosition(file, before, after, index, y))
                    except Exception as error:
                        rect = window.rectangle()
                        self.mouse.click(coords=(rect.left + rect.width() // 2, rect.top + 55))
                        check_cancel(self.stop)
                        warnings.append(f"附件自动另存失败：{type(error).__name__}，可使用补充附件。")
                self.scroll(window, -max(2, int(window.rectangle().height() * .55 / 120)))
            if not reached_bottom:
                warnings.append("已达到 100 屏上限，请检查记录是否完整。")
            lines = merge_pages(pages)
            if not lines:
                raise RuntimeError("未读到聊天正文。请确保选中了打开的合并聊天记录，并保持可见。")
            if not files and attempted:
                warnings.append("微信未提供可自动保存的原附件。请将附件在微信另存后，通过“补充附件”重新导出。")
            return export_archive(Path(parent), lines, files, warnings=warnings, pages=len(pages),
                                  text_source="Windows UI Automation + 系统 OCR" if any_ax else "Windows 本地 OCR", stop=self.stop,
                                  existing_directory=temporary, attachment_positions=positions)


def win32clipboard_sequence():
    import ctypes
    return ctypes.windll.user32.GetClipboardSequenceNumber()


def rect_contains(outer, inner):
    return outer.left <= inner.left and outer.top <= inner.top and outer.right >= inner.right and outer.bottom >= inner.bottom
