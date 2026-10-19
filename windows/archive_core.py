"""Portable archive format and attachment copying. No Windows dependencies here."""
from __future__ import annotations

from dataclasses import dataclass
from contextlib import contextmanager
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


@dataclass(frozen=True)
class AttachmentPosition:
    file: Path
    before: tuple[str, ...] = ()
    after: tuple[str, ...] = ()
    page: int = 0
    y: float = 0


def resolve_attachment_positions(positions: list[AttachmentPosition], lines: list[Line]) -> dict[int, list[Path]]:
    """Read-only output metadata: never replace message lines or change page merging."""
    keys = [key(line.text) for line in lines]
    result = {}
    for position in sorted(positions, key=lambda p: (p.page, p.y)):
        before, after = [key(t) for t in position.before[-6:]], [key(t) for t in position.after[:6]]
        best_score, best = 0, []
        for boundary in range(len(lines) + 1):
            score = 0
            for left, right in zip(reversed(before), reversed(keys[:boundary])):
                if left != right: break
                score += 1
            for left, right in zip(after, keys[boundary:]):
                if left != right: break
                score += 1
            if score > best_score:
                best_score, best = score, [boundary]
            elif score == best_score:
                best.append(boundary)
        if best_score >= 2 and len(best) == 1:
            file = Path(position.file).resolve()
            if file not in result.setdefault(best[0], []): result[best[0]].append(file)
    return result


class Cancelled(Exception):
    pass


def check_cancel(stop: threading.Event | None):
    if stop is not None and stop.is_set():
        raise Cancelled("已停止提取，已保存的附件保留在同名文件夹中。")


def key(text: str) -> str:
    value = "".join(c for c in text.casefold() if c.isalnum())
    return value or text.strip()


def is_merged_record_title(title: str) -> bool:
    title = title.strip()
    lower = title.lower()
    if title.startswith(("搜索聊天记录", "查找聊天记录", "聊天记录管理", "聊天记录备份", "聊天记录迁移")):
        return False
    if lower.startswith(("search", "find")) or "backup" in lower or "migration" in lower:
        return False
    return title == "聊天记录" or title.endswith("的聊天记录") or lower.endswith("chat history")


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
        def heading(text):
            return text.strip().endswith("的聊天记录") or text.strip().lower().endswith("chat history")
        has_header = any(heading(line.text) for line in page[:4])
        incoming = [line for index, line in enumerate(page)
                    if line.text.strip() not in {"", "微信", "WeChat", "聊天记录", "关闭", "完成"}
                    and not ((line.y < .12 if line.height > 0 else index < 4)
                             and (heading(line.text) or (has_header and line.text.strip() in {"●", "••●", "•••", "···", "..."})))]
        result = _merge_overlap(result, incoming)
    return result


def _similar_line(a: Line, b: Line, *, before_timestamp=False) -> bool:
    if a.quoted != b.quoted:
        return False
    left, right = key(a.text), key(b.text)
    if left == right:
        return bool(left)
    if min(len(left), len(right)) < 6:
        return False
    timestamp = r"\d{4}年\d{1,2}月\d{1,2}日"
    if re.search(timestamp, left) and re.search(timestamp, right) and len(left) == len(right):
        return False
    latin_names = before_timestamp and max(len(left), len(right)) <= 32 and (left + right).isascii()
    if not (latin_names or (re.search(timestamp, left) and re.search(timestamp, right))):
        return False
    limit = min(2, max(len(left), len(right)) // 5)
    if abs(len(left) - len(right)) > limit:
        return False
    row = list(range(len(right) + 1))
    for i, character in enumerate(left):
        next_row = [i + 1] + [0] * len(right)
        for j in range(1, len(right) + 1):
            next_row[j] = min(row[j] + 1, next_row[j-1] + 1, row[j-1] + (character != right[j-1]))
        row = next_row
    return row[-1] <= limit


def _merge_overlap(previous: list[Line], incoming: list[Line]) -> list[Line]:
    """Suffix/prefix alignment only: equal messages elsewhere are deliberately retained."""
    if not previous or not incoming:
        return previous + incoming
    base = max(0, len(previous) - 160)
    a, b = previous[base:], incoming[:160]
    n, m = len(a), len(b)
    scores = [[0] * (m + 1) for _ in range(n + 1)]
    moves = [[0] * (m + 1) for _ in range(n + 1)]
    for j in range(1, m + 1):
        scores[0][j], moves[0][j] = -2 * j, 2
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            before_timestamp = (i < n and j < m
                                and re.search(r"\d{4}年\d{1,2}月\d{1,2}日", key(a[i].text))
                                and re.search(r"\d{4}年\d{1,2}月\d{1,2}日", key(b[j].text)))
            diagonal = scores[i-1][j-1] + 3 if _similar_line(a[i-1], b[j-1], before_timestamp=before_timestamp) else -100_000
            up, left = scores[i-1][j] - 2, scores[i][j-1] - 2
            scores[i][j] = max(diagonal, up, left)
            moves[i][j] = 0 if diagonal == scores[i][j] else 1 if up == scores[i][j] else 2
    best = None
    for end in range(1, m + 1):
        if scores[n][end] <= 0:
            continue
        i, j, steps, matches = n, end, [], []
        while j:
            if moves[i][j] == 0:
                i, j = i - 1, j - 1
                steps.append((i, j))
                matches.append((i, j))
            elif moves[i][j] == 1:
                i -= 1
                steps.append((i, None))
            else:
                j -= 1
                steps.append((None, j))
        anchors = {key(a[x].text) for x, _ in matches if len(key(a[x].text)) >= 6
                   and not re.search(r"\d{4}年\d{1,2}月\d{1,2}日", key(a[x].text))}
        matched_left, matched_right = {x for x, _ in matches}, {y for _, y in matches}
        old_times = [x for x in range(i, n) if x not in matched_left and re.fullmatch(r"\d{4}年\d{1,2}月\d{1,2}日\d{4}", key(a[x].text))]
        new_times = [y for y in range(end) if y not in matched_right and re.fullmatch(r"\d{4}年\d{1,2}月\d{1,2}日\d{4}", key(b[y].text))]
        if (len(matches) < 3 or sum(map(len, anchors)) < 12
                or (old_times and new_times)
                or len(matches) / max(n-i, end) < .7
                or min(y for _, y in matches) > 2 or max(x for x, _ in matches) < n - 3):
            continue
        if best is None or scores[n][end] > best[0]:
            best = scores[n][end], i, end, list(reversed(steps))
    if best is not None:
        _, start, end, steps = best
        merged = previous[:base+start]
        matched_left = {x for x, y in steps if x is not None and y is not None}
        matched_right = {y for x, y in steps if x is not None and y is not None}
        def sender(text):
            return 1 <= len(text) <= 32 and text.isascii() and any(c.isalpha() for c in text)
        duplicate_senders = {y-1 for x, y in steps if x is not None and y is not None and x > 0 and y > 0
                             and re.search(r"\d{4}年\d{1,2}月\d{1,2}日", key(a[x].text))
                             and re.search(r"\d{4}年\d{1,2}月\d{1,2}日", key(b[y].text))
                             and x-1 not in matched_left and y-1 not in matched_right
                             and sender(key(a[x-1].text)) and sender(key(b[y-1].text))}
        for left, right in steps:
            if left is None:
                if right not in duplicate_senders:
                    merged.append(b[right])
            elif right is not None and len(key(b[right].text)) > len(key(a[left].text)) and key(a[left].text) in key(b[right].text):
                merged.append(b[right])
            else:
                merged.append(a[left])
        return merged + incoming[end:]
    else:
        overlap = 0
        for count in range(min(n, m), 0, -1):
            if [(key(x.text), x.quoted) for x in a[-count:]] == [(key(x.text), x.quoted) for x in b[:count]]:
                overlap = count
                break
        return previous + incoming[overlap:]


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

    @property
    def markdown_path(self):
        return self.folder / (self.folder.name + ".md")


@contextmanager
def archive_workspace(parent: Path):
    folder = unique_path(Path(parent), f"微信聊天记录-{datetime.now():%Y-%m-%d-%H%M%S}")
    folder.mkdir()
    def note(reason):
        md = folder / (folder.name + ".md")
        text = f"# 微信合并聊天记录\n\n状态：{reason}\n\n## 已保存的附件\n\n"
        for file in folder.iterdir():
            if file != md and file.is_file():
                text += f"- [{escaped(file.name)}]({quote(file.name, safe='-._~')})\n"
        md.write_text(text, encoding="utf-8")
    note("正在提取，附件直接保存在本目录。")
    try:
        yield folder
    except BaseException:
        note("提取未完成或已停止，已保存的附件保留在本目录。")
        raise


def export_archive(parent: Path, lines: list[Line], sources: list[Path], *, warnings: list[str] | None = None,
                   pages: int = 0, text_source: str = "Windows UI Automation / 系统 OCR", stop=None,
                   existing_directory: Path | None = None, attachment_positions: list[AttachmentPosition] | None = None) -> Report:
    parent = Path(parent)
    if not parent.is_dir():
        raise ValueError("请选择存在的导出目录。")
    warnings = list(warnings or [])
    folder = Path(existing_directory) if existing_directory else unique_path(parent, f"微信聊天记录-{datetime.now():%Y-%m-%d-%H%M%S}")
    markdown_name = folder.name + ".md"
    stage = folder if existing_directory else Path(tempfile.mkdtemp(prefix=".聊析-", dir=parent))
    try:
        if not (stage / markdown_name).exists():
            (stage / markdown_name).touch(exist_ok=False)
        saved: list[tuple[str, str]] = []
        hashes = set()
        canonical_files = {}
        source_names = {}
        processed_paths = set()
        saved_names = set()
        ordered_sources = sorted(enumerate(sources), key=lambda item: (Path(item[1]).parent.resolve() != stage.resolve(), item[0]))
        for _, source in ordered_sources:
            check_cancel(stop)
            source = Path(source)
            normalized_path = source.resolve()
            if normalized_path in processed_paths:
                continue
            processed_paths.add(normalized_path)
            destination = None
            try:
                if source.is_symlink() or not source.is_file() or source.stat().st_size == 0:
                    raise ValueError("为空、是链接或不是普通文件")
                sha = digest(source)
                inside = source.parent.resolve() == stage.resolve()
                if sha in hashes:
                    source_names[source.resolve()] = canonical_files[sha].name
                    saved_names.add(source.name.casefold())
                    kept = canonical_files.get(sha)
                    if inside and kept is not None and kept.resolve() != source.resolve() and digest(kept) == sha:
                        source.unlink()  # Task-created duplicate in the export; verified first copy remains.
                    continue
                if inside:
                    if source.name == markdown_name:
                        continue
                    kind = "照片" if source.suffix.lower() in IMAGES else "视频" if source.suffix.lower() in VIDEOS else "文档 / 文件"
                    saved.append((source.name, kind))
                    hashes.add(sha)
                    canonical_files[sha] = source
                    source_names[source.resolve()] = source.name
                    saved_names.add(source.name.casefold())
                    continue
                destination = unique_path(stage, source.name)
                shutil.copyfile(source, destination)
                if digest(destination) != sha:
                    raise ValueError("复制后的内容校验失败")
                kind = "照片" if source.suffix.lower() in IMAGES else "视频" if source.suffix.lower() in VIDEOS else "文档 / 文件"
                saved.append((destination.name, kind))
                hashes.add(sha)
                canonical_files[sha] = destination
                source_names[source.resolve()] = destination.name
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
              "- **附件样式**：对话中的附件链接表示该处发送的照片、视频或文档；按实际文件名读取同目录原文件，照片内部文字不转写进正文。文末列表仅为索引，不是新的消息。无法确定位置的补充附件只列在索引，不猜测发送者或时间。",
              "- **缺失附件**：见文末“未保存的附件”；未下载成功、过期或未选择的文件不视为已保存。", "", "## 对话内容", ""]
        was_quote = False
        insertions = resolve_attachment_positions(attachment_positions or [], lines)
        located_names = set()
        for index in range(len(lines) + 1):
            boundary_names = set()
            for source in insertions.get(index, []):
                name = source_names.get(source)
                if name is not None:
                    if name in boundary_names: continue
                    kind = next(kind for saved_name, kind in saved if saved_name == name)
                    md.extend(["", f"[{kind}：{escaped(name)}]({quote(name, safe='-._~')})  ", ""])
                    located_names.add(name)
                    boundary_names.add(name)
                else:
                    md.extend(["", f"[附件未保存：{escaped(source.name)}]  ", ""])
                was_quote = False
            if index == len(lines): continue
            line = lines[index]
            if line.quoted != was_quote:
                md.append("")
            md.append(("> " if line.quoted else "") + escaped(line.text) + "  ")
            was_quote = line.quoted
        md.extend(["", "## 附件", ""])
        if not saved:
            md.extend(["本次未取得附件原文件。", ""])
        for name, kind in saved:
            suffix = "" if name in located_names else " — 聊天位置未确定"
            md.extend([f"[{kind}：{escaped(name)}]({quote(name, safe='-._~')}){suffix}", ""])
        if warnings:
            md.extend(["## 未保存的附件 / 提取提示", ""] + [f"- {escaped(w)}" for w in warnings] + [""])
        counts = [sum(kind == k for _, kind in saved) for k in ("照片", "视频", "文档 / 文件")]
        md.extend(["## 提取信息", "", f"读取 {pages} 屏，{len(lines)} 行文字；保存 {counts[0]} 张照片、{counts[1]} 个视频、{counts[2]} 个文件。", ""])
        (stage / markdown_name).write_text("\n".join(md), encoding="utf-8")
        check_cancel(stop)
        if not existing_directory:
            stage.rename(folder)
        return Report(folder, len(lines), *counts, warnings)
    finally:
        if stage.exists() and not existing_directory:
            shutil.rmtree(stage)
