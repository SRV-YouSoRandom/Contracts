// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

struct NFTListing {
    uint256 price;
    uint256 lastUpdateTime;
    address seller;
}

contract NFTMarket is 
    Initializable, 
    ERC721URIStorageUpgradeable, 
    OwnableUpgradeable, 
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using CountersUpgradeable for CountersUpgradeable.Counter;
    CountersUpgradeable.Counter private _tokenIDs;
    
    mapping(uint256 => NFTListing) private _listings;
    mapping(uint256 => address) private _creators;
    
    mapping(uint256 => uint256) private _mintLimits;
    mapping(uint256 => uint256) private _currentMintCounts;
    mapping(bytes32 => uint256) private _walletMints;

    uint256 private _royaltyPercentage;
    uint256 public maxMintsPerWallet;
    uint256 public constant PRICE_UPDATE_COOLDOWN = 1 days;

    event NFTCreated(uint256 indexed tokenID, address indexed creator, string tokenURI, uint256 mintLimit);
    event NFTListed(uint256 indexed tokenID, address indexed seller, uint256 price);
    event NFTPurchased(uint256 indexed tokenID, address indexed buyer, address indexed seller, uint256 price);
    event ListingCancelled(uint256 indexed tokenID, address indexed seller);
    event FundsReceived(address from, uint256 amount);
    event FallbackCalled(address from, uint256 value, bytes data);

    function initialize(
        string memory name, 
        string memory symbol, 
        uint256 royaltyPercentage, 
        uint256 maxMints
    ) public initializer {
        __ERC721_init(name, symbol);
        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        require(royaltyPercentage <= 100, "NFTMarket: royalty percentage cannot be more than 100");
        require(maxMints > 0, "NFTMarket: max mints per wallet must be greater than 0");
        _royaltyPercentage = royaltyPercentage;
        maxMintsPerWallet = maxMints;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    modifier onlySeller(uint256 tokenID) {
        require(_listings[tokenID].seller == msg.sender, "NFTMarket: caller is not the seller");
        _;
    }

    modifier isListed(uint256 tokenID) {
        require(_listings[tokenID].price > 0, "NFTMarket: not listed");
        _;
    }

    function getWalletMintKey(uint256 tokenId, address wallet) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenId, wallet));
    }

    function createNFT(string calldata tokenURI, uint256 mintLimit) external whenNotPaused {
        require(isValidURI(tokenURI), "NFTMarket: Invalid token URI");
        _tokenIDs.increment();
        uint256 currentID = _tokenIDs.current();
        _safeMint(msg.sender, currentID);
        _setTokenURI(currentID, tokenURI);

        _creators[currentID] = msg.sender;
        _mintLimits[currentID] = mintLimit;

        emit NFTCreated(currentID, msg.sender, tokenURI, mintLimit);
    }

    function mintDuplicate(uint256 originalTokenID, string calldata tokenURI) external whenNotPaused {
        require(isValidURI(tokenURI), "NFTMarket: Invalid token URI");
        require(_mintLimits[originalTokenID] > 0, "NFTMarket: this NFT is not set up for duplication");
        require(_currentMintCounts[originalTokenID] < _mintLimits[originalTokenID], "NFTMarket: mint limit reached for this NFT");
        
        bytes32 mintKey = getWalletMintKey(originalTokenID, msg.sender);
        require(_walletMints[mintKey] < maxMintsPerWallet, "NFTMarket: you cannot mint this NFT anymore");

        _tokenIDs.increment();
        uint256 newTokenID = _tokenIDs.current();
        _safeMint(msg.sender, newTokenID);
        _setTokenURI(newTokenID, tokenURI);

        _currentMintCounts[originalTokenID]++;
        _walletMints[mintKey]++;

        emit NFTCreated(newTokenID, msg.sender, tokenURI, _mintLimits[originalTokenID] - _currentMintCounts[originalTokenID]);
    }

    function listNFT(uint256 tokenID, uint256 price) external whenNotPaused {
        require(ownerOf(tokenID) == msg.sender, "NFTMarket: caller is not the owner");
        require(price > 0, "NFTMarket: price must be greater than 0");
        _transfer(msg.sender, address(this), tokenID);
        _listings[tokenID] = NFTListing(price, block.timestamp, msg.sender);
        emit NFTListed(tokenID, msg.sender, price);
    }

    function buyNFT(uint256 tokenID) external payable whenNotPaused isListed(tokenID) nonReentrant {
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

    function cancelListing(uint256 tokenID) external whenNotPaused onlySeller(tokenID) isListed(tokenID) {
        _transfer(address(this), msg.sender, tokenID);
        clearListing(tokenID);
        emit ListingCancelled(tokenID, msg.sender);
    }

    function updateListing(uint256 tokenID, uint256 newPrice) external whenNotPaused onlySeller(tokenID) isListed(tokenID) {
        require(newPrice > 0, "NFTMarket: price must be greater than 0");
        NFTListing storage listing = _listings[tokenID];
        require(block.timestamp >= listing.lastUpdateTime + PRICE_UPDATE_COOLDOWN, "NFTMarket: price update cooldown not elapsed");
        listing.price = newPrice;
        listing.lastUpdateTime = block.timestamp;
        emit NFTListed(tokenID, msg.sender, newPrice);
    }

    function withdrawFunds() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "NFTMarket: balance is zero");
        payable(msg.sender).transfer(balance);
    }

    function clearListing(uint256 tokenID) private {
        delete _listings[tokenID];
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function isValidURI(string calldata uri) external pure returns (bool) {
        bytes calldata uriBytes = bytes(uri);
        if (uriBytes.length == 0 || uriBytes.length > 2048) return false;
        return (uriBytes[0] == 0x68 && uriBytes[1] == 0x74 && uriBytes[2] == 0x74 && uriBytes[3] == 0x70); // 'http'
    }

    function batchMintNFTs(string[] calldata tokenURIs, uint256[] calldata mintLimits) external whenNotPaused {
        require(tokenURIs.length == mintLimits.length, "NFTMarket: arrays length mismatch");
        for (uint i = 0; i < tokenURIs.length; i++) {
            require(isValidURI(tokenURIs[i]), "NFTMarket: Invalid token URI");
            _tokenIDs.increment();
            uint256 currentID = _tokenIDs.current();
            _safeMint(msg.sender, currentID);
            _setTokenURI(currentID, tokenURIs[i]);
            _creators[currentID] = msg.sender;
            _mintLimits[currentID] = mintLimits[i];
            emit NFTCreated(currentID, msg.sender, tokenURIs[i], mintLimits[i]);
        }
    }

    receive() external payable {
        emit FundsReceived(msg.sender, msg.value);
    }

    fallback() external payable {
        emit FallbackCalled(msg.sender, msg.value, msg.data);
    }
}
