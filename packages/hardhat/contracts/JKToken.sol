// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

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
    }

    struct TierVestingRate {
        uint256 initialRelease;
        uint256 monthlyRelease;
    }

    mapping(address => VestingSchedule[]) public vestingSchedules;
    mapping(VestingTier => uint256) public tierTotalAllocation;
    mapping(VestingTier => TierVestingRate) public tierVestingRates;

    event TokensVested(address indexed beneficiary, uint256 amount, VestingTier tier);
    event VestingScheduleCreated(address indexed beneficiary, uint256 amount, VestingTier tier);
    event VestingScheduleRevoked(address indexed beneficiary, uint256 revokedAmount, VestingTier tier);
    event VestingScheduleAdjusted(address indexed beneficiary, uint256 scheduleIndex, uint256 newAdjustmentFactor);

    constructor(string memory name_, string memory symbol_, uint256 initialSupply_) ERC20(name_, symbol_) {
        INITIAL_SUPPLY = initialSupply_ * 10**decimals();
        _mint(_msgSender(), INITIAL_SUPPLY);
        
        tierVestingRates[VestingTier.SEED] = TierVestingRate(10, 15);
        tierVestingRates[VestingTier.PRIVATE] = TierVestingRate(15, 17);
        tierVestingRates[VestingTier.PUBLIC] = TierVestingRate(20, 20);
        tierVestingRates[VestingTier.TEAM] = TierVestingRate(0, 10);
        tierVestingRates[VestingTier.ADVISOR] = TierVestingRate(5, 12);
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
        VestingTier tier
    ) public onlyOwner {
        require(beneficiary != address(0), "Beneficiary cannot be zero address");
        require(amount > 0, "Vesting amount must be greater than 0");
        require(duration > 0, "Vesting duration must be greater than 0");
        require(cliffDuration <= duration, "Cliff duration cannot exceed vesting duration");

        _transfer(_msgSender(), address(this), amount);

        vestingSchedules[beneficiary].push(VestingSchedule({
            totalAmount: amount,
            releasedAmount: 0,
            startTime: startTime,
            duration: duration,
            cliffDuration: cliffDuration,
            revoked: false,
            tier: tier,
            adjustmentFactor: 100
        }));

        tierTotalAllocation[tier] = tierTotalAllocation[tier].add(amount);

        emit VestingScheduleCreated(beneficiary, amount, tier);
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

        emit TokensVested(beneficiary, releaseableAmount, schedule.tier);
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

    function getVestedAmount(address beneficiary, uint256 scheduleIndex) public view returns (uint256) {
        require(scheduleIndex < vestingSchedules[beneficiary].length, "Invalid schedule index");
        VestingSchedule memory schedule = vestingSchedules[beneficiary][scheduleIndex];
        if (schedule.revoked) {
            return 0;
        }
        return _calculateVestedAmount(schedule);
    }

    function getReleaseableAmount(address beneficiary, uint256 scheduleIndex) public view returns (uint256) {
        require(scheduleIndex < vestingSchedules[beneficiary].length, "Invalid schedule index");
        VestingSchedule memory schedule = vestingSchedules[beneficiary][scheduleIndex];
        if (schedule.revoked) {
            return 0;
        }
        uint256 vestedAmount = _calculateVestedAmount(schedule);
        return vestedAmount.sub(schedule.releasedAmount);
    }

    function revokeVestingSchedule(address beneficiary, uint256 scheduleIndex) public onlyOwner {
        require(scheduleIndex < vestingSchedules[beneficiary].length, "Invalid schedule index");
        VestingSchedule storage schedule = vestingSchedules[beneficiary][scheduleIndex];
        require(!schedule.revoked, "Vesting schedule already revoked");

        uint256 vestedAmount = _calculateVestedAmount(schedule);
        uint256 revokedAmount = schedule.totalAmount.sub(vestedAmount);

        schedule.revoked = true;
        schedule.totalAmount = vestedAmount;

        if (revokedAmount > 0) {
            _transfer(address(this), _msgSender(), revokedAmount);
            tierTotalAllocation[schedule.tier] = tierTotalAllocation[schedule.tier].sub(revokedAmount);
        }

        emit VestingScheduleRevoked(beneficiary, revokedAmount, schedule.tier);
    }

    function getTotalVestedAmount(address beneficiary) public view returns (uint256) {
        uint256 totalVested = 0;
        for (uint256 i = 0; i < vestingSchedules[beneficiary].length; i++) {
            totalVested = totalVested.add(getVestedAmount(beneficiary, i));
        }
        return totalVested;
    }

    function getTotalReleaseableAmount(address beneficiary) public view returns (uint256) {
        uint256 totalReleaseable = 0;
        for (uint256 i = 0; i < vestingSchedules[beneficiary].length; i++) {
            totalReleaseable = totalReleaseable.add(getReleaseableAmount(beneficiary, i));
        }
        return totalReleaseable;
    }

    function getTierTotalAllocation(VestingTier tier) public view returns (uint256) {
        return tierTotalAllocation[tier];
    }

    function getVestingSchedulesCount(address beneficiary) public view returns (uint256) {
        return vestingSchedules[beneficiary].length;
    }

    function setTierVestingRate(VestingTier tier, uint256 initialRelease, uint256 monthlyRelease) public onlyOwner {
        require(initialRelease <= 100, "Initial release percentage cannot exceed 100");
        require(monthlyRelease <= 100, "Monthly release percentage cannot exceed 100");
        tierVestingRates[tier] = TierVestingRate(initialRelease, monthlyRelease);
    }

    function getTierVestingRate(VestingTier tier) public view returns (uint256, uint256) {
        TierVestingRate memory rate = tierVestingRates[tier];
        return (rate.initialRelease, rate.monthlyRelease);
    }

    function adjustVestingSchedule(address beneficiary, uint256 scheduleIndex, uint256 newAdjustmentFactor) public onlyOwner {
        require(scheduleIndex < vestingSchedules[beneficiary].length, "Invalid schedule index");
        require(newAdjustmentFactor > 0 && newAdjustmentFactor <= 200, "Adjustment factor must be between 1 and 200");
        
        VestingSchedule storage schedule = vestingSchedules[beneficiary][scheduleIndex];
        require(!schedule.revoked, "Cannot adjust revoked schedule");
        
        schedule.adjustmentFactor = newAdjustmentFactor;
        
        emit VestingScheduleAdjusted(beneficiary, scheduleIndex, newAdjustmentFactor);
    }
}