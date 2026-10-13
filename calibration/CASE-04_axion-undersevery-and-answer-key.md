# CASE-04 · AXION #22 —— 判级 100% 偏低，以及一个更贵的错误：我把答案键当成了真理

> **English abstract.** Target #22 (Sherlock 2024-10-axion, 10 files / 1,588 LOC) is the case where
> every scored dimension that could go wrong did: **14/14 findings under-graded**, **≥12 root-cause
> families never seen**, and a coarseness failure in the opposite direction — I *overrode my own
> verified disproof* because the official answer key disagreed with it.
> This writeup documents (a) two blood-evidence failures where **my own "valid protection" note was
> itself the vulnerability**, (b) a **lens mismatch** that cost one severity tier on a
> selected High report, and (c) a **provable error in the answer key itself** (OZ v4.9.6 source,
> byte-identical to upstream, sha256 `82789e6b…`), which I had previously absorbed as "my mistake".
> Post-hoc, independent reproduction — the author did **not** participate in the contest.
> Everything below was written before the sealed judging repo was opened; see `README.md` §2.

---

## 0. 阅读警告（本篇与前三篇不同）

前三篇 CASE 是「我做对 / 做对一半 / 做错」。**这一篇是「我做错了两遍，方向相反」**：

| 方向 | 内容 | 代价 |
|---|---|---|
| **向下错** | 14 条候选**全部判低** 1–2 档；≥12 个大族**从未看见** | 竞奖档位全灭；本靶四条 H 级主报告我一条没独立命中 |
| **向上错** | 我把自己**已实证**的否证主动改判为「我错了」，只因为官方条目说 High | **能力画像被系统性扭曲** —— 不是少赚，是知道了错的东西 |

**第二类是本篇唯一的增量。** 前三篇的所有规则都指向「我太宽松 / 我漏了」，都假设 *官方判罚 = 地面真值*。
本靶把这个假设打穿了：**答案键也是人对公开代码的判断，也有误差，也可以被复核。**
本文给出可复现的复核证据。这不是自我辩护 —— 我保留反向适用的门槛（§6.3），因为它同样容易被滥用。

---

## 1. 靶况

| 项 | 值 |
|---|---|
| 靶 | `AXION-MONEY/liquidity-amo@9a9adab9` + `AXION-MONEY/solidly-utils@7946d226` |
| scope | **10 文件 / 1,588 行**（逐字表见 `CONTEST_INFO.md §二`；§T7 已核零漏零多） |
| 判罚仓 | `sherlock-audit/2024-10-axion-judging` —— **家族制**：34 个一级族目录（225 条）+ 110 个扁平根 `NNN.md` = **335 valid** |
| `invalid/` | **仅 `.gitkeep`，零实体条目** ⇒ **该靶误报率不可测**，只能测召回 |
| 官方精选 | README 收录 **H-1…H-4 / M-1…M-6**（10 条） |
| 我的盲练产出 | 候选 **F1–F14** ／ 实证否证 **§F1–§F10** ／ 观察区 **G1–G7** |

> **布局变体（第 10 种）**：家族目录与扁平根**编号不相交**（根 110 个编号 ∩ 家族 225 个编号 = ∅）。
> 这与第 9 种「拍平」同为**误报率不可测**，但族结构可测 ⇒ 覆盖面仍可算。
> 教训：**族内条数多 ≠ 族重要** —— `001/` 有 68 条，我却 0 条独立命中（见 §3.1）。

---

## 2. 三个数字

| # | 指标 | 值 | 判定 |
|---|---|---|---|
| 1 | 条目级命中 | **14 / 14 = 100%**（无一条空转） | ✅ 连续第 5 靶 100% |
| 2 | 误纳 | **0** | ✅ 连续第 10 轮归零 |
| 3 | **判级偏低** | **14 / 14 = 100%**（低 1 档 8 条、低 2 档 6 条） | ❌ **首次「全量偏低」** |
| 4 | **簇级漏族** | **≥ 12 大族**（保守）／ ≥ 16（宽口径） | ❌ 本靶最大失败项 |
| 5 | 覆盖率 | ≈ 20 / 335 ≈ **6%**（宽口径族覆盖 14/34 ≈ 41%） | ⚠️ |

**精度侧稳固、召回与判级双崩。** 这张表本身没新意 —— 前三篇都指向同一结论。本靶的增量在下面的三节。

---

## 3. 血证一：我的「有效防护」批注，就是官方最大的漏洞族

### 3.1 事实

`SolidlyV2AMO.sol:187-188`（卖出路径）与 `:284-285`（撤池路径）都有这样一段：

```solidity
uint256 usdBalanceBefore = IERC20Upgradeable(usd).balanceOf(address(this));
// ... router swap ...
uint256 usdBalanceAfter = IERC20Upgradeable(usd).balanceOf(address(this));
if (usdAmountOut != usdBalanceAfter - usdBalanceBefore) revert UsdAmountOutMismatch(...);
```

我在 `_FINDINGS.md §F8` 的结论是（逐字）：

> **✅ V2 的 router 谎报校验有效** —— 做了 `if (usdAmountOut != usdBalanceAfter - usdBalanceBefore) revert UsdAmountOutMismatch(...)` ⇒ 用真实余额差校验 router 返回值。**有效防护。**

**同一个 check，官方读成了 DoS 触发器。** `001/017.md`（Watson `Shallow Tan Mule`，**High**）逐字：

> "**`_mintAndSellBoost()`** verifies if **`usdAmountOut != usdBalanceAfter - usdBalanceBefore`** . If they don't match, the transaction reverts. However, with Fee-on-Transfer (FoT) tokens, the balance difference will always be smaller than **`usdAmountOut`** due to the transfer fee applied when tokens are transfered from the DEX to the contract. **As a result, the transaction always reverts.**"

其 Impact 段逐字：

> "The transactions will always revert, making it impossible to call **`_mintAndSellBoost()`**, which breaks one of the core functionalities of the protocol."

并给了数值 PoC（`usdBalanceBefore = 0`，10% 转账费，`boostAmount = 100` ⇒ `100 != 90 - 0` ⇒ revert `UsdAmountOutMismatch()`）。

**这一族在判罚仓里是 `001/` 目录，共 68 条。**

### 3.2 我为什么读错

我的 §T1 反向 checklist 里，I-13 的结论是（逐字）：

> "⚠️ **会计未设防** —— 代码对非标准 ERC20 无防护：`approve` 返回值全部被忽略……**Q&A 只排除 fee-on-transfer**，未排除『返回 false / 无返回值 / 可暂停 / 可黑名单』"

**我把 fee-on-transfer 理解成了「被官方豁免的一个类别」** —— 因为 Q&A 写了 *"any USD-pegged token, beside fee-on-transfer ones"*。

而官方的读法是：**「我们不打算支持 FoT」不等于「FoT 出现时协议不出事」。** 一个由**代币选择**触发的、使**核心功能永久 revert** 的条件，本身就是 High —— 它不因「作者说我们不支持它」而消失。这和「出 scope」是两回事。

### 3.3 固化规则

> **§V2 余额差校验必须双向问。** 凡见 `balanceAfter - balanceBefore` 形式的校验，问两个方向：
> ① **返回值可信吗**（防 router/预言机谎报 —— 我做了）
> ② **该校验在非标准 ERC-20 下会恒假吗**（FoT / rebasing / 有 hook / 可暂停 / 黑名单 —— 我漏了）
> ② 的交付物是一条独立 finding，**不得**折叠进「approve 返回值」那条，也**不得**因 Q&A 声明「不支持该类代币」而剔除。

---

## 4. 血证二：「接口语义自洽」≠「目标实现兼容」

### 4.1 事实

我的 `§F5` 否证（逐字）：

> **✅ `ISolidlyV3Pool.swap` 的 `amountSpecified` 正=exact input ⇒ AMO 用法正确**
> 接口逐字（`ISolidlyV3Pool:88,109`）：*"which implicitly configures the swap as exact input (**positive**), or exact output (negative)"*。V3 传 `int256(boostAmount)`（正）⇒ 与意图一致。**非漏洞。**

**这段推理每一步都是对的，结论仍然是错的。** 因为我核对的是**本项目自己写的接口文件**的语义 —— 而官方精选 **H-2** 的说法是（逐字）：

> "According to the docs, the Dex scope for SolidlyV2 includes Velodrome/Aerodrome. … However, for Velodrome/Aerodrome implementations, the current `SolidlyV2AMO` is **not compatible**."

具体到函数签名（H-2 逐字给的对照）：

```solidity
// Aerodrome 真实接口
function getReward(address _account) external;

// 项目自带的 IGauge.sol
function getReward(address account, address[] memory tokens) external;
function getReward(uint256 tokenId) external;
function getReward() external;
```

**参数个数都不一样。** 项目 README 逐字声称：*"We expect the SolidlyV2 tech-implementation work with the 'classic' pools on the following Dexes: Velodrome, Aerodrome, Thena, Equalizer, Ramses and forks, Tokan"* —— 而代码只与其中一个子集兼容。

这一族在本靶判罚仓里 ≥8 个大族（`010/013/002/006/018/020/032/034`），**是最大的结构性缺口**，且我**一个都没做**。

### 4.2 我为什么读错

因为我做的是「**读我自己 scope 内的接口，验证它内部自洽**」。而兼容性问题的答案**根本不在 scope 内** —— 它在**目标 DEX 已部署的真实合约源码**里。

这是 `§U2` 的由来：

> **§V3 多实现集成靶 = 接口签名 × 真实实现的逐字比对表。** 凡 README 声称「支持 N 个外部 DEX/协议」且 scope 内逐字列出各自的 `*Utils` 文件 ⇒ 必须建表：
> `scope 内接口签名` × `目标协议真实已部署源码的签名`，逐函数比对参数个数、顺序、大小写风格、返回值。
> **「接口语义自洽」永不等于「目标实现兼容」。**

旁证：本靶 scope 内 `AerodromeUtils` **覆写**了 `getVoterVe`/`checkIncreaseUnlockTime`（用 `IveAERO` 的 camelCase），而 `Equalizer/Ramses/ThenaUtils` **未覆写**（继承基类的 snake_case）。**作者自己已经在做「按 DEX 分叉接口」这件事了** —— 而我没有沿着他分叉的地方去问「还有哪些没分叉」。

---

## 5. 透镜错配：同一行代码，我只读到「量」，官方读到「义」

**这是本靶判级低 1 档的机制性来源 —— 不是「我不敢报 High」。**

我的 **F3**（自评 **Medium**）与官方精选 **H-1**（**High**，6 名 Watson，`Found by 0x37, carrotsmuggler, pkqs90, s1ce, spark1, vinica_boy`）**指向完全相同的代码**：

```solidity
// SolidlyV3AMO.sol:320-326
uint256 totalLiquidity = ISolidlyV3Pool(pool).liquidity();
liquidity = (totalLiquidity * (boostBalance - usdBalance)) / (boostBalance + usdBalance);
liquidity = (liquidity * LIQUIDITY_COEFF) / FACTOR;   // 0.995
```

### 我的透镜：数量口径

> 「用**全池** `totalLiquidity` 而不是 **AMO 自身持仓**当基数」⇒ 设 AMO 占全池比例 `f`，则需 `f ≥ (imbalance/2)/usdReserve`。
> ⇒ 结论 = **撤池会 revert（DoS）**。诚实地说，我连这个都想清楚了：V3 的 0.5% 缓冲（`LIQUIDITY_COEFF = 995000`）**只够抵消 `f ≥ 99.5%` 的舍入**，不足以覆盖任何真实第三方 LP。
> 方向归属：**可用性**。

### 官方透镜：经济含义

H-1 问的不是「这个数多大」，而是「**这个数是什么**」：

> "This is because in V3 pools, **single sided liquidity is allowed** which adds to the `totalLiquidity` count, but increases the reserves of only 1 token. If a user adds liquidity at a tick lower than the current price, they will be adding only usd to the pool."

然后给了反例（逐字）：

> "lets say the price currently is below peg, at 0.9. Say there are 1000 boost and 900 usd tokens in the pool… a user can come in and add 100 usd to the pool at a price of 0.5. Since this price is lower than the spot price, only usd will be needed to open this position. Now, **the total reserves of both boost and usd are 1000 each, so the calculated `liquidity` amount to be removed will be 0**."

以及最坏情形（逐字）：

> "In the worst case scenario, the liquidity calculated will be **overestimated** and the price will be pushed up even **above the peg price**. This is possible if users add single sided `boost` to the pool, increasing the `liquidity` amount calculated without changing the price. In this case, the contract assets will be used to **force the boost token above peg**, and **malicious actors can buy the boost token before and sell it after for a handy profit**."

### 差在哪

| | 我 | 官方 |
|---|---|---|
| 问的是 | `boostBalance - usdBalance` 这个数**会不会超过 AMO 持仓** | 这个数**在 CL 池里还是不是「价格偏离度」** |
| 池型假设 | 隐含假设 V2 式双边储备 ⇒ reserves 反映价格 | **显式指出 CL 池允许单边流动性 ⇒ reserves 不代表价格** |
| 可推结论 | DoS（不可用） | **可获利的操纵**（对手先买、协议抬价、对手后卖） |
| 级别 | Medium | High |

**我看的是「量」，官方看的是「义」。** 前者只能推出 DoS，后者才能推出「资金被移出」。判级差 1 档，根源是**词汇表**，不是胆量。

> **§V4 逐步问「这个变量在当前池型下是否仍是那个东西的代理」。**
> 凡出现 `x = f(A)` 形式的推导，必须逐项问：**A 在当前实现下是否仍是 target 的有效代理？**
> 具体到 AMM：**CL（集中流动性）池的 `reserves` ≠ AMM 的 `reserves`** —— 单边流动性使其与价格解耦。
> 通用形式：**任何「用储备/余额/总量推导价格、占比、偏离度」的算术，先问池型。**

---

## 6. 向上错：把答案键当真理（本轮最重要的发现）

### 6.1 我当时写了什么，又改判成了什么

`_FINDINGS.md §F2` 逐字（封笔时）：

> **✅ `MasterAMO` 未调用 `__ReentrancyGuard_init()` ⇒ 非漏洞**
> OZ 4.9.x：`_NOT_ENTERED = 1`（`:35`）、`_ENTERED = 2`（`:36`）、`_status` 默认 0（`:38`）、`_nonReentrantBefore` 只 `require(_status != _ENTERED)`（`:63`）。首次调用时 `0 != 2` ⇒ 通过并把 `_status` 置 2，退出时置 1 ⇒ **守卫自首次调用起即有效**。

开封对账后，官方有两条相关条目：

- `028/135.md`（Watson `Broad Jetblack Alligator`，**High**）：*"Uninitialized `__ReentrancyGuard_init` in `MasterAMO.sol::initialize`"*，Impact 逐字：**"The contract suffers from a complete loss of reentrancy protection"**
- `024/094.md`（**High**）：*"Reentrancy Vulnerability in Liquidity Management Functions Enables Unauthorized State Manipulation"*

我的成绩单 §五 把它们记成「**真误判，我错**」，并这样自我归因（逐字）：

> "我证明的是『`_status==0` 使首次调用通过』（真实且正确），但**漏了**『守卫从未被正确初始化 ⇒ 该保护在升级/重入路径上不成立』的独立危害。"

### 6.2 回码复核：这个自我归因是错的

**证据 1 —— OZ 源码，比特级核验。**
本地留存副本与上游 `openzeppelin-contracts-upgradeable@v4.9.6` **逐字节一致**：

```
vendored : sha256 82789e6bdc1d6b5d8348a741281ec7a1e46c602017e1e4b7ae805bd55bfed26b  3683 B
upstream : sha256 82789e6bdc1d6b5d8348a741281ec7a1e46c602017e1e4b7ae805bd55bfed26b  3683 B
=== 逐字节一致 ===
```

其中（行号即上游行号）：

```solidity
35:    uint256 private constant _NOT_ENTERED = 1;
36:    uint256 private constant _ENTERED = 2;
38:    uint256 private _status;                 // ← 默认 0

40:    function __ReentrancyGuard_init() internal onlyInitializing {
41:        __ReentrancyGuard_init_unchained();
44:    function __ReentrancyGuard_init_unchained() internal onlyInitializing {
45:        _status = _NOT_ENTERED;              // ← 只做这件事

55:    modifier nonReentrant() { _nonReentrantBefore(); _; _nonReentrantAfter(); }
61:    function _nonReentrantBefore() private {
63:        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
66:        _status = _ENTERED;
```

**`__ReentrancyGuard_init()` 的全部作用就是把 `_status` 从 `0` 设为 `1`。而守卫的判定式是 `_status != 2`。**
`0 != 2` 与 `1 != 2` 都是真。⇒ **未调用 `__ReentrancyGuard_init()` 不改变守卫的任何一次判定结果。**
「complete loss of reentrancy protection」在代码层不成立。

**证据 2 —— 守卫覆盖全部外部入口。** `MasterAMO.sol` 的 **6 个** `external` 入口全部带 `nonReentrant`：

```
L155 mintAndSellBoost(5参)  → nonReentrant @L164
L178 addLiquidity(4参)      → nonReentrant @L188
L219 mintSellFarm(5参)      → nonReentrant @L230
L251 unfarmBuyBurn(5参)     → nonReentrant @L262
L278 mintSellFarm() (0参)   → nonReentrant @L282
L296 unfarmBuyBurn()(0参)   → nonReentrant @L300
```

`SolidlyV2AMO.getReward` 另带守卫（`external override onlyRole(REWARD_COLLECTOR_ROLE) whenNotPaused nonReentrant`，`@L320-323`）。
而 `SolidlyV3AMO` 的全部 `_mintAndSellBoost` / `_addLiquidity` / `_unfarmBuyBurn` 都是 **`internal override`** —— **唯一到达路径就是上面那 6 个入口**。⇒ `024/094` 的根因表述（"absence of reentrancy guards in liquidity management functions"）在代码层同样不成立。

**证据 3 —— 该条目自己的前置条件就承认了可达性问题。** `024/094.md` 逐字：

> **Internal pre-conditions**: "1-An account with the **necessary privileges** triggers a liquidity management function like `_mintAndSellBoost`."
> **External pre-conditions**: "2-The pool contract is **malicious or compromised** to execute a reentrant call."

即：要**特权调用者** + **把外部依赖（池）假设为恶意**。前者与「无权限攻击者可触发」冲突，后者是标准信任模型明确排除的情形。

| 条目 | 事实前提是否成立 | 我的置信度 |
|---|---|---|
| `028/135`（守卫未初始化 ⇒ 完全失去重入保护） | ❌ **可证明不成立**（`_status != 2` 判定与初始化无关） | **高**（源码逐字 + 比特级比对） |
| `024/094`（流动性函数缺重入保护） | ❌ **前提不成立**（内部函数 + 6/6 外部入口有守卫）；但其「恶意池」路径属**信任模型判断**，留有解释空间 | **中高** |

⚠️ **我把它标为 CONTESTED，不是「官方一定错」。** 我无法排除评审另有考量（例如对未来升级路径的保守起见）。我能确证的是：**条目陈述的代码层前提，与我逐字复核的结果冲突。**

### 6.3 这一类错误的危害 & 反向门槛

**危害**：成绩单上「我误判 2 条」是假的。真实的错误分布被系统性地记错了 —— 我不是「判级偏低 14 条 + 误判 2 条」，而是「判级偏低 14 条 + **误判 1 条**（`§F5` 接口兼容，见 §4）+ **2 条被冤枉的正确否证**」。
**一个测得准的错误率才有价值；一个偏保守的错误率会让我在不该让步的地方让步。**

**固化规则（新）**：

> **§V5 答案键不是地面真值。**
> 对账时，凡我**已用源码逐字或已执行 PoC** 否证过的条目，遭官方否定时 —— 必须：
> ① 在成绩单里**单独开一栏「我不同意」**，写明代码证据；
> ② 要求官方条目给出**代码层可验证的新证据**才能推翻我；
> ③ 否则标记 **CONTESTED**，**不得**仅凭「官方判 High」就把自己的否证改判为「我错了」。

> **§V5′ 反向门槛（防止本条被滥用）。** 该规则**只**在当前否证同时满足两条时适用：
> **(a) 有源码逐字引用（含精确 `file:line`）**；**(b) 有可复现的实证（PoC 执行结果 / 比特级比对 / grep 全树 0 命中）**。
> 若否证建立在**推理 + 假设**上（「我认为攻击者拿不到那个角色」这类）⇒ 官方优先级更高，照旧改判自己。
> 判别式一句话：**否证是「事实」还是「我觉得」？前者遭否时先怀疑官方；后者遭否时先怀疑自己。**

---

## 7. 沉淀（本靶新增 5 条，全部带血证）

| # | 规则 | 血证 |
|---|---|---|
| **§V1** | **判级第 0 问（守恒问）前置**：凡使协议资金/背书/抵押品守恒可被移出或破坏 ⇒ High，**不问金额、不问攻击者是否特权角色、不问是否配置依赖** | 本靶 14 条候选**无一逃出该问**；官方对 F1/F2/F7/F8 一律 High，我全给 Medium/Low |
| **§V2** | **余额差校验双向问**：①返回值可信吗 ②该校验在非标准 ERC-20 下会恒假吗 | §3 `001/` 单族 **68 条**；我的「有效防护」批注即官方最大漏洞族 |
| **§V3** | **接口签名 × 真实实现逐字比对表**（凡 README 声称支持 N 个外部协议） | §4 `H-2`（Aerodrome `getReward` 参数个数不同）；本靶 ≥8 族，我 0 命中 |
| **§V4** | **逐步问「这个变量在当前池型下是否仍是那个东西的代理」** | §5 同一行代码：我只读到「量」（→DoS），官方读到「义」（→可获利操纵），差 1 档 |
| **§V5** | **答案键不是地面真值**（+ 反向门槛 §V5′） | §6 `028/135`、`024/094` 代码层前提不成立，我却改判自己 |

> 另注本靶三条**未改判**的正确否证（可作为「否证是事实还是我觉得」的对照样本）：
> `§F1`（`initialize` 嵌套因 OZ `Initializer` 而恒 revert ⇒ **已用 solc+anvil+cast 真跑证伪**，场景 D=1 成功）、
> `§F3`（AMO 实现合约缺 `_disableInitializers()` ⇒ 不可被接管）、
> `§F9`（`uint256(int256(-1))` 静默回绕 ⇒ **anvil 实测**返回 2²⁵⁶−1，但被后续守卫兜住）。
> 这三条都有源码 + 实证，且官方无反对条目 ⇒ 保持原判。

---

## 8. 与前三篇的对照

| | 靶 | 结局 | 一句话 |
|---|---|---|---|
| CASE-01 | morpho-x-index #23 | ✅ 命中，判级持平 High | 机制最干净的一次：`netBorrowLimit < 清算门槛` ⇒ 存在「去杠杆已 revert、清算未触发」的窄带 |
| CASE-02 | crestal-network #30 | ✅ 命中根因，❌ 级别合并 | 一个 typehash 被五个函数共用 ⇒ 跨动作重放；官方按后果拆成 High/Medium 两级，我合并成一个 |
| CASE-03 | morpho-x-index #23 | ❌ **误纳 1** | 我唯一一次误报：PoC 依赖「近清仓 + 特定参数 + 精度假设」三重边缘条件，仍保留提交 |
| **CASE-04** | **axion #22** | **❌ 判级 14/14 全偏低、漏族 ≥12；❌❌ 且把自己的正确否证改判为错** | **向下错了一整轮，向上又错了一次 —— 后者更贵** |

四篇合起来是一次完整的**错误方向扫描**：**判低 / 合并 / 多报 / 服从权威**。
前三个方向的修法都是「更严格地对待自己」；第四个方向的修法是「**同样严格地对待答案**」。

---

## 附：本靶可复现资产

| 资产 | 说明 |
|---|---|
| `_oz/ReentrancyGuardUpgradeable.sol` | sha256 `82789e6b…f26b`，与上游 `@v4.9.6` **逐字节一致** |
| `_upstream_rg.sol` | 同一文件的直取副本，用于比对 |
| `_poc/initnest/` | `verify.py` + `src/Init.sol`：anvil 实测「直连 impl 调 initialize = revert / `new Proxy(impl, data)` = 成功」 |
| `MY_FINDINGS.md` | 封笔产出（F1–F14 / §F1–§F10 / G1–G7），开封前打 sha256 |
| `SCORECARD.md` | 对账成绩单（本篇 §6 指出其中一处自我归因有误） |
