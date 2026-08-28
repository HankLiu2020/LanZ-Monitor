# LanZ Monitor

一个适用于 Windows 的轻量悬浮负载监控组件。它从兼容的模型状态 API 读取并展示各模型的当前并发量、容量、负载百分比及近期变化。

![LanZ Monitor 界面截图](docs/screenshot.png)

## 功能

- 每 10 秒自动刷新，也可暂停或手动刷新。
- 自适应纵轴折线图会放大近期波动区间。
- 绿、橙、红三档负载底色。
- 模型卡片可拖动排序，并在本机保存顺序。
- 大头钉可开启或取消窗口置顶。
- 会话失效时通过 WebView2 打开登录页面并自动接收新 Cookie。
- 连接配置和会话值使用 Windows DPAPI 加密，仅当前 Windows 用户可解密。

## 系统要求

- Windows 10 或 Windows 11
- PowerShell 7 或 Windows PowerShell 5.1
- Microsoft Edge WebView2 Runtime
- 一个与本项目数据结构兼容的模型状态 API

## 首次使用

1. 下载或克隆仓库。
2. 双击 `setup-session.cmd`。
3. 根据提示填写 API 地址、网页登录地址、Cookie 名称、请求令牌参数和接口状态代码。
4. 输入当前会话值。敏感输入不会显示在终端中。
5. 双击 `start-widget.cmd`。

配置保存在 `.lanz-config.bin`，会话值保存在 `.lanz-session.bin`。二者均经过当前 Windows 用户范围的 DPAPI 加密，并已被 `.gitignore` 排除。需要修改连接参数时可执行：

```powershell
pwsh -NoProfile -File .\Set-LanZSession.ps1 -Reconfigure
```

也可以临时设置环境变量 `LANZ_SESSION_VALUE` 来覆盖本地加密会话值。

## 界面说明

- 当前负载是模型卡片右上角的百分比。
- “纵轴 2–14%”表示折线图当前显示的纵轴刻度范围，并非当前负载。
- 负载低于 60% 显示绿色，60%–84% 显示橙色，85% 及以上显示红色。
- 按住模型卡片上下拖动可改变顺序。
- 右上角大头钉亮起时窗口保持置顶。

## 安全设计

- 仓库不包含服务地址、Cookie 名称、请求签名密钥、会话值或账号密码。
- 程序不会读取网页登录密码，只读取配置指定域名在登录完成后设置的会话 Cookie。
- WebView2 使用独立的持久化用户数据目录，不直接读取桌面版 Edge 的密码库。
- 自动填充和密码保存由 WebView2 Runtime 管理。

## 数据格式

当前解析逻辑期望 API 返回对象包含：

- `code`：接口状态代码
- `data[].modelName`：展示名称
- `data[].apiInterface`：模型 ID
- `data[].routeStatus.total_active`：当前并发量
- `data[].routeStatus.effective_max_concurrent`：有效容量
- `data[].routeStatus.available`：可用状态

负载计算方式为：

```text
floor(total_active / effective_max_concurrent * 100)
```

最高显示为 100%。

## 第三方组件

登录窗口使用 Microsoft WebView2 SDK。相关文件位于 `lib/WebView2`，组件许可见 `lib/WebView2/LICENSE.txt`。

## License

[MIT](LICENSE)
