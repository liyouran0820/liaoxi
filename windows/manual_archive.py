"""Manual paste + attachment export. Standard library only; never reads screen or WeChat."""
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
import shutil
from urllib.parse import quote

from archive_core import Cancelled, IMAGES, VIDEOS, Report, check_cancel, digest, unique_path


def kind(file):
    suffix = Path(file).suffix.lower()
    return '照片' if suffix in IMAGES else '视频' if suffix in VIDEOS else '文档 / 文件'


@dataclass(frozen=True)
class ManualAttachment:
    id: int
    source: Path

    @property
    def token(self):
        return f'[[{kind(self.source)} {self.id}：{self.source.name}]]'


def export_manual(parent, draft, attachments=(), stop=None):
    check_cancel(stop)
    parent = Path(parent)
    if not parent.is_dir():
        raise ValueError('请选择有效的导出文件夹。')
    if not draft.strip() and not attachments:
        raise ValueError('请先粘贴聊天文字或添加附件。')
    if len({entry.id for entry in attachments}) != len(attachments):
        raise ValueError('附件编号重复，请重新添加附件。')
    folder = unique_path(parent, f'微信聊天记录-{datetime.now():%Y-%m-%d-%H%M%S}')
    folder.mkdir()
    md_path = folder / (folder.name + '.md')
    retained, hashes, saved, warnings = {}, {}, [], []
    source_text = draft
    for entry in attachments:
        source_text = source_text.replace(entry.token, '')
    line_count = sum(bool(line.strip()) for line in source_text.splitlines())

    def label(text):
        return text.replace('\\', '\\\\').replace('[', '\\[').replace(']', '\\]')

    def link(file):
        return f'[{kind(file)}：{label(file.name)}]({quote(file.name, safe="-._~")})'

    def write(status=None):
        body = draft
        for entry in attachments:
            file = retained.get(entry.id)
            body = body.replace(entry.token, link(file) if file else f'[附件未保存：{label(entry.source.name)}]')
        md = f'# 微信聊天记录\n\n整理时间：{datetime.now():%Y-%m-%d %H:%M:%S}  \n文字来源：用户手动复制粘贴（未进行 OCR）\n\n'
        if status:
            md += f'状态：{status}\n\n'
        md += ('## 内容样式说明（供 LLM 阅读）\n\n'
               '- **正文样式**：以下内容由用户粘贴，保留原有文字、换行与 Markdown，不自动推断发言者，也不删除重复消息。\n'
               '- **引用样式**：以 `> ` 开头的内容是用户标记的引用；粘贴为纯文本后不根据微信颜色猜测引用。\n'
               '- **附件样式**：正文中的链接位于用户手动插入的位置，文件名对应本目录实际文件；照片 / 视频不识别文字。文末仅为索引，不是新消息。\n\n'
               '## 对话内容\n\n' + body + '\n\n## 附件索引\n\n')
        if not saved:
            md += '未添加附件。\n'
        for file in saved:
            located = any(retained.get(entry.id) == file and entry.token in draft for entry in attachments)
            md += link(file) + ('' if located else ' — 未插入正文') + '\n\n'
        if warnings:
            md += '## 附件提示\n\n' + '\n'.join('- ' + warning for warning in warnings) + '\n\n'
        images = sum(kind(file) == '照片' for file in saved)
        videos = sum(kind(file) == '视频' for file in saved)
        md += f'## 整理信息\n\n手动整理 {line_count} 行文字；保存 {images} 张照片、{videos} 个视频、{len(saved)-images-videos} 个文件。\n'
        temporary = folder / ('.' + md_path.name + '.writing')
        temporary.write_text(md, encoding='utf-8')
        temporary.replace(md_path)

    try:
        write('正在整理，附件尚未全部保存。')
        for entry in attachments:
            check_cancel(stop)
            file = Path(entry.source)
            destination = None
            try:
                if file.is_symlink() or not file.is_file() or file.stat().st_size == 0:
                    raise ValueError('为空、是链接或不是普通文件')
                sha = digest(file)
                if sha in hashes:
                    retained[entry.id] = hashes[sha]
                    continue
                destination = unique_path(folder, file.name)
                shutil.copyfile(file, destination)
                if digest(destination) != sha:
                    raise ValueError('复制后的内容校验失败')
                retained[entry.id] = destination
                hashes[sha] = destination
                saved.append(destination)
            except (OSError, ValueError) as error:
                if destination is not None and destination.exists() and destination not in saved:
                    destination.unlink()  # This iteration's incomplete copy only, never an external source.
                warnings.append(f'{file.name}：未保存（{error}）。')
        check_cancel(stop)
        write()
        images = sum(kind(file) == '照片' for file in saved)
        videos = sum(kind(file) == '视频' for file in saved)
        return Report(folder, line_count, images, videos, len(saved)-images-videos, warnings)
    except BaseException as error:
        try:
            write('已停止，粘贴文字及已保存附件保留。' if isinstance(error, Cancelled) else f'整理失败：{error}')
        except OSError:
            pass
        raise
