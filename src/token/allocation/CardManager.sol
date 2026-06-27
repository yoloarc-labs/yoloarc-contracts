// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgrades/contracts/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-upgrades/contracts/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin-upgrades/contracts/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
import "@openzeppelin-upgrades/contracts/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";

import {CardManagerStorage} from "./CardManagerStorage.sol";

contract CardManager is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    ERC721Upgradeable,
    ERC721BurnableUpgradeable,
    ERC721URIStorageUpgradeable,
    CardManagerStorage
{
    using SafeERC20 for IERC20;

    string private constant CARD_NAME = "YoloArc Card";
    string private constant CARD_SYMBOL = "Yolo Card";
    uint256 private constant MIN_TRANSFERABLE_BALANCE = 16;

    constructor() {
        _disableInitializers();
    }

    modifier onlyManager() {
        require(msg.sender == manager, "onlyManager");
        _;
    }

    modifier onlyFundManager() {
        require(msg.sender == fundManager, "onlyFundManager");
        _;
    }

    modifier onlyContractCaller() {
        require(msg.sender == contractCaller, "onlyContractCaller");
        _;
    }

    receive() external payable {
        require(!paused(), "Pausable: paused");
        fundingBalance[NativeTokenAddress] += msg.value;
        emit Deposit(NativeTokenAddress, msg.sender, msg.value);
    }

    function initialize(address initialOwner, address _manager,  address _contractCaller, address _underlyingToken,  string memory _nftJson) public initializer {
        __Ownable_init(initialOwner);
        __ERC721_init(CARD_NAME, CARD_SYMBOL);
        __ERC721Burnable_init();
        __ERC721URIStorage_init();
        manager = _manager;
        contractCaller = _contractCaller;
        underlyingToken = _underlyingToken;
        nftJson = _nftJson;
    }

    function setManager(address _manager) external onlyOwner {
        require(_manager != address(0), "CardManager: manager cannot be zero address");
        manager = _manager;
    }

    function setContractCaller(address _contractCaller) external onlyOwner {
        require(_contractCaller != address(0), "CardManager: manager cannot be zero address");
        contractCaller = _contractCaller;
    }

    function setFundManager(address _fundManager) external onlyOwner {
        require(_fundManager != address(0), "CardManager: fund manager cannot be zero address");
        fundManager = _fundManager;
    }

    function updateFundingBalance(address tokenAddress, uint256 amount) external onlyOwner {
        require(tokenAddress != address(0), "CardManager: token address cannot be zero address");
        fundingBalance[tokenAddress] += amount;
    }

    function deposit() external payable whenNotPaused returns (bool) {
        fundingBalance[NativeTokenAddress] += msg.value;
        emit Deposit(NativeTokenAddress, msg.sender, msg.value);
        return true;
    }

    function depositRewardErc20(address tokenAddress, address feePayer, uint256 amount) external whenNotPaused returns (bool) {
        require(amount > 0, "CardManager: depositRewardErc20 invalid amount");
        require(tokenAddress != address(0), "CardManager: depositRewardErc20 token address is zero address");

        IERC20 token = IERC20(tokenAddress);

        token.safeTransferFrom(feePayer, address(this), amount);

        fundingBalance[tokenAddress] += amount;

        emit Deposit(tokenAddress, feePayer, amount);

        return true;
    }

    function withdraw(address payable withdrawAddress, uint256 amount)
        external
        payable
        whenNotPaused
        onlyFundManager
        returns (bool)
    {
        require(
            address(this).balance >= amount,
            "CardManager withdraw: insufficient native token balance in contract"
        );
        fundingBalance[NativeTokenAddress] -= amount;
        (bool success,) = withdrawAddress.call{value: amount}("");
        if (!success) {
            return false;
        }
        emit Withdraw(NativeTokenAddress, msg.sender, withdrawAddress, amount);
        return true;
    }

    function withdrawErc20(address recipient, uint256 amount) external whenNotPaused onlyFundManager returns (bool) {
        require(
            amount <= _tokenBalance(), "CardManager: withdraw erc20 amount more token balance in this contracts"
        );

        IERC20(underlyingToken).safeTransfer(recipient, amount);

        emit Withdraw(underlyingToken, msg.sender, recipient, amount);

        return true;
    }

    function validatorMine(address tokenAddress, address[] calldata miner, uint256[] calldata amount) external onlyContractCaller {
        uint256 length = miner.length;
        require(length == amount.length, "CardManager: miner and amount length mismatch");

        for (uint256 i = 0; i < length;) {
            validatorBalance[tokenAddress][miner[i]] += amount[i];
            emit ValidatorMine(tokenAddress, miner[i], amount[i]);
            unchecked {
                ++i;
            }
        }
    }

    function validatorMineClaim(address tokenAddress, uint256 amount) external {
        require(validatorBalance[tokenAddress][msg.sender] >= amount, "CardManager: validator balance is not enough");

        validatorBalance[tokenAddress][msg.sender] -= amount;

        IERC20(tokenAddress).safeTransfer(msg.sender, amount);

        emit ValidatorMineClaim(tokenAddress, msg.sender, amount);
    }

    function buyCard(uint256 amount) external nonReentrant returns (bool, uint256) {
        uint256[] memory tokenIds = _buyCards(msg.sender, 1, amount);
        return (true, tokenIds[0]);
    }

    function buyCards(uint256 quantity, uint256 amount) external nonReentrant returns (bool, uint256[] memory) {
        return (true, _buyCards(msg.sender, quantity, amount));
    }

    function freeMintCards(address receiver, uint256 quantity) external onlyOwner returns (bool, uint256[] memory) {
        return (true, _freeMints(receiver, quantity));
    }

    function tokenURI(uint256 tokenId) public view override(ERC721Upgradeable, ERC721URIStorageUpgradeable) returns (string memory) {
        require(_ownerOf(tokenId) != address(0), "ERC721Metadata: URI query for nonexistent token");
        return nftJson;
    }

    function uri(uint256 inputTokenId) public view virtual returns (string memory) {
        return tokenURI(inputTokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function cardPrice() public view returns (uint256) {
        uint256 tier = _nextTokenId / 10000;
        return minAmount * (100 + (tier * 20)) / 100;
    }

    function pause() external onlyManager {
        _pause();
    }

    function unpause() external onlyManager {
        _unpause();
    }

    // ========= internal =========
    function _buyCards(address buyer, uint256 quantity, uint256 amount) internal returns (uint256[] memory tokenIds) {
        require(quantity > 0, "CardManager buyCards: quantity must be greater than zero");

        uint256 totalPrice = _batchCardPrice(quantity);

        require(
            IERC20(underlyingToken).allowance(buyer, address(this)) >= totalPrice,
            "CardManager buyCard: User allowance must more than price"
        );
        require(amount >= totalPrice, "CardManager buyCard: amount must be more than price");

        IERC20(underlyingToken).safeTransferFrom(buyer, address(this), totalPrice);

        tokenIds = new uint256[](quantity);

        for (uint256 i = 0; i < quantity;) {
            tokenIds[i] = _mintCard(buyer);
            unchecked {
                ++i;
            }
        }
    }

    function _freeMints(address buyer, uint256 quantity) internal returns (uint256[] memory tokenIds) {
        require(quantity > 0, "CardManager freeMints: quantity must be greater than zero");

        tokenIds = new uint256[](quantity);

        for (uint256 i = 0; i < quantity;) {
            tokenIds[i] = _mintCard(buyer);
            unchecked {
                ++i;
            }
        }
    }

    function _batchCardPrice(uint256 quantity) internal view returns (uint256 totalPrice) {
        uint256 nextTokenId = _nextTokenId;

        for (uint256 i = 0; i < quantity;) {
            uint256 tier = nextTokenId / 10000;
            totalPrice += minAmount * (100 + (tier * 20)) / 100;
            unchecked {
                ++nextTokenId;
                ++i;
            }
        }
        return totalPrice;
    }

    function _mintCard(address buyer) internal returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _safeMint(buyer, tokenId);
        emit CreateNFT(buyer, tokenId, nftJson);
    }

//    function _update(address to, uint256 tokenId, address auth)
//        internal
//        override(ERC721Upgradeable)
//        returns (address)
//    {
//        address from = _ownerOf(tokenId);
//
//        if (from != address(0) && to != address(0)) {
//            require(
//                balanceOf(from) >= MIN_TRANSFERABLE_BALANCE,
//                "CardManager: holder must own at least 16 NFTs to transfer"
//            );
//        }
//
//        return super._update(to, tokenId, auth);
//    }

    function _tokenBalance() internal view virtual returns (uint256) {
        return IERC20(underlyingToken).balanceOf(address(this));
    }
}
