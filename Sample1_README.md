# Sample 1 — 入金费 100% 可绕过（双路径费用不对等）

**Severity: Medium ｜ 类型: Economic / Fee Bypass ｜ 方法论: 费用绕过四问**

## 协议意图

`EntryFeeVault` 对每笔存款收 1% 入金费（`ENTRY_FEE_BPS = 100`），划转至 `feeTreasury`，存款人按扣费后净额获得份额。

- **Path A** `depositWithFee(uint256)`：用户路径，合约内收 1% 并转账给财政库。
- **Path B** `depositViaRouter(address router, uint256)`：为前端/合作 router 预留——**文档假设** router 会自行把费用划给财政库，但合约**不验证**、**无权限控制**。

## 漏洞

`depositViaRouter` 对任意人开放，`router` 参数仅作占位（`router; // unused`）。
任何人直接调用即可按**全额**获得份额，1% 费用分文不付：

> **同结果 × 两条路径（金库余额同样 +amount），其中一条完全不付费 ⇒ Medium+**

## 经济影响

- 绕过路径**严格占优**：理性用户 100% 走免费路径 ⇒ 费用收入趋近 **100% 流失**。
- PoC 实测（10/10 PASS）：
  - Path A 存 1,000,000 USDC → 财政库收 10,000 USDC ✅
  - Path B 存 1,000,000 USDC → 金库全额入账、财政库 **0 收入** ✅
  - 5 次绕过后财政库仍只有 Path A 那一笔 10,000 ✅

## PoC 锚点

- 漏洞点：`src/Sample1_FeeBypassVault.sol` — `depositViaRouter()`（无授权检查 + `_convertToShares(amount)` 按全额计股）
- 对照：同文件 `depositWithFee()`（fee/net 正确拆分）
- 测试：`test/Sample1_FeeBypass.t.sol` — `test_routerPath_bypassesFee` / `test_feeRevenue_fullyEvadable`

## 修复建议

- `depositViaRouter` 加 `require(router == authorizedRouter)` 或直接删除该函数；
- 或改为合约内统一计费：任何入金路径都先在合约层扣费，router 仅做转发。
