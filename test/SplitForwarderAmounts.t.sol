// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SplitForwarder, Leg, TokenSplit, FlexibleLeg, FlexibleTokenSplit} from "../src/SplitForwarder.sol";
import {IPermit2} from "../src/interfaces/IPermit2.sol";

contract MockPermitToken {
    string public constant name = "Mock Permit Token";
    string public constant symbol = "MPT";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function permit(address owner, address spender, uint256 value, uint256, uint8, bytes32, bytes32) external {
        allowance[owner][spender] = value;
        ++nonces[owner];
    }

    function DOMAIN_SEPARATOR() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract AmountHookReceiver {
    uint256 public calls;
    uint256 public lastAmount;
    uint256 public lastValue;

    function pullToken(address token, uint256 amount) external {
        ++calls;
        lastAmount = amount;
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "pull failed");
    }

    function convert(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) external {
        ++calls;
        lastAmount = amountIn;
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "pull failed");
        MockPermitToken(tokenOut).mint(msg.sender, amountOut);
    }

    function pullAndRefund(address token, uint256 amount, uint256 refund) external {
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "pull failed");
        require(IERC20(token).transfer(msg.sender, refund), "refund failed");
    }

    function acceptNative(uint256 amount) external payable {
        require(msg.value == amount, "value/amount mismatch");
        ++calls;
        lastAmount = amount;
        lastValue = msg.value;
    }

    function callOnly() external {
        ++calls;
    }
}

contract MockPermit2 {
    bytes32 public lastWitness;
    address public lastOwner;

    function permitWitnessTransferFrom(
        IPermit2.PermitTransferFrom memory permit,
        IPermit2.SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata,
        bytes calldata
    ) external {
        require(transferDetails.requestedAmount == permit.permitted.amount, "amount mismatch");
        lastWitness = witness;
        lastOwner = owner;
        require(
            IERC20(permit.permitted.token).transferFrom(owner, transferDetails.to, transferDetails.requestedAmount),
            "pull failed"
        );
    }
}

contract SplitForwarderAmountsTest is Test {
    uint256 internal constant NO_SUB = type(uint256).max;

    SplitForwarder internal forwarder;
    MockPermitToken internal token;
    MockPermitToken internal outputToken;
    AmountHookReceiver internal hook;

    address internal user = makeAddr("user");
    address internal recipientA = makeAddr("recipientA");
    address internal recipientB = makeAddr("recipientB");

    function setUp() external {
        forwarder = new SplitForwarder();
        token = new MockPermitToken();
        outputToken = new MockPermitToken();
        hook = new AmountHookReceiver();
    }

    function testRunFlexibleSplitsERC20AcrossPlainHookAndCallOnlyLegs() external {
        token.mint(address(forwarder), 1_000 ether);

        FlexibleLeg[] memory legs = new FlexibleLeg[](3);
        legs[0] = _plain(recipientA, 300 ether);
        legs[1] = FlexibleLeg({
            target: address(hook),
            shareBps: 0,
            amount: 700 ether,
            amountOffset: 36,
            data: abi.encodeCall(hook.pullToken, (address(token), 0))
        });
        legs[2] = _callOnly(address(hook), abi.encodeCall(hook.callOnly, ()));

        forwarder.runFlexible(_single(address(token), legs));

        assertEq(token.balanceOf(recipientA), 300 ether);
        assertEq(token.balanceOf(address(hook)), 700 ether);
        assertEq(token.balanceOf(address(forwarder)), 0);
        assertEq(token.allowance(address(forwarder), address(hook)), 0);
        assertEq(hook.lastAmount(), 700 ether);
        assertEq(hook.calls(), 2);
    }

    function testRunFlexibleSplitsNativeAndPatchesHookCalldata() external {
        FlexibleLeg[] memory legs = new FlexibleLeg[](2);
        legs[0] = _plain(recipientA, 1 ether);
        legs[1] = FlexibleLeg({
            target: address(hook),
            shareBps: 0,
            amount: 2 ether,
            amountOffset: 4,
            data: abi.encodeCall(hook.acceptNative, (0))
        });

        forwarder.runFlexible{value: 3 ether}(_single(address(0), legs));

        assertEq(recipientA.balance, 1 ether);
        assertEq(address(hook).balance, 2 ether);
        assertEq(address(forwarder).balance, 0);
        assertEq(hook.lastAmount(), 2 ether);
        assertEq(hook.lastValue(), 2 ether);
    }

    function testRunFlexibleProcessesSequentialUnknownAmmOutput() external {
        token.mint(address(forwarder), 1_000 ether);

        FlexibleTokenSplit[] memory splits = new FlexibleTokenSplit[](2);
        FlexibleLeg[] memory inputLegs = new FlexibleLeg[](1);
        inputLegs[0] = FlexibleLeg({
            target: address(hook),
            shareBps: 0,
            amount: 1_000 ether,
            amountOffset: 68,
            data: abi.encodeCall(hook.convert, (address(token), address(outputToken), 0, 600 ether))
        });
        splits[0] = FlexibleTokenSplit({token: address(token), legs: inputLegs});

        FlexibleLeg[] memory outputLegs = new FlexibleLeg[](2);
        outputLegs[0] = _plain(recipientA, 100 ether);
        outputLegs[1] = _share(recipientB, 10_000);
        splits[1] = FlexibleTokenSplit({token: address(outputToken), legs: outputLegs});

        forwarder.runFlexible(splits);

        assertEq(token.balanceOf(address(forwarder)), 0);
        assertEq(outputToken.balanceOf(address(forwarder)), 0);
        assertEq(outputToken.balanceOf(recipientA), 100 ether);
        assertEq(outputToken.balanceOf(recipientB), 500 ether);
    }

    function testRunFlexibleSplitsRemainderPoolByBpsAndLastShareConsumesRounding() external {
        token.mint(address(forwarder), 1_001);

        FlexibleLeg[] memory legs = new FlexibleLeg[](3);
        legs[0] = _plain(recipientA, 100);
        legs[1] = _share(recipientB, 3_333);
        legs[2] = _share(user, 6_667);

        forwarder.runFlexible(_single(address(token), legs));

        // The 901-token remainder pool floors the first share to 300; the
        // final share receives all 601 tokens left, including rounding dust.
        assertEq(token.balanceOf(recipientA), 100);
        assertEq(token.balanceOf(recipientB), 300);
        assertEq(token.balanceOf(user), 601);
        assertEq(token.balanceOf(address(forwarder)), 0);
    }

    function testRunFlexibleRevertsAtomicallyWhenRemainderIsUnallocated() external {
        token.mint(address(forwarder), 1_000 ether);
        FlexibleLeg[] memory legs = new FlexibleLeg[](2);
        legs[0] = _plain(recipientA, 300 ether);
        legs[1] = _plain(recipientB, 699 ether);

        vm.expectRevert(abi.encodeWithSelector(SplitForwarder.SharesMustSumTo10000.selector, 0, 0));
        forwarder.runFlexible(_single(address(token), legs));

        assertEq(token.balanceOf(address(forwarder)), 1_000 ether);
        assertEq(token.balanceOf(recipientA), 0);
        assertEq(token.balanceOf(recipientB), 0);
    }

    function testRunFlexibleRejectsZeroAmountPlainLeg() external {
        token.mint(address(forwarder), 1 ether);
        FlexibleLeg[] memory legs = new FlexibleLeg[](2);
        legs[0] = _plain(recipientA, 1 ether);
        legs[1] = _plain(recipientB, 0);

        vm.expectRevert(abi.encodeWithSelector(SplitForwarder.ZeroLegAmount.selector, 0, 1));
        forwarder.runFlexible(_single(address(token), legs));
    }

    function testRunFlexibleRejectsLegUsingAmountAndBps() external {
        token.mint(address(forwarder), 1 ether);
        FlexibleLeg[] memory legs = new FlexibleLeg[](1);
        legs[0] = FlexibleLeg({target: recipientA, shareBps: 10_000, amount: 1 ether, amountOffset: NO_SUB, data: ""});

        vm.expectRevert(abi.encodeWithSelector(SplitForwarder.LegCannotUseAmountAndBps.selector, 0, 0));
        forwarder.runFlexible(_single(address(token), legs));
    }

    function testRunFlexibleRejectsFixedAmountsAboveLiveBalance() external {
        token.mint(address(forwarder), 1 ether);
        FlexibleLeg[] memory legs = new FlexibleLeg[](1);
        legs[0] = _plain(recipientA, 2 ether);

        vm.expectRevert(abi.encodeWithSelector(SplitForwarder.FixedAmountsExceedBalance.selector, 0, 2 ether, 1 ether));
        forwarder.runFlexible(_single(address(token), legs));
    }

    function testRunFlexibleRejectsInvalidHookOffset() external {
        token.mint(address(forwarder), 1 ether);
        FlexibleLeg[] memory legs = new FlexibleLeg[](1);
        legs[0] = FlexibleLeg({
            target: address(hook),
            shareBps: 0,
            amount: 1 ether,
            amountOffset: 100,
            data: abi.encodeCall(hook.pullToken, (address(token), 0))
        });

        vm.expectRevert(abi.encodeWithSelector(SplitForwarder.InvalidAmountOffset.selector, 0, 0));
        forwarder.runFlexible(_single(address(token), legs));
    }

    function testRunFlexibleTerminalInvariantRejectsHookRefund() external {
        token.mint(address(forwarder), 1_000 ether);
        FlexibleLeg[] memory legs = new FlexibleLeg[](1);
        legs[0] = FlexibleLeg({
            target: address(hook),
            shareBps: 0,
            amount: 1_000 ether,
            amountOffset: NO_SUB,
            data: abi.encodeCall(hook.pullAndRefund, (address(token), 1_000 ether, 1 ether))
        });

        vm.expectRevert(abi.encodeWithSelector(SplitForwarder.BalanceNotConsumed.selector, address(token), 1 ether));
        forwarder.runFlexible(_single(address(token), legs));

        assertEq(token.balanceOf(address(forwarder)), 1_000 ether);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function testRunFlexibleWithPermitPullsAndBindsHybridPlan() external {
        address permit2 = address(forwarder.PERMIT2());
        vm.etch(permit2, type(MockPermit2).runtimeCode);
        token.mint(user, 1_000 ether);
        vm.prank(user);
        token.approve(permit2, type(uint256).max);

        FlexibleLeg[] memory legs = new FlexibleLeg[](2);
        legs[0] = _plain(recipientA, 250 ether);
        legs[1] = _share(recipientB, 10_000);
        FlexibleTokenSplit[] memory splits = _single(address(token), legs);
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({token: address(token), amount: 1_000 ether}),
            nonce: 1,
            deadline: block.timestamp + 1 hours
        });

        forwarder.runFlexibleWithPermit(permit, user, splits, hex"1234");

        assertEq(token.balanceOf(user), 0);
        assertEq(token.balanceOf(recipientA), 250 ether);
        assertEq(token.balanceOf(recipientB), 750 ether);
        assertEq(MockPermit2(permit2).lastOwner(), user);
        assertEq(MockPermit2(permit2).lastWitness(), keccak256(abi.encode(forwarder.FLEXIBLE_WITNESS_TAG(), splits)));
    }

    function testPermitAndRunFlexiblePullsFromDirectCaller() external {
        token.mint(user, 1_000 ether);
        FlexibleLeg[] memory legs = new FlexibleLeg[](2);
        legs[0] = _plain(recipientA, 400 ether);
        legs[1] = _share(recipientB, 10_000);

        vm.prank(user);
        forwarder.permitAndRunFlexible(
            address(token),
            1_000 ether,
            block.timestamp + 1 hours,
            27,
            bytes32(0),
            bytes32(0),
            _single(address(token), legs)
        );

        assertEq(token.balanceOf(user), 0);
        assertEq(token.balanceOf(recipientA), 400 ether);
        assertEq(token.balanceOf(recipientB), 600 ether);
        assertEq(token.balanceOf(address(forwarder)), 0);
        assertEq(token.nonces(user), 1);
    }

    function testExistingBpsHookPathStillWorks() external {
        token.mint(address(forwarder), 1_000 ether);
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg({target: recipientA, shareBps: 2_500, amountOffset: NO_SUB, data: ""});
        legs[1] = Leg({
            target: address(hook),
            shareBps: 7_500,
            amountOffset: 36,
            data: abi.encodeCall(hook.pullToken, (address(token), 0))
        });
        TokenSplit[] memory splits = new TokenSplit[](1);
        splits[0] = TokenSplit({token: address(token), legs: legs});

        forwarder.run(splits);

        assertEq(token.balanceOf(recipientA), 250 ether);
        assertEq(token.balanceOf(address(hook)), 750 ether);
        assertEq(token.balanceOf(address(forwarder)), 0);
    }

    function _plain(address target, uint256 amount) internal pure returns (FlexibleLeg memory) {
        return FlexibleLeg({target: target, shareBps: 0, amount: amount, amountOffset: NO_SUB, data: ""});
    }

    function _share(address target, uint96 shareBps) internal pure returns (FlexibleLeg memory) {
        return FlexibleLeg({target: target, shareBps: shareBps, amount: 0, amountOffset: NO_SUB, data: ""});
    }

    function _callOnly(address target, bytes memory data) internal pure returns (FlexibleLeg memory) {
        return FlexibleLeg({target: target, shareBps: 0, amount: 0, amountOffset: NO_SUB, data: data});
    }

    function _single(address splitToken, FlexibleLeg[] memory legs)
        internal
        pure
        returns (FlexibleTokenSplit[] memory splits)
    {
        splits = new FlexibleTokenSplit[](1);
        splits[0] = FlexibleTokenSplit({token: splitToken, legs: legs});
    }
}
