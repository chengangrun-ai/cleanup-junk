---
name: cleanup-junk
description: "Windows 电脑垃圾清理助手。当用户要求清理电脑垃圾、清缓存、释放C盘空间、清理临时文件、清回收站或扫描大文件时使用。该 skill 采用先扫描报告、再确认清理的两阶段流程，默认只读取并生成可清理项报告，删除动作在用户明确确认后才执行，且临时文件与浏览器缓存一律送入回收站（可恢复），绝不触碰桌面、文档、下载等个人目录。仅支持 Windows。"
---

# Cleanup Junk（Windows 垃圾清理）

## Overview

本 skill 帮助在 Windows 上安全清理“垃圾”文件，覆盖四类目标：系统/应用临时文件、浏览器缓存、回收站、下载目录的大/旧文件。设计核心是**安全优先**——默认只读扫描并生成报告，任何删除都需用户确认，且除回收站清空外一律送入回收站（可恢复）。

## When to Use

在以下场景触发本 skill：

- 用户说“清理电脑垃圾”“清一下 C 盘”“清理临时文件/缓存”“清空回收站”“释放磁盘空间”。
- 用户要求“扫描大文件 / 找占空间的文件 / 看看哪些文件很久没动”。
- 注意：若用户要求**直接、无确认地删除**个人目录（桌面、文档、下载）中的文件，应拒绝并提示风险，仅提供只读扫描报告。

## Workflow（两阶段）

### 阶段 0：确认范围（必要时）

若用户未说明要清理哪些类别，先按 `references/safety.md` 的“确认话术模板”询问。默认四类都扫描，但清理需逐类确认。

### 阶段 1：扫描并报告（始终只读）

运行扫描脚本，生成结构化 JSON 报告：

```powershell
# 默认扫描全部四类；也可指定类别
scripts/scan_junk.ps1 -Categories temp,browsercache,recyclebin,largeold -Output report.json
# 或仅打印到 stdout
scripts/scan_junk.ps1
```

读取报告后，用自然语言向用户汇总：
- 各类别可清理大小（temp / browsercache / recyclebin / largeold）。
- 明确标注：`largeold` 仅为报告、不删除；`recyclebin` 清空为永久删除。
- 列出每类 top 文件（来自报告的 `topFiles` / `files`）让用户心里有数。

**不要在此阶段执行任何删除。**

### 阶段 2：确认后清理

根据用户选定的类别执行。先做一次 dry-run 预览（不传 `-Force` 仅打印计划），确认无误后再带 `-Force` 真正执行：

```powershell
# 1) 预览计划（不改动任何文件）
scripts/clean_junk.ps1 -Categories temp,browsercache

# 2) 真正送入回收站（可恢复）
scripts/clean_junk.ps1 -Categories temp,browsercache -Force

# 3) 仅当用户明确同意清空回收站时（永久删除）
scripts/clean_junk.ps1 -Categories recyclebin -Force -EmptyRecycleBin
```

清理结果会输出 JSON（每项成功/失败）。向用户汇报清理了多少、有无失败项。

## Safety Rules（必须严格遵守，详见 references/safety.md）

1. **先报告，后清理**：未展示扫描报告并获确认前，不删除任何东西。
2. **回收站优先**：temp / browsercache 一律“送入回收站”（`FOF_ALLOWUNDO`），可恢复。
3. **No-Go 区**：桌面、文档、用户主目录根、系统盘根、下载目录——绝不自动删除；下载目录只扫描、不删。
4. **largeold 永不自动删**：仅报告，删除由用户手动决定。
5. **回收站清空需单独、明确确认**，并在对话中以醒目方式提示“不可恢复”。
6. 清理脚本内置 No-Go 校验，任何落入禁区的路径会被自动跳过并告警——但不要因此放松对话层的确认。

## Resources

- `scripts/scan_junk.ps1` —— 只读扫描，输出 JSON 报告（路径/大小/日期/分类）。参数：`-Categories`、`-LargeFileMB`、`-OldDays`、`-ScanRoot`、`-TopFiles`、`-Output`。
- `scripts/clean_junk.ps1` —— 清理执行。默认 dry-run；`-Force` 才真正删除；`-EmptyRecycleBin` 仅用于永久清空回收站。内置 No-Go 校验与回收站投递。
- `references/safety.md` —— 垃圾目标完整清单、No-Go 区、确认话术模板、脚本调用约定。
