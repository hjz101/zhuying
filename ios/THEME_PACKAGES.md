# 主题套装文件

## 全局主题包 v1

从「我的 → 主题管理」进入。内置竹影原色、清透青绿和幻想夜航，切换不改变页面布局、导航顺序及功能入口。制作页支持配色、图片背景、应用内图标及状态图片、点击反馈，背景可用于页面、卡片、正文及默认封面。

「打包分享」导出 `.zhuyingtheme`（标准 ZIP），携带当前实际生效的阅读字号、行段距、留白、页眉页脚、CSS 标题、气泡与段评外观。原生字体角色会保存；附带自定义字体需填写分发许可。不会导出书籍、进度、账号、真实评论或书籍／书源专属规则。

收到主题包后先预览，可仅加入库、完整应用或选择范围混搭。完整应用替换旧的个人外观覆盖，保存恢复点；阅读模式、点击翻页及震动默认保留。正在使用或用于恢复的主题不能删除，可以先切换并清除恢复点。正式模式下全局主题资源同时进入书库备份，恢复时跟随独立数据代次切换。

「导出给 AI 的制作资料」提供有效基础模板、能力合同、两份 JSON Schema 和制作说明。v1 每包仅含一种浅色／深色变体；图标支持 PNG/JPEG 和系统符号，气泡支持被动 SVG，标题仍使用原生 CSS 白名单；原生开关／滑块保留系统绘制并跟随配色，系统键盘和授权弹窗不属于任意皮肤替换范围。

详细说明见 [主题包规范](../docs/design/ZHUYING-THEME-PACKAGE.md) 与 [AI 制作文稿](../docs/design/ZHUYING-THEME-AI-PROMPT.md)。

## 原有阅读 JSON 套装

“主题管理 → 导入套装 / 样式 → 选择套装文件”读取 JSON，可多选。主题、章节标题与段评气泡分别计数；确认读取后加入本机保存的样式库，应用搭配另行操作。单文件最多 3 MB，每款 CSS／SVG 最多 60,000 字节。

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
    "godStyle": "画框",
    "chapterTitles": [{
      "id": "chapter-one",
      "name": "居中章首",
      "css": ".chapter-title { text-align:center; color:var(--accent); padding-bottom:12px; }"
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

`godStyle` 为可选的神人评论卡片基础样式，可用 `纯色`、`液态玻璃` 或 `画框`。应用套装后，在阅读偏好中开启“显示神人评论”并选择跟随主题即可使用；省略时保留当前主题卡片样式。评论内容仍为本地示例，玻璃样式为半透明绘图效果。

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

以下范围针对原有阅读 JSON 导入器。全局 ZIP 主题包请使用上方的新入口，两个入口的格式不混用。

预览使用系统 WebKit 实际渲染 CSS 和 SVG。SVG 支持路径、几何图形、文字、内联样式、渐变、裁剪、蒙版与本地定义引用；外部文件、脚本和嵌入网页不支持。空白、无效、缺少图形或引用外部文件的资源会计入无效项并提示名称，套装中的其他有效资源仍可使用。不读取 ZIP 或附带的外部 CSS／SVG 路径。

选择资源缩略图仅修改预览；应用整套或混搭后才更新当前搭配并应用到原生正文。也可仅应用配色。未附带的组件保留当前搭配；自定义选择“默认标题／默认气泡”则明确恢复默认。正在使用的资源受删除保护。主题、资源、收藏和搭配在本机持久化，重启后恢复；不会同步到其他设备。

正文使用原生标题 CSS 子集：`.chapter-title` 中的 `font-size`、`font-weight`、`text-align`、`color`、`background-color`、`letter-spacing`、`padding-top`、`padding-bottom` 和 `border-bottom`。其中 `border-bottom` 转为文字下划线，不保留网页边框的宽度、线型及布局；数值使用 px／pt 或无单位值。不支持伪元素、侧边框、复杂背景及其他选择器，主题应用时会提取兼容属性并提示，详情的“正文实际效果”展示原生结果。直接在阅读偏好中编辑或导入章节 CSS 时，不支持的属性会报错并保留上次有效样式。

SVG 气泡在本机通过 WebKit 生成图片后嵌入段末；原生正文当前使用本地示例数字和评论。个人自定义标题、个人气泡及神评皮肤优先于主题组件，切换主题不会覆盖这些个人选择；可在对应偏好页切回“跟随当前主题”。字体文件通过“字体管理”单独导入，不随主题 JSON 加载。
