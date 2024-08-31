// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

struct NFTListing {
    uint256 price;
    address seller;
}

struct NFTMetadata {
    uint256 mintLimit;
    uint256 currentMintCount;
    mapping(address => uint256) walletMints;
}

contract NFTMarket is ERC721URIStorage, Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIDs;
    mapping(uint256 => NFTListing) private _listings;
    mapping(uint256 => address) private _creators;
    mapping(uint256 => NFTMetadata) private _nftMetadata;

    uint256 private _royaltyPercentage;
    uint256 public maxMintsPerWallet;

    event NFTCreated(uint256 indexed tokenID, address indexed creator, string tokenURI, uint256 mintLimit);
    event NFTListed(uint256 indexed tokenID, address indexed seller, uint256 price);
    event NFTPurchased(uint256 indexed tokenID, address indexed buyer, address indexed seller, uint256 price);
    event ListingCancelled(uint256 indexed tokenID, address indexed seller);

    constructor(uint256 royaltyPercentage, uint256 maxMints) ERC721("Abdou's NFTs", "ANFT") {
        require(royaltyPercentage <= 100, "NFTMarket: royalty percentage cannot be more than 100");
        require(maxMints > 0, "NFTMarket: max mints per wallet must be greater than 0");
        _royaltyPercentage = royaltyPercentage;
        maxMintsPerWallet = maxMints;
    }

    modifier onlySeller(uint256 tokenID) {
        require(_listings[tokenID].seller == msg.sender, "NFTMarket: caller is not the seller");
        _;
    }

    modifier isListed(uint256 tokenID) {
        require(_listings[tokenID].price > 0, "NFTMarket: not listed");
        _;
    }

    function createNFT(string calldata tokenURI, uint256 mintLimit) public {
        _tokenIDs.increment();
        uint256 currentID = _tokenIDs.current();
        _safeMint(msg.sender, currentID);
        _setTokenURI(currentID, tokenURI);

        _creators[currentID] = msg.sender;
        _nftMetadata[currentID].mintLimit = mintLimit;

        emit NFTCreated(currentID, msg.sender, tokenURI, mintLimit);
    }

    function mintDuplicate(uint256 originalTokenID, string calldata tokenURI) public {
        NFTMetadata storage metadata = _nftMetadata[originalTokenID];
        
        require(metadata.mintLimit > 0, "NFTMarket: this NFT is not set up for duplication");
        require(metadata.currentMintCount < metadata.mintLimit, "NFTMarket: mint limit reached for this NFT");
        require(metadata.walletMints[msg.sender] < maxMintsPerWallet, "NFTMarket: you cannot mint this NFT anymore");

        _tokenIDs.increment();
        uint256 newTokenID = _tokenIDs.current();
        _safeMint(msg.sender, newTokenID);
        _setTokenURI(newTokenID, tokenURI);

        metadata.currentMintCount++;
        metadata.walletMints[msg.sender]++;

        emit NFTCreated(newTokenID, msg.sender, tokenURI, metadata.mintLimit - metadata.currentMintCount);
    }

    function listNFT(uint256 tokenID, uint256 price) public onlySeller(tokenID) {
        require(price > 0, "NFTMarket: price must be greater than 0");
        _transfer(msg.sender, address(this), tokenID);
        _listings[tokenID] = NFTListing(price, msg.sender);
        emit NFTListed(tokenID, msg.sender, price);
    }

    function buyNFT(uint256 tokenID) public payable isListed(tokenID) nonReentrant {
        NFTListing memory listing = _listings[tokenID];
        require(msg.value == listing.price, "NFTMarket: incorrect price");

        address creator = _creators[tokenID];
        uint256 royalty = listing.price * _royaltyPercentage / 100;
        uint256 sellerAmount = listing.price - royalty;

        payable(creator).transfer(royalty);
        payable(listing.seller).transfer(sellerAmount);

        _transfer(address(this), msg.sender, tokenID);
        clearListing(tokenID);
        emit NFTPurchased(tokenID, msg.sender, listing.seller, listing.price);
    }

    function cancelListing(uint256 tokenID) public onlySeller(tokenID) isListed(tokenID) {
        _transfer(address(this), msg.sender, tokenID);
        clearListing(tokenID);
        emit ListingCancelled(tokenID, msg.sender);
    }

    function updateListing(uint256 tokenID, uint256 newPrice) public onlySeller(tokenID) isListed(tokenID) {
        require(newPrice > 0, "NFTMarket: price must be greater than 0");
        _listings[tokenID].price = newPrice;
        emit NFTListed(tokenID, msg.sender, newPrice);
    }

    function withdrawFunds() public onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "NFTMarket: balance is zero");
        payable(msg.sender).transfer(balance);
    }

    function clearListing(uint256 tokenID) private {
        delete _listings[tokenID];
    }

    receive() external payable {
        emit FundsReceived(msg.sender, msg.value);
    }

    fallback() external payable {
        emit FallbackCalled(msg.sender, msg.value, msg.data);
    }

    event FundsReceived(address from, uint256 amount);
    event FallbackCalled(address from, uint256 value, bytes data);
}
