#!/usr/bin/env python3
"""Convert the user-supplied ink-mountain Origo v4 artwork into Zhuying v1 packages.

Reads data and assets only; never executes content from the input archive.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import stat
import unicodedata
import zipfile


SYMBOLS = {
    'library': 'books.vertical book book.closed book.closed.fill book.pages square.stack',
    'back': 'chevron.left arrow.left arrow.uturn.backward',
    'forward': 'chevron.right arrow.right arrow.uturn.forward arrow.up.right',
    'search': 'magnifyingglass text.magnifyingglass checkmark.magnifyingglass doc.text.magnifyingglass',
    'more': 'ellipsis', 'close': 'xmark', 'settings': 'gearshape slider.horizontal.3',
    'refresh': 'arrow.clockwise', 'add': 'plus plus.circle',
    'share': 'square.and.arrow.up', 'delete': 'trash',
    'check': 'checkmark.circle checkmark.circle.fill checklist',
    'bookmark': 'bookmark bookmark.fill bookmark.badge.plus bookmark.slash pin pin.fill',
    'catalog': 'list.bullet list.number list.bullet.rectangle',
    'readAloud': 'headphones waveform', 'play': 'play.fill play.circle play.circle.fill play.rectangle',
    'pause': 'pause.fill pause.circle.fill', 'previous': 'backward.end.fill', 'next': 'forward.end.fill',
    'rewind': 'gobackward.15', 'fastForward': 'goforward.15', 'speed': 'speedometer',
    'timer': 'bell bell.badge', 'volume': 'speaker.wave.2',
    'expand': 'chevron.up arrow.up.left.and.arrow.down.right',
    'collapse': 'chevron.down rectangle.compress.vertical', 'remove': 'minus.circle',
    'filter': 'line.3.horizontal.decrease', 'sort': 'arrow.up.arrow.down arrow.up.arrow.down.circle arrow.up.and.down',
    'layoutGrid': 'square.grid.2x2 square.grid.3x3',
    'layoutList': 'rectangle.on.rectangle rectangle.bottomthird.inset.filled rectangle.topthird.inset.filled',
    'download': 'square.and.arrow.down arrow.down.circle', 'folder': 'folder archivebox',
    'createFolder': 'folder.badge.plus', 'edit': 'pencil square.and.pencil',
    'copy': 'doc.on.clipboard', 'note': 'doc doc.text doc.plaintext doc.richtext pdf',
    'highlight': 'highlighter', 'history': 'clock clock.arrow.circlepath',
    'help': 'questionmark.circle', 'info': 'info.circle', 'cloud': 'icloud',
    'sync': 'arrow.triangle.2.circlepath.icloud', 'restore': 'externaldrive.badge.timemachine',
    'link': 'link', 'palette': 'paintpalette paintbrush tshirt',
    'font': 'textformat textformat.size text.alignleft text.line.first.and.arrowtriangle.forward',
    'image': 'photo photo.on.rectangle', 'device': 'internaldrive externaldrive server.rack',
    'key': 'key person.badge.key', 'extension': 'curlybraces chevron.left.forwardslash.chevron.right',
    'network': 'network globe', 'visibility': 'eye', 'visibilityOff': 'eye.slash',
    'darkMode': 'moon', 'swap': 'arrow.left.arrow.right arrow.triangle.swap',
    'warning': 'exclamationmark.circle', 'favorite': 'heart heart.fill',
    'security': 'lock', 'chat': 'bubble.left bubble.right bubble.left.and.bubble.right quote.bubble text.bubble',
    'logout': 'power', 'schedule': 'calendar', 'tag': 'square.on.circle',
    'stats': 'chart.bar chart.bar.xaxis chart.pie', 'ai': 'sparkles',
    'profile': 'person.crop.circle person.circle person.2 person.2.wave.2 person.wave.2',
    'discover': 'safari',
}
NAVIGATION = {'shelf': 'library', 'footprints': 'schedule', 'profile': 'profile', 'search': 'search',
              'discover': 'discover', 'sources': 'network', 'tools': 'settings', 'back': 'back'}
FILENAMES = {'light': '水墨山水-孤舟-浅色.zhuyingtheme', 'dark': '水墨山水-孤舟-深色.zhuyingtheme'}


def read_source(path):
    if path.stat().st_size > 20 * 1024 * 1024:
        raise ValueError('Source ZIP exceeds 20 MB')
    files, normalized = {}, set()
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > 512 or sum(e.file_size for e in entries) > 64 * 1024 * 1024:
            raise ValueError('Source ZIP exceeds resource limits')
        for entry in entries:
            name = entry.filename
            parts = PurePosixPath(name).parts
            key = unicodedata.normalize('NFC', name.rstrip('/')).casefold()
            if (not parts or name.startswith('/') or '..' in parts or '\\' in name or ':' in name
                    or any(ord(c) < 32 for c in name) or key in normalized
                    or stat.S_ISLNK(entry.external_attr >> 16) or entry.flag_bits & 1):
                raise ValueError('Unsafe, conflicting or encrypted source ZIP entry')
            normalized.add(key)
            if not entry.is_dir():
                files[name] = archive.read(entry)
    manifest = json.loads(files['manifest.json'])
    if (manifest.get('format'), manifest.get('schemaVersion'), manifest.get('id')) != ('origo.theme-suite', 4, 'ink-mountain-ensou'):
        raise ValueError('This converter requires the ink-mountain Origo v4 suite')
    return manifest, files


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n').encode()


def build_theme(source, files, mode, contract):
    dark = mode == 'dark'
    components = source['components']
    palette = components['palette'][mode]
    reader = components['reader'][mode]
    card = components['reader']['commentCard'][mode]
    top = palette['topBar']
    resources = {}

    def asset(path):
        data = files[path]
        if not data:
            raise ValueError('Empty source asset: ' + path)
        resources[path] = data
        return path

    icons = {}
    # Preserve all supplied normal/selected artwork for this appearance, including
    # assets with no corresponding control in the current Zhuying version.
    for name, item in components['skin']['icons'].items():
        key = 'darkAsset' if dark else 'asset'
        normal = asset(item['normal'][key]); selected = asset(item['selected'][key])
        value = {'path': normal, 'selected': selected, 'pressed': selected, 'focused': selected, 'template': False}
        for symbol in SYMBOLS.get(name, '').split():
            role = 'symbol.' + symbol
            if role in contract['symbolIconRoles']:
                icons[role] = dict(value)
        for role, target in NAVIGATION.items():
            if name == target:
                icons['navigation.' + role] = dict(value)
    poster = asset(components['reader']['openingIndicator'][mode]['poster'])
    icons['state.loading'] = {'path': poster, 'template': False}
    background = asset(components['skin']['artwork']['pageBackground']['darkAsset' if dark else 'asset'])
    # Secondary text is slightly darker than the source's light muted tone so it
    # stays readable on the paper/card surfaces used by the existing app.
    muted = '#B0ABA2' if dark else '#6B655D'
    colors = {'background.page': top['background'], 'background.card': card['background'],
              'background.soft': reader['controlBar'], 'text.primary': palette['primary'],
              'text.secondary': muted, 'border': card['border'], 'accent': palette['primary'],
              'action.primary.background': top['selectedBackground'],
              'action.primary.foreground': top['selectedForeground']}
    backgrounds = {role: {'path': background, 'mode': 'fill', 'opacity': 1, 'overlayOpacity': .12 if dark else .08}
                   for role in ['page', 'shelf', 'profile', 'settings']}
    name = '水墨山水·孤舟（' + ('深色' if dark else '浅色') + '）'
    prefs = {'paragraphSpacing': 22, 'leftMargin': 25, 'rightMargin': 25, 'topMargin': 24, 'bottomMargin': 20,
             'marginsLinked': True, 'firstLineIndent': True, 'fontWeight': '常规',
             'colors': {'background': reader['background'], 'ink': reader['text'], 'accent': palette['primary'], 'name': name, 'dark': dark},
             'headerEnabled': True, 'footerEnabled': True, 'headerHeight': 48, 'footerHeight': 48, 'headerGap': 12, 'footerGap': 12,
             'pageElements': [
                 {'id': 'ink-header-time', 'zone': 'header', 'kind': '时间', 'text': '', 'x': 20, 'y': 50, 'width': 30, 'fontSize': 12, 'color': muted},
                 {'id': 'ink-footer-book', 'zone': 'footer', 'kind': '书名', 'text': '', 'x': 28, 'y': 50, 'width': 46, 'fontSize': 12, 'color': muted},
                 {'id': 'ink-footer-progress', 'zone': 'footer', 'kind': '进度', 'text': '', 'x': 80, 'y': 50, 'width': 30, 'fontSize': 12, 'color': muted}],
             'horizontalEffect': '平移', 'verticalEffect': '平移', 'rules': [],
             'showCommentBubbles': True, 'showGodComments': True, 'bubbleStyle': '自定义', 'godStyle': '画框',
             'bubbleRadius': 14, 'godRadius': card['radius'], 'bubbleColor': palette['primary'],
             'godBackground': card['background'], 'godBorder': card['border']}
    css = '.chapter-title { font-size:28pt; font-weight:medium; text-align:center; color:' + reader['text'] + '; letter-spacing:2pt; padding-top:20pt; padding-bottom:24pt; }\n'
    # Native bubbles accept passive SVG, not the source's raster review badge.
    svg = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 88 44">
<path d="M8 9 Q24 3 44 6 Q67 3 80 11 L79 31 Q64 38 45 35 L25 36 L15 42 L16 35 Q5 31 8 9Z" fill="{{background}}" stroke="{{ink}}" stroke-width="1.6"/>
<path d="M11 12 Q42 5 76 13 M12 29 Q46 37 76 30" fill="none" stroke="{{accent}}" stroke-width="1.2" opacity="0.32"/>
<circle cx="6" cy="17" r="1.5" fill="{{ink}}" opacity="0.35"/><circle cx="82" cy="25" r="1" fill="{{ink}}" opacity="0.45"/>
<text x="44" y="26" text-anchor="middle" font-size="15" fill="{{ink}}">{{count}}</text></svg>'''
    resources['assets/reader/title.css'] = css.encode()
    resources['assets/reader/bubble.svg'] = svg.encode()
    font_id = components['fonts']['roles']['body']
    font = next(f for f in components['fonts']['resources'] if f['id'] == font_id)
    font_path = asset(font['asset'])
    license_path = 'licenses/reader-font.txt'
    resources[license_path] = files[font['licenseAsset']]
    if b'SIL OPEN FONT LICENSE' not in resources[license_path]:
        raise ValueError('Expected font redistribution license is missing')
    resources['licenses/original-theme.txt'] = files['LICENSE.txt']
    resources['licenses/ATTRIBUTION.txt'] = (f'''竹影主题适配：{name}
原主题：{source['name']}，作者：{source['author']}，原格式：{source['format']} v{source['schemaVersion']}，原版本：{source['version']}。
原主题许可与字体许可分别见 original-theme.txt、reader-font.txt；保留原作者署名。原包内背景声明为用户提供的画作，按原包声明随主题分发；适配不新增画作权利声明。
保留此变体的全部 80 组普通／选中图标和原背景。语义相符的图标映射到竹影现有控件，其余资源保留在包内。
字体真实文件用于正文；竹影 v1 尚不能替换应用 UI、页眉页脚的系统字体。
章节标题补为原生兼容居中水墨样式；段评位图适配为被动 SVG 水墨气泡，并非原图逐像素复刻；评论卡片采用原生画框、原色与圆角。
保留时间、书名和进度信息；当前原生页眉不支持电量元素，未伪造电量读数。
48 帧 WebP 加载动画使用原包的静态墨圈海报；无任意脚本和动画执行。
启动画面和导航条装饰暂无对应主题槽位，未写入无效字段，也未沿用源包其他软件的启动标识。应用布局与手势不变。
主／次文字与按钮颜色适配原生控件，浅色次要文字略加深以确保可读。
''').encode()
    document = {'contractVersion': 1, 'app': {'dark': dark, 'colors': colors, 'icons': icons, 'backgrounds': backgrounds,
                                            'motion': {'pressOpacity': .7, 'duration': .12}},
                'reader': {'appearance': {'fontSize': 22, 'lineSpacing': 12, 'preferences': prefs},
                           'resources': {'title': {'path': 'assets/reader/title.css'}, 'bubble': {'path': 'assets/reader/bubble.svg'}},
                           'background': {'path': background, 'mode': 'fill', 'opacity': reader['backgroundImageOpacity'], 'overlayOpacity': 0}},
                'fontBindings': {'reader.body': {'path': font_path, 'postScriptName': font['family'], 'licensePath': license_path}}}
    resources['theme.json'] = json_bytes(document)
    manifest = {'format': 'zhuying-theme', 'formatVersion': 1, 'themeID': 'zhuying.port.ink-mountain-ensou.' + mode,
                'themeVersion': '1.0.0', 'name': name, 'author': source['author'], 'packageKind': 'full',
                'scopes': ['app', 'reader'], 'appearanceModes': [mode],
                'requiredCapabilities': contract['capabilities'], 'optionalCapabilities': [], 'entry': 'theme.json', 'files': []}
    types = {'png': 'image/png', 'jpg': 'image/jpeg', 'otf': 'font/otf', 'ttf': 'font/ttf', 'txt': 'text/plain',
             'css': 'text/css', 'svg': 'image/svg+xml', 'json': 'application/json'}
    for path, data in sorted(resources.items()):
        ext = path.rsplit('.', 1)[-1]
        role = ('configuration' if path == 'theme.json' else 'license' if path.startswith('licenses/') else
                'font' if ext in ['otf', 'ttf'] else 'title-css' if ext == 'css' else 'bubble-svg' if ext == 'svg' else
                'icon' if path.startswith('assets/icons/') or path == poster else 'background')
        manifest['files'].append({'path': path, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(), 'mediaType': types[ext], 'role': role})
    resources['manifest.json'] = json_bytes(manifest)
    return manifest, document, resources


def write_package(path, files):
    if path.exists():
        raise ValueError('Refusing to overwrite an existing theme package')
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            item = zipfile.ZipInfo(name, date_time=(2026, 11, 6, 0, 0, 0))
            item.compress_type = zipfile.ZIP_DEFLATED
            item.external_attr = (stat.S_IFREG | 0o644) << 16
            archive.writestr(item, data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    contract = json.loads((Path(__file__).resolve().parents[1] / 'Zhuying/Resources/theme-contract.json').read_text())
    source, files = read_source(args.source)
    for mode, filename in FILENAMES.items():
        manifest, document, resources = build_theme(source, files, mode, contract)
        path = args.output / filename
        write_package(path, resources)
        print(json.dumps({'artifact': str(path), 'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                          'files': len(resources), 'mappedIconRoles': len(document['app']['icons']), 'mode': mode}, ensure_ascii=False))


if __name__ == '__main__':
    main()
