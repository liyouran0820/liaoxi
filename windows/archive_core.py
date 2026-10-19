"""Portable archive format and attachment copying. No Windows dependencies here."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import hashlib
from pathlib import Path
import re
import shutil
import tempfile
import threading
from urllib.parse import quote

IMAGES = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".heif", ".bmp", ".tif", ".tiff"}
VIDEOS = {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm", ".wmv", ".3gp"}
FILE_PATTERN = re.compile(r"(?i)(?:^|[\s：:（(【\[])([^/\\:*?\"<>|\n]{1,120}\.(?:pdf|docx?|xlsx?|pptx?|zip|rar|7z|txt|md|csv|json|ya?ml|png|jpe?g|gif|webp|heic|mp4|mov|m4v|avi|mkv|webm|mp3|wav))(?=$|[\s：:）)】\]])")


@dataclass(frozen=True)
class Line:
    text: str
    x: float = 0
    y: float = 0
    width: float = 0
    height: float = 0
    muted: bool = False
    quoted: bool = False


class Cancelled(Exception):
    pass


def check_cancel(stop: threading.Event | None):
    if stop is not None and stop.is_set():
        raise Cancelled("已停止提取，未写入未完成的结果。")


def key(text: str) -> str:
    return "".join(c for c in text.casefold() if c.isalnum())


def mark_quotes(lines: list[Line]) -> list[Line]:
    """Positions are normalized, top-left origin; do not propagate across headers."""
    from dataclasses import replace
    result = []
    previous = None
    for line in lines:
        attribution = bool(re.match(r"^[^：:\n]{1,32}[：:]\s*\S", line.text))
        timestamp = bool(re.search(r"\d{1,2}:\d{2}|\d{4}年|\d{4}[-/]\d", line.text))
        continuation = previous is not None and 0 <= line.y - (previous.y + previous.height) <= .025 and abs(line.x - previous.x) <= .035
        quoted = line.muted and not timestamp and (attribution or continuation)
        result.append(replace(line, quoted=quoted))
        previous = line if quoted else None
    return result


def merge_pages(pages: list[list[Line]]) -> list[Line]:
    result: list[Line] = []
    for page in pages:
        incoming = [line for line in page if line.text.strip() not in {"", "微信", "WeChat", "聊天记录", "关闭", "完成"}]
        overlap = 0
        for count in range(min(len(result), len(incoming)), 0, -1):
            if [(key(x.text), x.quoted) for x in result[-count:]] == [(key(x.text), x.quoted) for x in incoming[:count]]:
                overlap = count
                break
        result.extend(incoming[overlap:])
    return result


def file_names(lines: list[Line]) -> list[str]:
    return list(dict.fromkeys(m.group(1).strip() for line in lines for m in FILE_PATTERN.finditer(line.text)))


def safe_name(raw: str) -> str:
    name = re.sub(r'[\x00-\x1f/\\:*?"<>|]', "_", raw).strip(" .") or "attachment"
    reserved = {"CON", "PRN", "AUX", "NUL"} | {f"COM{i}" for i in range(1, 10)} | {f"LPT{i}" for i in range(1, 10)}
    if name.split(".")[0].upper() in reserved:
        name = "_" + name
    return name


def unique_path(folder: Path, name: str) -> Path:
    target = folder / safe_name(name)
    stem, suffix = target.stem, target.suffix
    n = 2
    while target.exists():
        target = folder / f"{stem}-{n}{suffix}"
        n += 1
    return target


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def escaped(text: str) -> str:
    return re.sub(r"([\\*_`\[\]<>#])", r"\\\1", text)


@dataclass
class Report:
    folder: Path
    line_count: int
    image_count: int
    video_count: int
    file_count: int
    warnings: list[str]


def export_archive(parent: Path, lines: list[Line], sources: list[Path], *, warnings: list[str] | None = None,
                   pages: int = 0, text_source: str = "Windows UI Automation / 系统 OCR", stop=None) -> Report:
    parent = Path(parent)
    if not parent.is_dir():
        raise ValueError("请选择存在的导出目录。")
    warnings = list(warnings or [])
    stage = Path(tempfile.mkdtemp(prefix=".聊析-", dir=parent))
    try:
        (stage / "conversation.md").touch(exist_ok=False)
        saved: list[tuple[str, str]] = []
        hashes = set()
        saved_names = set()
        for source in sources:
            check_cancel(stop)
            source = Path(source)
            destination = None
            try:
                if source.is_symlink() or not source.is_file() or source.stat().st_size == 0:
                    raise ValueError("为空、是链接或不是普通文件")
                sha = digest(source)
                if sha in hashes:
                    saved_names.add(source.name.casefold())
                    continue
                destination = unique_path(stage, source.name)
                shutil.copyfile(source, destination)
                if digest(destination) != sha:
                    raise ValueError("复制后的内容校验失败")
                kind = "照片" if source.suffix.lower() in IMAGES else "视频" if source.suffix.lower() in VIDEOS else "文档 / 文件"
                saved.append((destination.name, kind))
                hashes.add(sha)
                saved_names.add(source.name.casefold())
            except (OSError, ValueError) as error:
                if destination is not None and destination.exists() and destination.name != "conversation.md":
                    # Only remove this iteration's incomplete copy, never a source.
                    if destination.name not in {name for name, _ in saved}:
                        destination.unlink()
                warnings.append(f"{source.name}：原文件未保存（{error}）。")
        for name in file_names(lines):
            if name.casefold() not in saved_names:
                warnings.append(f"{name}：检测到文件卡片，未取得原文件。可在微信另存后使用“补充附件”。")
        md = ["# 微信合并聊天记录", "", f"提取时间：{datetime.now():%Y-%m-%d %H:%M:%S}  ", f"文字来源：{text_source}", "",
              "## 内容样式说明（供 LLM 阅读）", "",
              "- **正文样式**：不带引用前缀的普通文本，表示当前消息正文。",
              "- **引用样式**：以 `> ` 开头的 Markdown 引用块，表示微信正文下方灰色的被引用原消息；它是上下文，不是当前发送者的新正文。",
              "- **附件样式**：图片使用图片链接，视频和文档使用文件链接，路径相对于本 Markdown。",
              "- **缺失附件**：见文末“未保存的附件”；未下载成功、过期或未选择的文件不视为已保存。", "", "## 对话内容", ""]
        was_quote = False
        for line in lines:
            if line.quoted != was_quote:
                md.append("")
            md.append(("> " if line.quoted else "") + escaped(line.text) + "  ")
            was_quote = line.quoted
        md.extend(["", "## 附件", ""])
        if not saved:
            md.extend(["本次未取得附件原文件。", ""])
        for name, kind in saved:
            md.extend([("!" if kind == "照片" else "") + f"[{escaped(name)}]({quote(name, safe='-._~')})", "", f"类型：{kind}", ""])
        if warnings:
            md.extend(["## 未保存的附件 / 提取提示", ""] + [f"- {escaped(w)}" for w in warnings] + [""])
        counts = [sum(kind == k for _, kind in saved) for k in ("照片", "视频", "文档 / 文件")]
        md.extend(["## 提取信息", "", f"读取 {pages} 屏，{len(lines)} 行文字；保存 {counts[0]} 张照片、{counts[1]} 个视频、{counts[2]} 个文件。", ""])
        (stage / "conversation.md").write_text("\n".join(md), encoding="utf-8")
        check_cancel(stop)
        folder = unique_path(parent, f"微信聊天记录-{datetime.now():%Y-%m-%d-%H%M%S}")
        stage.rename(folder)
        return Report(folder, len(lines), *counts, warnings)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
