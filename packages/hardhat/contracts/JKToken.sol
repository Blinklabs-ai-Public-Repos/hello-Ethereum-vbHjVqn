// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract JKToken is ERC20, Ownable {
    using SafeMath for uint256;

    uint256 private immutable INITIAL_SUPPLY;

    struct VestingSchedule {
        uint256 totalAmount;
        uint256 releasedAmount;
        uint256 startTime;
        uint256 duration;
        uint256 cliffDuration;
        bool revoked;
    }

    mapping(address => VestingSchedule) public vestingSchedules;

    event TokensVested(address indexed beneficiary, uint256 amount);
    event VestingScheduleCreated(address indexed beneficiary, uint256 amount);
    event VestingScheduleRevoked(address indexed beneficiary, uint256 revokedAmount);
    event VestingScheduleModified(address indexed beneficiary, uint256 newAmount, uint256 newDuration, uint256 newCliffDuration);

    constructor(string memory name_, string memory symbol_, uint256 initialSupply_) ERC20(name_, symbol_) {
        INITIAL_SUPPLY = initialSupply_ * 10**decimals();
        _mint(_msgSender(), INITIAL_SUPPLY);
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
        uint256 cliffDuration
    ) public onlyOwner {
        require(beneficiary != address(0), "Beneficiary cannot be zero address");
        require(amount > 0, "Vesting amount must be greater than 0");
        require(duration > 0, "Vesting duration must be greater than 0");
        require(cliffDuration <= duration, "Cliff duration cannot exceed vesting duration");

        VestingSchedule storage schedule = vestingSchedules[beneficiary];
        require(schedule.totalAmount == 0, "Vesting schedule already exists for beneficiary");

        _transfer(_msgSender(), address(this), amount);

        vestingSchedules[beneficiary] = VestingSchedule({
            totalAmount: amount,
            releasedAmount: 0,
            startTime: startTime,
            duration: duration,
            cliffDuration: cliffDuration,
            revoked: false
        });

        emit VestingScheduleCreated(beneficiary, amount);
    }

    function releaseVestedTokens(address beneficiary) public {
        VestingSchedule storage schedule = vestingSchedules[beneficiary];
        require(schedule.totalAmount > 0, "No vesting schedule found for beneficiary");
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
        if (block.timestamp >= schedule.startTime.add(schedule.duration)) {
            return schedule.totalAmount;
        }
        return schedule.totalAmount.mul(block.timestamp.sub(schedule.startTime)).div(schedule.duration);
    }

    function getVestedAmount(address beneficiary) public view returns (uint256) {
        VestingSchedule memory schedule = vestingSchedules[beneficiary];
        if (schedule.revoked) {
            return 0;
        }
        return _calculateVestedAmount(schedule);
    }

    function getReleaseableAmount(address beneficiary) public view returns (uint256) {
        VestingSchedule memory schedule = vestingSchedules[beneficiary];
        if (schedule.revoked) {
            return 0;
        }
        uint256 vestedAmount = _calculateVestedAmount(schedule);
        return vestedAmount.sub(schedule.releasedAmount);
    }

    function revokeVestingSchedule(address beneficiary) public onlyOwner {
        VestingSchedule storage schedule = vestingSchedules[beneficiary];
        require(schedule.totalAmount > 0, "No vesting schedule found for beneficiary");
        require(!schedule.revoked, "Vesting schedule already revoked");

        uint256 vestedAmount = _calculateVestedAmount(schedule);
        uint256 revokedAmount = schedule.totalAmount.sub(vestedAmount);

        schedule.revoked = true;
        schedule.totalAmount = vestedAmount;

        if (revokedAmount > 0) {
            _transfer(address(this), _msgSender(), revokedAmount);
        }

        emit VestingScheduleRevoked(beneficiary, revokedAmount);
    }

    function modifyVestingSchedule(
        address beneficiary,
        uint256 newAmount,
        uint256 newDuration,
        uint256 newCliffDuration
    ) public onlyOwner {
        VestingSchedule storage schedule = vestingSchedules[beneficiary];
        require(schedule.totalAmount > 0, "No vesting schedule found for beneficiary");
        require(!schedule.revoked, "Cannot modify revoked vesting schedule");
        require(newAmount > 0, "New vesting amount must be greater than 0");
        require(newDuration > 0, "New vesting duration must be greater than 0");
        require(newCliffDuration <= newDuration, "New cliff duration cannot exceed new vesting duration");

        uint256 vestedAmount = _calculateVestedAmount(schedule);
        require(newAmount >= vestedAmount, "New amount cannot be less than already vested amount");

        if (newAmount > schedule.totalAmount) {
            uint256 additionalAmount = newAmount.sub(schedule.totalAmount);
            _transfer(_msgSender(), address(this), additionalAmount);
        } else if (newAmount < schedule.totalAmount) {
            uint256 excessAmount = schedule.totalAmount.sub(newAmount);
            _transfer(address(this), _msgSender(), excessAmount);
        }

        schedule.totalAmount = newAmount;
        schedule.duration = newDuration;
        schedule.cliffDuration = newCliffDuration;

        emit VestingScheduleModified(beneficiary, newAmount, newDuration, newCliffDuration);
    }
}