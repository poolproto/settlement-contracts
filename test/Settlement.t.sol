// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Settlement.sol";

contract SettlementTest is Test {
    Settlement public settlement;

    address buyer;
    uint256 buyerPk;
    address seller;
    uint256 sellerPk;

    address asset = address(0xA);
    address collateral = address(0xC);

    bytes32 DOMAIN_SEPARATOR;
    bytes32 constant BATCH_TYPEHASH = keccak256(
        "SettlementBatch(bytes32 tradeId,address buyer,address seller,address asset,address collateral,uint256 assetAmount,uint256 collateralAmount,uint256 deadline)"
    );

    function setUp() public {
        settlement = new Settlement();

        (buyer, buyerPk) = makeAddrAndKey("buyer");
        (seller, sellerPk) = makeAddrAndKey("seller");

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Pool Protocol"),
                keccak256("1"),
                block.chainid,
                address(settlement)
            )
        );
    }

    function _digest(bytes32 tradeId, uint256 assetAmount, uint256 collateralAmount, uint256 deadline) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(BATCH_TYPEHASH, tradeId, buyer, seller, asset, collateral, assetAmount, collateralAmount, deadline)
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_successfulSettlement() public {
        bytes32 tradeId = keccak256("trade1");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _digest(tradeId, 100e18, 200e6, deadline);

        bytes memory buyerSig = _sign(buyerPk, digest);
        bytes memory sellerSig = _sign(sellerPk, digest);

        settlement.settle(
            tradeId, buyer, seller, asset, collateral,
            100e18, 200e6, deadline, buyerSig, sellerSig
        );
    }

    function test_replayProtection() public {
        bytes32 tradeId = keccak256("trade2");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _digest(tradeId, 50e18, 100e6, deadline);

        bytes memory buyerSig = _sign(buyerPk, digest);
        bytes memory sellerSig = _sign(sellerPk, digest);

        settlement.settle(tradeId, buyer, seller, asset, collateral, 50e18, 100e6, deadline, buyerSig, sellerSig);

        vm.expectRevert();
        settlement.settle(tradeId, buyer, seller, asset, collateral, 50e18, 100e6, deadline, buyerSig, sellerSig);
    }

    function test_expiredDeadlineReverts() public {
        bytes32 tradeId = keccak256("trade3");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _digest(tradeId, 10e18, 20e6, deadline);

        bytes memory buyerSig = _sign(buyerPk, digest);
        bytes memory sellerSig = _sign(sellerPk, digest);

        vm.warp(deadline + 1);

        vm.expectRevert();
        settlement.settle(tradeId, buyer, seller, asset, collateral, 10e18, 20e6, deadline, buyerSig, sellerSig);
    }

    function test_badSignatureReverts() public {
        bytes32 tradeId = keccak256("trade4");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _digest(tradeId, 10e18, 20e6, deadline);

        (, uint256 fakePk) = makeAddrAndKey("fake");
        bytes memory fakeSig = _sign(fakePk, digest);
        bytes memory sellerSig = _sign(sellerPk, digest);

        vm.expectRevert();
        settlement.settle(tradeId, buyer, seller, asset, collateral, 10e18, 20e6, deadline, fakeSig, sellerSig);
    }

    function test_cancelledTradeCantSettle() public {
        bytes32 tradeId = keccak256("trade5");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _digest(tradeId, 10e18, 20e6, deadline);

        bytes memory buyerSig = _sign(buyerPk, digest);
        bytes memory sellerSig = _sign(sellerPk, digest);

        settlement.cancelTrade(tradeId);

        vm.expectRevert();
        settlement.settle(tradeId, buyer, seller, asset, collateral, 10e18, 20e6, deadline, buyerSig, sellerSig);
    }
}
