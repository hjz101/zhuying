# 主题套装文件

“主题管理 → 导入套装 / 样式 → 选择套装文件”读取 JSON，可多选。主题、章节标题与段评气泡分别计数；确认读取后加入本次运行的样式库，应用搭配另行操作。单文件最多 3 MB，每款 CSS／SVG 最多 60,000 字节。

## 套装结构

支持根对象的 `themes` 数组、直接主题数组或一个主题对象。颜色为六位十六进制字符串，`mode` 为 `light` 或 `dark`，省略时为浅色。省略主题 ID 时根据名称与配色生成稳定 ID。

```json
{
  "themes": [{
    "id": "my-theme",
    "name": "山间来信",
    "mode": "light",
    "background": "#F7F6F0",
    "ink": "#354F40",
    "accent": "#B7815A",
    "chapterTitles": [{
      "id": "chapter-one",
      "name": "侧线章首",
      "css": ".chapter-title { border-left:4px solid var(--accent); padding:8px 12px; }"
    }],
    "commentBubbles": [{
      "id": "bubble-one",
      "name": "圆角气泡",
      "svg": "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 72 44'><rect x='2' y='2' width='68' height='36' rx='10' fill='{{accent}}'/><text x='36' y='26' text-anchor='middle' font-size='16' fill='{{background}}'>{{count}}</text></svg>"
    }]
  }]
}
```

`summary`、`version` 可选。标题样式作用于预览中的 `.chapter-title`，预览提供 `--background`、`--ink`、`--accent` 变量。SVG 可使用 `{{background}}`、`{{ink}}`、`{{accent}}`、`{{count}}` 占位符；未包含数字占位符的纯图形气泡会叠加示例数字。预览同时展示三种位数，长标题可在详情中切换。

标题与气泡 ID 按套装 ID、资源类型、局部 ID 组合，避免不同主题中的 `main` 相互覆盖。资源省略局部 ID 时根据内容生成稳定 ID；重复 ID 保留原样式。引用删除过的套装所保留的资源时，会复用资源并恢复关联。

## 独立样式

根对象也可直接包含 `chapterTitles` 或 `commentBubbles`，并用 `source` 标记来源；结构与套装内部相同。可与 `themes` 同时存在。

```json
{
  "source": "我的标题集",
  "chapterTitles": [{
    "id": "centered",
    "name": "居中章首",
    "css": ".chapter-title { text-align:center; letter-spacing:2px; }"
  }],
  "commentBubbles": []
}
```

## 当前支持范围

预览使用系统 WebKit 实际渲染 CSS 和 SVG。SVG 支持路径、几何图形、文字、内联样式、渐变、裁剪、蒙版与本地定义引用；外部文件、脚本和嵌入网页不支持。空白、无效、缺少图形或引用外部文件的资源会计入无效项并提示名称，套装中的其他有效资源仍可使用。不读取 ZIP 或附带的外部 CSS／SVG 路径。

选择资源缩略图仅修改预览；应用整套或混搭后才更新当前搭配。未附带的组件保留当前搭配；自定义选择“默认标题／默认气泡”则明确恢复默认。正在使用的资源受删除保护。主题、资源、收藏和搭配仅在本次运行内保存，未接入正文阅读器的 CSS／SVG 渲染或跨启动持久化。
