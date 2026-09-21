# claude-code-cache-keepalive

[English](README.md) · **简体中文**

<p>
<a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
<a href="test.sh"><img alt="tests: 29 passing" src="https://img.shields.io/badge/tests-29%20passing-brightgreen"></a>
<img alt="Claude Code plugin" src="https://img.shields.io/badge/Claude%20Code-plugin-6E56CF">
<img alt="requires Monitor tool" src="https://img.shields.io/badge/requires-Monitor%20tool-orange">
</p>

**让 Claude Code 的 prompt cache 在闲置期间保持温热 —— 而且不冻结你的终端。**

一个 `Stop` hook 只做一件事：把"这个会话刚刚活跃过"的时间戳写下来。
后台的 **Monitor** 盯着这个时间戳，只有当会话空闲超过阈值（默认 **50 分钟**）时
才输出一行。这一行会被投递给 Claude 当作通知 → 触发一次新回合 → **读取**缓存
→ 刷新 prompt cache 的 TTL。用一次便宜的读，换掉一次昂贵的整体重写。

面向 **1 小时** 缓存 TTL 设计；如果你用的是 5 分钟 TTL，把
`CCKA_IDLE_SECONDS` 设为 `240`。

## 省钱一览

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/cost-chart-dark.svg">
  <img alt="柱状图：1M 上下文下 warm 10 次 vs cold start 1 次。Opus 5 $5/$10、Sonnet 5 $2/$4、Sonnet 4.6 $3/$6、Haiku 4.5 $1/$2、Fable 5.1 $2.50/$20，节约 2×（Fable 5.1 为 8×）" src="docs/cost-chart-light.svg" width="860">
</picture>

warm ×10（缓存**读**）vs. cold start ×1（1 小时缓存**重写**），USD：

| 模型 | 100K 上下文 | 1M 上下文 | 节约倍数 |
| --- | ---: | ---: | ---: |
| Opus 5 / 4.8 / 4.7 / 4.6 | $0.50 → $1.00 | $5.00 → $10.00 | **2×** |
| Sonnet 5 | $0.20 → $0.40 | $2.00 → $4.00 | **2×** |
| Sonnet 4.6 / 4.5 | $0.30 → $0.60 | $3.00 → $6.00 | **2×** |
| Haiku 4.5 | $0.10 → $0.20 | $1.00 → $2.00 | **2×** |
| Fable 5.1 | $0.25 → $2.00 | $2.50 → $20.00 | **8×** |

`warm ×10 → cold ×1`。10 次 ping ≈ **8 小时**温热；空闲 12 小时后停止 ping，正好压在
1 小时重写的 **20 次**回本线内。完整表格（20K–1M、全部模型、回本线）与生成脚本：
**[docs/COST.md](docs/COST.md)**（英文）。

## 适合谁 / 不适合谁

✅ **适合：官方 Anthropic 上的 Claude Code** —— **Pro/Max 订阅**和 **Console API key**
都行。订阅制下主对话默认是 **1 小时** 的 prompt cache TTL（在套餐额度内）；一旦你离开
超过 1 小时，下一条消息就要重新处理整个前缀——更慢，而且比一次缓存读多消耗得多。
这个插件把前缀保持温热，让你回来时走一次便宜的缓存**读**。默认配置（50 分钟）就是
照 1 小时 TTL 调的。

API key 默认只有 **5 分钟** TTL，那就要把参数调小，或自己设 1 小时 TTL——见“时序约束”。

❌ **不适合**：DeepSeek / GLM / OpenRouter 等**第三方 Anthropic 兼容网关**，以及
Bedrock / Vertex / Foundry——**Monitor 工具是官方专属**，那里 monitor 根本不会启动，
而且它们的缓存语义也不同。

## 原理

```
回合结束 (Stop) ─────────────► stamp hook: last_stop = now   （瞬间返回，不阻塞）
你提交 (UserPromptSubmit) ───► stamp hook: last_stop = now

后台 Monitor（随会话结束而终止）：
  每 TICK（默认 300s）：
    idle = now - last_stop
    idle < IDLE_SECONDS ? 什么都不做
                        : echo "<ping>"  ─► 作为通知投递给 Claude
                                              └► 新回合 → 读缓存 → 刷新 TTL
                                                 └► 回合结束 → Stop → 重新计时 → ↻
```

计时器就是 `now - last_stop`，所以它是一个**可重置的空闲计时器**：每次 Stop 都
重新开始计 50 分钟。你在连续对话时永远不会被打扰，只有真正静置才会 ping。

### 为什么用 Monitor，而不是"睡觉的 Stop hook"

| | 睡觉的 Stop hook | **Monitor（本仓库）** |
|---|---|---|
| 阻塞界面 | 是（要按 Esc） | **否** |
| 受 8 次连续 block 上限 | 是 | **否** |
| 一次等 ~50 分钟 | 不行（hook 超时） | **可以** |
| 空闲期间成本 | — | 一次本地 `sleep`，0 token |
| 何时 ping | 每个回合之后 | 只在真正空闲时 |

## 安装

**方式一（推荐）—— 作为插件，自动启动 Monitor**

```
/plugin marketplace add demouo/claude-code-cache-keepalive
/plugin install cache-keepalive@claude-cache-tools
```

非交互式：

```bash
git clone https://github.com/demouo/claude-code-cache-keepalive.git
claude plugin marketplace add ./claude-code-cache-keepalive
claude plugin install cache-keepalive@claude-cache-tools
```

插件自带 `monitors/monitors.json`（`"when": "always"`），Monitor 会随会话自动启动。

**方式二 —— 直接写 `settings.json`**

```bash
git clone https://github.com/demouo/claude-code-cache-keepalive.git
cd claude-code-cache-keepalive
./test.sh          # 可选自检
./install.sh       # 写入 hooks
```

这种方式**不会自动启动 Monitor**，需要每个会话手动起一次：

```
Monitor(command="bash ~/.claude/hooks/cache-keepalive-monitor.sh", persistent=true)
```

## 配置

Monitor 读取顺序：**环境变量 → `~/.claude/cache-keepalive/config` → 默认值**。

| 变量 | 默认 | 说明 |
|---|---|---|
| `CCKA_IDLE_SECONDS` | `3000` | 空闲多久才 ping（50 分钟） |
| `CCKA_TICK_SECONDS` | `300` | 检查粒度（5 分钟） |
| `CCKA_MAX_IDLE_SECONDS` | `43200` | 空闲超过这么久就停止 ping（12 小时；0 = 不限） |
| `CCKA_PING_TEXT` | 一句 bland 文本 | 注入给 Claude 的内容 |
| `CCKA_ENABLED` | `1` | `0`/`false`/`no`/`off` 关闭 |
| `CCKA_RETENTION_DAYS` | `7` | 超过多久的会话状态进入归档 |
| `CCKA_ARCHIVE_KEEP_DAYS` | `0` | 归档保留多久（0 = 永久） |
| `CCKA_HOUSEKEEP_INTERVAL` | `21600` | 两次清理的最小间隔秒数 |

时序约束：`IDLE + (TICK - 1)` 必须小于缓存 TTL（默认组合最坏 55 分钟 < 1 小时）。

## 验证

```bash
./test.sh        # 29 项自检，不需要 Claude Code
```

运行时日志（按会话分开）：

```bash
tail -f ~/.claude/cache-keepalive/cache-keepalive.<session-id>.log
# 出现 "emitting keepalive" 且 Claude 主动回话 = 全链路跑通
```

## 卸载

```bash
claude plugin uninstall cache-keepalive
# 或者（settings 方式）
./uninstall.sh --purge
```

## 注意事项

1. **需要 Monitor 工具**：较新版 Claude Code，且不能设置
   `DISABLE_TELEMETRY` / `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`，也不支持
   Bedrock / Vertex / Foundry。插件 monitor 仅在**交互式 CLI** 会话运行。
2. **用量**：订阅和 API 都适用。订阅制下它的意义是避免“空闲超过 1 小时 TTL 后再
   重新处理整段前缀”——那会更慢、也更吃套餐额度；ping 本身只花一次缓存读。
3. **ping 是一个真实回合**，会进 transcript、消耗一次缓存读 + 一句回复。
4. **退出时会弹确认**："Background work is running … Exit anyway?"（上游
   issue #58852，已 closed as not planned，插件侧无法关闭）。默认就停在
   *Exit anyway*，回车即可。
5. 每会话独立计时；隔很久 resume 时会把过期心跳重置为"现在"，不会一进来就 ping。
6. 状态文件会在会话启动时按日期归档到 `archive/cache-keepalive-<日期>.tar.gz`。
7. 空闲超过 `CCKA_MAX_IDLE_SECONDS`（默认 12 小时）后会**停止 ping**，避免被晾着的
   会话白烧用量；一旦有新活动（新消息 / Stop）就自动恢复。

## 相关项目

- [yujiachen-y/claude-code-cache-keepalive](https://github.com/yujiachen-y/claude-code-cache-keepalive)
  —— 同样目标，用"睡觉的 Stop hook"实现，任何 provider 都能跑，但阻塞界面、
  受 8 次 block 上限、一次只能覆盖约 30 分钟。
- Aider `--cache-keepalive-pings`、Cache-Refresh-SillyTavern、cline/cline#414
  —— 同一个"读缓存会刷新 TTL"的技巧，出现在别的工具里。

## License

MIT —— 见 [LICENSE](LICENSE)。
