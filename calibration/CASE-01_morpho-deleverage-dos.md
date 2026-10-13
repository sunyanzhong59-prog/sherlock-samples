# CASE-01 —— 去杠杆全线 revert：一个"救不了"的杠杆头寸

> **English abstract.** On Index Coop's `MorphoLeverageStrategyExtension`, the repayment-side
> cap is derived from a borrow limit that is discounted by the *unutilized leverage buffer*.
> Because that discounted limit sits **strictly below** Morpho's liquidation threshold,
> there is a band of borrow balances in which **deleveraging reverts but liquidation has
> not yet triggered**. Every de-risking entry point (`rebalance` → `_handleRebalance`,
> `iterateRebalance`, `ripcord`, `disengage`) routes through the same helper, so the
> position cannot be saved — it can only be liquidated.
> Target: `index-coop-smart-contracts @ 7202ed7d`. Original contest: Sherlock
> `2024-10-morpho-x-index`. **This is a post-hoc independent reproduction against the
> public judging repository, not a contest submission.**

---

## 0. 溯源

| 项 | 值 |
|---|---|
| 协议 | Index Coop 杠杆代币（Set Token）接 Morpho Blue |
| 靶 | Sherlock `2024-10-morpho-x-index` |
| scope pin | `index-coop-smart-contracts @ 7202ed7d335c107d51efa5c081fcd68517c310d5` |
| 主文件 | `contracts/adapters/MorphoLeverageStrategyExtension.sol`（1291 行） |
| 官方结论 | **High** —— 独立条目 `034.md`；`005/026.md` 同根因 |
| 我的产出 | 独立复现并命中；判级一致（High） |

---

## 1. 这一段代码在做什么

杠杆代币的"去杠杆"是一次普通的再平衡：**卖一部分抵押品 → 用所得还款 → 杠杆率下降**。

但"能还多少"不能随便填 —— 还多了会把抵押品卖光。所以 adapter 要先算出一个"本次最多能动用多少抵押品"的上限，这个上限由 Morpho 的超额抵押约束决定：

```
netBorrowLimit = 抵押品价值 × LLTV × (1 − unutilizedLeveragePercentage)
```

- `LLTV` = Morpho 市场的清算贷款价值比（例如 0.90）
- `unutilizedLeveragePercentage` = 协议预留的**安全缓冲**（例如 0.02，即永远不把杠杆顶满）

然后分两个方向用这个上限：

```solidity
// MorphoLeverageStrategyExtension.sol:1121-1137
function _calculateMaxBorrowCollateral(ActionInfo memory _actionInfo, bool _isLever) internal virtual view returns(uint256) {

    // Note NetBorrow Limit is already denominated in borrow asset
    uint256 netBorrowLimit = _actionInfo.collateralBalance
        .mul(_actionInfo.collateralPrice).div(MORPHO_ORACLE_PRICE_SCALE)
        .preciseMul(_actionInfo.lltv)
        .preciseMul(PreciseUnitMath.preciseUnit().sub(execution.unutilizedLeveragePercentage));   // L1124-1127
    if (_isLever) {
        return netBorrowLimit
            .sub(_actionInfo.borrowBalance)
            .mul(MORPHO_ORACLE_PRICE_SCALE).div(_actionInfo.collateralPrice);
    } else {
        return _actionInfo.collateralBalance
            .preciseMul(netBorrowLimit.sub(_actionInfo.borrowBalance))                            // L1134  ← 断点
            .preciseDiv(netBorrowLimit);
    }
}
```

**加杠杆**方向（`_isLever == true`）问的是"我还能再借多少" —— 用 `netBorrowLimit − borrowBalance` 是合理的。

**去杠杆**方向（`_isLever == false`）问的是"我最多能还多少" —— 这里复用同一个减法就出问题了。

---

## 2. 根因：还款能力被"借款上限"卡住

L1134 的 `netBorrowLimit.sub(_actionInfo.borrowBalance)` 是 **0.8 的 SafeMath / `PreciseUnitMath` 减法**：一旦

```
borrowBalance > netBorrowLimit
```

就直接 **underflow revert**。而 `_calculateChunkRebalanceNotional`（L1084）在算任何再平衡量之前都会先调它（L1099）：

```solidity
// L1099
uint256 maxBorrow = _calculateMaxBorrowCollateral(_leverageInfo.action, _isLever);
```

**⇒ revert 发生在任何还款动作之前 ⇒ 去杠杆整条路径不可达。**

### 2.1 为什么说这是设计错误，而不是"参数没调好"

关键在数值关系。注意两个门槛：

| 量 | 表达式 | 代入 LLTV=0.90, buffer=0.02 |
|---|---|---|
| **净借款上限**（adapter 用的） | `C·P × LLTV × (1 − buffer)` | `0.882 · C·P` |
| **清算门槛**（Morpho 用的） | `C·P × LLTV` | `0.900 · C·P` |

因为 `(1 − buffer) < 1` ⇒ **净借款上限永远严格小于清算门槛**。于是存在一条窄带：

```
borrowBalance ∈ ( 0.882·C·P , 0.900·C·P ]
        ↑ 去杠杆已 revert      ↑ 尚未达到清算线
```

在这条带里：**头寸还没被清算，但已经无法被救。**

而这条带**正是由那个安全缓冲本身造出来的**。缓冲的初衷是"永远留一点余量别顶到清算线"，结果它变成了"一旦越线，就再也回不去了"的死区 —— 预留的余量被借款余额的**自然增长**（利息累积）吃掉，而不是被主动加杠杆吃掉。

### 2.2 进入这条带有三条日常路径（都不需要攻击者）

官方 `034.md` 列了三条，全部是**正常市场行为**：

1. **利息累积** —— 借款余额随时间增长，抵押品不动；
2. **利用率飙升导致利率跳升** —— Morpho 是利用率定价，借得多时利息涨得快；
3. **抵押品相对借款资产贬值** —— 价格下跌让 `C·P` 缩水。

三者都**不需要**预言机失效（stale / 被操纵）。这一点很重要：协议的已知风险清单里只写了"预言机 stale ⇒ 无法维持杠杆率"，**没有覆盖正常价格波动**。

---

## 3. 可达性：哪几个入口被打死

`_calculateChunkRebalanceNotional` 的全部调用点（pin `7202ed7d`，逐行核实）：

| 调用点 | 所属函数 | `isLever` | 是否走 L1134 |
|---|---|---|---|
| L294 | `engage()` | `true` | 否（加杠杆） |
| **L406** | **`ripcord()`** | **`false`** | ✅ |
| **L444** | **`disengage()`** | **`false`** | ✅ |
| L674 | `getChunkRebalanceNotional()`（view） | 依方向 | ✅（视图同样 revert） |
| **L864** | **`_handleRebalance()`** | **`false`** | ✅ |
| L871 | `_handleRebalance()` | `true` | 否 |

而 `_handleRebalance()`（L857）被两个**面向 keeper 的去杠杆入口**调用：

| 调用点 | 所属函数 |
|---|---|
| L340 | `rebalance()`（L324，`onlyEOA onlyAllowedCaller`） |
| L373 | `iterateRebalance()`（L358，`onlyEOA onlyAllowedCaller`） |

**⇒ 被打死的完整集合**：`rebalance()`（方向向下时）· `iterateRebalance()` · `ripcord()`（**无许可，`onlyEOA`**）· `disengage()`（`onlyOperator`，去杠杆到 1x）。

其中 `ripcord()` 是设计上的**紧急出口** —— 它的整个存在意义就是"杠杆率失控时把它拉回来，并给调用者 ETH 奖励"。紧急出口自己 revert 掉，是这个漏洞最讽刺的部分。

---

## 4. 判级论证：为什么是 High 而不是 Medium

按判级第 0 问（**该问题是否使协议资金/背书/抵押品守恒可被移出或破坏？**）：

- **是**。机制是"应被阻止的清算实际发生了" —— 清算罚金从 Set Token 的 NAV 里扣走。
- 按杠杆倍数**乘性放大**：Morpho 多数市场清算罚金 ≥5% ⇒ 3x 杠杆代币损失 **15% NAV**，5x 损失 **25% NAV**。
- 触发者是**任何人**（`ripcord` 无许可）或**keeper**（`rebalance`/`iterateRebalance`），且**不需要作恶** —— 他们只是调用了本来就该成功的函数。
- 不需要预言机被操纵、不需要管理员误配、不需要恶意 token。

对照协议的**声明不变量**：`shouldRebalance` 指示时应调用 `rebalance`/`iterateRebalance` ⇒ 头寸不可被清算。本漏洞直接使该不变量不可达 —— `shouldRebalance` 会正确指示，但指示的目标函数 revert。

---

## 5. 官方评审结论（逐字对标）

> **`034.md`** — Watson `Fierce Ultraviolet Rhino`，**High**
>
> **Title**: Potential DOS on deleveraging which can lead to unfair liquidation
>
> **Summary**: "Deleveraging can't be executed due to repayment is not possible."
>
> **Root Cause**: "Deleveraging process involves the calculation of maximum amount to repay for a loan. As you can see the function below line 1137, this is where calculation involves subtraction of borrow balance from net borrow limit. If the borrow balance is more than net borrow limit, the operation will revert."

> **`005/026.md`** — Watson `Polite Sand Finch`，**High**
>
> **Title**: `_calculateMaxBorrowCollateral` calculates repay incorrectly and can lead to set token liquidation
>
> **Summary**: "When calculating the amount to repay, `_calculateMaxBorrowCollateral` incorrectly applies `unutilizedLeveragePercentage` when calculating `netRepayLimit`. The result is that if the `borrowBalance` ever exceeds `liquidationThreshold * (1 - unutilizedLeveragPercentage)` then all attempts to repay will revert."

`005/026` 的根因定位比 `034` 更精确 —— 它指名**问题不在减法本身，而在"还款侧不该套用 `unutilizedLeveragePercentage`"**。这与 §2.1 的数值论证是同一件事。

### 5.1 一个值得单独记的细节：这是**返祖 bug**

`005/026` 正文里有一句（逐字）：

> "This is nearly identical to the [valid issue](https://github.com/sherlock-audit/2023-05-Index-judging/issues/254) reported in the last contest **that was fixed in the Aave leverage extension**."

也就是说：**同一处逻辑在 Aave 版杠杆扩展里被报过、被修过，然后在 Morpho 版移植时又被带回来了。**

这给审计一个很实用的动作：**审计"某协议的移植/fork 版本"时，先把上游版本的历史判罚仓 diff 一遍** —— 上游修过的 bug 恰恰是移植时最容易丢的部分（修复没跟着一起搬）。

---

## 6. 我的产出 vs 官方：差在哪

| 项 | 我的 | 官方 | 差异 |
|---|---|---|---|
| 根因定位 | L1132-1136 减法 underflow | `034` L1134 减法；`005/026` L1124-1127（缓冲不该用于还款侧） | 方向一致；`005/026` 更精确 |
| 可达性 | 我**额外**把 `rebalance`/`iterateRebalance`/`disengage` 全部枚举出来（含 `_handleRebalance` 调用链） | `034` 只说 deleveraging；`005/026` 只点 `ripcord` | ✅ 我的覆盖面**更宽** |
| 触发路径 | 价格下跌 + 利息累积 | `034` 三条（利息/利率跳升/贬值） | 一致 |
| 判级 | High | High | ✅ 持平 |

**这是 30 靶里为数不多"判级完全一致"的样本**，也是它被选作本目录 flagship case 的原因 —— 它证明了这样一件事：**当根因是"资金守恒被破坏"这种机制级问题时，判级几乎不会错；错的全是那些需要二次推理（"这算不算有影响"）的条目。** 见 [`README.md` §5.1](README.md#51-判级偏低最顽固)。

---

## 7. 修复方向

三个层次，从最小改动到结构性：

1. **最小**：还款侧不套用缓冲 —— 用 `liquidationThreshold`（即 `C·P × LLTV`）作为分母，而不是 `netBorrowLimit`。这使"能还多少"的边界与清算线对齐，窄窗归零。
2. **防御性**：把 L1134 的减法换成饱和减法（`>` 判断后返回 0 / 或返回 `collateralBalance` 上限），保证**去杠杆永不 revert**。
3. **结构性**：`ripcord()` 作为紧急出口，应有一条**不依赖任何上限计算**的兜底路径（例如"允许还款到债务为 0"），因为紧急出口的核心要求是"总能执行"。

官方 `034.md` 的 mitigation 意见与第 3 条同向（逐字）：

> "Deleveraging should not be restricted in a certain amount. It should give the user the freedom to repay the loan in any amount until it paid it fully."

---

## 8. 复现与核实方式

```bash
# 1. 取 pin 源码
git clone https://github.com/index-coop/index-coop-smart-contracts
cd index-coop-smart-contracts && git checkout 7202ed7d335c107d51efa5c081fcd68517c310d5

# 2. 看根因（L1121-1137）
sed -n '1121,1137p' contracts/adapters/MorphoLeverageStrategyExtension.sol

# 3. 数所有调用点
grep -n "_calculateChunkRebalanceNotional(" contracts/adapters/MorphoLeverageStrategyExtension.sol \
  --include=*.sol | grep -v "function "

# 4. 官方判罚仓（公开）
#    https://github.com/sherlock-audit/2024-10-morpho-x-index-judging
#    → 034.md（High）/ 005/026.md（High）
```

**最小化验证（无需 fork 主网）**：把 `_calculateMaxBorrowCollateral` 与其依赖的 `PreciseUnitMath` 抽成独立 harness，参数取 `C=100e18, P=1e36, lltv=0.9e18, buffer=0.02e18, borrow=89e18`：

- `netBorrowLimit = 88.2e18`（官方 `034` 的例子里取整为 88）
- `borrowBalance (89e18) > netBorrowLimit (88.2e18)` ⇒ **L1134 revert**
- 而 Morpho 的清算门槛 = `90e18` ⇒ **尚未触发清算**

即：**89 这个借款水平上，头寸既救不了、也还没被清算 —— 但只需要再涨 1，就进入清算。**
