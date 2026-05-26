# Render2img

SketchUp Ruby 插件，将 3D 模型一键渲染为 2D 图片平面，支持自动去背景和多视角输出。

## 功能

- **多视角渲染** — 前、后、左、右、顶 5 个正交视图
- **单面渲染** — 仅渲染正面，适合做卡片/立牌
- **居中模式** — 多面居中排列，背面自动交换材质
- **自动裁剪** — 像素检测自动裁剪白边
- **透明背景** — 白色背景自动转为透明
- **分辨率可调** — 64px ~ 4096px

## 安装

将整个仓库文件夹放入 SketchUp 插件目录：

```
%APPDATA%\SketchUp\SketchUp 20XX\SketchUp\Plugins\
```

## 使用

1. 在 SketchUp 中选中模型或组件
2. 点击 **Auto Render** 工具栏按钮
3. 设置渲染分辨率
4. 选择渲染模式，自动生成结果

## 依赖

- SketchUp 2018+
- [ChunkyPNG](https://github.com/wvanbergen/chunky_png) v1.4.0（已内置，也支持系统安装版）
- ImageMagick（可选，用于去背景和裁剪的备用方案）

## 配置

在 `render2img.rb` 中修改 `DEFAULT_CONFIG`：

```ruby
DEFAULT_CONFIG = {
  crop_method: 'pixel_detect',  # 裁剪方式
  uv_method: 'point_mapping',   # UV 贴图方式
  enable_crop: true              # 是否启用裁剪
}
```

## 目录结构

```
├── render2img.rb              # 主插件文件
├── chunky_png/                # ChunkyPNG 库（内置）
│   └── lib/
│       ├── chunky_png.rb
│       └── chunky_png/
│           ├── canvas.rb
│           ├── color.rb
│           ├── image.rb
│           └── ...
└── README.md
```
