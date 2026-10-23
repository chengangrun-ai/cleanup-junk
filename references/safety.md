# cleanup-junk 安全规范与垃圾目标清单

本文件供 skill 执行时参考。核心原则：**先报告，再确认，回收站优先，绝不碰个人目录。**

## 一、铁律（任何情况下不得违反）

1. **默认只读**：未收到明确的清理指令前，只扫描、只报告，不创建/不修改/不删除任何文件。
2. **删除必须显式确认**：向用户展示扫描报告后，由用户选定要清理的类别，才能执行清理。
3. **回收站优先**：temp / browsercache 的清理一律“送入回收站”（`SHFileOperation` + `FOF_ALLOWUNDO`），可恢复，绝不永久删除。
4. **No-Go 区永不处理**：
   - 桌面（`Desktop`）
   - 文档（`Documents`）
   - 用户主目录根（`C:\Users\<用户>`）
   - 系统盘根（`C:\`）
   - 下载目录（`Downloads`）**仅允许扫描报告，禁止自动删除**
5. **largeold 类别永不自动删除**：扫描下载目录的大/旧文件只为“提示”，删除与否完全由用户手动决定。
6. **回收站清空是永久操作**：清空回收站会把已删除文件彻底抹掉、不可恢复；只能在用户**单独、明确**同意时，用 `-EmptyRecycleBin -Force` 执行，且要在报告里用醒目文字提示“不可恢复”。

## 二、垃圾目标清单（Windows）

### temp —— 系统/应用临时文件与缓存
| 目标路径（变量展开后） | 内容 | 风险 |
|---|---|---|
| `%TEMP%` / `%TMP%` | 当前用户临时文件 | 低，多为可重建 |
| `C:\Windows\Temp` | 系统临时文件 | 低 |
| `C:\Windows\Prefetch` | 预读取缓存 | 低（系统会重建） |
| `%LOCALAPPDATA%\Temp` | 应用临时文件 | 低 |
| `%LOCALAPPDATA%\Microsoft\Windows\WER` | Windows 错误报告 | 低 |
| `%LOCALAPPDATA%\Microsoft\Windows\Explorer` | 缩略图缓存 `thumbcache_*.db` | 低 |

### browsercache —— 浏览器缓存
| 浏览器 | 处理的子目录 | 绝不碰的文件 |
|---|---|---|
| Chrome | `User Data\Default(|Profile*)\Cache / Code Cache / Media Cache / GPUCache / Service Worker\CacheStorage / ShaderCache` | `Cookies`、`History`、`Bookmarks`、`Login Data`、`Web Data` |
| Edge | 同上（Microsoft\Edge） | 同上 |
| Firefox | `Profiles\*\cache2 / thumbnails / startupCache` | `places.sqlite`、`cookies.sqlite`、`logins.json` |

> 清理方式是删除“缓存子目录内的内容”，浏览器下次启动会重建缓存，不影响登录态与书签。

### recyclebin —— 回收站
- 仅报告大小与项数；清空为永久删除，需单独确认。

### largeold —— 下载目录大/旧文件（仅报告）
- 默认扫描 `%USERPROFILE%\Downloads`：文件 ≥ 200MB 或 最后写入 > 90 天 命中。
- 仅列出路径、大小、日期、命中原因；**不删除**。

## 三、确认话术模板（向用户展示）

```
已扫描完成。可清理项合计约 X GB：
- temp：Y GB（系统/应用临时文件，清理后送入回收站，可恢复）
- browsercache：Z GB（浏览器缓存，不影响书签/登录）
- recyclebin：W GB（清空为永久删除，不可恢复）
- largeold：V GB（仅报告，需你手动决定）

请选择要清理的类别（可多选）：temp / browsercache / recyclebin（含清空）/ largeold(不删)
```

## 四、脚本调用约定

- 扫描：`scripts/scan_junk.ps1 [-Categories ...] [-Output report.json]`
- 计划预览（dry-run）：`scripts/clean_junk.ps1 -Categories temp,browsercache`（不传 -Force 仅打印计划）
- 执行（进回收站）：`scripts/clean_junk.ps1 -Categories temp,browsercache -Force`
- 清空回收站（永久）：`scripts/clean_junk.ps1 -Categories recyclebin -Force -EmptyRecycleBin`

> 清理脚本内置 No-Go 校验：任何落入禁区的路径都会被跳过并告警。
