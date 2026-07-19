// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {TTPToken} from "../src/TTPToken.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {RewardsDistributor} from "../src/RewardsDistributor.sol";
import {MockStockToken} from "../src/mocks/MockStockToken.sol";

/// Phase 4 hardening — property tests.
///
/// Handler-based invariants for the distributor (the contract holding user-claimable
/// value): no matter the call sequence, total paid out can never exceed what was
/// funded, and a leaf can never be paid twice.
contract DistributorHandler is Test {
    RewardsDistributor public dist;
    MockStockToken public token;

    uint256 public totalFunded;
    uint256 public totalClaimed;

    // one committed epoch with two known leaves
    bytes32 leafA;
    bytes32 leafB;
    bytes32 root;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 constant AMT_A = 60e18;
    uint256 constant AMT_B = 40e18;

    constructor() {
        dist = new RewardsDistributor();
        token = new MockStockToken("Mock", "MCK");
        token.mint(address(dist), 100e18);
        totalFunded = 100e18;

        leafA = keccak256(abi.encode(uint256(1), alice, address(token), AMT_A));
        leafB = keccak256(abi.encode(uint256(1), bob, address(token), AMT_B));
        root = leafA < leafB ? keccak256(abi.encode(leafA, leafB)) : keccak256(abi.encode(leafB, leafA));
        dist.commitEpoch(root, uint64(block.number));
    }

    function _proof(bool forAlice) internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = forAlice ? leafB : leafA;
    }

    // fuzz actions ---------------------------------------------------------

    function claimA() external {
        uint256 before = token.balanceOf(alice);
        try dist.claim(1, alice, address(token), AMT_A, _proof(true)) {
            totalClaimed += token.balanceOf(alice) - before;
        } catch {}
    }

    function claimB() external {
        uint256 before = token.balanceOf(bob);
        try dist.claim(1, bob, address(token), AMT_B, _proof(false)) {
            totalClaimed += token.balanceOf(bob) - before;
        } catch {}
    }

    /// adversarial: forged amounts/accounts/proofs must always revert
    function claimForged(address who, uint256 amount, bytes32 fakeSibling) external {
        bytes32[] memory p = new bytes32[](1);
        p[0] = fakeSibling;
        try dist.claim(1, who, address(token), amount, p) {
            // only the two legitimate (leaf, amount) pairs can ever succeed
            bool legit = (who == alice && amount == AMT_A) || (who == bob && amount == AMT_B);
            require(legit, "forged claim succeeded");
            totalClaimed += amount;
        } catch {}
    }

    function pauseToggle(bool on) external {
        dist.setPaused(on);
    }
}

contract DistributorInvariants is StdInvariant, Test {
    DistributorHandler h;

    function setUp() public {
        h = new DistributorHandler();
        targetContract(address(h));
    }

    /// paid out never exceeds funding
    function invariant_NoOverpayment() public view {
        assertLe(h.totalClaimed(), h.totalFunded(), "overpaid");
    }

    /// distributor balance + paid out always equals funding (no leaks, no mints)
    function invariant_Conservation() public view {
        assertEq(
            h.token().balanceOf(address(h.dist())) + h.totalClaimed(),
            h.totalFunded(),
            "conservation violated"
        );
    }

    /// each account can never exceed its entitlement
    function invariant_EntitlementCaps() public view {
        assertLe(h.token().balanceOf(address(0xA11CE)), 60e18, "alice over");
        assertLe(h.token().balanceOf(address(0xB0B)), 40e18, "bob over");
    }
}

/// Fuzz: TTPToken transfer/approve arithmetic can't create or destroy supply.
contract TokenFuzz is Test {
    TTPToken t;
    address a = address(0xAAA1);
    address b = address(0xBBB1);

    function setUp() public {
        t = new TTPToken();
        t.transfer(a, 1_000_000e18);
    }

    function testFuzz_TransferConservesSupply(uint256 amt) public {
        amt = bound(amt, 0, t.balanceOf(a));
        vm.prank(a);
        t.transfer(b, amt);
        assertEq(t.balanceOf(a) + t.balanceOf(b), 1_000_000e18, "conservation");
    }

    function testFuzz_TransferFromRespectsAllowance(uint256 approve_, uint256 spend) public {
        approve_ = bound(approve_, 0, 1_000_000e18);
        spend = bound(spend, 0, 1_000_000e18);
        vm.prank(a);
        t.approve(address(this), approve_);
        if (spend > approve_ || spend > t.balanceOf(a)) {
            vm.expectRevert();
            t.transferFrom(a, b, spend);
        } else {
            t.transferFrom(a, b, spend);
            assertEq(t.allowance(a, address(this)), approve_ - spend, "allowance math");
        }
    }
}

/// Fuzz: FeeVault releases only to authorized callers, exactly the requested amount.
contract VaultFuzz is Test {
    FeeVault v;
    address puller = address(0xE461);

    function setUp() public {
        v = new FeeVault();
        v.setAuthorized(puller, true);
        vm.deal(address(this), 1000 ether);
    }

    function testFuzz_ReleaseExactAndAuthorized(uint96 fund, uint96 take, address rando) public {
        vm.assume(rando != puller);
        take = uint96(bound(take, 0, fund));
        vm.deal(address(this), fund); // deal the fuzzed amount so the send can't run dry
        (bool ok,) = address(v).call{value: fund}("");
        require(ok);

        vm.prank(rando);
        vm.expectRevert(FeeVault.NotAuthorized.selector);
        v.releaseEth(take);

        uint256 before = puller.balance;
        vm.prank(puller);
        v.releaseEth(take);
        assertEq(puller.balance - before, take, "exact release");
    }
}
