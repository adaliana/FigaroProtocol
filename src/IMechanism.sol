// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMechanism {
    struct AddSrpPayload {
        uint256 processId;
        address seller;
        uint256 amount;
        address token;
        uint256 totalProcessValue;
        uint256 deadline;
        uint256 nonce;
        bytes metadata; // optional provenance/URI
    }

    /// Submit multiple signed SRP payloads to a target Figaro contract
    /// Implementations are relayers/adapters that aggregate off-chain-signed payloads
    /// and call Figaro's signed entrypoints.
    function submitSrpsToFigaro(
        address figaro,
        AddSrpPayload[] calldata payloads,
        bytes[] calldata sellerSigs,
        bytes[] calldata erc2612Permits
    ) external;
}
