# Squirrel 编译指南

## 环境要求

- macOS 10.15+
- **Xcode**（从 App Store 安装，不是只装 Command Line Tools）
- CMake

## 编译步骤

### 1. 设置 Xcode 路径

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

### 2. 安装依赖并初始化

```bash
sh action-install.sh   # 下载 librime、Sparkle 等预编译依赖
sh action-init.sh      # 初始化 plum、安装双拼等
```

### 2. 编译

```bash
make
```

## 常见问题

### xcodebuild requires Xcode

错误：`xcode-select: error: tool 'xcodebuild' requires Xcode`

解决：确保已安装完整 Xcode，然后设置路径

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

### make copy-rime-binaries 报错 rime-plugins 不存在

可以忽略，不影响编译。librime 已内置插件，无需外部 rime-plugins 目录。

## 输出

编译完成后，产物位于 `package/` 目录。
