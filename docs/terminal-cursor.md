# 附二：TUI 光标不可见（pi / vim 的"反显光标"）—— 根因与修法

> 结论先说：**这不是 Zed 的渲染 bug**。反显属性在到达 Zed 之前，就已经被 **Windows ConPTY 烘焙成了显式颜色**，
> 而浅色主题把 `ansi.white` 映射成了和终端背景相同的白色，于是"白色块 + 空格"= 看不见。

## 现象

- 在 Zed（浅色主题）的终端里跑 `pi`，输入行的光标看不见；
- 同一个 `pi` 在 Windows Terminal / VS Code（深色背景）里正常；
- 加上 `showHardwareCursor: true`（Pi 设置）或 `PI_HARDWARE_CURSOR=1` 就正常；
- `vim` / `htop` 之类同样是浅色主题下光标丢失。

## 证据链（逐段实测）

### 1. Pi 画的是"反显单元格"

Pi 的 TUI 用反显视频画软件光标（`pi-tui` 的 `components/input.js` / `editor.js`）：

```js
const cursorChar = `\x1b[7m${atCursor}\x1b[27m`;   // ESC[7m = 反显, ESC[27m = 取消反显
```

### 2. ConPTY 把"反显"烘焙成 ANSI 默认调色板颜色

Windows 的 console 属性模型里**没有"反显"这一位**（只有前景色/背景色），所以 ConPTY 在
重发屏幕内容时会把反显折算成显式颜色。实测（`node` 写入，抓 `ssh -tt` 回来的字节）：

```
写入 :  A  ESC[7m  X  ESC[27m  B
回来 :  A  ESC[30m ESC[47m X ESC[m B        ← 反显被换成了 黑字(30) + ANSI 白底(47)
```

对照：显式写 `ESC[30m ESC[47m` 的字节原样回来，没有被改动。

> 注意：如果你只是把 `ESC[7m` **当文本**写进控制台（例如 `[Console]::Write`），它会原样透传——
> 那是字符，不是属性。必须像 Pi 那样由 VT 处理才会被烘焙。

### 3. 浅色主题里 `ansi.white` == 终端背景色

用户主题 `VS Code Light 2026`：

```
terminal.background = #FFFFFF
terminal.ansi.white = #FFFFFF     ← ConPTY 烘焙出的光标底色
```

于是那格 = **白底 + 空格**，在白色终端背景上完全不可见。

对比 Zed 内置的 `One Light`：`background #fafafa` / `ansi.white #bbbbbb` → 浅灰块可见 ✓
（`Ayu Light`：`#fcfcfc` / `#fcfcfc`，同样有问题 ✗）

## 修法

### A. 用硬件光标（推荐，最省事）

```jsonc
// %USERPROFILE%\.pi\agent\settings.json  （跑 pi 的那台机器）
{ "showHardwareCursor": true }
```

或临时：`PI_HARDWARE_CURSOR=1`。硬件光标由终端自己绘制（用主题的 cursor 颜色），
完全不经过 ConPTY 的调色板烘焙，任何主题下都可见。

### B. 主题覆盖：让 `ansi.white` 与背景可区分

```jsonc
// 客户端那台机器的 Zed settings.json（渲染在本地，所以改客户端就行，不用改远端）
"experimental.theme_overrides": {
  "terminal.ansi.white": "#b0b0b0"     // 浅灰；想更淡/更深可调 #c8c8c8 / #999999
}
```

也可以写成新式的、按主题名分组的形式（Zed 文档里的 `theme_overrides`）：

```jsonc
"theme_overrides": {
  "VS Code Light 2026": { "terminal.ansi.white": "#b0b0b0" }
}
```

选色建议：

| 取值 | 效果 |
| --- | --- |
| `#b0b0b0` | 白底上是一块明显的浅灰（推荐） |
| `#c8c8c8` | 更柔和、更不明显 |
| `#999999` / `#8a8a8a` | 对比度最强，但 ANSI white 的文字也会明显变灰 |

副作用：终端里所有 ANSI white（`\x1b[37m` / `\x1b[47m`）都变成这个灰。在浅色主题下通常**反而更好**
（浅背景上的“白字”本来就没对比度；`One Light` 就是这么映射的：`#fafafa` + `#bbbbbb`）。

> 注意：覆盖后需要**新开一个终端标签**（或等设置热重载）才会看到效果。

### C. 换主题 / 换背景

- 用把 white 映射成灰色的浅色主题（如 Zed 内置 `One Light`）；
- 或把终端背景改成深色（`terminal.background`）。

### D. 反馈上游

1. **Pi**：在 Windows/ConPTY 下默认使用硬件光标就更稳；或者用 OSC 11 查到的终端背景色来选光标的显式颜色。
2. **主题 / Zed 内置主题**：浅色主题里 `ansi.white` 不应等于 `terminal.background`（`Ayu Light` 也有同样问题）。

## 一句话总结

| 层 | 行为 |
| --- | --- |
| Pi | 用 `ESC[7m` 画反显光标（本身没问题，主题无关） |
| ConPTY | 把反显折算为 `ESC[30m ESC[47m`（黑字 + ANSI 白底）——**信息在这里丢失** |
| Zed | 忠实渲染 `47m` = 主题的 `ansi.white`；若它等于背景色 → 光标不可见 |
