// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Pool Protocol Settlement
/// @notice Non-custodial settlement for matched tokenized equity orders.
///         Nothing moves unless the trader signed for it.
contract Settlement {
    struct SettlementBatch {
        bytes32 tradeId;
        address buyer;
        address seller;
        address asset;
        address collateral;
        uint256 assetAmount;
        uint256 collateralAmount;
        uint256 deadline;
        bytes buyerSig;
        bytes sellerSig;
    }

    event Settled(
        bytes32 indexed tradeId,
        address indexed buyer,
        address indexed seller,
        address asset,
        uint256 assetAmount,
        uint256 collateralAmount
    );

    event Cancelled(bytes32 indexed tradeId, address indexed by);

    mapping(bytes32 => bool) public settled;
    mapping(bytes32 => bool) public cancelled;

    /// @notice Settle a matched trade. Both signatures required.
    function settle(SettlementBatch calldata batch) external {
        require(!settled[batch.tradeId], "already settled");
        require(!cancelled[batch.tradeId], "cancelled");
        require(block.timestamp <= batch.deadline, "expired");

        bytes32 digest = _digest(batch);
        require(_recover(digest, batch.buyerSig) == batch.buyer, "bad buyer sig");
        require(_recover(digest, batch.sellerSig) == batch.seller, "bad seller sig");

        settled[batch.tradeId] = true;

        // Transfer asset from seller to buyer
        _transferFrom(batch.asset, batch.seller, batch.buyer, batch.assetAmount);
        // Transfer collateral from buyer to seller
        _transferFrom(batch.collateral, batch.buyer, batch.seller, batch.collateralAmount);

        emit Settled(
            batch.tradeId,
            batch.buyer,
            batch.seller,
            batch.asset,
            batch.assetAmount,
            batch.collateralAmount
        );
    }

    function cancel(bytes32 tradeId) external {
        require(!settled[tradeId], "already settled");
        cancelled[tradeId] = true;
        emit Cancelled(tradeId, msg.sender);
    }

    function _digest(SettlementBatch calldata b) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            "\x19\x01",
            _domainSeparator(),
            keccak256(abi.encode(
                b.tradeId, b.buyer, b.seller,
                b.asset, b.collateral,
                b.assetAmount, b.collateralAmount,
                b.deadline
            ))
        ));
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("Pool Protocol"),
            keccak256("1"),
            block.chainid,
            address(this)
        ));
    }

    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        require(sig.length == 65, "bad sig length");
        bytes32 r; bytes32 s; uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        return ecrecover(digest, v, r, s);
    }

    function _transferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "transfer failed");
    }
}