// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentIDRegistry
/// @notice Minimal read interface for the SPACE ID Agent ID registry
///         (ERC-721, non-transferable) on BNB Smart Chain.
/// @dev The production registry lives at
///      0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F on BSC mainnet.
///      AgentBoard only needs one question answered: "does this address
///      currently hold at least one Agent ID?" That is `balanceOf > 0`.
interface IAgentIDRegistry {
    /// @notice Returns how many Agent IDs `account` currently holds.
    /// @param account The address to check.
    /// @return The number of Agent ID tokens held (0 means "not a holder").
    function balanceOf(address account) external view returns (uint256);
}
