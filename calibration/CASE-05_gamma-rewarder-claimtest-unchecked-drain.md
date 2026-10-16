# CASE-05 — `gamma-rewarder`：反向配平治好了误剔，却暴露了另一头

> **靶**：Sherlock `sherlock-audit/2024-10-gamma-rewarder`（Optimism 单合约 + Brevis zk 回调）
> **作用**：epoch 区间奖励分发 + zk 证明回调 + 防重复领取状态机
> **我的结局**：命中 **4 个独立根因（含 High×2）+ 零误报**（语义口径）→ **Track C 入场闸门第 3 靶，达成 3/3**
> **本篇要说的**：这一靶是「我方短板从误剔转向低估+漏报」的转折点。前 3 靶（PinLink、Rova）的病灶是**报告阈值过高、把正确的怀疑删了**；本靶我立誓「只降权不删除」，结果误剔归零，但**低估 2 级**和**漏掉 3 条官方 High**同时冒出来。两头的病不会同时消失，只是换边。

---

## 0. 靶面（参赛者可见）

- **链**：Optimism · **单合约** `GammaRewarder`，奖励用 Brevis zk 证明回调到账。
- **两份同名实现**（scope 判定坑）：
  - `contracts/GammaRewarder.sol`（286 行，solc 0.8.20）= **Brevis zk 版**，README 的 Q&A 逐条对应 ⇒ **主对象**。
  - `src/GammaRewarder.sol`（462 行，solc ^0.8.17）= **Merkle tree 版**，README 只字未提 ⇒ 一并审，但对账时按文件名核对归属。
- **官方明确给了 4 条 invariants**（Sherlock 口径「违反 README 声明的不变量 = valid Medium」）：
  1. 总发放 == 初始存入 − 协议费
  2. 每期不得超额领取
  3. 同一笔奖励不得领两次
  4. 分发参数一经设定不可变

---

## 1. 我报的（开箱前封笔，sha256 可证）

### A. 【High】`claimTest` 无证明校验 + `totalRewardAmount` 无上限 ⇒ 任何人可掏空合约全部奖励

**位置**：`contracts/GammaRewarder.sol:150-181`（`claimTest`）

**根因**：`claimTest(bytes32, bytes32 _vkHash, bytes calldata _appCircuitOutput) external` ——
1. **无任何 caller / proof 校验**：`_appCircuitOutput` 由调用者任意构造，`decodeOutput()` 直接按偏移解出 8 个字段；
2. 唯一 require 是 `vkHashes[_vkHash]`（vkHash 亦由调用者传，正常运营必然 add 过）；
3. **`totalRewardAmount`（uint248，来自构造字节）未与「distributionAmountPerEpoch × epoch 数」做任何上限校验**，合约直接 `safeTransfer(userAddress, totalRewardAmount)`。

**可通过的校验（攻击者用链上真实 distribution 的公开字段即可全部满足）**：
- `startBlock < endBlock && (endBlock-startBlock) % blocksPerEpoch == 0` ✔ 自选区间
- `startBlock >= params.startBlockNumber && endBlock <= params.endBlockNumber` ✔
- `lpTokenAddress == params.hypervisor && rewardTokenAddress == params.rewardToken && distributionAmountPerEpoch == params.distributionAmountPerEpoch` ✔ 照抄链上
- `totalRewardAmount > 0` ✔
- `claim.amount == 0` ✔ 选一个未领过的 (user, token, distributionId)

**触发路径**：任意 EOA → 读链上任一 distribution 的 params → 本地 `abi.encode` 出 178 字节 output（user=自己，totalRewardAmount=**合约该 token 的全部余额**）→ 调 `claimTest` → 一次转走。对**每一个** rewardToken 重复即可掏空全部。违反官方 invariant 1 与 2。

**自问证伪**：①「README 说 claimTest 审计后会删除」⇒ 按 Sherlock 口径，**README 声明不具排除力**（PinLink 血训：6 条「已声明接受」全判 valid，含 `033` High）；函数已部署在 scope 内、无权限闸 ⇒ 不剔除。②「生产走 `handleProofResult`」⇒ `brevisCallback`（`BrevisApp.sol:22-26`）校验 `appCommitHash == keccak256(_appCircuitOutput)`，而 `claimTest` **完全绕过该校验**，两条路径安全性不对等 ⇒ 风险真实。

**判级**：High（Sherlock 口径下 Critical 通常并轨 High）。置信度：高。

---

### B. 【High】「一个 distribution 只能领一次」⇒ 中途领取的用户，剩余 epoch 奖励永久冻结

**位置**：`contracts/GammaRewarder.sol:171-177`（`claimTest`）与 `208-214`（`handleProofResult`），逻辑相同

**根因**：防重复领取的 key 是 `claimed[userAddress][rewardTokenAddress][distributionId]`，**不含 `startBlock/endBlock`**；判据是 `claim.amount == 0`（「是否已领过」的**布尔**语义）。而结构体 `CumulativeClaim` 明明存了 `startBlock/endBlock`，却**从不用于区间累积或合并校验**。

**影响**：用户在 distribution 进行中领取（只覆盖已过去的部分 epoch）后，`claim.amount != 0` ⇒ **之后无论生成多少新 proof 都永远无法再领**；剩余 epoch 的奖励永久留在合约，且协议**没有任何 sweep/reclaim** ⇒ 既不属于用户也不属于 incentivizor。

**二阶自问**：用户「可以选择等到结束再领」⇒ 削弱但不消除：① 协议是 epoch 累积语义（`CumulativeClaim` 字段名即为证），中途领取是**预期用法**；② 链下 prover 按前端请求生成 proof，用户没有理由知道「提前领会永久作废」；③ 用户损失 = 剩余全部奖励（非 dust）。

**判级**：High（资金永久冻结，违反 invariant 1/2）。置信度：中高。

---

### C. 【Medium】分发结束后剩余奖励无任何取回路径 ⇒ incentivizor 余额 + 整除余数永久锁死

**位置**：`contracts/GammaRewarder.sol` 全文（`ReclaimPeriodUpdated` 事件在 L75 声明，**但没有任何 `reclaim*` 函数实现**；`setReclaimPeriod` 也不存在）

**根因**：
1. `contracts/` 版**没有** `reclaimRemainingDistribution`（该函数只存在于 `src/` 版）；
2. 即使看 `src/` 版，`remainingRewardsById` **从未被任何代码写入**（grep 全库无赋值）⇒ 恒为 0 ⇒ reclaim 形同虚设；
3. `amountPerEpoch = realAmountToDistribute / numberOfEpochs`（L127）**向下取整**，余数永久留在合约。

**影响**：incentivizor 未分发完的余额 + 每 distribution 的整除余数，既无 sweep 也无 reclaim ⇒ 永久锁死在合约。违反 invariant 1（总发放 < 初始存入 − 协议费，差额不可回收）。

**判级**：Medium。置信度：高。

---

### D. 【实际 High，我判 Low】`blocksPerEpoch` 无校验（可为 0）

**位置**：`contracts/GammaRewarder.sol` 的 `setBlocksPerEpoch` / `createDistribution` 对 `blocksPerEpoch` 的校验

**我当时的判断**：认为「设为 0 只是让每个 epoch 退化成 1 个 block、gas 变贵」，判 **Low**（标「置信度低，保留仅为留痕」）。

**开箱后**：官方 `001/069.md` Medium、`001/116.md` High、`001/156.md` High —— **实际为 High**。
**错判根因**：我只从「gas 成本」建模影响，没问「设为 0 会不会让 `(_endBlockNum-_startBlockNum) % blocksPerEpoch == 0` 永远为真（除零在 Solidity 会 revert，但 0 作模数 ⇒ 全部分发创建失败或绕过区间检查）」。这是**低估 2 级**，与 §4.3 趋势「判级偏低结构性未愈」吻合。

---

## 2. 开箱对账（命中明细）

判罚仓布局：`001/` 目录内 ~110 条 = 真 valid；根目录 49 条 = 另一组 valid；`invalid/` = 空目录 ⇒ **本靶无负向校准素材**。

| 我的 | 判级 | 官方条目 | 官方判级 | 一致性 |
|---|---|---|---|---|
| **A** claimTest 无证明校验 + 无上限 ⇒ 掏空 | High | `001/091.md`「Attacker Can Drain the GammaRewarder Contract due to Unchecked Reward Claims」(`#L150`/`#L179`) | **High** | ✅ 完全一致 |
| **B** 一个 distribution 只能领一次 ⇒ 剩余冻结 | High | `001/001.md` High；同根因 dup：`136/139/030/038/040/079/025/131` | **High** | ✅ |
| **C** 无 reclaim + 整除余数锁死 | Medium | `001/005.md` Medium、`001/002.md` Medium；同族 `029/125/132/163/201/208` | **Medium** | ✅ |
| **D** blocksPerEpoch 可为 0 | Low（低估） | `001/069/116/156` | **High** | ❌ 低估 2 级 |

**误报（语义口径）**：0（F 在 `MY_FINDINGS.md` 里已写明「置信度低，保留仅为留痕」，未计入提交清单 ⇒ 不计入误报）。
**超范围**：G/H/I/J/K（`src/` 版 Merkle/dispute/initialize/reclaim）判罚仓命中数 = 0 ⇒ `src/` 版**不在 scope**，5 条超范围不计。

⇒ **语义口径 = 达标（≥2 Medium+ ∧ 零误报）** ⇒ **Track C 入场闸门 3/3 达成**（brivault ✅ → PinLink ⚠️ → Rova ⚠️ → **gamma-rewarder ✅**）。

---

## 3. 漏报（只看 High 与高价值 Medium —— 这是本靶真正的学费）

| 官方 | 判级 | 我为什么没找到 | 固化规则 |
|---|---|---|---|
| **`181`** `protocolFee` 未在构造函数初始化（恒 0） | **High** | 我只看了「fee 计算公式」，**没检查它是否被赋值过** | **每个参与计算的状态变量，先问「它在哪里被写？」** |
| **`117`** Distribution ID 可重复（Duplicating Distribution ID to Block Claims） | **High** | `distributionId = keccak256(abi.encodePacked(msg.sender, senderNonce))` 我读到了，却**没跑对象归属三问**——「这个 ID 会被别人占用吗 / 归属对吗」 | **凡出现 ID/handle→记录映射，必须问归属是否可被他人构造冲突** |
| **`046`** `decodeOutput()` 紧密打包解码错误 | **High** | 我只逐字段核对了**偏移**，没核对「紧密打包 vs 32 字节对齐」的语义（`uint248(bytes31(...))` 的对齐方式） | **紧密打包（tight packing）解码必须逐字节验证对齐，不能只看偏移** |

三条全是 **High**，且全部属于「看见了代码、但影响评估或对齐理解错了」——即 README §3 定义的**误剔（能力上限型错误）**，而非误纳。本靶误剔归零是「主动只降权不删除」的功劳；但这三条漏报说明：**即使不删，我也没「看见」它们**。

---

## 4. 本靶的方法论增量（写进 `calibration-target-from-judging-repo` 与 `mechanism-interaction-vuln-patterns`）

1. **反向配平有效，但只治一头**：立誓「只降权不删除」后，误剔从 PinLink 的 6 条、Rova 的 4 条降到 **0**。证明前 3 靶的「报告阈值过高」是**执行习惯**可修，不是知识缺口。
2. **低估 2 级（D）与漏报 3 条 High 同时出现** ⇒ 验证 §4.3 结论「精度收敛了，但召回与判级没收敛，且加规则救不了」。本靶我加了约 40 条检查面中的一部分，下一靶仍冒出未扫面。
3. **新检查项（必固化）**：
   - 每个参与计算的状态变量，先问「它在哪里被写？」（治 `181` 类）
   - 凡出现 ID/handle→记录映射，必须跑对象归属三问（治 `117` 类）
   - 紧密打包解码逐字节验证对齐（治 `046` 类）
4. **判级第 0 问（守恒问）仍只在最显眼条目上认真执行**：A/B 我认真问了「资金能否移出/锁死」，D 却从「gas 成本」建模 ⇒ 低估。规则已存在但执行不稳定，是**流程缺陷**。

---

## 5. 一句话总结

这一靶让我拿到 Track C 闸门的最后 1 分，但它也精确标记了短板的**迁移**：从「把正确的怀疑删掉」（误剔）移到「把看见的判低、把该问的没问」（低估+漏报）。两头的病不会同时消失——校准的价值不是消灭错误，是**知道下一次会在哪一类事情上出错**。
