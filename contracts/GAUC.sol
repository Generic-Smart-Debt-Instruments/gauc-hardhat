// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.3 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "gsdi/contracts/GSDIWallet.sol";
import "gsdi/contracts/GSDINFT.sol";

import "./interfaces/IGAUC.sol";

/// @title GSDI Auction house.
/// @author jkp
contract GAUC is IGAUC {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Counters for Counters.Counter;

    event Deposit(
        address indexed sender,
        uint256 _amount,
        address indexed _user
    );
    event Withdraw(address indexed user, uint256 _amount);
    event ERC20AuctionCreate(
        address indexed creator,
        address indexed _token,
        uint256 _amount,
        address _borrower,
        uint256 _auctionEndTimestamp,
        uint256 _maxFaceValue,
        uint256 _minBidIncrement,
        uint256 _maturity,
        uint256 _price,
        address indexed IGSDIWallet
    );
    event ERC721AuctionCreate(
        address indexed creator,
        address indexed _token,
        uint256[] _ids,
        address _borrower,
        uint256 _auctionEndTimestamp,
        uint256 _maxFaceValue,
        uint256 _minBidIncrement,
        uint256 _maturity,
        uint256 _price,
        address indexed IGSDIWallet
    );
    event AuctionCancel(address indexed user, uint256 _auctionId);
    event AuctionBid(address indexed user, uint256 _auctionId, uint256 _amount);
    event AuctionClaim(
        uint256 _auctionId,
        address indexed borrower,
        address indexed lender,
        uint256 _tokenId
    );

    address public dai;
    GSDINFT public gsdiNFT;

    struct AuctionInfo {
        uint256 auctionEndTimestamp;
        uint256 lowestBid;
        uint256 maturity;
        uint256 price;
        uint256 minBidIncrement;
        address IGSDIWallet;
        address lowestBidder;
        address borrower;
        AUCTION_STATUS auctionStatus;
    }

    Counters.Counter private _auctionIdTracker;
    mapping(uint256 => AuctionInfo) public override auctionInfo;
    mapping(address => uint256) public override balance;
    mapping(address => uint256) public override balanceLocked;

    constructor(address _dai, address _gsdiNFT) {
        dai = _dai;
        gsdiNFT = GSDINFT(_gsdiNFT);
    }

    function balanceAvailable(address _user)
        public
        view
        override
        returns (uint256)
    {
        return balance[_user].sub(balanceLocked[_user]);
    }

    function auctionStatus(uint256 _auctionId)
        public
        view
        override
        returns (AUCTION_STATUS)
    {
        AuctionInfo storage auction = getAuctionInfo(_auctionId);

        if (
            auction.auctionEndTimestamp <= block.timestamp &&
            auction.auctionStatus == AUCTION_STATUS.OPEN
        ) {
            if (auction.lowestBidder != address(0)) {
                return AUCTION_STATUS.CLAIMABLE;
            } else {
                return AUCTION_STATUS.EXPIRED;
            }
        }

        return auction.auctionStatus;
    }

    function deposit(uint256 _amount, address _user) public override {
        require(
            IERC20(dai).transferFrom(msg.sender, address(this), _amount),
            "GAUC: Dai transferFrom failed"
        );
        balance[_user] = balance[_user].add(_amount);

        emit Deposit(msg.sender, _amount, _user);
    }

    function withdraw(uint256 _amount) public override {
        uint256 available = balanceAvailable(msg.sender);

        require(available >= _amount, "GAUC: insufficient available balance");

        require(
            IERC20(dai).transfer(msg.sender, _amount),
            "GAUC: Dai transfer failed"
        );
        balance[msg.sender] = balance[msg.sender].sub(_amount);

        emit Withdraw(msg.sender, _amount);
    }

    function createERC20Auction(
        IERC20 _token,
        uint256 _amount,
        address _borrower,
        uint256 _auctionEndTimestamp,
        uint256 _maxFaceValue,
        uint256 _minBidIncrement,
        uint256 _maturity,
        uint256 _price
    ) public override {
        // TODO: deploy proxy
        GSDIWallet wallet = new GSDIWallet();
        wallet.initialize(address(gsdiNFT), address(this));

        require(
            _token.transferFrom(msg.sender, address(wallet), _amount),
            "GAUC: IERC20 transferFrom failed"
        );

        uint256 auctionId = _auctionIdTracker.current();

        auctionInfo[auctionId] = AuctionInfo(
            _auctionEndTimestamp,
            _maxFaceValue,
            _maturity,
            _price,
            _minBidIncrement,
            address(wallet),
            address(0),
            _borrower,
            AUCTION_STATUS.OPEN
        );

        _auctionIdTracker.increment();

        emit ERC20AuctionCreate(
            msg.sender,
            address(_token),
            _amount,
            _borrower,
            _auctionEndTimestamp,
            _maxFaceValue,
            _minBidIncrement,
            _maturity,
            _price,
            address(wallet)
        );
    }

    function createERC721Auction(
        IERC721 _token,
        uint256[] calldata _ids,
        address _borrower,
        uint256 _auctionEndTimestamp,
        uint256 _maxFaceValue,
        uint256 _minBidIncrement,
        uint256 _maturity,
        uint256 _price
    ) public override {
        // TODO: deploy proxy
        GSDIWallet wallet = new GSDIWallet();
        wallet.initialize(address(gsdiNFT), address(this));

        for (uint8 i = 1; i <= _ids.length; i++) {
            _token.safeTransferFrom(msg.sender, address(wallet), _ids[i], "");
        }

        uint256 auctionId = _auctionIdTracker.current();

        auctionInfo[auctionId] = AuctionInfo(
            _auctionEndTimestamp,
            _maxFaceValue,
            _maturity,
            _price,
            _minBidIncrement,
            address(wallet),
            address(0),
            _borrower,
            AUCTION_STATUS.OPEN
        );

        _auctionIdTracker.increment();

        emit ERC721AuctionCreate(
            msg.sender,
            address(_token),
            _ids,
            _borrower,
            _auctionEndTimestamp,
            _maxFaceValue,
            _minBidIncrement,
            _maturity,
            _price,
            address(wallet)
        );
    }

    function cancel(uint256 _auctionId) public override {
        AuctionInfo storage auction = updateAuctionStatus(_auctionId);

        require(
            auction.auctionStatus == AUCTION_STATUS.OPEN ||
                auction.auctionStatus == AUCTION_STATUS.EXPIRED,
            "GAUC: auction not open or expired"
        );
        require(auction.lowestBidder == address(0), "GAUC: bidder exists");

        GSDIWallet(auction.IGSDIWallet).setExecutor(auction.borrower);
        auction.auctionStatus = AUCTION_STATUS.CANCELED;

        emit AuctionCancel(msg.sender, _auctionId);
    }

    function bid(uint256 _auctionId, uint256 _amount) public override {
        AuctionInfo storage auction = updateAuctionStatus(_auctionId);
        uint256 purchasePrice = getPurchasePrice(auction.price);

        require(
            auction.auctionStatus == AUCTION_STATUS.OPEN,
            "GAUC: auction not open"
        );
        require(
            auction.minBidIncrement <= _amount,
            "GAUC: must be at least minBidIncrement"
        );
        require(
            auction.lowestBid.mul(99) >= _amount.mul(100),
            "GAUC: must be 1% lower than lowest bid"
        );
        require(
            msg.sender == auction.lowestBidder ||
                balanceAvailable(msg.sender) >= purchasePrice,
            "GAUC: insufficient balance"
        );

        // unlock prev bidder balance
        balanceLocked[auction.lowestBidder] = balanceLocked[
            auction.lowestBidder
        ]
            .sub(purchasePrice);

        auction.lowestBid = _amount;
        auction.lowestBidder = msg.sender;

        // lock bidder balance
        balanceLocked[msg.sender] = balanceLocked[msg.sender].add(
            purchasePrice
        );

        emit AuctionBid(msg.sender, _auctionId, _amount);
    }

    function claim(uint256 _auctionId) public override {
        AuctionInfo storage auction = updateAuctionStatus(_auctionId);

        require(
            auction.auctionStatus == AUCTION_STATUS.CLAIMABLE,
            "GAUC: auction not claimable"
        );
        require(auction.lowestBidder == msg.sender, "GAUC: invalid claimer");

        uint256 tokenId =
            gsdiNFT.propose(
                auction.maturity,
                auction.lowestBid,
                auction.price,
                GSDIWallet(auction.IGSDIWallet),
                dai,
                auction.borrower
            );

        uint256 purchasePrice = getPurchasePrice(auction.price);
        IERC20(dai).safeApprove(address(gsdiNFT), 0);
        IERC20(dai).safeApprove(address(gsdiNFT), purchasePrice);

        gsdiNFT.purchase(tokenId);

        auction.auctionStatus = AUCTION_STATUS.CLAIMED;

        balance[msg.sender] = balance[msg.sender].sub(purchasePrice);
        balanceLocked[msg.sender] = balanceLocked[msg.sender].sub(
            purchasePrice
        );

        balance[auction.borrower] = balance[auction.borrower].add(
            auction.price
        );

        emit AuctionClaim(
            _auctionId,
            auction.borrower,
            auction.borrower,
            tokenId
        );
    }

    // internal
    function getAuctionInfo(uint256 _auctionId)
        private
        view
        returns (AuctionInfo storage)
    {
        require(
            _auctionId < _auctionIdTracker.current(),
            "GAUC: invalid auction id"
        );

        return auctionInfo[_auctionId];
    }

    function updateAuctionStatus(uint256 _auctionId)
        private
        returns (AuctionInfo storage)
    {
        AuctionInfo storage auction = getAuctionInfo(_auctionId);
        auction.auctionStatus = auctionStatus(_auctionId);

        return auction;
    }

    function getPurchasePrice(uint256 price) internal view returns (uint256) {
        if (gsdiNFT.isFeeEnabled()) {
            return price.add(price.mul(30).div(10000));
        }
        return price;
    }
}
