// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Owned} from "solmate/auth/Owned.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {LSSVMPair} from "./LSSVMPair.sol";
import {LSSVMRouter} from "./LSSVMRouter.sol";
import {LSSVMPairETH} from "./LSSVMPairETH.sol";
import {ICurve} from "./bonding-curves/ICurve.sol";
import {LSSVMPairERC20} from "./LSSVMPairERC20.sol";
import {LSSVMPairCloner} from "./lib/LSSVMPairCloner.sol";
import {ILSSVMPairFactoryLike} from "./ILSSVMPairFactoryLike.sol";

/**
 * Imports for AuthOracle (forked from manifold.xyz Royalty Registry)
 */
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/IAccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@manifoldxyz/libraries-solidity/contracts/access/IAdminControl.sol";
import "./royalty-auth/INiftyGateway.sol";
import "./royalty-auth/IFoundation.sol";
import "./royalty-auth/IDigitalax.sol";
import "./royalty-auth/IArtBlocks.sol";

contract LSSVMPairFactory is Owned, ILSSVMPairFactoryLike {
    using LSSVMPairCloner for address;
    using AddressUpgradeable for address;
    using SafeTransferLib for address payable;
    using SafeTransferLib for ERC20;

    uint256 internal constant MAX_PROTOCOL_FEE = 0.1e18; // 10%, must <= 1 - MAX_FEE

    LSSVMPairETH public immutable ethTemplate;
    LSSVMPairERC20 public immutable erc20Template;
    address payable public override protocolFeeRecipient;

    // Units are in base 1e18
    uint256 public override protocolFeeMultiplier;

    mapping(ICurve => bool) public bondingCurveAllowed;
    mapping(address => bool) public override callAllowed;
    mapping(address => address) public authorizedAgreement;
    mapping(address => Agreement) public bpsForPairInAgreement;

    struct RouterStatus {
        bool allowed;
        bool wasEverAllowed;
    }

    mapping(LSSVMRouter => RouterStatus) public override routerStatus;

    event NewPair(address poolAddress);
    event TokenDeposit(address poolAddress);
    event NFTDeposit(address poolAddress, uint256[] ids);
    event ProtocolFeeRecipientUpdate(address recipientAddress);
    event ProtocolFeeMultiplierUpdate(uint256 newMultiplier);
    event BondingCurveStatusUpdate(ICurve bondingCurve, bool isAllowed);
    event CallTargetStatusUpdate(address target, bool isAllowed);
    event RouterStatusUpdate(LSSVMRouter router, bool isAllowed);

    constructor(
        LSSVMPairETH _ethTemplate,
        LSSVMPairERC20 _erc20Template,
        address payable _protocolFeeRecipient,
        uint256 _protocolFeeMultiplier,
        address _owner
    ) Owned(_owner) {
        ethTemplate = _ethTemplate;
        erc20Template = _erc20Template;
        protocolFeeRecipient = _protocolFeeRecipient;
        require(_protocolFeeMultiplier <= MAX_PROTOCOL_FEE, "Fee too large");
        protocolFeeMultiplier = _protocolFeeMultiplier;
    }

    /**
     * External functions
     */

    /**
     * @notice Creates a pair contract using EIP-1167.
     *     @param _nft The NFT contract of the collection the pair trades
     *     @param _bondingCurve The bonding curve for the pair to price NFTs, must be whitelisted
     *     @param _assetRecipient The address that will receive the assets traders give during trades.
     *                           If set to address(0), assets will be sent to the pool address.
     *                           Not available to TRADE pools.
     *     @param _poolType TOKEN, NFT, or TRADE
     *     @param _delta The delta value used by the bonding curve. The meaning of delta depends
     *     on the specific curve.
     *     @param _fee The fee taken by the LP in each trade. Can only be non-zero if _poolType is Trade.
     *     @param _spotPrice The initial selling spot price
     *     @param _initialNFTIDs The list of IDs of NFTs to transfer from the sender to the pair
     *     @return pair The new pair
     */
    function createPairETH(
        IERC721 _nft,
        ICurve _bondingCurve,
        address payable _assetRecipient,
        LSSVMPair.PoolType _poolType,
        uint128 _delta,
        uint96 _fee,
        uint128 _spotPrice,
        uint256[] calldata _initialNFTIDs
    ) external payable returns (LSSVMPairETH pair) {
        require(
            bondingCurveAllowed[_bondingCurve],
            "Bonding curve not whitelisted"
        );

        pair = LSSVMPairETH(
            payable(
                address(ethTemplate).cloneETHPair(
                    this,
                    _bondingCurve,
                    _nft,
                    uint8(_poolType)
                )
            )
        );

        _initializePairETH(
            pair,
            _nft,
            _assetRecipient,
            _delta,
            _fee,
            _spotPrice,
            _initialNFTIDs
        );
        emit NewPair(address(pair));
    }

    /**
     * @notice Creates a pair contract using EIP-1167.
     *     @param _nft The NFT contract of the collection the pair trades
     *     @param _bondingCurve The bonding curve for the pair to price NFTs, must be whitelisted
     *     @param _assetRecipient The address that will receive the assets traders give during trades.
     *                             If set to address(0), assets will be sent to the pool address.
     *                             Not available to TRADE pools.
     *     @param _poolType TOKEN, NFT, or TRADE
     *     @param _delta The delta value used by the bonding curve. The meaning of delta depends
     *     on the specific curve.
     *     @param _fee The fee taken by the LP in each trade. Can only be non-zero if _poolType is Trade.
     *     @param _spotPrice The initial selling spot price, in ETH
     *     @param _initialNFTIDs The list of IDs of NFTs to transfer from the sender to the pair
     *     @param _initialTokenBalance The initial token balance sent from the sender to the new pair
     *     @return pair The new pair
     */
    struct CreateERC20PairParams {
        ERC20 token;
        IERC721 nft;
        ICurve bondingCurve;
        address payable assetRecipient;
        LSSVMPair.PoolType poolType;
        uint128 delta;
        uint96 fee;
        uint128 spotPrice;
        uint256[] initialNFTIDs;
        uint256 initialTokenBalance;
    }

    function createPairERC20(CreateERC20PairParams calldata params)
        external
        returns (LSSVMPairERC20 pair)
    {
        require(
            bondingCurveAllowed[params.bondingCurve],
            "Bonding curve not whitelisted"
        );

        pair = LSSVMPairERC20(
            payable(
                address(erc20Template).cloneERC20Pair(
                    this,
                    params.bondingCurve,
                    params.nft,
                    uint8(params.poolType),
                    params.token
                )
            )
        );

        _initializePairERC20(
            pair,
            params.token,
            params.nft,
            params.assetRecipient,
            params.delta,
            params.fee,
            params.spotPrice,
            params.initialNFTIDs,
            params.initialTokenBalance
        );
        emit NewPair(address(pair));
    }

    /**
     * @notice Checks if an address is a LSSVMPair. Uses the fact that the pairs are EIP-1167 minimal proxies.
     *     @param potentialPair The address to check
     *     @param variant The pair variant (Pair uses ETH or ERC20)
     *     @return True if the address is the specified pair variant, false otherwise
     */
    function isPair(address potentialPair, PairVariant variant)
        public
        view
        override
        returns (bool)
    {
        if (variant == PairVariant.ETH) {
            return
                LSSVMPairCloner.isETHPairClone(
                    address(this),
                    address(ethTemplate),
                    potentialPair
                );
        } else if (variant == PairVariant.ERC20) {
            return
                LSSVMPairCloner.isERC20PairClone(
                    address(this),
                    address(erc20Template),
                    potentialPair
                );
        } else {
            // invalid input
            return false;
        }
    }

    /**
     * @notice Checks if an address is an allowed auth for a token
     *   @param tokenAddress The token address to check
     *   @param proposedAuthAddress The auth address to check
     *   @return True if the proposedAuthAddress is a valid auth for the tokenAddress, false otherwise.
     */
    function authAllowedForToken(
        address tokenAddress,
        address proposedAuthAddress
    ) public view returns (bool) {
        // Check for admin interface
        if (
            ERC165Checker.supportsInterface(
                tokenAddress,
                type(IAdminControl).interfaceId
            ) && IAdminControl(tokenAddress).isAdmin(proposedAuthAddress)
        ) {
            return true;
        }
        // Check for owner
        try OwnableUpgradeable(tokenAddress).owner() returns (address owner) {
            if (owner == proposedAuthAddress) return true;

            if (owner.isContract()) {
                try OwnableUpgradeable(owner).owner() returns (
                    address passThroughOwner
                ) {
                    if (passThroughOwner == proposedAuthAddress) return true;
                } catch {}
            }
        } catch {}
        // Check for default OZ auth role
        try
            IAccessControlUpgradeable(tokenAddress).hasRole(
                0x00,
                proposedAuthAddress
            )
        returns (bool hasRole) {
            if (hasRole) return true;
        } catch {}
        // Nifty Gateway overrides
        try
            INiftyBuilderInstance(tokenAddress).niftyRegistryContract()
        returns (address niftyRegistry) {
            try
                INiftyRegistry(niftyRegistry).isValidNiftySender(
                    proposedAuthAddress
                )
            returns (bool valid) {
                return valid;
            } catch {}
        } catch {}
        // Foundation overrides
        try
            IFoundationTreasuryNode(tokenAddress).getFoundationTreasury()
        returns (address payable foundationTreasury) {
            try
                IFoundationTreasury(foundationTreasury).isAdmin(
                    proposedAuthAddress
                )
            returns (bool isAdmin) {
                return isAdmin;
            } catch {}
        } catch {}
        // DIGITALAX overrides
        try IDigitalax(tokenAddress).accessControls() returns (
            address externalAccessControls
        ) {
            try
                IDigitalaxAccessControls(externalAccessControls).hasAdminRole(
                    proposedAuthAddress
                )
            returns (bool hasRole) {
                if (hasRole) return true;
            } catch {}
        } catch {}
        // Art Blocks overrides
        try IArtBlocks(tokenAddress).admin() returns (address admin) {
            if (admin == proposedAuthAddress) return true;
        } catch {}
        return false;
    }

    /**
     * @notice Returns the Agreement for a pair if it is currently in an Agreement
     * @param pairAddress The address of the pair to look up
     * Returns whether or not the pair is in an Agreement, and what its bps should be (if valid)
     */
    function agreementForPair(address pairAddress)
        public
        view
        returns (bool isInAgreement, uint96 bps)
    {
        Agreement memory agreement = bpsForPairInAgreement[pairAddress];
        if (agreement.pairAddress == pairAddress) {
            isInAgreement = true;
            bps = agreement.bps;
        }
    }

    /**
     * @notice Allows receiving ETH in order to receive protocol fees
     */
    receive() external payable {}

    /**
     * Admin functions
     */

    /**
     * @notice Withdraws the ETH balance to the protocol fee recipient.
     *     Only callable by the owner.
     */
    function withdrawETHProtocolFees() external onlyOwner {
        protocolFeeRecipient.safeTransferETH(address(this).balance);
    }

    /**
     * @notice Withdraws ERC20 tokens to the protocol fee recipient. Only callable by the owner.
     *     @param token The token to transfer
     *     @param amount The amount of tokens to transfer
     */
    function withdrawERC20ProtocolFees(ERC20 token, uint256 amount)
        external
        onlyOwner
    {
        token.safeTransfer(protocolFeeRecipient, amount);
    }

    /**
     * @notice Changes the protocol fee recipient address. Only callable by the owner.
     *     @param _protocolFeeRecipient The new fee recipient
     */
    function changeProtocolFeeRecipient(address payable _protocolFeeRecipient)
        external
        onlyOwner
    {
        require(_protocolFeeRecipient != address(0), "0 address");
        protocolFeeRecipient = _protocolFeeRecipient;
        emit ProtocolFeeRecipientUpdate(_protocolFeeRecipient);
    }

    /**
     * @notice Changes the protocol fee multiplier. Only callable by the owner.
     *     @param _protocolFeeMultiplier The new fee multiplier, 18 decimals
     */
    function changeProtocolFeeMultiplier(uint256 _protocolFeeMultiplier)
        external
        onlyOwner
    {
        require(_protocolFeeMultiplier <= MAX_PROTOCOL_FEE, "Fee too large");
        protocolFeeMultiplier = _protocolFeeMultiplier;
        emit ProtocolFeeMultiplierUpdate(_protocolFeeMultiplier);
    }

    /**
     * @notice Sets the whitelist status of a bonding curve contract. Only callable by the owner.
     *     @param bondingCurve The bonding curve contract
     *     @param isAllowed True to whitelist, false to remove from whitelist
     */
    function setBondingCurveAllowed(ICurve bondingCurve, bool isAllowed)
        external
        onlyOwner
    {
        bondingCurveAllowed[bondingCurve] = isAllowed;
        emit BondingCurveStatusUpdate(bondingCurve, isAllowed);
    }

    /**
     * @notice Sets the whitelist status of a contract to be called arbitrarily by a pair.
     *     Only callable by the owner.
     *     @param target The target contract
     *     @param isAllowed True to whitelist, false to remove from whitelist
     */
    function setCallAllowed(address payable target, bool isAllowed)
        external
        onlyOwner
    {
        // ensure target is not / was not ever a router
        if (isAllowed) {
            require(
                !routerStatus[LSSVMRouter(target)].wasEverAllowed,
                "Can't call router"
            );
        }

        callAllowed[target] = isAllowed;
        emit CallTargetStatusUpdate(target, isAllowed);
    }

    /**
     * @notice Updates the router whitelist. Only callable by the owner.
     *     @param _router The router
     *     @param isAllowed True to whitelist, false to remove from whitelist
     */
    function setRouterAllowed(LSSVMRouter _router, bool isAllowed)
        external
        onlyOwner
    {
        // ensure target is not arbitrarily callable by pairs
        if (isAllowed) {
            require(!callAllowed[address(_router)], "Can't call router");
        }
        routerStatus[_router] = RouterStatus({
            allowed: isAllowed,
            wasEverAllowed: true
        });

        emit RouterStatusUpdate(_router, isAllowed);
    }

    /**
     * @notice Sets or removes an authorized overrider to set pool overrides on an owner's behalf
     *      @param agreement The address to add with Agreement logic
     *      @param collectionAddress The NFT project that the agreement can administer for
     *      @param isAllowed True to allow, false to revoke
     */
    function toggleAgreementForCollection(
        address agreement,
        address collectionAddress,
        bool isAllowed
    ) public {
        require(
            authAllowedForToken(collectionAddress, msg.sender),
            "Unauthorized caller"
        );
        if (isAllowed) {
            authorizedAgreement[agreement] = collectionAddress;
        } else {
            delete authorizedAgreement[agreement];
        }
    }

    /**
     * @notice Sets a separate bps override for a pool, only callable by authorized Agreements
     *    @param pairAddress The address of the pool to set a different bps for
     *    @param bps The bps override to set
     */
    function toggleBpsForPairInAgreement(
        address pairAddress,
        uint96 bps,
        bool isEnteringAgreement
    ) public {
      
        // Only pairs are valid targets
        require(
            isPair(pairAddress, PairVariant.ERC20) ||
                isPair(pairAddress, PairVariant.ETH),
            "Not pair"
        );

        // Only authorized Agreements for the pair's underlying NFT address can toggle the pair
        require(
            authorizedAgreement[msg.sender] ==
                address(LSSVMPair(pairAddress).nft()),
            "Unauthorized caller"
        );

        // Check if toggling on or off
        address eitherZeroOrPairAddress = address(0);
        if (isEnteringAgreement) {
            eitherZeroOrPairAddress = pairAddress;
        }

        bpsForPairInAgreement[pairAddress] = Agreement({
            bps: bps,
            pairAddress: eitherZeroOrPairAddress
        });
    }

    /**
     * Internal functions
     */

    function _initializePairETH(
        LSSVMPairETH _pair,
        IERC721 _nft,
        address payable _assetRecipient,
        uint128 _delta,
        uint96 _fee,
        uint128 _spotPrice,
        uint256[] calldata _initialNFTIDs
    ) internal {
        // initialize pair
        _pair.initialize(msg.sender, _assetRecipient, _delta, _fee, _spotPrice);

        // transfer initial ETH to pair
        payable(address(_pair)).safeTransferETH(msg.value);

        // transfer initial NFTs from sender to pair
        uint256 numNFTs = _initialNFTIDs.length;
        for (uint256 i; i < numNFTs; ) {
            _nft.transferFrom(msg.sender, address(_pair), _initialNFTIDs[i]);

            unchecked {
                ++i;
            }
        }
    }

    function _initializePairERC20(
        LSSVMPairERC20 _pair,
        ERC20 _token,
        IERC721 _nft,
        address payable _assetRecipient,
        uint128 _delta,
        uint96 _fee,
        uint128 _spotPrice,
        uint256[] calldata _initialNFTIDs,
        uint256 _initialTokenBalance
    ) internal {
        // initialize pair
        _pair.initialize(msg.sender, _assetRecipient, _delta, _fee, _spotPrice);

        // transfer initial tokens to pair (if > 0)
        if (_initialTokenBalance > 0) {
            _token.safeTransferFrom(
                msg.sender,
                address(_pair),
                _initialTokenBalance
            );
        }

        // transfer initial NFTs from sender to pair
        uint256 numNFTs = _initialNFTIDs.length;
        for (uint256 i; i < numNFTs; ) {
            _nft.transferFrom(msg.sender, address(_pair), _initialNFTIDs[i]);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Used to deposit NFTs into a pair after creation and emit an event for indexing (if recipient is indeed a pair)
     */
    function depositNFTs(
        IERC721 _nft,
        uint256[] calldata ids,
        address recipient
    ) external {
        // transfer NFTs from caller to recipient
        uint256 numNFTs = ids.length;
        for (uint256 i; i < numNFTs; ) {
            _nft.transferFrom(msg.sender, recipient, ids[i]);

            unchecked {
                ++i;
            }
        }
        if (
            isPair(recipient, PairVariant.ETH) ||
            isPair(recipient, PairVariant.ERC20)
        ) {
            emit NFTDeposit(recipient, ids);
        }
    }

    /**
     * @dev Used to deposit ERC20s into a pair after creation and emit an event for indexing (if recipient is indeed an ERC20 pair and the token matches)
     */
    function depositERC20(
        ERC20 token,
        address recipient,
        uint256 amount
    ) external {
        token.safeTransferFrom(msg.sender, recipient, amount);
        if (
            isPair(recipient, PairVariant.ERC20) &&
            token == LSSVMPairERC20(recipient).token()
        ) {
            emit TokenDeposit(recipient);
        }
    }
}
