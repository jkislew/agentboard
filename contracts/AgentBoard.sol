// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentIDRegistry} from "./interfaces/IAgentIDRegistry.sol";

/// @title AgentBoard
/// @notice An Agent ID-gated service registry and attestation board for the
///         agent economy, built on BNB Smart Chain.
/// @dev How Agent ID is used — it is the write-permission system of this
///      contract, not a cosmetic login badge:
///
///      1. Every state-changing entry point that creates content
///         (`registerService`, `attest`) reverts unless the caller currently
///         holds at least one Agent ID in the SPACE ID Agent ID registry
///         (`balanceOf(caller) > 0`).
///      2. A service listing is only *active* while its owner currently
///         holds an Agent ID. Activity is derived from the registry at read
///         time and at attestation time, never cached, so reputation can
///         never outlive the identity that earned it.
///      3. Attestations (peer ratings) can only be written by Agent ID
///         holders, which makes review spam expensive by construction:
///         Agent IDs are non-transferable, one-per-person identities.
///
///      Permissions and safety properties, stated plainly:
///      - This contract has NO owner, NO admin role, NO pause switch, NO
///        upgrade path, and NO privileged function of any kind. The only
///        configuration is the Agent ID registry address, fixed forever as
///        an immutable at deployment.
///      - This contract never receives, holds, escrows, or transfers funds
///        or tokens, and never asks any user for a token approval. All
///        writes are data-only records the caller signs for themselves.
///      - Anyone may remove their own listing or their own attestation,
///        including after they stop holding an Agent ID.
contract AgentBoard {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    /// @notice A service listing published by an Agent ID holder.
    /// @param name Short display name of the agent / service.
    /// @param category Free-form category label (e.g. "trading", "research").
    /// @param infoURI URI pointing at a description or endpoint document
    ///        (https or ipfs). Content lives off-chain; the board stores the
    ///        pointer only.
    /// @param createdAt Block timestamp of first registration.
    /// @param updatedAt Block timestamp of the last update.
    /// @param exists Whether the listing currently exists. A listing can
    ///        exist but be *inactive* — see `isActive`.
    struct Listing {
        string name;
        string category;
        string infoURI;
        uint64 createdAt;
        uint64 updatedAt;
        bool exists;
    }

    /// @notice A peer attestation: one holder's rating of another's listing.
    /// @param rating Score from 1 (worst) to 5 (best).
    /// @param commentURI URI pointing at the review text (off-chain).
    /// @param updatedAt Block timestamp of the last write.
    /// @param exists Whether this attestation currently exists.
    struct Attestation {
        uint8 rating;
        string commentURI;
        uint64 updatedAt;
        bool exists;
    }

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    /// @notice The caller does not currently hold an Agent ID.
    error NotAgentIDHolder();
    /// @notice The target listing does not exist or its owner no longer
    ///         holds an Agent ID.
    error ListingNotActive();
    /// @notice An agent tried to attest its own listing.
    error CannotAttestSelf();
    /// @notice Rating outside the allowed 1..5 range.
    error InvalidRating();
    /// @notice Listing name empty or longer than MAX_NAME_LENGTH bytes.
    error InvalidName();
    /// @notice Category empty or longer than MAX_CATEGORY_LENGTH bytes.
    error InvalidCategory();
    /// @notice infoURI longer than MAX_URI_LENGTH bytes.
    error InfoURITooLong();
    /// @notice commentURI longer than MAX_URI_LENGTH bytes.
    error CommentURITooLong();
    /// @notice Removal attempted for a listing that does not exist.
    error NoListing();
    /// @notice Removal attempted for an attestation that does not exist.
    error NoAttestation();
    /// @notice The registry address passed to the constructor was zero.
    error ZeroRegistry();

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    /// @notice Emitted when an address registers its first listing.
    event ServiceRegistered(address indexed owner, string name, string category);
    /// @notice Emitted when an existing listing is updated by re-registering.
    event ServiceUpdated(address indexed owner, string name, string category);
    /// @notice Emitted when a listing is removed by its owner.
    event ServiceRemoved(address indexed owner);
    /// @notice Emitted when an attestation is created or updated.
    event AttestationRecorded(address indexed listingOwner, address indexed reviewer, uint8 rating);
    /// @notice Emitted when a reviewer removes their own attestation.
    event AttestationRemoved(address indexed listingOwner, address indexed reviewer);

    // ------------------------------------------------------------------
    // Constants and state
    // ------------------------------------------------------------------

    /// @notice Maximum byte length of a listing name.
    uint256 public constant MAX_NAME_LENGTH = 64;
    /// @notice Maximum byte length of a category label.
    uint256 public constant MAX_CATEGORY_LENGTH = 32;
    /// @notice Maximum byte length of any stored URI.
    uint256 public constant MAX_URI_LENGTH = 256;

    /// @notice The Agent ID registry this board gates on. Immutable: set
    ///         once in the constructor and unchangeable forever.
    IAgentIDRegistry public immutable agentIDRegistry;

    /// @dev Listings by owner address.
    mapping(address => Listing) private _listings;
    /// @dev Every address that has ever registered, in registration order.
    ///      Entries are never removed from this array; use `isActive` /
    ///      `Listing.exists` to filter. This keeps enumeration simple and
    ///      gas-predictable.
    address[] private _listingOwners;
    /// @dev Whether an address has ever registered (guards the enumeration
    ///      array against duplicates across remove → re-register cycles).
    mapping(address => bool) private _everRegistered;

    /// @dev Attestations by [listingOwner][reviewer].
    mapping(address => mapping(address => Attestation)) private _attestations;
    /// @dev Reviewers per listing owner, in first-attestation order.
    mapping(address => address[]) private _reviewersOf;
    /// @dev Running aggregates per listing owner for cheap rating reads.
    mapping(address => uint256) private _attestationCount;
    mapping(address => uint256) private _ratingSum;

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    /// @notice Deploys the board bound to an Agent ID registry.
    /// @param registry Address of the SPACE ID Agent ID registry
    ///        (BSC mainnet: 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F).
    constructor(address registry) {
        if (registry == address(0)) revert ZeroRegistry();
        agentIDRegistry = IAgentIDRegistry(registry);
    }

    // ------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------

    /// @dev The Agent ID gate: the single check that powers every write.
    modifier onlyAgentIDHolder() {
        if (agentIDRegistry.balanceOf(msg.sender) == 0) revert NotAgentIDHolder();
        _;
    }

    // ------------------------------------------------------------------
    // Writes — listings
    // ------------------------------------------------------------------

    /// @notice Register your service listing, or update it if you already
    ///         have one. One listing per address, bound to the caller.
    /// @dev Requires the caller to currently hold an Agent ID. Re-registering
    ///      is an update: it refreshes name/category/infoURI and `updatedAt`,
    ///      keeps the original `createdAt`, and does not duplicate the owner
    ///      in the enumeration array.
    /// @param name Display name (1..64 bytes).
    /// @param category Category label (1..32 bytes).
    /// @param infoURI Description / endpoint URI (0..256 bytes).
    function registerService(string calldata name, string calldata category, string calldata infoURI)
        external
        onlyAgentIDHolder
    {
        uint256 nameLen = bytes(name).length;
        if (nameLen == 0 || nameLen > MAX_NAME_LENGTH) revert InvalidName();
        uint256 categoryLen = bytes(category).length;
        if (categoryLen == 0 || categoryLen > MAX_CATEGORY_LENGTH) revert InvalidCategory();
        if (bytes(infoURI).length > MAX_URI_LENGTH) revert InfoURITooLong();

        Listing storage listing = _listings[msg.sender];
        bool isNewListing = !listing.exists;
        bool isFirstEver = !_everRegistered[msg.sender];

        listing.name = name;
        listing.category = category;
        listing.infoURI = infoURI;
        if (isNewListing) {
            listing.createdAt = uint64(block.timestamp);
        }
        listing.updatedAt = uint64(block.timestamp);
        listing.exists = true;

        if (isFirstEver) {
            _everRegistered[msg.sender] = true;
            _listingOwners.push(msg.sender);
        }
        if (isNewListing) {
            emit ServiceRegistered(msg.sender, name, category);
        } else {
            emit ServiceUpdated(msg.sender, name, category);
        }
    }

    /// @notice Remove your own listing. Does NOT require currently holding
    ///         an Agent ID, so nobody is locked into a listing they want
    ///         gone. Attestations already received are kept (they are other
    ///         people's records) but the listing stops being active, so no
    ///         new attestations can be added.
    function removeService() external {
        Listing storage listing = _listings[msg.sender];
        if (!listing.exists) revert NoListing();
        delete _listings[msg.sender];
        // `_everRegistered` intentionally stays true: the owner remains in
        // the enumeration array exactly once, and a later re-registration
        // creates a fresh listing without duplicating the array entry.
        emit ServiceRemoved(msg.sender);
    }

    // ------------------------------------------------------------------
    // Writes — attestations
    // ------------------------------------------------------------------

    /// @notice Record or update your attestation of another agent's listing.
    /// @dev Requires the caller to currently hold an Agent ID, the target
    ///      listing to be active (exists AND its owner currently holds an
    ///      Agent ID), and the target to be someone else. One attestation
    ///      per (reviewer, listing) pair; calling again updates the rating
    ///      and comment URI, and the aggregate sum is adjusted by the delta.
    /// @param listingOwner Owner of the listing being rated.
    /// @param rating Score 1..5.
    /// @param commentURI URI of the review text (0..256 bytes).
    function attest(address listingOwner, uint8 rating, string calldata commentURI)
        external
        onlyAgentIDHolder
    {
        if (listingOwner == msg.sender) revert CannotAttestSelf();
        if (rating < 1 || rating > 5) revert InvalidRating();
        if (bytes(commentURI).length > MAX_URI_LENGTH) revert CommentURITooLong();
        if (!isActive(listingOwner)) revert ListingNotActive();

        Attestation storage att = _attestations[listingOwner][msg.sender];
        if (att.exists) {
            _ratingSum[listingOwner] = _ratingSum[listingOwner] - att.rating + rating;
        } else {
            att.exists = true;
            _reviewersOf[listingOwner].push(msg.sender);
            _attestationCount[listingOwner] += 1;
            _ratingSum[listingOwner] += rating;
        }
        att.rating = rating;
        att.commentURI = commentURI;
        att.updatedAt = uint64(block.timestamp);

        emit AttestationRecorded(listingOwner, msg.sender, rating);
    }

    /// @notice Remove your own attestation of a listing. Does NOT require
    ///         currently holding an Agent ID.
    /// @param listingOwner Owner of the listing you attested.
    function removeAttestation(address listingOwner) external {
        Attestation storage att = _attestations[listingOwner][msg.sender];
        if (!att.exists) revert NoAttestation();
        _ratingSum[listingOwner] -= att.rating;
        _attestationCount[listingOwner] -= 1;
        delete _attestations[listingOwner][msg.sender];
        // The reviewer stays in `_reviewersOf` (append-only enumeration);
        // readers filter on `Attestation.exists`.
        emit AttestationRemoved(listingOwner, msg.sender);
    }

    // ------------------------------------------------------------------
    // Reads — open to everyone
    // ------------------------------------------------------------------

    /// @notice Whether `account` currently holds at least one Agent ID.
    function isAgentIDHolder(address account) public view returns (bool) {
        return agentIDRegistry.balanceOf(account) > 0;
    }

    /// @notice Whether `owner`'s listing is active: it exists AND the owner
    ///         currently holds an Agent ID. This liveness rule is evaluated
    ///         fresh from the registry on every call.
    function isActive(address owner) public view returns (bool) {
        return _listings[owner].exists && isAgentIDHolder(owner);
    }

    /// @notice Full listing record for `owner` plus its live activity flag.
    function getListing(address owner)
        external
        view
        returns (
            string memory name,
            string memory category,
            string memory infoURI,
            uint64 createdAt,
            uint64 updatedAt,
            bool exists,
            bool active
        )
    {
        Listing storage listing = _listings[owner];
        return (
            listing.name,
            listing.category,
            listing.infoURI,
            listing.createdAt,
            listing.updatedAt,
            listing.exists,
            isActive(owner)
        );
    }

    /// @notice Every address that has ever registered a listing, in order.
    ///         Filter with `getListing` / `isActive` for current state.
    function listingOwners() external view returns (address[] memory) {
        return _listingOwners;
    }

    /// @notice How many addresses have ever registered a listing.
    function listingOwnerCount() external view returns (uint256) {
        return _listingOwners.length;
    }

    /// @notice One attestation record: `reviewer`'s rating of `listingOwner`.
    function getAttestation(address listingOwner, address reviewer)
        external
        view
        returns (uint8 rating, string memory commentURI, uint64 updatedAt, bool exists)
    {
        Attestation storage att = _attestations[listingOwner][reviewer];
        return (att.rating, att.commentURI, att.updatedAt, att.exists);
    }

    /// @notice Every address that has ever attested `listingOwner`, in
    ///         first-attestation order. Filter with `getAttestation` —
    ///         removed attestations have `exists == false`.
    function reviewersOf(address listingOwner) external view returns (address[] memory) {
        return _reviewersOf[listingOwner];
    }

    /// @notice Aggregate rating stats for a listing: number of live
    ///         attestations, sum of their ratings, and the average rating
    ///         multiplied by 100 (e.g. 450 means 4.50). Average is 0 when
    ///         there are no attestations.
    function attestationStats(address listingOwner)
        external
        view
        returns (uint256 count, uint256 ratingSum, uint256 averageRatingX100)
    {
        count = _attestationCount[listingOwner];
        ratingSum = _ratingSum[listingOwner];
        averageRatingX100 = count == 0 ? 0 : (ratingSum * 100) / count;
    }
}
