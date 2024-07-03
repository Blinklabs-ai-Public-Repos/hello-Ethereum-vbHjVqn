// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract JKToken is ERC20, Ownable {
    using SafeMath for uint256;

    uint256 private immutable INITIAL_SUPPLY;

    enum VestingTier { SEED, PRIVATE, PUBLIC, TEAM, ADVISOR }

    struct VestingSchedule {
        uint256 totalAmount;
        uint256 releasedAmount;
        uint256 startTime;
        uint256 duration;
        uint256 cliffDuration;
        bool revoked;
        VestingTier tier;
        uint256 adjustmentFactor;
        uint256 performanceMetricId;
    }

    struct TierVestingRate {
        uint256 initialRelease;
        uint256 monthlyRelease;
    }

    struct PerformanceMetric {
        string name;
        uint256 threshold;
        uint256 adjustmentFactor;
    }

    struct StakingInfo {
        uint256 amount;
        uint256 startTime;
        uint256 lastRewardTime;
    }

    mapping(address => VestingSchedule[]) public vestingSchedules;
    mapping(VestingTier => uint256) public tierTotalAllocation;
    mapping(VestingTier => TierVestingRate) public tierVestingRates;
    mapping(uint256 => PerformanceMetric) public performanceMetrics;
    mapping(address => StakingInfo) public stakedTokens;
    uint256 public performanceMetricCount;
    uint256 public stakingRewardRate;
    uint256 public totalStaked;

    event TokensVested(address indexed beneficiary, uint256 amount);
    event VestingScheduleCreated(address indexed beneficiary, uint256 amount);
    event VestingScheduleRevoked(address indexed beneficiary, uint256 revokedAmount);
    event VestingScheduleAdjusted(address indexed beneficiary, uint256 scheduleIndex);
    event PerformanceMetricCreated(uint256 indexed metricId, string name);
    event PerformanceMetricUpdated(uint256 indexed metricId, uint256 newValue);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);

    constructor(string memory name_, string memory symbol_, uint256 initialSupply_) ERC20(name_, symbol_) {
        INITIAL_SUPPLY = initialSupply_ * 10**decimals();
        _mint(_msgSender(), INITIAL_SUPPLY);
        
        tierVestingRates[VestingTier.SEED] = TierVestingRate(10, 15);
        tierVestingRates[VestingTier.PRIVATE] = TierVestingRate(15, 17);
        tierVestingRates[VestingTier.PUBLIC] = TierVestingRate(20, 20);
        tierVestingRates[VestingTier.TEAM] = TierVestingRate(0, 10);
        tierVestingRates[VestingTier.ADVISOR] = TierVestingRate(5, 12);

        stakingRewardRate = 5; // 5% annual reward rate
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    function burn(uint256 amount) public {
        _burn(_msgSender(), amount);
    }

    function createVestingSchedule(
        address beneficiary,
        uint256 amount,
        uint256 startTime,
        uint256 duration,
        uint256 cliffDuration,
        VestingTier tier,
        uint256 performanceMetricId
    ) public onlyOwner {
        require(beneficiary != address(0), "Beneficiary cannot be zero address");
        require(amount > 0, "Vesting amount must be greater than 0");
        require(duration > 0, "Vesting duration must be greater than 0");
        require(cliffDuration <= duration, "Cliff duration cannot exceed vesting duration");
        require(performanceMetricId < performanceMetricCount, "Invalid performance metric ID");

        _transfer(_msgSender(), address(this), amount);

        vestingSchedules[beneficiary].push(VestingSchedule({
            totalAmount: amount,
            releasedAmount: 0,
            startTime: startTime,
            duration: duration,
            cliffDuration: cliffDuration,
            revoked: false,
            tier: tier,
            adjustmentFactor: 100,
            performanceMetricId: performanceMetricId
        }));

        tierTotalAllocation[tier] = tierTotalAllocation[tier].add(amount);

        emit VestingScheduleCreated(beneficiary, amount);
    }

    function releaseVestedTokens(address beneficiary, uint256 scheduleIndex) public {
        require(scheduleIndex < vestingSchedules[beneficiary].length, "Invalid schedule index");
        VestingSchedule storage schedule = vestingSchedules[beneficiary][scheduleIndex];
        require(!schedule.revoked, "Vesting schedule has been revoked");

        uint256 vestedAmount = _calculateVestedAmount(schedule);
        uint256 releaseableAmount = vestedAmount.sub(schedule.releasedAmount);

        require(releaseableAmount > 0, "No tokens available for release");

        schedule.releasedAmount = schedule.releasedAmount.add(releaseableAmount);
        _transfer(address(this), beneficiary, releaseableAmount);

        emit TokensVested(beneficiary, releaseableAmount);
    }

    function _calculateVestedAmount(VestingSchedule memory schedule) private view returns (uint256) {
        if (block.timestamp < schedule.startTime.add(schedule.cliffDuration)) {
            return 0;
        }
        
        TierVestingRate memory rate = tierVestingRates[schedule.tier];
        uint256 initialRelease = schedule.totalAmount.mul(rate.initialRelease).div(100);
        
        if (block.timestamp >= schedule.startTime.add(schedule.duration)) {
            return schedule.totalAmount.mul(schedule.adjustmentFactor).div(100);
        }
        
        uint256 monthsPassed = (block.timestamp.sub(schedule.startTime)).div(30 days);
        uint256 monthlyVesting = schedule.totalAmount.sub(initialRelease).mul(rate.monthlyRelease).div(100);
        uint256 vestedAmount = initialRelease.add(monthlyVesting.mul(monthsPassed));
        
        vestedAmount = vestedAmount.mul(schedule.adjustmentFactor).div(100);
        return vestedAmount > schedule.totalAmount ? schedule.totalAmount : vestedAmount;
    }

    function stake(uint256 amount) public {
        require(amount > 0, "Cannot stake 0 tokens");
        require(balanceOf(_msgSender()) >= amount, "Insufficient balance");

        if (stakedTokens[_msgSender()].amount > 0) {
            claimReward();
        }

        _transfer(_msgSender(), address(this), amount);
        stakedTokens[_msgSender()].amount = stakedTokens[_msgSender()].amount.add(amount);
        stakedTokens[_msgSender()].startTime = block.timestamp;
        stakedTokens[_msgSender()].lastRewardTime = block.timestamp;
        totalStaked = totalStaked.add(amount);

        emit Staked(_msgSender(), amount);
    }

    function unstake(uint256 amount) public {
        require(stakedTokens[_msgSender()].amount >= amount, "Insufficient staked amount");

        claimReward();

        stakedTokens[_msgSender()].amount = stakedTokens[_msgSender()].amount.sub(amount);
        totalStaked = totalStaked.sub(amount);
        _transfer(address(this), _msgSender(), amount);

        emit Unstaked(_msgSender(), amount);
    }

    function claimReward() public {
        StakingInfo storage stakingInfo = stakedTokens[_msgSender()];
        require(stakingInfo.amount > 0, "No staked tokens");

        uint256 reward = calculateReward(_msgSender());
        require(reward > 0, "No reward to claim");

        stakingInfo.lastRewardTime = block.timestamp;
        _mint(_msgSender(), reward);

        emit RewardClaimed(_msgSender(), reward);
    }

    function calculateReward(address user) public view returns (uint256) {
        StakingInfo memory stakingInfo = stakedTokens[user];
        if (stakingInfo.amount == 0) {
            return 0;
        }

        uint256 stakingDuration = block.timestamp.sub(stakingInfo.lastRewardTime);
        return stakingInfo.amount.mul(stakingRewardRate).mul(stakingDuration).div(365 days).div(100);
    }

    function setStakingRewardRate(uint256 newRate) public onlyOwner {
        require(newRate > 0, "Reward rate must be greater than 0");
        stakingRewardRate = newRate;
    }
}

contract JKLoyaltyProgram is ERC721Enumerable, Ownable {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;

    bool public isTransferable;
    JKToken public jkToken;

    mapping(uint256 => uint256) public tokenPoints;

    event RewardMinted(address indexed user, uint256 tokenId, uint256 points);
    event RewardRedeemed(address indexed user, uint256 tokenId, uint256 points);
    event TransferabilitySet(bool isTransferable);

    constructor(string memory name_, string memory symbol_, address jkTokenAddress) ERC721(name_, symbol_) {
        jkToken = JKToken(jkTokenAddress);
        isTransferable = false;
    }

    function mintReward(address user, uint256 points) public onlyOwner {
        _tokenIds.increment();
        uint256 newTokenId = _tokenIds.current();
        _safeMint(user, newTokenId);
        tokenPoints[newTokenId] = points;

        emit RewardMinted(user, newTokenId, points);
    }

    function redeemReward(uint256 tokenId) public {
        require(_exists(tokenId), "Token does not exist");
        require(ownerOf(tokenId) == _msgSender(), "Not the owner of the token");

        uint256 points = tokenPoints[tokenId];
        require(points > 0, "No points associated with this token");

        delete tokenPoints[tokenId];
        _burn(tokenId);

        jkToken.mint(_msgSender(), points);

        emit RewardRedeemed(_msgSender(), tokenId, points);
    }

    function setTransferable(bool _isTransferable) public onlyOwner {
        isTransferable = _isTransferable;
        emit TransferabilitySet(_isTransferable);
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId, uint256 batchSize)
        internal
        override(ERC721Enumerable)
    {
        require(isTransferable || from == address(0) || to == address(0), "Transfers are currently disabled");
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Enumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}