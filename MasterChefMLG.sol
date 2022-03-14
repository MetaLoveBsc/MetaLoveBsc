pragma solidity 0.6.12;

import './lib/SafeMath.sol';
import './lib/IBEP20.sol';
import './lib/SafeBEP20.sol';
import './lib/Ownable.sol';
import './lib/ReentrancyGuard.sol';

import './MetaLoveGoldToken.sol';

// MasterChef is the master of MLG. He can make MLG and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once MLG is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChefMLG is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 rewardLockedUp;  // Reward locked up.
        uint256 nextHarvestUntil; // When can the user harvest again.
        //
        // We do some fancy math here. Basically, any point in time, the amount of MLGs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accMLGPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accMLGPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. MLGs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that MLGs distribution occurs.
        uint256 accMLGPerShare; // Accumulated MLGs per share, times 1e24. See below.
        uint16 depositFeeBP; // Deposit fee in basis points
        uint256 harvestInterval;  // Harvest interval in seconds
        uint256 lpSupply;  // Current LP Supply
    }

    // The MLG TOKEN!
    MetaLoveGoldToken public immutable mlg;
    // MLG tokens created per block.
    uint256 public immutable mlgPerBlock;
    // Deposit Fee address
    address public feeAddress;
    // Max harvest interval: 4 hours.
    uint256 public constant MAXIMUM_HARVEST_INTERVAL = 4 hours;
    // Max alloc point
    uint256 public constant MAX_ALLOC_POINT = 3500;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when MLG mining starts.
    uint256 public immutable startBlock;
    // The block number when Reward mining ends.
    uint256 public immutable endBlock;
    // Total locked up rewards
    uint256 public totalLockedUpRewards;
    // Referral Bonus in basis points. Initially set to 3%
    uint256 public refBonusBP = 300;
    // Max referral commission rate: 5%.
    uint16 public constant MAXIMUM_REFERRAL_BP = 500;
    // Referral Mapping
    mapping(address => address) public referrers; // account_address -> referrer_address
    mapping(address => uint256) public referredCount; // referrer_address -> num_of_referred
    // Max deposit fee: 5%.
    uint16 public constant MAXIMUM_DEPOSIT_FEE_BP = 500;
    // Max emission rate
    uint256 public constant MAX_EMISSION_RATE = 1 ether;
    // Pool Exists Mapper
    mapping(IBEP20 => bool) public poolExistence;

    event AddPool(IBEP20 lpToken, uint256 allocPoint, uint256 lastRewardBlock, uint256 accMLGPerShare, uint16 depositFeeBP, uint256 harvestInterval);
    event SetPool(uint256 pid, uint256 allocPoint, uint16 depositFeeBP, uint256 harvestInterval, bool withUpdate);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetFeeAddress(address indexed user, address indexed _feeAddress);
    event RewardLockedUp(address indexed user, uint256 indexed pid, uint256 amountLockedUp);
    event ReferralSet(address indexed _referrer, address indexed _user);
    event ReferralPaid(address indexed _user, address indexed _userTo, uint256 _reward);
    event ReferralBonusBpChanged(uint256 _oldBp, uint256 _newBp);

    constructor(
        MetaLoveGoldToken _mlg,
        address _feeAddress,
        uint256 _mlgPerBlock,
        uint256 _startBlock,
        uint256 _endBlock
    ) public {
        require(address(_mlg) != address(0));
        require(_feeAddress != address(0));
        require(_mlgPerBlock <= MAX_EMISSION_RATE, "Tokens per block more than allowed");
        require(_startBlock > block.number, "Start block must be higher than current");
        require(_endBlock > _startBlock, "The end block must be larger than the start block");

        mlg = _mlg;
        feeAddress = _feeAddress;
        mlgPerBlock = _mlgPerBlock;
        startBlock = _startBlock;
        endBlock = _endBlock;

        // staking pool
        poolInfo.push(PoolInfo({
            lpToken: _mlg,
            allocPoint: 1000,
            lastRewardBlock: _startBlock,
            accMLGPerShare: 0,
            depositFeeBP: 0,
            harvestInterval: 4 hours,
            lpSupply: 0
        }));

        poolExistence[_mlg] = true;

        emit AddPool(_mlg, 1000, _startBlock, 0, 0, 4 hours);

        totalAllocPoint = 1000;

    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Modifier to check Duplicate pools
    modifier nonDuplicated(IBEP20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, uint256 _harvestInterval, bool _withUpdate) external onlyOwner nonDuplicated(_lpToken) {
        require(_depositFeeBP <= MAXIMUM_DEPOSIT_FEE_BP, "add: invalid deposit fee basis points");
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "add: invalid harvest interval");
        require(_allocPoint <= MAX_ALLOC_POINT, "add: invalid alloc point");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[_lpToken] = true;
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accMLGPerShare: 0,
            depositFeeBP: _depositFeeBP,
            harvestInterval: _harvestInterval,
            lpSupply: 0
        }));

        emit AddPool(_lpToken, _allocPoint, lastRewardBlock, 0, _depositFeeBP, _harvestInterval);
    }

    // Update the given pool's MLG allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, uint256 _harvestInterval, bool _withUpdate) external onlyOwner {
        require(_depositFeeBP <= MAXIMUM_DEPOSIT_FEE_BP, "set: invalid deposit fee basis points");
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "set: invalid harvest interval");
        require(_allocPoint <= MAX_ALLOC_POINT, "set: invalid alloc point");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].harvestInterval = _harvestInterval;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
        }

        emit SetPool(_pid, _allocPoint, _depositFeeBP, _harvestInterval, _withUpdate);
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_to <= endBlock) {
            return _to.sub(_from);
        } else if (_from >= endBlock) {
            return 0;
        } else {
            return endBlock.sub(_from);
        }
    }

    // View function to see pending MLGs on frontend.
    function pendingReward(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accMLGPerShare = pool.accMLGPerShare;
        uint256 lpSupply = pool.lpSupply;
        if (block.number > pool.lastRewardBlock && lpSupply != 0 && totalAllocPoint != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 mlgReward = multiplier.mul(mlgPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accMLGPerShare = accMLGPerShare.add(mlgReward.mul(1e24).div(lpSupply));
        }
        uint256 pending = user.amount.mul(accMLGPerShare).div(1e24).sub(user.rewardDebt);
        return pending.add(user.rewardLockedUp);
    }

    // View function to see if user can harvest MLG's.
    function canHarvest(uint256 _pid, address _user) public view returns (bool) {
        UserInfo storage user = userInfo[_pid][_user];
        return block.timestamp >= user.nextHarvestUntil;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpSupply;
        if (lpSupply == 0 || totalAllocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 mlgReward = multiplier.mul(mlgPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        mlg.mint(feeAddress, mlgReward.div(3));
        mlg.mint(address(this), mlgReward);
        pool.accMLGPerShare = pool.accMLGPerShare.add(mlgReward.mul(1e24).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for MLG allocation.
    function deposit(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        payOrLockupPendingCryptoMLG(_pid);
        if (_amount > 0) {
            uint256 balanceBefore = pool.lpToken.balanceOf(address(this));
            pool.lpToken.safeTransferFrom(msg.sender, address(this), _amount);
            _amount = pool.lpToken.balanceOf(address(this)).sub(balanceBefore);
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                user.amount = user.amount.add(_amount).sub(depositFee);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
            pool.lpSupply = pool.lpSupply.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMLGPerShare).div(1e24);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Deposit LP tokens to MasterChef for MLG allocation with referral.
    function deposit(uint256 _pid, uint256 _amount, address _referrer) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        payOrLockupPendingCryptoMLG(_pid);
        if (_amount > 0) {
            setReferral(msg.sender, _referrer);
            uint256 balanceBefore = pool.lpToken.balanceOf(address(this));
            pool.lpToken.safeTransferFrom(msg.sender, address(this), _amount);
            _amount = pool.lpToken.balanceOf(address(this)).sub(balanceBefore);
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                user.amount = user.amount.add(_amount).sub(depositFee);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
            pool.lpSupply = pool.lpSupply.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMLGPerShare).div(1e24);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        payOrLockupPendingCryptoMLG(_pid);
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(msg.sender, _amount);
            pool.lpSupply = pool.lpSupply.sub(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMLGPerShare).div(1e24);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(msg.sender, user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        pool.lpSupply = pool.lpSupply.sub(user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Pay or lockup pending MLG's.
    function payOrLockupPendingCryptoMLG(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.nextHarvestUntil == 0) {
            if (block.number >= startBlock) {
                user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);
            } else {
                //1 Block every 3 seconds aprox;
                uint256 aproxSecondsToRewardsStarts = startBlock.sub(block.number).mul(3);
                user.nextHarvestUntil = block.timestamp.add(aproxSecondsToRewardsStarts).add(pool.harvestInterval);
            }
        }

        uint256 pending = user.amount.mul(pool.accMLGPerShare).div(1e24).sub(user.rewardDebt);
        if (canHarvest(_pid, msg.sender)) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                uint256 totalRewards = pending.add(user.rewardLockedUp);
                totalLockedUpRewards = totalLockedUpRewards.sub(user.rewardLockedUp);
                user.rewardLockedUp = 0;
                user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);

                safeMLGTransfer(msg.sender, totalRewards);
                payReferralCommission(msg.sender, totalRewards);
            }
        } else if (pending > 0) {
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            totalLockedUpRewards = totalLockedUpRewards.add(pending);
            emit RewardLockedUp(msg.sender, _pid, pending);
        }
    }

    // Safe mlg transfer function, just in case if rounding error causes pool to not have enough MLGs.
    function safeMLGTransfer(address _to, uint256 _amount) internal {
        uint256 mlgBalance = mlg.balanceOf(address(this));
        if (_amount > mlgBalance) {
            mlg.transfer(_to, mlgBalance);
        } else {
            mlg.transfer(_to, _amount);
        }
    }

    // Update fee address by the previous fee address.
    function setFeeAddress(address _feeAddress) external {
        require(_feeAddress != address(0), "setFeeAddress: invalid address");
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }

    // Set Referral Address for a user
    function setReferral(address _user, address _referrer) internal {
        if (_referrer == address(_referrer) && referrers[_user] == address(0) && _referrer != address(0) && _referrer != _user) {
            referrers[_user] = _referrer;
            referredCount[_referrer] += 1;
            emit ReferralSet(_referrer, _user);
        }
    }

    // Get Referrer Address for a Account
    function getReferrer(address _user) public view returns (address) {
        return referrers[_user];
    }

    // Pay referrer commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        address referrer = getReferrer(_user);
        if (referrer != address(0) && referrer != _user && refBonusBP > 0) {
            uint256 refBonusEarned = _pending.mul(refBonusBP).div(10000);
            mlg.mint(referrer, refBonusEarned);
            emit ReferralPaid(_user, referrer, refBonusEarned);
        }
    }

    // Referral Bonus in basis points.
    function updateReferralBonusBp(uint256 _newRefBonusBp) external onlyOwner {
        require(_newRefBonusBp <= MAXIMUM_REFERRAL_BP, "updateReferralBonusBp: invalid referral bonus, no changes");
        require(_newRefBonusBp != refBonusBP, "updateReferralBonusBp: same bonus bp, no changes");
        uint256 previousRefBonusBP = refBonusBP;
        refBonusBP = _newRefBonusBp;
        emit ReferralBonusBpChanged(previousRefBonusBP, _newRefBonusBp);
    }
}