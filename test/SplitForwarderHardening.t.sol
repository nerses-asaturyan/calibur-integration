// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SplitForwarder, Leg, TokenSplit, FlexibleLeg, FlexibleTokenSplit} from "../src/SplitForwarder.sol";
import {MockPermitToken} from "./SplitForwarderAmounts.t.sol";

/// @dev Receives a native leg mid-plan and tries the cross-split theft: a
///      nested permissionless run() sweeping a token an outer LATER split was
///      going to distribute, then donating one unit back so the outer plan's
///      terminal checks would still pass. Records whether the lock blocked it.
contract ReentrantSweeper {
    SplitForwarder internal immutable forwarder;
    address internal immutable sweepToken;
    bool internal immutable useFlexible;
    bool public nestedCallReverted;

    constructor(SplitForwarder forwarder_, address sweepToken_, bool useFlexible_) {
        forwarder = forwarder_;
        sweepToken = sweepToken_;
        useFlexible = useFlexible_;
    }

    receive() external payable {
        if (useFlexible) {
            FlexibleLeg[] memory legs = new FlexibleLeg[](1);
            legs[0] = FlexibleLeg({
                target: address(this),
                shareBps: 10_000,
                amount: 0,
                amountOffset: type(uint256).max,
                data: ""
            });
            FlexibleTokenSplit[] memory splits = new FlexibleTokenSplit[](1);
            splits[0] = FlexibleTokenSplit({token: sweepToken, legs: legs});
            try forwarder.runFlexible(splits) {
                MockPermitToken(sweepToken).transfer(address(forwarder), 1);
            } catch {
                nestedCallReverted = true;
            }
        } else {
            Leg[] memory legs = new Leg[](1);
            legs[0] = Leg({target: address(this), shareBps: 10_000, amountOffset: type(uint256).max, data: ""});
            TokenSplit[] memory splits = new TokenSplit[](1);
            splits[0] = TokenSplit({token: sweepToken, legs: legs});
            try forwarder.run(splits) {
                MockPermitToken(sweepToken).transfer(address(forwarder), 1);
            } catch {
                nestedCallReverted = true;
            }
        }
    }
}

/// @dev Hook target that reenters run() WITHOUT catching, so the lock's revert
///      bubbles verbatim through the hook and pins the exact error selector.
contract ReenteringHook {
    SplitForwarder internal immutable forwarder;

    constructor(SplitForwarder forwarder_) {
        forwarder = forwarder_;
    }

    function pullAndReenter(address token, uint256 amount) external {
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "pull failed");
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({target: address(this), shareBps: 10_000, amountOffset: type(uint256).max, data: ""});
        TokenSplit[] memory splits = new TokenSplit[](1);
        splits[0] = TokenSplit({token: token, legs: legs});
        forwarder.run(splits);
    }
}

/// @notice Regression tests for the audit fixes: the shared reentrancy lock,
///         the entry-baseline native check (one-wei censorship), and the
///         zero-pool-robust flexible remainder.
contract SplitForwarderHardeningTest is Test {
    uint256 internal constant NO_SUB = type(uint256).max;

    SplitForwarder internal forwarder;
    MockPermitToken internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() external {
        forwarder = new SplitForwarder();
        token = new MockPermitToken();
    }

    // ---------------------------------------------------------------- lock --

    function testRunBlocksCrossSplitReentrancyTheft() external {
        // The audit trace: 1 ETH → attacker (split 0), 100 tokens → alice
        // (split 1). Mid-callback the attacker nests a run() to sweep the
        // tokens and donate 1 back; the lock must leave alice fully paid.
        token.mint(address(forwarder), 100 ether);
        ReentrantSweeper attacker = new ReentrantSweeper(forwarder, address(token), false);

        TokenSplit[] memory splits = new TokenSplit[](2);
        Leg[] memory nativeLegs = new Leg[](1);
        nativeLegs[0] = Leg({target: address(attacker), shareBps: 10_000, amountOffset: NO_SUB, data: ""});
        splits[0] = TokenSplit({token: address(0), legs: nativeLegs});
        Leg[] memory tokenLegs = new Leg[](1);
        tokenLegs[0] = Leg({target: alice, shareBps: 10_000, amountOffset: NO_SUB, data: ""});
        splits[1] = TokenSplit({token: address(token), legs: tokenLegs});

        forwarder.run{value: 1 ether}(splits);

        assertTrue(attacker.nestedCallReverted());
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(address(attacker)), 0);
        assertEq(address(attacker).balance, 1 ether);
        assertEq(token.balanceOf(address(forwarder)), 0);
    }

    function testRunFlexibleBlocksCrossSplitReentrancyTheft() external {
        // Same theft against the hybrid path, nesting through the OTHER
        // selector to prove the lock is shared across all entry points.
        token.mint(address(forwarder), 100 ether);
        ReentrantSweeper attacker = new ReentrantSweeper(forwarder, address(token), true);

        FlexibleTokenSplit[] memory splits = new FlexibleTokenSplit[](2);
        FlexibleLeg[] memory nativeLegs = new FlexibleLeg[](1);
        nativeLegs[0] =
            FlexibleLeg({target: address(attacker), shareBps: 10_000, amount: 0, amountOffset: NO_SUB, data: ""});
        splits[0] = FlexibleTokenSplit({token: address(0), legs: nativeLegs});
        FlexibleLeg[] memory tokenLegs = new FlexibleLeg[](2);
        tokenLegs[0] = FlexibleLeg({target: alice, shareBps: 0, amount: 40 ether, amountOffset: NO_SUB, data: ""});
        tokenLegs[1] = FlexibleLeg({target: bob, shareBps: 10_000, amount: 0, amountOffset: NO_SUB, data: ""});
        splits[1] = FlexibleTokenSplit({token: address(token), legs: tokenLegs});

        forwarder.runFlexible{value: 1 ether}(splits);

        assertTrue(attacker.nestedCallReverted());
        assertEq(token.balanceOf(alice), 40 ether);
        assertEq(token.balanceOf(bob), 60 ether);
        assertEq(token.balanceOf(address(attacker)), 0);
        assertEq(token.balanceOf(address(forwarder)), 0);
    }

    function testReentrantHookBubblesReentrancyError() external {
        token.mint(address(forwarder), 100 ether);
        ReenteringHook hook = new ReenteringHook(forwarder);

        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            target: address(hook),
            shareBps: 10_000,
            amountOffset: 36,
            data: abi.encodeCall(hook.pullAndReenter, (address(token), 0))
        });
        TokenSplit[] memory splits = new TokenSplit[](1);
        splits[0] = TokenSplit({token: address(token), legs: legs});

        vm.expectRevert(SplitForwarder.Reentrancy.selector);
        forwarder.run(splits);
    }

    // ------------------------------------------------ native entry baseline --

    function testRunTokenPlanNotCensoredByForceSentWei() external {
        // A wei parked in the forwarder beforehand must not revert an
        // unrelated ERC-20-only plan; it simply stays behind.
        vm.deal(address(forwarder), 1);
        token.mint(address(forwarder), 100 ether);

        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({target: alice, shareBps: 10_000, amountOffset: NO_SUB, data: ""});
        TokenSplit[] memory splits = new TokenSplit[](1);
        splits[0] = TokenSplit({token: address(token), legs: legs});

        forwarder.run(splits);

        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(address(forwarder).balance, 1);
    }

    function testRunFlexibleTokenPlanNotCensoredByForceSentWei() external {
        vm.deal(address(forwarder), 1);
        token.mint(address(forwarder), 100 ether);

        FlexibleLeg[] memory legs = new FlexibleLeg[](2);
        legs[0] = FlexibleLeg({target: alice, shareBps: 0, amount: 25 ether, amountOffset: NO_SUB, data: ""});
        legs[1] = FlexibleLeg({target: bob, shareBps: 10_000, amount: 0, amountOffset: NO_SUB, data: ""});
        FlexibleTokenSplit[] memory splits = new FlexibleTokenSplit[](1);
        splits[0] = FlexibleTokenSplit({token: address(token), legs: legs});

        forwarder.runFlexible(splits);

        assertEq(token.balanceOf(alice), 25 ether);
        assertEq(token.balanceOf(bob), 75 ether);
        assertEq(address(forwarder).balance, 1);
    }

    function testRunStillRejectsUnconsumedMsgValue() external {
        // The msg.value / hook-produced-ETH leftover hole stays closed: only
        // PRE-EXISTING native is tolerated, never value the call introduced.
        token.mint(address(forwarder), 100 ether);

        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({target: alice, shareBps: 10_000, amountOffset: NO_SUB, data: ""});
        TokenSplit[] memory splits = new TokenSplit[](1);
        splits[0] = TokenSplit({token: address(token), legs: legs});

        vm.expectRevert(abi.encodeWithSelector(SplitForwarder.BalanceNotConsumed.selector, address(0), 1 ether));
        forwarder.run{value: 1 ether}(splits);
    }

    function testRunNamedNativeSplitSweepsPreExistingWei() external {
        // A plan that DOES name native consumes the parked residue too and
        // still passes (final balance below the entry baseline is fine).
        vm.deal(address(forwarder), 5);

        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({target: alice, shareBps: 10_000, amountOffset: NO_SUB, data: ""});
        TokenSplit[] memory splits = new TokenSplit[](1);
        splits[0] = TokenSplit({token: address(0), legs: legs});

        forwarder.run{value: 1 ether}(splits);

        assertEq(alice.balance, 1 ether + 5);
        assertEq(address(forwarder).balance, 0);
    }

    // ------------------------------------------- zero-pool-robust remainder --

    function testRunFlexibleFixedPlusFullBpsRemainderAcceptsZeroPool() external {
        // ONE calldata shape must serve both remainder states. Zero pool: the
        // 10_000-bps leg receives nothing and is skipped.
        token.mint(address(forwarder), 100);

        forwarder.runFlexible(_feePlusRemainder());

        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(forwarder)), 0);
    }

    function testRunFlexibleFixedPlusFullBpsRemainderAcceptsDonatedWei() external {
        // Same calldata, one donated unit: the remainder leg sweeps it, so a
        // donor cannot flip a signed plan between valid and invalid.
        token.mint(address(forwarder), 101);

        forwarder.runFlexible(_feePlusRemainder());

        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(bob), 1);
        assertEq(token.balanceOf(address(forwarder)), 0);
    }

    function testRunFlexiblePartialSharesStillRejectedOnZeroPool() external {
        token.mint(address(forwarder), 100);

        FlexibleLeg[] memory legs = new FlexibleLeg[](2);
        legs[0] = FlexibleLeg({target: alice, shareBps: 0, amount: 100, amountOffset: NO_SUB, data: ""});
        legs[1] = FlexibleLeg({target: bob, shareBps: 5_000, amount: 0, amountOffset: NO_SUB, data: ""});
        FlexibleTokenSplit[] memory splits = new FlexibleTokenSplit[](1);
        splits[0] = FlexibleTokenSplit({token: address(token), legs: legs});

        vm.expectRevert(abi.encodeWithSelector(SplitForwarder.SharesMustSumTo10000.selector, 0, 5_000));
        forwarder.runFlexible(splits);
    }

    function testRunFlexibleSkipsShareFlooredToZeroAndLastLegSweeps() external {
        // Pool of 1: the 1-bps share floors to zero and is skipped; the final
        // share leg's remainder takes the whole pool.
        token.mint(address(forwarder), 101);

        FlexibleLeg[] memory legs = new FlexibleLeg[](3);
        legs[0] = FlexibleLeg({target: alice, shareBps: 0, amount: 100, amountOffset: NO_SUB, data: ""});
        legs[1] = FlexibleLeg({target: bob, shareBps: 1, amount: 0, amountOffset: NO_SUB, data: ""});
        legs[2] = FlexibleLeg({target: makeAddr("carol"), shareBps: 9_999, amount: 0, amountOffset: NO_SUB, data: ""});
        FlexibleTokenSplit[] memory splits = new FlexibleTokenSplit[](1);
        splits[0] = FlexibleTokenSplit({token: address(token), legs: legs});

        forwarder.runFlexible(splits);

        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(makeAddr("carol")), 1);
        assertEq(token.balanceOf(address(forwarder)), 0);
    }

    function _feePlusRemainder() internal view returns (FlexibleTokenSplit[] memory splits) {
        FlexibleLeg[] memory legs = new FlexibleLeg[](2);
        legs[0] = FlexibleLeg({target: alice, shareBps: 0, amount: 100, amountOffset: NO_SUB, data: ""});
        legs[1] = FlexibleLeg({target: bob, shareBps: 10_000, amount: 0, amountOffset: NO_SUB, data: ""});
        splits = new FlexibleTokenSplit[](1);
        splits[0] = FlexibleTokenSplit({token: address(token), legs: legs});
    }
}
