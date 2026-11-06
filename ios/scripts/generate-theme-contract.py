#!/usr/bin/env python3
"""Generate the v1 authoring contract and JSON Schemas shipped with Zhuying."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DESTINATION = ROOT / 'ios/Zhuying/Resources'
COLOR = {'type': 'string', 'pattern': '^#[0-9A-Fa-f]{6}$'}
PATH = {'type': 'string', 'minLength': 1, 'maxLength': 512, 'pattern': r'^(?!/)(?!.*\\)(?!.*:)(?!.*(?:^|/)\.{1,2}(?:/|$))(?!.*//)[^\u0000-\u001f]+$'}
CAPABILITIES = ['app.appearance.v1', 'reader.appearance.v1', 'reader.native-title-css.v1', 'reader.comment-bubble-svg.v1', 'reader.font.v1']
COLORS = ['background.page', 'text.primary', 'text.secondary', 'border', 'accent', 'background.card', 'background.soft', 'action.primary.background', 'action.primary.foreground']


def obj(properties, required=None, **kwargs):
    return {'type': 'object', 'properties': properties, 'required': list(properties) if required is None else required, 'additionalProperties': False, **kwargs}


def num(low, high):
    return {'type': 'number', 'minimum': low, 'maximum': high}


def enum(*values):
    return {'enum': list(values)}


def array(value, maximum=None):
    result = {'type': 'array', 'items': value}
    if maximum is not None:
        result['maxItems'] = maximum
    return result


def nullable(value):
    return {'anyOf': [value, {'type': 'null'}]}


def documents():
    boolean = {'type': 'boolean'}
    string = {'type': 'string'}
    background = obj({'path': PATH, 'mode': enum('fill', 'fit', 'tile'), 'opacity': num(0, 1), 'overlayOpacity': num(0, 1)})
    icon = obj({'symbol': string, **{key: PATH for key in ['path', 'selected', 'disabled', 'pressed', 'focused', 'loading']}, 'template': boolean}, ['template'], oneOf=[{'required': ['symbol'], 'not': {'required': ['path']}}, {'required': ['path'], 'not': {'required': ['symbol']}}])
    page = obj({'id': {'type': 'string', 'minLength': 1}, 'zone': enum('header', 'footer'), 'kind': enum('书名', '章节', '时间', '进度', '自定义文字'), 'text': {'type': 'string', 'maxLength': 160}, 'x': num(0, 100), 'y': num(0, 100), 'width': num(15, 90), 'fontSize': num(9, 22), 'color': nullable(COLOR)}, ['id', 'zone', 'kind', 'text', 'x', 'y', 'width', 'fontSize'])
    rule = obj({'id': {'type': 'string', 'minLength': 1}, 'name': {'type': 'string', 'minLength': 1, 'maxLength': 80}, 'match': enum('对话引号', '系统提示', '诗词段落', '章节首段', '正则表达式', '关键词'), 'pattern': {'type': 'string', 'maxLength': 512}, 'presentation': enum('文字高亮', '段落底色', '居中斜体', '首字下沉'), 'color': COLOR, 'enabled': boolean, 'scope': {'const': '全部书籍'}})
    preferences = {
        'paragraphSpacing': num(0, 48), **{key: num(0, 80) for key in ['leftMargin', 'rightMargin', 'topMargin', 'bottomMargin']},
        'marginsLinked': boolean, 'firstLineIndent': boolean, 'fontWeight': enum('常规', '细体', '中等', '粗体'),
        'colors': obj({'background': COLOR, 'ink': COLOR, 'accent': COLOR, 'name': string, 'dark': boolean}),
        'headerEnabled': boolean, 'footerEnabled': boolean, 'headerHeight': num(48, 140), 'footerHeight': num(48, 140), 'headerGap': num(0, 48), 'footerGap': num(0, 48),
        'pageElements': array(page, 32), 'horizontalEffect': enum('平移', '覆盖', '仿真', '无动画'), 'verticalEffect': enum('平移', '覆盖', '无动画'),
        'rules': array(rule, 64), 'showCommentBubbles': boolean, 'showGodComments': boolean, 'bubbleStyle': enum('胶囊', '方块', '圆形'),
        'godStyle': enum('纯色', '液态玻璃', '画框', '自定义'), 'bubbleRadius': num(0, 30), 'godRadius': num(0, 30),
        **{key: nullable(COLOR) for key in ['bubbleColor', 'godBackground', 'godBorder']}
    }
    # The native picker also supports additional built-in bubble names. It is a string, not an extensible program.
    preferences['bubbleStyle'] = enum('胶囊', '描边', '圆角方形', '自定义')
    required_preferences = [key for key in preferences if key not in ['bubbleColor', 'godBackground', 'godBorder']]
    app = obj({'dark': boolean, 'colors': {'type': 'object', 'properties': {key: COLOR for key in COLORS}, 'required': COLORS, 'additionalProperties': COLOR},
               'icons': {'type': 'object', 'additionalProperties': icon}, 'backgrounds': {'type': 'object', 'additionalProperties': background}, 'motion': obj({'pressOpacity': num(.2, 1), 'duration': num(0, .4)})})
    reader = obj({'appearance': obj({'fontSize': num(14, 30), 'lineSpacing': num(0, 24), 'preferences': obj(preferences, required_preferences)}),
                  'resources': obj({'title': obj({'path': PATH}), 'bubble': obj({'path': PATH})}, []),
                  'optionalReadingBehavior': obj({'mode': enum('scroll', 'paged', 'verticalPaged'), 'tapToTurn': boolean, 'haptics': boolean}), 'background': background, 'systemFont': enum('default', 'serif')}, ['appearance', 'resources'])
    font = obj({'path': PATH, 'postScriptName': {'type': 'string', 'minLength': 1}, 'licensePath': PATH})
    theme = obj({'contractVersion': {'const': 1}, 'app': app, 'reader': reader, 'fontBindings': obj({'reader.body': font}, [])}, ['contractVersion', 'app', 'fontBindings'])
    theme.update({'$schema': 'https://json-schema.org/draft/2020-12/schema', 'title': '竹影 theme.json v1'})
    file = obj({'path': PATH, 'bytes': {'type': 'integer', 'minimum': 1, 'maximum': 20 * 1024 * 1024}, 'sha256': {'type': 'string', 'pattern': '^[a-f0-9]{64}$'},
                'mediaType': string, 'role': enum('configuration', 'icon', 'background', 'title-css', 'bubble-svg', 'font', 'preview', 'license')})
    manifest = obj({'format': {'const': 'zhuying-theme'}, 'formatVersion': {'const': 1}, 'themeID': {'type': 'string', 'pattern': '^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$'},
                    'themeVersion': {'type': 'string', 'pattern': r'^\d+\.\d+\.\d+$'}, 'name': {'type': 'string', 'minLength': 1, 'maxLength': 100}, 'author': string,
                    'packageKind': enum('full', 'component'), 'scopes': {'type': 'array', 'items': enum('app', 'reader'), 'minItems': 1, 'maxItems': 2, 'uniqueItems': True},
                    'appearanceModes': {'type': 'array', 'items': enum('light', 'dark'), 'minItems': 1, 'maxItems': 1}, 'requiredCapabilities': array(enum(*CAPABILITIES)),
                    'optionalCapabilities': array(string), 'entry': {'const': 'theme.json'}, 'files': array(file, 511)})
    manifest.update({'$schema': 'https://json-schema.org/draft/2020-12/schema', 'title': '竹影 manifest.json v1',
                     'allOf': [{'if': {'properties': {'packageKind': {'const': 'full'}}}, 'then': {'properties': {'scopes': {'minItems': 2}}}}]})
    symbols = set()
    for path in (ROOT / 'ios/Zhuying').rglob('*.swift'):
        if path.name.startswith('GlobalTheme'):
            continue
        source = path.read_text()
        symbols.update(re.findall(r'(?:systemName|systemImage|icon):\s*"([a-z0-9.-]+)"', source))
        for expression in re.findall(r'(?:systemName|systemImage):([^,\n)]+)', source):
            symbols.update(re.findall(r'"([a-z0-9.-]+)"', expression))
    symbols.update(['books.vertical', 'calendar', 'safari', 'externaldrive', 'square.grid.2x2', 'person.crop.circle', 'magnifyingglass', 'play.fill', 'pause.fill', 'xmark'])
    contract = {'product': '竹影', 'format': 'zhuying-theme', 'formatVersion': 1, 'contractVersion': 1,
                'capabilities': CAPABILITIES, 'requiredColorRoles': COLORS,
                'backgroundRoles': ['page', 'shelf', 'profile', 'settings', 'card', 'cover.default'],
                'semanticIconRoles': ['navigation.' + tab for tab in ['shelf', 'footprints', 'profile', 'search', 'discover', 'sources', 'tools', 'back']] + ['state.loading'],
                'symbolIconRoles': ['symbol.' + name for name in sorted(symbols)],
                'iconStates': ['normal', 'selected', 'disabled', 'pressed', 'focused', 'loading'],
                'stateFallback': '缺少状态图片时使用普通图标；按下透明度、禁用与聚焦由原生控件和主题反馈提供。',
                'limits': {'archiveBytes': 20 * 1024 * 1024, 'expandedBytes': 64 * 1024 * 1024, 'files': 512, 'cssSVGBytes': 60000, 'imageBytes': 4 * 1024 * 1024, 'imageDimension': 2048, 'fontBytes': 10 * 1024 * 1024},
                'nativeTitleCSS': ['font-size', 'font-weight', 'text-align', 'color', 'background-color', 'letter-spacing', 'padding-top', 'padding-bottom', 'border-bottom'],
                'notes': ['每包包含一个浅色或深色变体；可分别打包分享。', '当前 reader.resources 支持 title/bubble，阅读背景位于 reader.background。', '图标 PNG/JPEG 或系统符号；SVG 用于阅读气泡。', 'JSON Schema 不代替 App 的资源、原生 CSS/SVG、字形与事务验证。']}
    return {'theme-contract.json': contract, 'theme.schema.json': theme, 'manifest.schema.json': manifest}


if __name__ == '__main__':
    for filename, document in documents().items():
        (DESTINATION / filename).write_text(json.dumps(document, ensure_ascii=False, indent=2) + '\n')
    print('Generated Zhuying theme contract and JSON Schemas.')
