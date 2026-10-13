# CASE-02 —— 一个 typehash 被五个函数共用：无状态签名的跨动作重放

> **English abstract.** Crestal Network's EIP-712 layer defines a single
> `DEPLOYMENT_REQUEST_TYPEHASH` over `(projectId, base64RecParam, serverURL)`, with **no
> function selector, no nonce, and no deadline**. Five public entry points recompute that
> identical digest. A signature harvested from the mempool can therefore be spent on a
> *different* function with attacker-chosen parameters — forcing the signer to pay, or
> consuming their one-shot whitelist / NFT slot. The EIP-712 domain separator does **not**
> help: it binds chain and contract, not action.
> Target: `crestal-omni-contracts @ dc45e98a`. Original contest: Sherlock
> `2025-03-crestal-network`. **Post-hoc independent reproduction against the public judging
> repository, not a contest submission.**

---

## 0. 溯源

| 项 | 值 |
|---|---|
| 协议 | Crestal Network（Base，DePIN 「blueprint 部署服务市场」） |
| 靶 | Sherlock `2025-03-crestal-network` |
| scope pin | `crestalnetwork/crestal-omni-contracts @ dc45e98af5e247dce5bbe53b0bd5b1f256884f84` |
| scope | `Blueprint.sol`(91) / `BlueprintCore.sol`(763) / `BlueprintV5.sol`(25) / `EIP712.sol`(52) / `Payment.sol`(33) = **964 行** |
| 官方结论 | 同一根因被**拆成两个级别**：`updateWorkerDeploymentConfigWithSig` 重放族 = **High**（`042/065/091/170/279/338/391` 等）；广义 EIP-712 函数重放 = **Medium**（`105`） |
| 我的产出 | 独立命中根因；但**我把两个后果合并成一个 High** —— 见 §6 |

---

## 1. 设计意图：给 gasless 用的无状态签名

Crestal 的核心流程是"用户签名、服务方代提交"（gasless）。所以 Five 个入口都接受一个 `bytes signature`，链上用 `ECDSA.recover` 还原签名者身份，然后把**签名者**当成操作主体：

```solidity
// BlueprintCore.sol:400-414
function createProjectIDAndDeploymentRequestWithSig(
    bytes32 projectId, string memory base64Proposal, string memory serverURL, bytes memory signature
) public returns (bytes32 requestID) {
    bytes32 digest = getRequestDeploymentDigest(projectId, base64Proposal, serverURL);
    address signerAddr = getSignerAddress(digest, signature);
    requestID = createCommonProjectIDAndDeploymentRequest(signerAddr, projectId, base64Proposal, dummyAddress, serverURL);
}
```

问题的全部根源在这个 `digest` 里 —— **它描述了"用户想要什么数据"，但没有描述"用户授权执行什么操作"。**

---

## 2. 根因

### 2.1 摘要里有什么、没有什么

```solidity
// EIP712.sol:9-11
bytes32 public constant DEPLOYMENT_REQUEST_TYPEHASH =
    keccak256("DeploymentRequest(bytes32 projectId,string base64RecParam,string serverURL)");

// EIP712.sol:33-45
function getRequestDeploymentDigest(bytes32 projectId, string memory base64RecParam, string memory serverURL)
    public view returns (bytes32)
{
    bytes32 structHash = keccak256(
        abi.encode(
            DEPLOYMENT_REQUEST_TYPEHASH, projectId, keccak256(bytes(base64RecParam)), keccak256(bytes(serverURL))
        )
    );
    return _hashTypedDataV4(structHash);
}
```

| 摘要**绑定**了 ✅ | 摘要**没有**绑定 ❌ |
|---|---|
| 域名（`chainId` + `verifyingContract`） | **被调用的函数**（无 selector / 无 per-action typehash） |
| `projectId` | **`tokenAddress`** —— 也就是**这次要扣多少钱** |
| `base64RecParam` | `privateWorkerAddress` |
| `serverURL` | `requestID`（付费更新哪一个部署） |
| | **`nonce`**（能否重复使用） |
| | **`deadline`**（是否有有效期） |

### 2.2 一个摘要，五个消费者

`getRequestDeploymentDigest` 有 **5 个调用方**（pin 逐行核实）：

| # | 函数 | 行号 | 摘要参数 |
|---|---|---|---|
| 1 | `createProjectIDAndDeploymentRequestWithSig` | L400（digest @L407） | `(projectId, base64Proposal, serverURL)` |
| 2 | `createAgentWithTokenWithSig` | L491（digest @L502） | `(projectId, base64Proposal, serverURL)` |
| 3 | `createAgentWithWhitelistUsersWithSig` | L540（digest @L549） | `(projectId, base64Proposal, serverURL)` |
| 4 | `createAgentWithSigWithNFT` | L566（digest @L575） | `(projectId, base64Proposal, serverURL)` |
| 5 | `updateWorkerDeploymentConfigWithSig` | L672（digest @**L680**） | `(projectId, updatedBase64Config, **"app.crestal.network"**)` |

前四个**参数完全一致** ⇒ 对同一组 `(P, X, S)`，它们算出的是**同一个 digest**。

### 2.3 域分隔符救不了你

EIP-712 的域分隔符包含 `chainId` 与 `verifyingContract`，所以这里**跨链重放和跨合约重放确实被挡住了**。但它挡不住**同合约、同链、跨函数**的重放 —— 而那正是本漏洞的形态。

> 这是一个很容易自我说服的点。我最初的否证记录里写过"EIP-712 域含 chainId+verifyingContract ⇒ 无重放"，随后自己推翻：**域分隔符防的是"在别处用"，不是"换个用法用"。**

### 2.4 第 5 个消费者更糟：`serverURL` 被写成常量

`updateWorkerDeploymentConfigWithSig` 传给 digest 的第三个参数是硬编码字符串：

```solidity
// BlueprintCore.sol:678-686
function updateWorkerDeploymentConfigWithSig(
    address tokenAddress, bytes32 projectId, bytes32 requestID,
    string memory updatedBase64Config, bytes memory signature
) public {
    bytes32 digest = getRequestDeploymentDigest(projectId, updatedBase64Config, "app.crestal.network");
    address signerAddr = getSignerAddress(digest, signature);
    updateWorkerDeploymentConfigCommon(tokenAddress, signerAddr, projectId, requestID, updatedBase64Config);
}
```

两个后果：

1. `requestID` **不在摘要里** ⇒ 攻击者可以自选"更新哪一个部署"（该部署须属于受害者，但受害者的哪个部署由攻击者挑）。
2. `serverURL` 被钉死 ⇒ 任何 `serverURL == "app.crestal.network"` 的 DeploymentRequest 摘要都与此**完全碰撞**，重放面进一步扩大。

---

## 3. 攻击路径

### 3.1 跨函数重放 → 受害者为攻击者的操作买单

前提：受害者已对本合约 `approve` 了 ERC-20（正常使用协议的常规动作）。

```
① 受害者签名 DeploymentRequest(P, X, S)，广播意图调用
   createProjectIDAndDeploymentRequestWithSig(...)

② 攻击者从 mempool 抄走 signature，改为调用
   createAgentWithTokenWithSig(P, X, W_attacker, S, tokenAddress, signature)
   ├ digest 在 L502 重算 —— (P, X, S) 相同 ⇒ 与受害者签的**完全一致** ✅
   ├ L505 还原出的 signerAddr = 受害者 ✅
   └ L507 → createAgent(victim, …) 且 tokenAddress ≠ 0 ⇒ 走 token 分支
        ├ L461  cost = paymentOpCostMp[tokenAddress][CREATE_AGENT_OP]
        └ L464  payWithERC20(tokenAddress, cost, victim, feeCollectionWalletAddress)
                 ↑ 受害者被扣款，收款方是协议费钱包
```

攻击者的收益：**用受害者的钱创建了一个归属受害者的 agent / 部署请求**，而 `privateWorkerAddress` 由攻击者指定 ⇒ 部署请求被指向攻击者自己。

同时受害者的原始交易随后必然 revert（`newProject` 修饰符要求 `projects[P].id == 0`，而该 projectId 已被占用）⇒ **合法流程被劫持且失败**。

### 3.2 消耗一次性权益

同理调用 ③ 或 ④：`whitelistUsers[victim]` 与 `nftTokenIdMap[tokenId]` 会被置为 `Pickup` ⇒ **受害者永久丧失 agent 创建权**（白名单一个地址只能建一次；NFT tokenId 用过即不可复用）。

### 3.3 同函数重放 → 重复扣费

对第 5 个消费者，同一签名可以被**反复**使用：每次都会扣一次 `paymentOpCostMp[tokenAddress][UPDATE_AGENT_OP]`。这是官方判为 **High** 的那条路径（"token balance draining"）。

---

## 4. 官方评审结论：一个根因，两个后果，两个级别

这是本 case 最值得记录的部分 —— 官方的拆分方式直接暴露了我的判级缺陷。

> **`042.md`** — Watson `Soaring Caramel Dragon`，**High**
>
> **Title**: Missing signature invalidation in `BlueprintCore::updateWorkerDeploymentConfigWithSig()` allows token balance draining and configuration update replay
>
> **Summary**: "Missing signature invalidation ... causes unauthorized token deductions and configuration update replay as attackers can use the same signature multiple times to repeatedly charge the user's token balance for configuration updates."

同族 High 还有 `065 / 091 / 170 / 279 / 338 / 391`（标题均为签名重放 / 配置更新回滚 / 资金流失）。

> **`105.md`** — Watson `Raspy Eggplant Mouse`，**Medium**
>
> **Title**: Signatures can be replayed in EIP712-based functions, leading to unauthorized payments and duplicate agent creation
>
> **Impact 逐字**: "Malicious actors can replay valid signatures to create multiple duplicate agents / Users will be charged multiple times for token payments"

`105.md` 是与我 §3.1 最贴近的条目，官方给的是 **Medium**。

---

## 5. 判级复盘：我犯的是"级别合并"错误

| 项 | 我 | 官方 | 结论 |
|---|---|---|---|
| 根因 | 摘要不绑定动作 + 无 nonce/deadline | 同 | ✅ 完全一致 |
| 消费者枚举 | 我列出全部 5 个（含硬编码 `serverURL`） | `105` 列出 3 个（`491/566/672`） | ✅ 我的覆盖更宽 |
| 攻击路径（跨函数强制付款） | **High** | ≈ `105.md` ⇒ **Medium** | ❌ **偏高 1 级** |
| 攻击路径（同函数重复扣费） | 合并进同一个 High | `042` 等独立 ⇒ **High** | ✅ 若单列则正确 |

**我的错误不是判级方向，而是把性质不同的两个后果塞进了一个 finding。**

- "攻击者强制受害者付款**一次**、且资金**留在协议内**"——受害者的钱变成了自己名下的 agent/部署请求。这更接近**非自愿消费**，官方判 Medium。
- "攻击者用同一签名**反复**扣款直到余额耗尽"——资金**持续流出**且无对应产出。这才是 High。

我合并后只报了一个 High，于是**丢掉了官方的级别结构**：既没有为 Medium 那部分给出准确级别，也让 High 那部分的论证依赖于"重复"这一前提却没写出来。

**这在 30 靶的错误分类里是独一份的** —— 其他靶都是清一色的"偏低"，这里是"偏高"，而且成因是一条以前没记过的病灶：

> **固化规则（新）**：一个根因若同时产生**后果强度不同**的多条路径，必须**按后果分列**并各自判级，不能合并成一个 finding 取最高级。
> 判别标准：**资金是否离开受害者的控制范围、以及能否重复**。
> ——"留在他自己名下的资产里"与"流出到协议外且可重复"是两档，不是一档。

这也是本目录里唯一一条**我自己记录中的成绩单与复查结果不一致**的地方（原成绩单把 F3 记为"判级准确"，未计入偏高）。**保留这个不一致，比修正它更有价值** —— 它说明"我当时用来给自己打分的口径"本身也需要校准。

---

## 6. 修复方向

三层，官方 `105.md` 的建议与第 1 层一致：

1. **摘要绑定动作**：为每个入口定义独立的 `TYPEHASH`（如 `CreateAgentWithToken(bytes32 projectId,string base64RecParam,string serverURL,address tokenAddress,uint256 amount)`），把**所有会改变后果的参数**（`tokenAddress`、`requestID`、`privateWorkerAddress`、金额）纳入摘要。
2. **加一次性语义**：`nonce`（每用户递增）或 `usedSignature` mapping + `deadline`。
3. **取消硬编码**：`updateWorkerDeploymentConfigWithSig` 里的 `"app.crestal.network"` 必须改为真实参数（或从摘要中移除该槽位），消除摘要碰撞面。

---

## 7. 复现方式

```bash
git clone https://github.com/crestalnetwork/crestal-omni-contracts
cd crestal-omni-contracts && git checkout dc45e98af5e247dce5bbe53b0bd5b1f256884f84

# 五个消费者
grep -n "WithSig" src/BlueprintCore.sol

# 摘要定义（只有三样东西）
sed -n '7,11p;33,45p' src/EIP712.sol

# 第 5 个消费者的硬编码 serverURL
sed -n '672,686p' src/BlueprintCore.sol
```

**最小验证思路**（无需分叉主网）：用 `solc` 编译 `EIP712.sol` + `BlueprintCore.sol`，在 `anvil` 上部署，然后：

1. 用测试私钥对 `getRequestDeploymentDigest(P, X, S)` 签名；
2. 断言 `createProjectIDAndDeploymentRequestWithSig(P, X, S, sig)` 中被 `recover` 出的地址 = 签名者；
3. **断言同一个 `sig` 在 `createAgentWithTokenWithSig(P, X, W, S, token, sig)` 中同样被接受** —— 这一条即可证成根因；
4. 部署一个 `MockERC20`，让签名者 `approve`，观察 `payWithERC20` 把签名者的余额划走。

第 3 步是关键：**它同时证明了"摘要跨函数相同"和"签名没有一次性语义"**，不需要真的构造完整攻击。
