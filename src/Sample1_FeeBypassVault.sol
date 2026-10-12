// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MockUSDC — minimal plain ERC20 (no hooks, standard behavior)
contract MockUSDC {
    string public constant name = "Mock USDC";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @title EntryFeeVault — staking vault with a 1% entry fee credited to the fee treasury.
///
/// Intended flow (Path A): users call `depositWithFee` — 1% of every deposit is
/// pulled into `feeTreasury` and the depositor is credited shares net of the fee.
///
/// Second flow (Path B): `depositViaRouter` exists for front-end/partner routers
/// that are *supposed* to remit the entry fee to the treasury off-chain. The
/// contract, however, never verifies that the fee was actually paid, and the
/// function has no access control: ANY user can call `depositViaRouter` directly
/// with an arbitrary `router` address and receive shares for the FULL amount,
/// bypassing the fee 100% of the time.
///
/// Same result (vault +`amount`), two paths, one of which pays no fee.
contract EntryFeeVault {
    MockUSDC public immutable asset;
    address public feeTreasury;
    uint256 public constant ENTRY_FEE_BPS = 100; // 1%

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    event Deposited(address indexed user, uint256 amount, uint256 shares, bool feePaid);

    constructor(MockUSDC _asset, address _treasury) {
        asset = _asset;
        feeTreasury = _treasury;
    }

    /// @notice Path A — the fee-paying deposit (intended default).
    function depositWithFee(uint256 amount) external {
        uint256 fee = (amount * ENTRY_FEE_BPS) / 10_000;
        uint256 net = amount - fee;

        asset.transferFrom(msg.sender, address(this), amount);
        asset.transfer(feeTreasury, fee);

        uint256 shares = _convertToShares(net);
        sharesOf[msg.sender] += shares;
        totalShares += shares;

        emit Deposited(msg.sender, amount, shares, true);
    }

    /// @notice Path B — "router" deposit. The router is *documented* to remit the
    ///         1% fee to `feeTreasury` itself, but nothing enforces it and the
    ///         function is permissionless: calling it directly skips the fee.
    function depositViaRouter(address router, uint256 amount) external {
        router; // unused — fee handling "delegated" to the router
        asset.transferFrom(msg.sender, address(this), amount);

        uint256 shares = _convertToShares(amount); // full amount, no fee
        sharesOf[msg.sender] += shares;
        totalShares += shares;

        emit Deposited(msg.sender, amount, shares, false);
    }

    function _convertToShares(uint256 assets) internal view returns (uint256) {
        if (totalShares == 0) return assets;
        return (assets * totalShares) / (asset.balanceOf(address(this)) - assets);
    }
}
