# Sample 2 — 跨函数重入：单函数守卫齐全仍被抽干（ERC777 hook × 股份会计）

**Severity: High ｜ 类型: Mechanism Interaction / Cross-function Reentrancy ｜ 方法论: §AJ 重入四步**

## 协议形态

`StakingPool` 接受 hook 型资产（ERC777 族：`tokensReceived` 回调），`totalShares` 跨 `deposit` / `withdraw` 共享：

- `withdraw(uint256)`：**有** `nonReentrant` 守卫；
- `deposit(uint256)`：**无**守卫（"存款是安全的"这一直觉假设）；
- `withdraw` 的执行序：扣 `sharesOf` → **外部调用** `asset.transfer`（此处触发 hook）→ **之后**才 `totalShares -= shares`。

## §AJ 四步推导

| 步骤 | 结论 |
|------|------|
| ① 回调点 | `asset.transfer` 在 `withdraw` 中段触发 `tokensReceived` |
| ② 守卫边界 | `nonReentrant` 只封 `withdraw`；`deposit` 可从 hook 内自由重入 |
| ③ 最终化时序 | hook 时刻 `balanceOf(pool)` 已减、`totalShares` **尚未减**（虚高） |
| ④ 窗口内 delta | `sharePrice = balanceOf×1e18/totalShares` 被临时压低 → 重入 `deposit` 按折价铸股 |

## 攻击与实测数字（10/10 PASS）

Setup：victim 与 attacker 各存 100 tokens（par 价 1e18）。

1. attacker `unstake(100e18 shares)` → pool 付 100 tokens，hook 触发；
2. hook 内：`balanceOf(pool)=100e18`、`totalShares=200e18`（stale）→ 池价 **0.5e18**；
3. 重入 `deposit(100 tokens)` → 铸出 **200e18 shares**（付 100 得 200）；
4. hook 返回后 `totalShares -= 100e18` → 终态池价 0.667e18。

**终态（实测）**：
- attacker：200e18 shares ≈ **133.3 tokens**（实付 100）✅
- victim：100e18 shares ≈ **66.7 tokens**（存入 100，**单轮被偷 33%**）✅
- 复利 3 轮（每轮抽半复投）→ attacker 池内价值 **161 tokens，占池 80.68%** ✅ → 可逼近吃干。

## PoC 锚点

- 漏洞点：`src/Sample2_CrossFnReentrancy.sol` — `StakingPool.withdraw()`（`totalShares` 在外部调用后才最终化）+ `deposit()`（无守卫）
- 攻击合约：同文件 `Attacker`（`tokensReceived` 内重入 `pool.deposit`）
- 测试：`test/Sample2_CrossFnReentrancy.t.sol` — `test_endToEnd_dilution` / `test_repeatable_untilPoolDrained`
- 真跑：`verify_samples.py` [S2] 段 6/6 断言

## 现实对应

该模式不要求合约"写错"重入守卫——**守卫写对了照样中招**。只要 ① 资产可带回调（ERC777 / 带钩子的 rebasing 包装物）② 两个函数共享全局会计状态 ③ 其一在外部调用后最终化状态，即可成立。属于 AI 审计自认短板的"复杂机制交互"类。

## 修复建议

- `withdraw` 先**全部**最终化状态（`totalShares -= shares` 移到 `asset.transfer` 之前，CEI 模式）；
- 或对 `deposit` / `withdraw` 共用同一把全局重入锁（池级锁，而非函数级）；
- 接受资产白名单（仅无 hook 的标准 ERC20）。
