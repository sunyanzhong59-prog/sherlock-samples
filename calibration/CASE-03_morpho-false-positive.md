# CASE-03 —— 我唯一一次误报：一个"三重边缘条件"的赎回 DoS

> **English abstract.** This is the author's single recorded false positive across 30
> calibration exercises, published deliberately. The claim: ceil-rounded debt accounting in
> `componentRedeemHook` lets accumulated rounding push the requested repay above the
> outstanding Morpho debt, reverting the redeem path. The underlying Morpho property is
> real — the official judgement *did* accept it, but only in its **attacker-triggered**
> form (`050.md`, Medium). The variant presented here needs no attacker; it needs a
> near-closed position plus a specific parameter/decimal combination. It was not accepted.
> **The lesson is not "the code is fine" — it is "a weaker trigger is a different finding".**

---

## 0. 为什么要把自己的误报写成文档

30 个靶里，我只有 **1 条**误报（`#23 morpho-x-index` 的 F2）。其余靶的误纳在 0–4 之间，`#27`/`#30` 归零。

一条误报听起来微不足道。但它是**唯一一个"我报了、而对方判定不成立"的样本** —— 也就是说，它是**唯一一个真实暴露了 submission 风险的样本**。把它写出来、把触发条件摊开、把官方的分界线标清楚，比再写十篇成功的 exploit 更有用：

- 对读者：这是"什么程度才算真的可报"的边界标本；
- 对我自己：它是**唯一一条无法靠"再读一遍代码"消除的错误** —— 代码我读对了，结论方向也对了，错的是**可接受门槛**。

---

## 1. 我报了什么

**主张**：`MorphoLeverageModule.componentRedeemHook` 在赎回 Set Token 时，把「每个 Set Token 对应的债务」按**向上取整**存入外部头寸，赎回时用该单位值 × 赎回量计算还款额；由于向上取整，**多次部分赎回的还款额之和会超过实际剩余债务**，最终使 Morpho 的 `repay` 因 `toSharesDown(assets) > borrowShares` 而下溢 revert ⇒ **赎回路径 DoS**。

**自评级别**：Medium（核心赎回功能在特定参数域不可用）。

**我引用的协议声明（逐字）**：

> "should always be possible to redeem tokens as long as the total supply after redemption is > 0.001 Tokens (1e15 wei)"
> —— 并明确：**由舍入引发的次生安全问题 in scope**

---

## 2. 机制

### 2.1 单位债务被向上取整

```solidity
// MorphoLeverageModule.sol:657  —— 记账
borrowPosition = borrowBalance.preciseDivCeil(_setTotalSupply).toInt256().mul(-1);
```

`preciseDivCeil` ⇒ 每个 Set Token 分摊的债务**向上取整**。这对"不能欠债不足"是保守的、正确的方向。

### 2.2 赎回 hook 用这个单位值反向乘回来

```solidity
// MorphoLeverageModule.sol:586-612（节选）
function componentRedeemHook(...) external override onlyModule(_setToken) {
    MarketParams memory setMarketParams = marketParams[_setToken];
    ...
    if (!_isEquity) {
        require(setMarketParams.loanToken == address(_component), "Debt component mismatch");
        int256 componentDebt = _setToken.getExternalPositionRealUnit(address(_component), address(this));
        require(componentDebt < 0, "Component must be negative");

        uint256 notionalDebt = componentDebt.mul(-1).toUint256().preciseMul(_setTokenQuantity);
        _repayBorrow(_setToken, setMarketParams, notionalDebt, 0);   // L610  ← assets 计价，shares = 0
    }
}
```

### 2.3 断点在 Morpho 侧

`_repayBorrow(..., shares = 0)` 走 Morpho 的**按资产额还款**分支。Morpho v1.1：

```solidity
// morpho-blue/src/Morpho.sol:283-286
shares = assets.toSharesDown(market[id].totalSupplyAssets, market[id].totalSupplyShares);
position[id][onBehalf].borrowShares -= shares.toUint128();   // ← shares > borrowShares ⇒ 0.8 underflow revert
```

所以链条是：

```
ceil 单位债务 × 赎回量  >  实际剩余债务
        ⇒ toSharesDown(assets) > borrowShares
        ⇒ Morpho repay 下溢 revert
        ⇒ componentRedeemHook revert
        ⇒ 赎回不可用
```

**注意 `_repayBorrow` 的 `shares = 0`**：调用方已经决定了"要还多少资产"，链上无法再回退到"还到债务清零为止"。这是本机制的关键脆弱点 —— **它把"还多少"的话语权完全交给了借方计算，而不是交给实际债务状态。**

---

## 3. 我自己的数值推演 —— 以及它本该如何阻止我

我在封笔前已经算过触发条件（原文摘录）：

> ceil 残差 `ε_total < supply / 1e18`（base 单位）；`K = (T + 1e6) / (A + 1) ≈ 1e6`（Morpho 的 VIRTUAL_SHARES 使 `shares ≈ assets × 1e6`）⇒ `ε × K ≈ N_tokens × 1e6`；剩余 supply `r` 的债务缓冲 = `S_p × r / supply`。
> **`r = 1e15 wei`（Q&A 底线）时，revert 条件 ≈ `debt < supply × 1e-7`**
> USDC 数值例：`supply = 1000 tokens` ⇒ 需要 `debt < ~$1000`。

换句话说，**我算出了触发条件需要三个条件同时成立**：

| 条件 | 说明 |
|---|---|
| ① 头寸接近清仓 | 债务远小于供应量（比例 ~1e-7） |
| ② 特定市场参数组合 | 抵押品价格 / LLTV / VIRTUAL 缩放共同决定残差能否超过缓冲 |
| ③ 精度组合 | 抵押品与借款资产的 decimals 差异放大或缩小残差 |

**然后我仍然保留了 Medium 并列为"待提交"。**

这是本轮最该记的一件事：**数值推演已经给出了否证，但"否证结论"没有被执行。** 我把它写成了"参数依赖"这一副注，然后让主张继续留在提交清单里 —— 因为"参数依赖"在我的直觉里还不等于"不可报"。

---

## 4. 官方为什么没收

判罚仓（`_judging_repo/`，根目录 + 家族目录双读并比对了 `invalid/`）中**没有与本条同触发条件的条目**。所以按严格口径记 **误纳 1**。

但更值得注意的是：官方**确实**收了同一个底层 Morpho 性质的另一条 —— 只不过**触发者是攻击者，不是舍入**。

> **`050.md`** — Watson `Brisk Cherry Aphid`，**Medium**
>
> **Title**: Morpho allows `onBehalf` repayment which can be weaponized to dos full repayment
>
> **Summary**: "Malicious users can frontrun calls to fully delever through `deleverToZeroBorrowBalance` by repaying dust amounts on behalf of the settoken to continously grief the repayment process."
>
> **机制（逐字）**: "when the manager tries to repay the full amount a malicious user could just front-run the transaction and repay 1 wei on behalf of the connector address, thus reverting the transaction due to underflow."

对照一下：

| | 官方 `050.md`（**收**，Medium） | 我的 F2（**不收**） |
|---|---|---|
| 底层条件 | Morpho `repay` 在 `assets` 超出对应 shares 时下溢 | **同一个** |
| 触发入口 | `deleverToZeroBorrowBalance` → `_repayBorrow` | `componentRedeemHook` → `_repayBorrow` |
| **触发者** | **无许可攻击者**（front-run，付 1 wei） | **无人** —— 靠舍入残差自然累积 |
| 触发成本 | 1 wei + gas（可无限重复 grief） | 需要①近清仓 ②特定参数 ③特定精度 三者同时成立 |
| 实际性 | 攻击者可控、可重复 | 依赖部署时的参数组合，非攻击者可控 |

---

## 5. 两种读法，以及我采用的是哪一种

| 读法 | 结论 |
|---|---|
| **严格口径**（我记录所用的） | 无同根因条目 ⇒ **误纳 1** |
| **公平口径** | 官方收了同一底层性质的**攻击者触发版**（`050`）⇒ 我的条目是"**同一机制、更弱触发**"，应记作**冗余/未达实际性门槛**，不是"假" |

**两种读法都指向同一条结论：我的主张不是错的，是"不够"的。**

"不够"在哪，现在很清楚：

> Morpho 的这个下溢性质，只有在**攻击者能主动、低成本、可重复地制造它**时才成立为可报条目。
> 一个只有靠"特定部署参数 + 自然舍入"才会浮现的版本，官方按**实际性（actuality）**门槛挡掉。

**这正是我后来固化的规则**（写回方法论文档）：

> 当 PoC 依赖「接近清仓 + 特定市场参数 + decimals 组合」**三重边缘条件**同时成立时 ⇒ **落观察区，不提交**。
> 判据不是"能不能触发"，而是"**攻击者能不能让它发生**"。

---

## 6. 这条误报买到了什么

它把我原先对"实际性"的理解从：

> ❌ "只要存在一组参数能让它 revert，就是 Medium"

修正为：

> ✅ "触发权必须在攻击者手里。参数依赖的 DoS 不是 DoS，是**配置敏感性**。"

此后 8 个靶（`#24`–`#30`）的误纳分别是 1 / 1 / 3 / 0 / 1 / 1 / 0 —— 再未出现同类"参数依赖充数"的条目。**这是 30 靶里唯一一次我把"我错了"变成了一条能复用的判据。**

---

## 7. 复现与核实

```bash
# 1. 上游
git checkout 7202ed7d335c107d51efa5c081fcd68517c310d5   # index-coop-smart-contracts / index-protocol

# 2. 取整点
sed -n '650,660p' index-protocol/contracts/protocol/modules/v1/MorphoLeverageModule.sol
#   → L657  preciseDivCeil

# 3. 赎回 hook
sed -n '586,612p'  index-protocol/contracts/protocol/modules/v1/MorphoLeverageModule.sol
#   → L610  _repayBorrow(..., notionalDebt, 0)

# 4. Morpho 侧下溢
#    morpho-blue @ d60e123c  src/Morpho.sol:283-286

# 5. 官方两条对照
#    sherlock-audit/2024-10-morpho-x-index-judging
#      → 050.md   （收了：攻击者 front-run 版，Medium）
#      → 与本条同触发条件的条目：不存在
```
