// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ERC-165 Interface
interface ERC165 {
    function supportsInterface(bytes4 interfaceID) external view returns (bool);
}

/// @title ERC-721 Non-Fungible Token Implementation
interface ERC721 is ERC165 {
    event Transfer(address indexed _from, address indexed _to, uint256 indexed _tokenId);
    event Approval(address indexed _owner, address indexed _approved, uint256 indexed _tokenId);
    event ApprovalForAll(address indexed _owner, address indexed _operator, bool _approved);

    function balanceOf(address _owner) external view returns (uint256);
    function ownerOf(uint256 _tokenId) external view returns (address);
    function safeTransferFrom(address _from, address _to, uint256 _tokenId, bytes memory data) external payable;
    function safeTransferFrom(address _from, address _to, uint256 _tokenId) external payable;
    function transferFrom(address _from, address _to, uint256 _tokenId) external payable;
    function approve(address _approved, uint256 _tokenId) external payable;
    function setApprovalForAll(address _operator, bool _approved) external;
    function getApproved(uint256 _tokenId) external view returns (address);
    function isApprovedForAll(address _owner, address _operator) external view returns (bool);
}

/// @title ERC-2981 Interface for Royalties
interface ERC2981 {
    function royaltyInfo(uint256 _tokenId, uint256 _salePrice) external view returns (address receiver, uint256 royaltyAmount);
}

contract MyNFT is ERC721, ERC2981 {
    string private _name;
    string private _symbol;
    string private _baseURI;

    uint256 private _totalSupply;
    uint256 private _maxSupply;
    address private _contractOwner;
    bool private _paused;
    bool private _allowMultipleMints;
    uint256 private _mintLimit;

    mapping(uint256 => TokenOwnership) private _owners;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping(uint256 => RoyaltyInfo) private _royalties;
    mapping(address => uint256) private _mintCount;

    struct TokenOwnership {
        address owner;
        address approved;
        bool exists;
    }

    struct RoyaltyInfo {
        address receiver;
        uint256 royaltyFraction;
    }

    modifier onlyOwner() {
        require(msg.sender == _contractOwner, "Not the contract owner");
        _;
    }

    modifier whenNotPaused() {
        require(!_paused, "Contract is paused");
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        string memory baseURI_,
        uint256 maxSupply_,
        bool allowMultipleMints_,
        uint256 mintLimit_
    ) {
        _name = name_;
        _symbol = symbol_;
        _baseURI = baseURI_;
        _contractOwner = msg.sender;
        _paused = false;
        _maxSupply = maxSupply_;
        _allowMultipleMints = allowMultipleMints_;
        _mintLimit = mintLimit_;
    }

    function supportsInterface(bytes4 interfaceID) public pure override returns (bool) {
        return interfaceID == type(ERC721).interfaceId ||
               interfaceID == type(ERC2981).interfaceId ||
               interfaceID == type(ERC165).interfaceId;
    }

    function balanceOf(address _owner) external view override returns (uint256) {
        require(_owner != address(0), "Zero address is not a valid owner");
        return _balances[_owner];
    }

    function ownerOf(uint256 _tokenId) external view override returns (address) {
        require(_owners[_tokenId].exists, "Token does not exist");
        return _owners[_tokenId].owner;
    }

    function approve(address _approved, uint256 _tokenId) external payable override whenNotPaused {
        address owner = _owners[_tokenId].owner;
        require(msg.sender == owner || isApprovedForAll(owner, msg.sender), "Not authorized to approve");
        _owners[_tokenId].approved = _approved;
        emit Approval(owner, _approved, _tokenId);
    }

    function setApprovalForAll(address _operator, bool _approved) external override whenNotPaused {
        _operatorApprovals[msg.sender][_operator] = _approved;
        emit ApprovalForAll(msg.sender, _operator, _approved);
    }

    function getApproved(uint256 _tokenId) external view override returns (address) {
        require(_owners[_tokenId].exists, "Token does not exist");
        return _owners[_tokenId].approved;
    }

    function isApprovedForAll(address _owner, address _operator) public view override returns (bool) {
        return _operatorApprovals[_owner][_operator];
    }

    function safeTransferFrom(address _from, address _to, uint256 _tokenId, bytes memory data) public payable override whenNotPaused {
        _transfer(_from, _to, _tokenId);
        // Need handle `data` if `_to` is a contract
    }

    function safeTransferFrom(address _from, address _to, uint256 _tokenId) public payable override whenNotPaused {
        safeTransferFrom(_from, _to, _tokenId, "");
    }

    function transferFrom(address _from, address _to, uint256 _tokenId) external payable override whenNotPaused {
        _transfer(_from, _to, _tokenId);
    }

    function _transfer(address _from, address _to, uint256 _tokenId) internal {
        require(_owners[_tokenId].exists, "Token does not exist");
        require(_owners[_tokenId].owner == _from, "Transfer from incorrect owner");
        require(_to != address(0), "Transfer to zero address");

        // Clear approvals from the previous owner
        _owners[_tokenId].approved = address(0);

        _balances[_from] -= 1;
        _balances[_to] += 1;

        // Transfer ownership
        _owners[_tokenId].owner = _to;

        emit Transfer(_from, _to, _tokenId);
    }

    function mint(address _to, uint256 mintAmount) external onlyOwner whenNotPaused {
        require(mintAmount > 0, "Must mint at least one token");
        require(_totalSupply + mintAmount <= _maxSupply, "Max supply reached");

        if (_allowMultipleMints) {
            require(_mintCount[_to] + mintAmount <= _mintLimit, "Mint limit reached for this address");
        } else {
            require(_balances[_to] == 0, "Address already owns a token");
            require(mintAmount == 1, "Cannot mint more than one token per address");
        }

        for (uint256 i = 0; i < mintAmount; i++) {
            uint256 tokenId = _totalSupply + 1;
            _balances[_to] += 1;
            _owners[tokenId] = TokenOwnership({owner: _to, approved: address(0), exists: true});
            _mintCount[_to] += 1;
            _totalSupply += 1;

            emit Transfer(address(0), _to, tokenId);
        }
    }

    function burn(uint256 _tokenId) external whenNotPaused {
        require(_owners[_tokenId].exists, "Token does not exist");
        address owner = _owners[_tokenId].owner;
        require(msg.sender == owner || isApprovedForAll(owner, msg.sender), "Not authorized to burn");

        // Clear approvals
        _owners[_tokenId].approved = address(0);

        _balances[owner] -= 1;

        // Remove token
        delete _owners[_tokenId];
        _mintCount[owner] -= 1;

        emit Transfer(owner, address(0), _tokenId);
    }

    function setBaseURI(string memory baseURI_) external onlyOwner {
        _baseURI = baseURI_;
    }

    function baseURI() external view returns (string memory) {
        return _baseURI;
    }

    function royaltyInfo(uint256 _tokenId, uint256 _salePrice) external view override returns (address receiver, uint256 royaltyAmount) {
        RoyaltyInfo memory royalty = _royalties[_tokenId];
        return (royalty.receiver, (_salePrice * royalty.royaltyFraction) / 10000);
    }

    function setRoyaltyInfo(uint256 _tokenId, address receiver, uint256 royaltyFraction) external onlyOwner {
        _royalties[_tokenId] = RoyaltyInfo({receiver: receiver, royaltyFraction: royaltyFraction});
    }

    function pause() external onlyOwner {
        _paused = true;
    }

    function unpause() external onlyOwner {
        _paused = false;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function maxSupply() external view returns (uint256) {
        return _maxSupply;
    }

    function allowMultipleMints() external view returns (bool) {
        return _allowMultipleMints;
    }

    function mintLimit() external view returns (uint256) {
        return _mintLimit;
    }
}