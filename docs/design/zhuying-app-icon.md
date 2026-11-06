# 竹影应用图标

## 设计

图标将竹叶与展开的书页合成一个主体，使用应用既有的墨绿、暖米白与少量灰绿。留白与粗轮廓用于保证主屏幕小尺寸的辨识度；不使用文字。

成品位于 `ios/Zhuying/Assets.xcassets/AppIcon.appiconset/zhuying-app-icon.png`，为 1024 × 1024 的不透明 PNG。图片铺满正方形画布，圆角由系统遮罩。当前正式模式与 Demo 模式共用 `Zhuying` target 的 `AppIcon`，无需维护两套图标。

## 生成记录

- 方式：内置 ImageGen 图像生成工具。
- 设计参考：UI/UX Pro Max 的 Minimalism & Swiss Style 搜索结果，采用其中留白、简洁与高对比原则；颜色沿用竹影现有主题。
- 原始生成提示词如下；尺寸与色彩格式可在资源导出时规范化，不改变图形构成。

```text
Use case: logo-brand
Asset type: final iOS application icon for 竹影 (Zhuying), a calm Chinese personal reading app.
Primary request: Design one exquisite, immediately recognizable app icon combining bamboo leaves and an open book into ONE unified bold sculptural emblem. Quiet contemporary East Asian literary sensibility. The bamboo meaning and the reading meaning must fuse elegantly.
Scene/backdrop: full-bleed square rich matte forest green field, close to #304D3F; extremely restrained tonal depth, no frame, fill every corner.
Subject: a large centered warm ivory #F5F1DF emblem: two generous curved page-like leaf forms opening left and right from a central book fold, with one clean ascending bamboo leaf gesture integrated into the fold. A subtle muted sage offset shadow behind the emblem gently suggests the name's 'shadow'. It should first read as a beautiful iconic open book, then reveal bamboo. One coherent silhouette, 3 to 4 broad shapes maximum, intentional negative space, smooth clean edges, delicate low-relief paper quality but essentially flat. Strong balanced geometry with a little organic elegance.
Composition/framing: one icon only, orthographic front view, square 1024 by 1024 canvas; emblem occupies about 62 percent of width, generous optically balanced margins; crisp and recognizable at 32 pixels.
Lighting/mood: calm, warm, restrained, premium, soft and barely perceptible paper relief.
Color palette: existing app colors forest green #304D3F, warm ivory #F5F1DF, and a very small amount of muted sage.
Text: none. No letters or Chinese characters anywhere.
Constraints: production icon art itself, not a presentation or mockup. Full opaque background. Square edges with NO baked rounded corners; iOS supplies the mask. No border, no surrounding white area, no device, no grid, no caption, no extra icons, no watermark, no tiny strokes, no realistic bamboo forest, no landscape, no ornate illustration, no glossy glass, no metallic gradients.
```

## 验证

`npm test` 包含图标资源回归验证，检查 PNG 尺寸与不透明像素、资产目录文件引用、Xcode 项目的资源关联和正式／Demo scheme 共用关系。使用 Xcode 模拟器构建验证资产编译与应用包中的图标声明。
