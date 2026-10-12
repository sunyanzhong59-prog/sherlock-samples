# Sherlock PoC Samples — Adversarial Solidity 样例集

> 两个自包含的对抗性漏洞样例，对准 AI 审计（如 Audit Engine 类工具）的自认短板：**复杂经济类漏洞**与**跨函数机制交互**。
> 均零第三方依赖（仅 forge-std），可直接编译，且附带**可复跑的链上验证**（非纸面 PoC）。

## 样例一览

| # | 类型 | 漏洞 | 判级 | 对准的方法论 |
|---|------|------|------|--------------|
| 1 | 复杂经济 | 同结果 × 两条路径，一条绕过 100% 入金费 | Medium（费用收入全额流失，理性用户必然走免费路径） | 费用绕过四问 |
| 2 | 机制交互 | ERC777 hook 打在 `withdraw` 中段，无守卫的 `deposit` 可跨函数重入，按虚低价铸股 | High（直接窃取其他存款人资金） | §AJ 重入四步 |

## 运行方式

### 方式 A — 标准 Foundry（任何正常环境）
```bash
forge test -vvv
```

### 方式 B — 本仓库自带的无 forge 真跑链路（solc + anvil + cast）
```bash
solc --combined-json abi,bin src/Sample1_FeeBypassVault.sol src/Sample2_CrossFnReentrancy.sol > _combined.json
anvil --port 8899
python verify_samples.py    # → TOTAL: 10/10 PASS
```

## 已执行验证结果（2026-10-13，solc 0.8.26 + anvil，10/10 PASS）

- **S1**：诚实路径付 10,000 USDC 费；`depositViaRouter` 路径同结果入账、财政库 **0 收入**，可无限重复。
- **S2**：hook 内池价 0.667e18 → attacker 付 100 tokens 拿 **133.3** tokens 价值，victim 100 → **66.7**（单轮偷走 33%）；复利 3 轮后 attacker 占池 **80.68%**。

## 方法论映射（为什么这两个样例打在 AI 审计的盲区上）

- **样例 1** 不是"找一个 bug"，而是**系统性问法**：任何"同一结果存在付费/免费两条路径"的协议面都适用。AI 审计容易逐函数看，容易漏"两条路径结果等价、费用处理不对等"这种跨函数经济对比。
- **样例 2** 的四步框架（回调点 → 守卫边界 → 状态最终化时序 → 窗口内 delta）把"跨函数重入"从模式匹配变成可推导的检查——单函数守卫齐全的协议照样中招，这正是"复杂机制交互"类漏洞的典型形态。

## 文件地图

```
src/Sample1_FeeBypassVault.sol      漏洞合约（MockUSDC + EntryFeeVault）
test/Sample1_FeeBypass.t.sol        Foundry 测试
src/Sample2_CrossFnReentrancy.sol   漏洞合约（HookToken + StakingPool + Attacker）
test/Sample2_CrossFnReentrancy.t.sol Foundry 测试
verify_samples.py                   无 forge 真跑验证（10/10 PASS，可复跑）
Sample1_README.md / Sample2_README.md 逐样例漏洞分析 + 判级论证
```
